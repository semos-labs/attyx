// Attyx — agent orchestration client (`attyx agent send` / `attyx agent await`)
//
// Submits a prompt to the agent in a pane and blocks until that agent's turn
// completes, returning the outcome (and optionally the turn's output + token
// cost). Pure client-side orchestration over existing IPC primitives — a
// precondition `list_agents` snapshot, `send_keys` to submit, the `watch agents`
// stream to detect completion, and `get_text --since` to capture output. No
// server blocking, no new long-lived server state.
//
// The turn detector (`Machine`) is a pure function over status frames so it can
// be unit-tested without a real agent. Orchestration is added below it.

const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol.zig");
const client = @import("client.zig");
const IpcRequest = @import("../config/cli_ipc.zig").IpcRequest;

const POLLIN: i16 = 0x0001;

// The pure turn detector lives in its own module (no IO, unit-tested there).
// Re-exported so this file's orchestration and external callers keep one import.
const machine_mod = @import("client_agent_machine.zig");
pub const State = machine_mod.State;
pub const Outcome = machine_mod.Outcome;
pub const Machine = machine_mod.Machine;

// ---------------------------------------------------------------------------
// Orchestration. Composes the same primitives — list_agents (snapshot),
// get_text --since (capture), write_input (submit), and the watch stream
// (completion) — over one of two transports. Without -s they go to the attached
// window's IPC socket; with -s they route through the daemon to the target
// session (the daemon holds every session's engine, attached or not), so
// `agent send/await` work headlessly against any session.
// ---------------------------------------------------------------------------

const keys = @import("keys.zig");
const json = std.json;
const dproto = @import("../app/daemon/protocol.zig");
const session_connect = @import("../app/session_connect.zig");
const client_daemon = @import("client_daemon.zig");
const agent_read = @import("client_agent_read.zig");

/// The turn's last assistant message, read from the transcript (like `agent
/// read`). The status hook can fire `idle` before the agent flushes its final
/// line, so we poll until a message past `baseline` lands — returning just the
/// newest one — then fall back to a best-effort read at the deadline. Returns
/// null only if the agent has no transcript at all (caller scrapes the screen).
fn captureTurnMessage(a: std.mem.Allocator, parsed: IpcRequest, baseline: ?usize) ?[]const u8 {
    const deadline = std.time.milliTimestamp() + capture_flush_wait_ms;
    var saw_transcript = false;
    while (true) {
        // Per-iteration arena: the transcript can be large and we read it many
        // times, so free each read instead of growing the caller's arena.
        var it = std.heap.ArenaAllocator.init(a);
        defer it.deinit();
        var newest: ?[]const u8 = null;
        if (agent_read.allMessages(it.allocator(), parsed)) |msgs| {
            saw_transcript = true;
            if (msgs.len > 0) {
                newest = msgs[msgs.len - 1];
                // A message past the baseline = this turn's output is in.
                if (baseline == null or msgs.len > baseline.?) {
                    return a.dupe(u8, msgs[msgs.len - 1]) catch null;
                }
            }
        }
        if (std.time.milliTimestamp() >= deadline) {
            // Flush never grew the transcript: best-effort newest, else give up.
            if (newest) |n| return a.dupe(u8, n) catch null;
            return if (saw_transcript) "" else null;
        }
        std.Thread.sleep(capture_poll_ms * std.time.ns_per_ms);
    }
}

/// Where the orchestration primitives are sent. `session == 0` is the attached
/// window (direct IPC); non-zero routes every primitive through the daemon's ctl
/// channel for that session.
const Ctx = struct {
    sock: []const u8,
    session: u32 = 0,
    fn daemon(self: Ctx) bool {
        return self.session != 0;
    }
};

/// Pick the transport: the daemon for any -s target, else the attached window.
/// `sock_buf` backs the returned socket path, so it must outlive the Ctx.
fn resolveCtx(parsed: IpcRequest, sock_buf: *[256]u8) Error!Ctx {
    if (parsed.target_session != 0) {
        const sock = session_connect.getSocketPath(sock_buf) orelse return Error.NoInstance;
        return .{ .sock = sock, .session = parsed.target_session };
    }
    const sock = client.discoverSocket(sock_buf, parsed.target_pid) orelse return Error.NoInstance;
    return .{ .sock = sock, .session = 0 };
}

/// One daemon ctl round-trip; reply body owned by `a`, null on any failure.
fn daemonCtl(a: std.mem.Allocator, ctx: Ctx, op: dproto.CtlOp, body: []const u8, resp_cap: usize) ?[]const u8 {
    const buf = a.alloc(u8, resp_cap) catch return null;
    const reply = client_daemon.ctl(ctx.sock, ctx.session, op, body, buf) catch return null;
    if (reply.status != 0) return null;
    return reply.body;
}

const Usage = struct {
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    cache_read_tokens: ?u64 = null,
    cost_usd: ?f64 = null,
    cost_is_estimate: bool = false,
};
const Rec = struct {
    pane_id: u32 = 0,
    session: u32 = 0,
    state: []const u8 = "none",
    message: []const u8 = "",
    usage: Usage = .{},
};
const SinceResp = struct {
    cursor: []const u8 = "",
    text: []const u8 = "",
    truncated: bool = false,
    reset: bool = false,
    rows: u64 = 0,
};

pub const Result = struct {
    pane: u32,
    session: u32,
    outcome: Outcome,
    duration_ms: i64,
    message: []const u8 = "",
    output: ?[]const u8 = null,
    truncated: bool = false,
    tokens: ?TokenDelta = null,
};
const TokenDelta = struct {
    input: u64,
    output: u64,
    cache_read: u64,
    cost_usd: ?f64,
    cost_is_estimate: bool,
};

const default_start_grace_ms: i64 = 3000;
const default_timeout_ms: i64 = 600_000;
const poll_ms: i32 = 250;
// --capture reads the turn's last message from the transcript, but the agent's
// status can flip to idle before its final assistant line is flushed to the
// JSONL. Poll up to `capture_flush_wait_ms` (at `capture_poll_ms` intervals) for
// a message past the pre-turn baseline before giving up.
const capture_flush_wait_ms: i64 = 3000;
const capture_poll_ms: u64 = 100;

const Error = error{ NoInstance, IpcFailed, NotAnAgent, Busy };

/// A persistent watch-stream connection, polled with a timeout so the state
/// machine's deadlines can fire between frames.
const WatchStream = struct {
    fd: posix.fd_t,
    is_daemon: bool,
    payload_buf: [65536]u8 = undefined,

    fn open(ctx: Ctx, pane_id: u32) !WatchStream {
        const fd = try client.connectToSocket(ctx.sock);
        errdefer protocol.closeFd(fd);
        if (ctx.daemon()) {
            // Daemon watch request: [target_session:u32 LE][pane_filter:u32 LE].
            var pl: [8]u8 = undefined;
            std.mem.writeInt(u32, pl[0..4], ctx.session, .little);
            std.mem.writeInt(u32, pl[4..8], pane_id, .little);
            var rb: [dproto.header_size + 8]u8 = undefined;
            const req = try dproto.encodeMessage(&rb, .watch_agents, &pl);
            try protocol.writeAll(fd, req);
        } else {
            var pl: [4]u8 = undefined;
            std.mem.writeInt(u32, &pl, pane_id, .little);
            var rb: [protocol.header_size + 4]u8 = undefined;
            const req = try protocol.encodeMessage(&rb, .watch_agents, &pl);
            try protocol.writeAll(fd, req);
        }
        return .{ .fd = fd, .is_daemon = ctx.daemon() };
    }
    fn close(self: *WatchStream) void {
        protocol.closeFd(self.fd);
    }

    // Both protocols share the 5-byte header (len:u32 LE, type:u8). The window
    // stream sends one agent-JSON frame per message; the daemon wraps each in an
    // `agent_event` and may interleave other control frames, so on the daemon
    // path we keep only agent_event and treat `err` as end-of-stream.
    const agent_event_type: u8 = @intFromEnum(dproto.MessageType.agent_event);
    const daemon_err_type: u8 = @intFromEnum(dproto.MessageType.err);

    const Next = union(enum) { frame: []const u8, none, eof };
    fn pollNext(self: *WatchStream, timeout: i32) Next {
        var pfd = [_]posix.pollfd{.{ .fd = self.fd, .events = POLLIN, .revents = 0 }};
        const r = posix.poll(&pfd, timeout) catch return .eof;
        if (r == 0) return .none;
        var hdr: [protocol.header_size]u8 = undefined;
        protocol.readExact(self.fd, &hdr) catch return .eof;
        const payload_len = std.mem.readInt(u32, hdr[0..4], .little);
        const type_byte = hdr[4];
        if (payload_len == 0) return .none;
        if (payload_len > self.payload_buf.len) return .eof;
        protocol.readExact(self.fd, self.payload_buf[0..payload_len]) catch return .eof;
        if (self.is_daemon) {
            if (type_byte == daemon_err_type) return .eof;
            if (type_byte != agent_event_type) return .none; // skip other control frames
        }
        return .{ .frame = self.payload_buf[0..payload_len] };
    }
};

fn parseRec(a: std.mem.Allocator, line: []const u8) ?Rec {
    const t = std.mem.trim(u8, line, " \t\r\n");
    if (t.len == 0 or t[0] != '{') return null;
    return json.parseFromSliceLeaky(Rec, a, t, .{ .ignore_unknown_fields = true }) catch null;
}

/// One-shot request → response payload (owned by `a`), or null on error.
fn oneShot(a: std.mem.Allocator, sock: []const u8, req: IpcRequest, resp_cap: usize) ?[]const u8 {
    var rb: [protocol.header_size + 4096]u8 = undefined;
    const request = client.buildRequest(&rb, req) catch return null;
    const resp_buf = a.alloc(u8, resp_cap) catch return null;
    const resp = client.sendCommand(sock, request, resp_buf) catch return null;
    if (resp.msg_type != .success) return null;
    return resp.payload;
}

/// Write raw bytes to a pane's PTY (no escape/token processing). Routes to the
/// daemon's write_input ctl op with -s, else the window's send_keys_pane.
fn submit(ctx: Ctx, pane_id: u32, bytes: []const u8) void {
    var pl: [4 + 8192]u8 = undefined;
    std.mem.writeInt(u32, pl[0..4], pane_id, .little);
    const n = @min(bytes.len, pl.len - 4);
    @memcpy(pl[4 .. 4 + n], bytes[0..n]);
    if (ctx.daemon()) {
        var rb: [256]u8 = undefined;
        _ = client_daemon.ctl(ctx.sock, ctx.session, .write_input, pl[0 .. 4 + n], &rb) catch {};
        return;
    }
    var rb: [protocol.header_size + 4 + 8192]u8 = undefined;
    const req = protocol.encodeMessage(&rb, .send_keys_pane, pl[0 .. 4 + n]) catch return;
    var resp: [256]u8 = undefined;
    _ = client.sendCommand(ctx.sock, req, &resp) catch {};
}

fn resolveSubmitKey(spec: []const u8, out: []u8) []const u8 {
    const s = if (spec.len == 0) "{Enter}" else spec;
    var iter = keys.KeyTokenIter{ .input = s };
    if (iter.next(out)) |tok| return out[0..tok.len];
    return "\r";
}

fn snapshotPane(a: std.mem.Allocator, ctx: Ctx, pane_id: u32) ?Rec {
    const body = if (ctx.daemon()) blk: {
        var ob: [5]u8 = undefined;
        ob[0] = 1; // JSON
        std.mem.writeInt(u32, ob[1..5], pane_id, .little);
        break :blk daemonCtl(a, ctx, .list_agents, &ob, 1 << 16);
    } else oneShot(a, ctx.sock, .{ .command = .list_agents, .pane_id = pane_id, .json_output = true }, 1 << 16);
    const arr = json.parseFromSliceLeaky([]Rec, a, std.mem.trim(u8, body orelse return null, " \t\r\n"), .{ .ignore_unknown_fields = true }) catch return null;
    for (arr) |rec| if (pane_id == 0 or rec.pane_id == pane_id) return rec;
    return null;
}

/// Incremental capture body ({cursor,text,…} JSON), via the right transport.
/// `cursor` empty (or unparseable) seeds from the current screen.
fn getTextSince(a: std.mem.Allocator, ctx: Ctx, pane_id: u32, cursor: []const u8) ?[]const u8 {
    var gen: u32 = 0;
    var line: u64 = 0;
    if (Cursor_parse(cursor)) |c| {
        gen = c.gen;
        line = c.line;
    }
    if (ctx.daemon()) {
        var ob: [20]u8 = undefined;
        std.mem.writeInt(u32, ob[0..4], pane_id, .little);
        std.mem.writeInt(u32, ob[4..8], gen, .little);
        std.mem.writeInt(u64, ob[8..16], line, .little);
        std.mem.writeInt(u32, ob[16..20], 0, .little); // visible screen only
        return daemonCtl(a, ctx, .get_text_since, &ob, 1 << 20);
    }
    return oneShot(a, ctx.sock, .{ .command = .get_text, .pane_id = pane_id, .has_since = true, .since_gen = gen, .since_line = line }, 1 << 20);
}

fn seedCursor(a: std.mem.Allocator, ctx: Ctx, pane_id: u32) []const u8 {
    const body = getTextSince(a, ctx, pane_id, "") orelse return "";
    const r = json.parseFromSliceLeaky(SinceResp, a, body, .{ .ignore_unknown_fields = true }) catch return "";
    return r.cursor;
}

fn captureSince(a: std.mem.Allocator, ctx: Ctx, pane_id: u32, cursor: []const u8) SinceResp {
    const body = getTextSince(a, ctx, pane_id, cursor) orelse return .{};
    return json.parseFromSliceLeaky(SinceResp, a, body, .{ .ignore_unknown_fields = true }) catch .{};
}

// Local copy of the cursor parse (cli_ipc.Cursor) to avoid a config import here.
fn Cursor_parse(tok: []const u8) ?struct { gen: u32, line: u64 } {
    if (tok.len < 4 or tok[0] != 'g') return null;
    const dot = std.mem.indexOfScalar(u8, tok, '.') orelse return null;
    if (dot + 1 >= tok.len or tok[dot + 1] != 'l') return null;
    const gen = std.fmt.parseInt(u32, tok[1..dot], 10) catch return null;
    const line = std.fmt.parseInt(u64, tok[dot + 2 ..], 10) catch return null;
    return .{ .gen = gen, .line = line };
}

/// `agent send` core. Submits the prompt and (with --wait) drives the turn to an
/// outcome. Returns a Result owned by `a`.
pub fn runSend(a: std.mem.Allocator, parsed: IpcRequest) Error!Result {
    var sock_buf: [256]u8 = undefined;
    const ctx = try resolveCtx(parsed, &sock_buf);

    const snap = snapshotPane(a, ctx, parsed.pane_id) orelse return Error.NotAnAgent;
    const s0 = State.fromStr(snap.state);
    if (s0 == .none) return Error.NotAnAgent;
    if (s0 == .working) return Error.Busy;
    const session = snap.session;

    const want_capture = parsed.agent_capture;
    const cursor: []const u8 = if (want_capture) seedCursor(a, ctx, parsed.pane_id) else "";
    // Assistant-message count before the turn, so capture can wait for the turn's
    // own message to land rather than reading a stale one (see captureTurnMessage).
    // null = the agent reports no transcript → screen-scrape fallback.
    const tx_baseline: ?usize = if (want_capture) blk: {
        const m = agent_read.allMessages(a, parsed) orelse break :blk null;
        break :blk m.len;
    } else null;

    // Open the watch stream BEFORE submitting so we can't miss the `working` edge.
    var ws = WatchStream.open(ctx, parsed.pane_id) catch return Error.IpcFailed;
    defer ws.close();

    // Submit: prompt body as a bracketed paste, then the submit key discretely.
    var paste: [8192]u8 = undefined;
    var ps = std.io.fixedBufferStream(&paste);
    ps.writer().writeAll("\x1b[200~") catch {};
    ps.writer().writeAll(parsed.text_arg[0..@min(parsed.text_arg.len, paste.len - 12)]) catch {};
    ps.writer().writeAll("\x1b[201~") catch {};
    submit(ctx, parsed.pane_id, ps.getWritten());
    var key_buf: [64]u8 = undefined;
    const submit_key = resolveSubmitKey(parsed.agent_submit_key, &key_buf);
    const submit_ms = std.time.milliTimestamp();
    submit(ctx, parsed.pane_id, submit_key);

    if (!parsed.wait) {
        return .{ .pane = parsed.pane_id, .session = session, .outcome = .done, .duration_ms = 0 };
    }

    const timeout_ms: i64 = if (parsed.agent_timeout_s > 0) @as(i64, parsed.agent_timeout_s) * 1000 else default_timeout_ms;
    var m = Machine{ .initial = s0, .submit_ms = submit_ms, .start_grace_ms = default_start_grace_ms, .timeout_ms = timeout_ms };
    var outcome: Outcome = .timeout;
    var end_message: []const u8 = "";
    loop: while (true) {
        switch (ws.pollNext(poll_ms)) {
            .frame => |p| {
                var fa = std.heap.ArenaAllocator.init(a);
                defer fa.deinit();
                if (parseRec(fa.allocator(), p)) |rec| {
                    if (rec.pane_id == parsed.pane_id) {
                        if (m.feed(State.fromStr(rec.state))) |o| {
                            outcome = o;
                            end_message = a.dupe(u8, rec.message) catch "";
                            break :loop;
                        }
                    }
                }
            },
            .none => if (m.tick(std.time.milliTimestamp())) |o| {
                outcome = o;
                break :loop;
            },
            .eof => {
                outcome = .ended;
                break :loop;
            },
        }
    }
    const duration_ms = std.time.milliTimestamp() - submit_ms;

    var result = Result{ .pane = parsed.pane_id, .session = session, .outcome = outcome, .duration_ms = duration_ms, .message = end_message };

    if (want_capture and (outcome == .done or outcome == .needs_input or outcome == .timeout)) {
        // The agent's last message from the transcript — same source as `agent
        // read`. Falls back to the screen scrape for agents with no transcript.
        result.output = captureTurnMessage(a, parsed, tx_baseline);
        if (result.output == null) {
            const cap = captureSince(a, ctx, parsed.pane_id, cursor);
            result.output = cap.text;
            result.truncated = cap.truncated;
        }
    }
    if (parsed.agent_tokens) {
        if (snapshotPane(a, ctx, parsed.pane_id)) |end_snap| {
            result.tokens = .{
                .input = (end_snap.usage.input_tokens orelse 0) -| (snap.usage.input_tokens orelse 0),
                .output = (end_snap.usage.output_tokens orelse 0) -| (snap.usage.output_tokens orelse 0),
                .cache_read = (end_snap.usage.cache_read_tokens orelse 0) -| (snap.usage.cache_read_tokens orelse 0),
                .cost_usd = end_snap.usage.cost_usd,
                .cost_is_estimate = end_snap.usage.cost_is_estimate,
            };
        }
    }
    return result;
}

/// `agent await` core. Observes (no input) until the pane's agent reaches the
/// target state, ends, or times out.
pub fn runAwait(a: std.mem.Allocator, parsed: IpcRequest) Error!Result {
    var sock_buf: [256]u8 = undefined;
    const ctx = try resolveCtx(parsed, &sock_buf);
    const snap = snapshotPane(a, ctx, parsed.pane_id) orelse return Error.NotAnAgent;
    const session = snap.session;

    var ws = WatchStream.open(ctx, parsed.pane_id) catch return Error.IpcFailed;
    defer ws.close();
    const start_ms = std.time.milliTimestamp();
    const timeout_ms: i64 = if (parsed.agent_timeout_s > 0) @as(i64, parsed.agent_timeout_s) * 1000 else default_timeout_ms;

    while (true) {
        switch (ws.pollNext(poll_ms)) {
            .frame => |p| {
                var fa = std.heap.ArenaAllocator.init(a);
                defer fa.deinit();
                if (parseRec(fa.allocator(), p)) |rec| {
                    if (rec.pane_id == parsed.pane_id) {
                        const st = State.fromStr(rec.state);
                        if (st == .none) return mkAwaitResult(parsed.pane_id, session, .ended, start_ms);
                        const hit = switch (parsed.agent_await_state) {
                            .idle => st == .idle,
                            .input => st == .input,
                            .any => st == .idle or st == .input,
                        };
                        if (hit) return mkAwaitResult(parsed.pane_id, session, if (st == .input) .needs_input else .done, start_ms);
                    }
                }
            },
            .none => if (std.time.milliTimestamp() - start_ms >= timeout_ms) return mkAwaitResult(parsed.pane_id, session, .timeout, start_ms),
            .eof => return mkAwaitResult(parsed.pane_id, session, .ended, start_ms),
        }
    }
}
fn mkAwaitResult(pane: u32, session: u32, outcome: Outcome, start_ms: i64) Result {
    return .{ .pane = pane, .session = session, .outcome = outcome, .duration_ms = std.time.milliTimestamp() - start_ms };
}

pub fn errMsg(e: Error) []const u8 {
    return switch (e) {
        Error.NoInstance => "no running Attyx instance found",
        Error.IpcFailed => "failed to communicate with Attyx instance",
        Error.NotAnAgent => "pane is not running an agent",
        Error.Busy => "the pane's agent is busy (working); wait for it to finish first",
    };
}

/// Serialize a Result as the §5 JSON object (owned by `a`).
pub fn resultJson(a: std.mem.Allocator, r: Result) []const u8 {
    var buf = std.ArrayList(u8){};
    const w = buf.writer(a);
    w.print("{{\"pane\":{d},\"session\":{d},\"outcome\":\"{s}\",\"duration_ms\":{d},\"message\":\"", .{ r.pane, r.session, r.outcome.label(), r.duration_ms }) catch {};
    writeJsonStr(w, r.message);
    w.writeAll("\"") catch {};
    if (r.output) |out| {
        w.writeAll(",\"output\":\"") catch {};
        writeJsonStr(w, out);
        w.print("\",\"truncated\":{}", .{r.truncated}) catch {};
    }
    if (r.tokens) |t| {
        w.print(",\"tokens\":{{\"input\":{d},\"output\":{d},\"cache_read\":{d}", .{ t.input, t.output, t.cache_read }) catch {};
        if (t.cost_usd) |c| w.print(",\"cost_usd\":{d},\"cost_is_estimate\":{}", .{ c, t.cost_is_estimate }) catch {};
        w.writeAll("}") catch {};
    }
    w.writeAll("}") catch {};
    return buf.items;
}

fn writeJsonStr(w: anytype, s: []const u8) void {
    for (s) |ch| switch (ch) {
        '"' => w.writeAll("\\\"") catch {},
        '\\' => w.writeAll("\\\\") catch {},
        '\n' => w.writeAll("\\n") catch {},
        '\r' => w.writeAll("\\r") catch {},
        '\t' => w.writeAll("\\t") catch {},
        else => if (ch < 0x20) {
            w.print("\\u{x:0>4}", .{ch}) catch {};
        } else w.writeByte(ch) catch {},
    };
}

/// CLI entry: orchestrate, print result, exit with the outcome's code.
pub fn run(parsed: IpcRequest) noreturn {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = (if (parsed.command == .agent_await) runAwait(a, parsed) else runSend(a, parsed)) catch |e| {
        std.fs.File.stderr().writeAll("error: ") catch {};
        std.fs.File.stderr().writeAll(errMsg(e)) catch {};
        std.fs.File.stderr().writeAll("\n") catch {};
        std.process.exit(1);
    };
    const stdout = std.fs.File.stdout();
    if (parsed.json_output) {
        stdout.writeAll(resultJson(a, r)) catch {};
        stdout.writeAll("\n") catch {};
    } else {
        // Human: summary to stderr, captured output to stdout (so it pipes).
        var sb: [256]u8 = undefined;
        const summary = std.fmt.bufPrint(&sb, "pane {d}: {s} in {d:.1}s\n", .{ r.pane, r.outcome.label(), @as(f64, @floatFromInt(r.duration_ms)) / 1000.0 }) catch "done\n";
        std.fs.File.stderr().writeAll(summary) catch {};
        if (r.output) |out| stdout.writeAll(out) catch {};
    }
    std.process.exit(r.outcome.exitCode());
}

/// MCP entry: orchestrate and return the §5 JSON (no print/exit).
pub fn runForMcp(a: std.mem.Allocator, parsed: IpcRequest) ![]const u8 {
    const r = if (parsed.command == .agent_await) try runAwait(a, parsed) else try runSend(a, parsed);
    return resultJson(a, r);
}

