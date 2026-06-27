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

/// Agent run-state as reported on the watch stream.
pub const State = enum {
    idle,
    working,
    input,
    none,

    pub fn fromStr(s: []const u8) State {
        if (std.mem.eql(u8, s, "working")) return .working;
        if (std.mem.eql(u8, s, "input")) return .input;
        if (std.mem.eql(u8, s, "idle")) return .idle;
        return .none;
    }
};

/// The result of a driven turn. Exit codes let scripts branch:
/// `attyx agent send -p 3 "run tests" --wait && deploy`.
pub const Outcome = enum {
    done, // working → idle: the agent finished its turn
    needs_input, // working → input: paused for permission/a question
    timeout, // still working past --timeout (we stop waiting; agent untouched)
    no_turn, // the agent never started working (wrong pane, modal, ignored input)
    ended, // the agent exited mid-wait (state none)

    pub fn exitCode(self: Outcome) u8 {
        return switch (self) {
            .done => 0,
            .needs_input => 2,
            .timeout => 3,
            .no_turn, .ended => 4,
        };
    }
    pub fn label(self: Outcome) []const u8 {
        return switch (self) {
            .done => "done",
            .needs_input => "needs_input",
            .timeout => "timeout",
            .no_turn => "no_turn",
            .ended => "ended",
        };
    }
};

/// Pure turn detector. The watch stream emits the pane's current state on
/// connect (a snapshot) then a frame per transition. We open it before sending,
/// so we must not mistake the pre-submit snapshot for completion: feed every
/// frame to `feed`, and clock checks to `tick`.
///
/// `initial` is the pane's state at submit time (from the precondition snapshot).
/// Until we observe `working`, frames equal to `initial` are the snapshot and are
/// ignored; a transition to `working` starts the turn; a transition to a
/// *different* terminal state (fast turn with no observed `working`) resolves it.
pub const Machine = struct {
    initial: State,
    submit_ms: i64,
    start_grace_ms: i64,
    timeout_ms: i64,
    saw_working: bool = false,

    /// Apply one status frame. Returns an Outcome when the turn resolves, else
    /// null to keep waiting.
    pub fn feed(self: *Machine, state: State) ?Outcome {
        if (state == .none) return .ended;
        if (self.saw_working) {
            return switch (state) {
                .idle => .done,
                .input => .needs_input,
                .working => null,
                .none => .ended,
            };
        }
        switch (state) {
            .working => {
                self.saw_working = true;
                return null;
            },
            // A change away from the pre-submit state without an observed
            // `working` = an instant turn; same state = the connect snapshot.
            .idle => return if (state != self.initial) .done else null,
            .input => return if (state != self.initial) .needs_input else null,
            .none => return .ended,
        }
    }

    /// Apply a clock check (called on poll timeouts). `no_turn` before the turn
    /// starts, `timeout` after.
    pub fn tick(self: *const Machine, now_ms: i64) ?Outcome {
        if (!self.saw_working) {
            if (now_ms - self.submit_ms >= self.start_grace_ms) return .no_turn;
        } else {
            if (now_ms - self.submit_ms >= self.timeout_ms) return .timeout;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Orchestration (attached/window path). Composes one-shot list_agents /
// get_text --since / send_keys with the watch stream. -s (background sessions)
// is a follow-up; rejected cleanly for now.
// ---------------------------------------------------------------------------

const keys = @import("keys.zig");
const json = std.json;

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

const Error = error{ NoInstance, IpcFailed, NotAnAgent, Busy, SessionUnsupported };

/// A persistent watch-stream connection, polled with a timeout so the state
/// machine's deadlines can fire between frames.
const WatchStream = struct {
    fd: posix.fd_t,
    payload_buf: [65536]u8 = undefined,

    fn open(sock: []const u8, pane_id: u32) !WatchStream {
        const fd = try client.connectToSocket(sock);
        var pl: [4]u8 = undefined;
        std.mem.writeInt(u32, &pl, pane_id, .little);
        var rb: [protocol.header_size + 4]u8 = undefined;
        const req = try protocol.encodeMessage(&rb, .watch_agents, &pl);
        try protocol.writeAll(fd, req);
        return .{ .fd = fd };
    }
    fn close(self: *WatchStream) void {
        protocol.closeFd(self.fd);
    }

    const Next = union(enum) { frame: []const u8, none, eof };
    fn pollNext(self: *WatchStream, timeout: i32) Next {
        var pfd = [_]posix.pollfd{.{ .fd = self.fd, .events = POLLIN, .revents = 0 }};
        const r = posix.poll(&pfd, timeout) catch return .eof;
        if (r == 0) return .none;
        var hdr: [protocol.header_size]u8 = undefined;
        protocol.readExact(self.fd, &hdr) catch return .eof;
        const h = protocol.decodeHeader(&hdr) catch return .eof;
        if (h.payload_len == 0) return .none;
        if (h.payload_len > self.payload_buf.len) return .eof;
        protocol.readExact(self.fd, self.payload_buf[0..h.payload_len]) catch return .eof;
        return .{ .frame = self.payload_buf[0..h.payload_len] };
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

/// Write raw bytes to a pane's PTY (no escape/token processing).
fn sendRaw(sock: []const u8, pane_id: u32, bytes: []const u8) bool {
    var pl: [4 + 8192]u8 = undefined;
    std.mem.writeInt(u32, pl[0..4], pane_id, .little);
    const n = @min(bytes.len, pl.len - 4);
    @memcpy(pl[4 .. 4 + n], bytes[0..n]);
    var rb: [protocol.header_size + 4 + 8192]u8 = undefined;
    const req = protocol.encodeMessage(&rb, .send_keys_pane, pl[0 .. 4 + n]) catch return false;
    var resp: [256]u8 = undefined;
    const r = client.sendCommand(sock, req, &resp) catch return false;
    return r.msg_type != .err;
}

fn resolveSubmitKey(spec: []const u8, out: []u8) []const u8 {
    const s = if (spec.len == 0) "{Enter}" else spec;
    var iter = keys.KeyTokenIter{ .input = s };
    if (iter.next(out)) |tok| return out[0..tok.len];
    return "\r";
}

fn snapshotPane(a: std.mem.Allocator, sock: []const u8, pane_id: u32) ?Rec {
    const body = oneShot(a, sock, .{ .command = .list_agents, .pane_id = pane_id, .json_output = true }, 1 << 16) orelse return null;
    const arr = json.parseFromSliceLeaky([]Rec, a, std.mem.trim(u8, body, " \t\r\n"), .{ .ignore_unknown_fields = true }) catch return null;
    for (arr) |rec| if (pane_id == 0 or rec.pane_id == pane_id) return rec;
    return null;
}

fn seedCursor(a: std.mem.Allocator, sock: []const u8, pane_id: u32) []const u8 {
    const body = oneShot(a, sock, .{ .command = .get_text, .pane_id = pane_id, .has_since = true }, 1 << 20) orelse return "";
    const r = json.parseFromSliceLeaky(SinceResp, a, body, .{ .ignore_unknown_fields = true }) catch return "";
    return r.cursor;
}

fn captureSince(a: std.mem.Allocator, sock: []const u8, pane_id: u32, cursor: []const u8) SinceResp {
    var req = IpcRequest{ .command = .get_text, .pane_id = pane_id, .has_since = true };
    if (Cursor_parse(cursor)) |c| {
        req.since_gen = c.gen;
        req.since_line = c.line;
    }
    const body = oneShot(a, sock, req, 1 << 20) orelse return .{};
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
    if (parsed.target_session != 0) return Error.SessionUnsupported;
    var sock_buf: [256]u8 = undefined;
    const sock = client.discoverSocket(&sock_buf, parsed.target_pid) orelse return Error.NoInstance;

    const snap = snapshotPane(a, sock, parsed.pane_id) orelse return Error.NotAnAgent;
    const s0 = State.fromStr(snap.state);
    if (s0 == .none) return Error.NotAnAgent;
    if (s0 == .working) return Error.Busy;
    const session = snap.session;

    const want_capture = parsed.agent_capture;
    const cursor: []const u8 = if (want_capture) seedCursor(a, sock, parsed.pane_id) else "";

    // Open the watch stream BEFORE submitting so we can't miss the `working` edge.
    var ws = WatchStream.open(sock, parsed.pane_id) catch return Error.IpcFailed;
    defer ws.close();

    // Submit: prompt body as a bracketed paste, then the submit key discretely.
    var paste: [8192]u8 = undefined;
    var ps = std.io.fixedBufferStream(&paste);
    ps.writer().writeAll("\x1b[200~") catch {};
    ps.writer().writeAll(parsed.text_arg[0..@min(parsed.text_arg.len, paste.len - 12)]) catch {};
    ps.writer().writeAll("\x1b[201~") catch {};
    _ = sendRaw(sock, parsed.pane_id, ps.getWritten());
    var key_buf: [64]u8 = undefined;
    const submit = resolveSubmitKey(parsed.agent_submit_key, &key_buf);
    const submit_ms = std.time.milliTimestamp();
    _ = sendRaw(sock, parsed.pane_id, submit);

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
        const cap = captureSince(a, sock, parsed.pane_id, cursor);
        result.output = cap.text;
        result.truncated = cap.truncated;
    }
    if (parsed.agent_tokens) {
        if (snapshotPane(a, sock, parsed.pane_id)) |end_snap| {
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
    if (parsed.target_session != 0) return Error.SessionUnsupported;
    var sock_buf: [256]u8 = undefined;
    const sock = client.discoverSocket(&sock_buf, parsed.target_pid) orelse return Error.NoInstance;
    const snap = snapshotPane(a, sock, parsed.pane_id) orelse return Error.NotAnAgent;
    const session = snap.session;

    var ws = WatchStream.open(sock, parsed.pane_id) catch return Error.IpcFailed;
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
        Error.SessionUnsupported => "agent send/await is not supported with -s yet; run it against the attached session",
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

// ---------------------------------------------------------------------------
// Tests — the state machine, no socket/agent required.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn machine(initial: State) Machine {
    return .{ .initial = initial, .submit_ms = 0, .start_grace_ms = 3000, .timeout_ms = 600_000 };
}

test "working then idle = done; working then input = needs_input" {
    var a = machine(.idle);
    try testing.expectEqual(@as(?Outcome, null), a.feed(.working));
    try testing.expectEqual(@as(?Outcome, .done), a.feed(.idle));

    var b = machine(.idle);
    _ = b.feed(.working);
    try testing.expectEqual(@as(?Outcome, .needs_input), b.feed(.input));
}

test "pre-submit snapshot of the same state does not false-fire" {
    var a = machine(.idle);
    try testing.expectEqual(@as(?Outcome, null), a.feed(.idle)); // connect snapshot
    try testing.expectEqual(@as(?Outcome, null), a.feed(.working)); // turn starts
    try testing.expectEqual(@as(?Outcome, .done), a.feed(.idle)); // turn ends
}

test "no working within start grace = no_turn" {
    var a = machine(.idle);
    _ = a.feed(.idle); // snapshot only
    try testing.expectEqual(@as(?Outcome, null), a.tick(2999));
    try testing.expectEqual(@as(?Outcome, .no_turn), a.tick(3000));
}

test "working then silence past deadline = timeout" {
    var a = machine(.idle);
    _ = a.feed(.working);
    try testing.expectEqual(@as(?Outcome, null), a.tick(599_999));
    try testing.expectEqual(@as(?Outcome, .timeout), a.tick(600_000));
}

test "agent exits mid-turn = ended" {
    var a = machine(.idle);
    _ = a.feed(.working);
    try testing.expectEqual(@as(?Outcome, .ended), a.feed(.none));
}

test "instant turn (input straight after submit, no observed working)" {
    var a = machine(.idle);
    try testing.expectEqual(@as(?Outcome, .needs_input), a.feed(.input));

    var b = machine(.input); // answering a paused agent
    try testing.expectEqual(@as(?Outcome, null), b.feed(.input)); // snapshot (==initial)
    _ = b.feed(.working);
    try testing.expectEqual(@as(?Outcome, .done), b.feed(.idle));
}

test "outcome exit codes" {
    try testing.expectEqual(@as(u8, 0), Outcome.done.exitCode());
    try testing.expectEqual(@as(u8, 2), Outcome.needs_input.exitCode());
    try testing.expectEqual(@as(u8, 3), Outcome.timeout.exitCode());
    try testing.expectEqual(@as(u8, 4), Outcome.no_turn.exitCode());
    try testing.expectEqual(@as(u8, 4), Outcome.ended.exitCode());
}
