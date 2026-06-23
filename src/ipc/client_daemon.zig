// Attyx — headless daemon control client
//
// Routes a small set of CLI commands (`send-text`, `get-text`) directly to a
// target session in the daemon when `-s/--session` is given, so they work no
// matter which window is attached — or whether any window is attached at all.
// Speaks the daemon protocol's ctl_request/ctl_response over the daemon socket.

const std = @import("std");
const builtin = @import("builtin");
const io = @import("protocol.zig"); // protocol-agnostic fd helpers (writeAll/readExact/closeFd)
const dproto = @import("../app/daemon/protocol.zig");
const keys = @import("keys.zig");
const client = @import("client.zig");
const session_connect = @import("../app/session_connect.zig");
const cli_ipc = @import("../config/cli_ipc.zig");
const IpcRequest = cli_ipc.IpcRequest;
const IpcCommand = cli_ipc.IpcCommand;

const inter_key_delay_ns: u64 = 30_000_000; // 30ms — mirrors the window send path

/// Read timeout (ms) for a ctl_response. A daemon that predates the headless
/// control channel silently drops the unknown ctl_request, so without this the
/// CLI would block forever — instead we fail with a clear "restart Attyx" hint.
const ctl_read_timeout_ms: i32 = 4000;

/// Commands that operate on a single session's I/O or layout view and so can
/// be served headlessly by the daemon. Mutating layout commands (tab/split/
/// focus) still need a window and land in a later phase.
pub fn isRoutable(cmd: IpcCommand) bool {
    return switch (cmd) {
        .send_keys, .get_text, .list, .list_tabs, .list_splits, .list_agents => true,
        .tab_create, .tab_select, .tab_next, .tab_prev => true,
        .tab_close, .tab_move_left, .tab_move_right, .tab_rename => true,
        .split_vertical, .split_horizontal, .split_close, .split_rotate => true,
        .scroll_to_top, .scroll_to_bottom, .scroll_page_up, .scroll_page_down => true,
        // Routed only to emit a clear "not headless" message (see run()).
        .split_zoom => true,
        else => false,
    };
}

pub fn run(parsed: IpcRequest) void {
    var sock_buf: [256]u8 = undefined;
    const sock = session_connect.getSocketPath(&sock_buf) orelse {
        stderr("error: cannot locate attyx daemon socket\n");
        std.process.exit(1);
    };
    switch (parsed.command) {
        .send_keys => sendKeys(sock, parsed),
        .get_text => getText(sock, parsed),
        .list => list(sock, parsed, .all),
        .list_tabs => list(sock, parsed, .tabs),
        .list_splits => list(sock, parsed, .panes),
        .list_agents => listAgents(sock, parsed),
        .tab_create => tabCreate(sock, parsed),
        .tab_select => simpleOk(sock, parsed, .tab_select, &[_]u8{parsed.index_arg}),
        .tab_next => simpleOk(sock, parsed, .tab_next, ""),
        .tab_prev => simpleOk(sock, parsed, .tab_prev, ""),
        .split_vertical => split(sock, parsed, 0),
        .split_horizontal => split(sock, parsed, 1),
        .split_close => paneClose(sock, parsed),
        .split_rotate => simpleOk(sock, parsed, .pane_rotate, ""),
        .tab_close => simpleOk(sock, parsed, .tab_close, &[_]u8{parsed.tab_idx}),
        .tab_move_left => simpleOk(sock, parsed, .tab_move, &[_]u8{0}),
        .tab_move_right => simpleOk(sock, parsed, .tab_move, &[_]u8{1}),
        .tab_rename => tabRename(sock, parsed),
        .scroll_to_top => scroll(sock, parsed, 0),
        .scroll_to_bottom => scroll(sock, parsed, 1),
        .scroll_page_up => scroll(sock, parsed, 2),
        .scroll_page_down => scroll(sock, parsed, 3),
        // Zoom is a per-window view state (not part of the session's layout),
        // so it has no headless meaning.
        .split_zoom => {
            stderr("error: 'split zoom' is a window-only view and isn't available with -s\n");
            std.process.exit(2);
        },
        else => unreachable, // guarded by isRoutable
    }
}

pub const CallResult = struct { is_error: bool, text: []const u8 };

/// Capture variant of run() for non-CLI callers (the MCP server): performs the
/// same daemon ctl round-trip for a routable, session-targeted command but
/// returns the outcome instead of printing to stdout / exiting. The result text
/// is allocated in `a`. Callers must ensure isRoutable(parsed.command) and
/// parsed.target_session != 0.
pub fn call(a: std.mem.Allocator, parsed: IpcRequest) CallResult {
    var sock_buf: [256]u8 = undefined;
    const sock = session_connect.getSocketPath(&sock_buf) orelse
        return .{ .is_error = true, .text = "cannot locate attyx daemon socket" };

    // Mirror run()'s rejections for combos with no headless meaning.
    switch (parsed.command) {
        .split_zoom => return .{ .is_error = true, .text = "'split zoom' is a window-only view and isn't available with a session target" },
        .split_vertical, .split_horizontal, .tab_create => {
            if (parsed.wait) return .{ .is_error = true, .text = "wait is not supported with a session target yet" };
        },
        else => {},
    }

    if (parsed.command == .send_keys) return callSendKeys(a, sock, parsed);

    var op_buf: [4 + 4096]u8 = undefined;
    const opreq = buildOp(parsed, &op_buf) orelse
        return .{ .is_error = true, .text = "command not routable to a session" };

    // get-text --lines can return megabytes; size the response buffer to match.
    var stack_buf: [65536]u8 = undefined;
    var heap: ?[]u8 = null;
    defer if (heap) |h| std.heap.page_allocator.free(h);
    const resp_buf: []u8 = if (parsed.command == .get_text and parsed.lines > 0) blk: {
        const b = std.heap.page_allocator.alloc(u8, 8 * 1024 * 1024) catch
            return .{ .is_error = true, .text = "out of memory for response buffer" };
        heap = b;
        break :blk b;
    } else stack_buf[0..];

    const reply = ctl(sock, parsed.target_session, opreq.op, opreq.body, resp_buf) catch |err| {
        return .{ .is_error = true, .text = switch (err) {
            error.Timeout => "no response from attyx daemon (it may be an older version — restart Attyx)",
            else => "failed to reach attyx daemon",
        } };
    };
    if (reply.status != 0) return .{ .is_error = true, .text = a.dupe(u8, reply.body) catch "error" };
    return .{ .is_error = false, .text = a.dupe(u8, reply.body) catch "" };
}

/// send_keys over the daemon: tokenize like the CLI path and write each token
/// to the target pane, pausing after named keys so the target TUI can redraw.
fn callSendKeys(a: std.mem.Allocator, sock: []const u8, parsed: IpcRequest) CallResult {
    var iter = keys.KeyTokenIter{ .input = parsed.text_arg };
    var tok_buf: [4096]u8 = undefined;
    var resp_buf: [256]u8 = undefined;

    while (iter.next(&tok_buf)) |token| {
        const processed = tok_buf[0..token.len];
        var op_body: [4 + 4096]u8 = undefined;
        std.mem.writeInt(u32, op_body[0..4], parsed.pane_id, .little);
        const n = @min(processed.len, op_body.len - 4);
        @memcpy(op_body[4 .. 4 + n], processed[0..n]);

        const reply = ctl(sock, parsed.target_session, .write_input, op_body[0 .. 4 + n], &resp_buf) catch
            return .{ .is_error = true, .text = "failed to reach attyx daemon" };
        if (reply.status != 0) return .{ .is_error = true, .text = a.dupe(u8, reply.body) catch "error" };
        if (token.is_named_key) std.Thread.sleep(inter_key_delay_ns);
    }
    return .{ .is_error = false, .text = "" };
}

const OpReq = struct { op: dproto.CtlOp, body: []const u8 };

/// Build the single ctl op + op_body for a routable, non-streaming command into
/// `buf`. Encodes to the op_body formats documented on dproto.CtlOp (the same
/// layouts run()'s CLI helpers build). Returns null for commands that aren't a
/// single fixed op: send_keys is multi-token, split_zoom is window-only.
fn buildOp(parsed: IpcRequest, buf: []u8) ?OpReq {
    switch (parsed.command) {
        .get_text => {
            std.mem.writeInt(u32, buf[0..4], parsed.pane_id, .little);
            std.mem.writeInt(u32, buf[4..8], parsed.lines, .little);
            return .{ .op = .get_text, .body = buf[0..8] };
        },
        .list => return listOp(buf, .all),
        .list_tabs => return listOp(buf, .tabs),
        .list_splits => return listOp(buf, .panes),
        .list_agents => {
            buf[0] = if (parsed.json_output) 1 else 0;
            std.mem.writeInt(u32, buf[1..5], parsed.pane_id, .little);
            return .{ .op = .list_agents, .body = buf[0..5] };
        },
        .tab_create => {
            const n = @min(parsed.text_arg.len, buf.len);
            @memcpy(buf[0..n], parsed.text_arg[0..n]);
            return .{ .op = .tab_create, .body = buf[0..n] };
        },
        .tab_select => {
            buf[0] = parsed.index_arg;
            return .{ .op = .tab_select, .body = buf[0..1] };
        },
        .tab_next => return .{ .op = .tab_next, .body = "" },
        .tab_prev => return .{ .op = .tab_prev, .body = "" },
        .tab_close => {
            buf[0] = parsed.tab_idx;
            return .{ .op = .tab_close, .body = buf[0..1] };
        },
        .tab_move_left => {
            buf[0] = 0;
            return .{ .op = .tab_move, .body = buf[0..1] };
        },
        .tab_move_right => {
            buf[0] = 1;
            return .{ .op = .tab_move, .body = buf[0..1] };
        },
        .tab_rename => {
            buf[0] = parsed.tab_idx;
            const n = @min(parsed.text_arg.len, buf.len - 1);
            @memcpy(buf[1 .. 1 + n], parsed.text_arg[0..n]);
            return .{ .op = .tab_rename, .body = buf[0 .. 1 + n] };
        },
        .split_vertical => return splitOp(parsed, buf, 0),
        .split_horizontal => return splitOp(parsed, buf, 1),
        .split_close => {
            std.mem.writeInt(u32, buf[0..4], parsed.pane_id, .little);
            return .{ .op = .pane_close, .body = buf[0..4] };
        },
        .split_rotate => return .{ .op = .pane_rotate, .body = "" },
        .scroll_to_top => return scrollOp(parsed, buf, 0),
        .scroll_to_bottom => return scrollOp(parsed, buf, 1),
        .scroll_page_up => return scrollOp(parsed, buf, 2),
        .scroll_page_down => return scrollOp(parsed, buf, 3),
        else => return null,
    }
}

fn listOp(buf: []u8, kind: dproto.CtlListKind) OpReq {
    buf[0] = @intFromEnum(kind);
    return .{ .op = .list, .body = buf[0..1] };
}

fn splitOp(parsed: IpcRequest, buf: []u8, dir: u8) OpReq {
    buf[0] = dir;
    const n = @min(parsed.text_arg.len, buf.len - 1);
    @memcpy(buf[1 .. 1 + n], parsed.text_arg[0..n]);
    return .{ .op = .split, .body = buf[0 .. 1 + n] };
}

fn scrollOp(parsed: IpcRequest, buf: []u8, kind: u8) OpReq {
    std.mem.writeInt(u32, buf[0..4], parsed.pane_id, .little);
    buf[4] = kind;
    return .{ .op = .scroll, .body = buf[0..5] };
}

/// Move the session's IPC-private scroll cursor (kind: 0=top, 1=bottom,
/// 2=page-up, 3=page-down). Silent on success, like the window-side scroll-to.
fn scroll(sock: []const u8, parsed: IpcRequest, kind: u8) void {
    var body: [5]u8 = undefined;
    std.mem.writeInt(u32, body[0..4], parsed.pane_id, .little); // 0 = first pane
    body[4] = kind;
    simpleOk(sock, parsed, .scroll, &body);
}

fn tabRename(sock: []const u8, parsed: IpcRequest) void {
    // op_body: [tab_idx:u8 (0xFF = active)][name...]
    var body: [1 + 256]u8 = undefined;
    body[0] = parsed.tab_idx; // 0xFF when no index was given
    const n = @min(parsed.text_arg.len, body.len - 1);
    @memcpy(body[1 .. 1 + n], parsed.text_arg[0..n]);
    simpleOk(sock, parsed, .tab_rename, body[0 .. 1 + n]);
}

fn split(sock: []const u8, parsed: IpcRequest, dir: u8) void {
    if (parsed.wait) {
        stderr("error: --wait is not supported with -s yet\n");
        std.process.exit(1);
    }
    // op_body: [dir:u8][cmd...]
    var body: [1 + 4096]u8 = undefined;
    body[0] = dir;
    const n = @min(parsed.text_arg.len, body.len - 1);
    @memcpy(body[1 .. 1 + n], parsed.text_arg[0..n]);
    var resp_buf: [256]u8 = undefined;
    const reply = ctlOrExit(sock, parsed.target_session, .split, body[0 .. 1 + n], &resp_buf);
    if (reply.status != 0) {
        reportError(reply.body);
        std.process.exit(1);
    }
}

fn paneClose(sock: []const u8, parsed: IpcRequest) void {
    var body: [4]u8 = undefined;
    std.mem.writeInt(u32, &body, parsed.pane_id, .little); // 0 = focused
    simpleOk(sock, parsed, .pane_close, &body);
}

/// Run a ctl op whose only outcome is success/failure (no body to print).
fn simpleOk(sock: []const u8, parsed: IpcRequest, op: dproto.CtlOp, op_body: []const u8) void {
    var resp_buf: [256]u8 = undefined;
    const reply = ctlOrExit(sock, parsed.target_session, op, op_body, &resp_buf);
    if (reply.status != 0) {
        reportError(reply.body);
        std.process.exit(1);
    }
}

fn tabCreate(sock: []const u8, parsed: IpcRequest) void {
    if (parsed.wait) {
        stderr("error: --wait is not supported with -s yet\n");
        std.process.exit(1);
    }
    var resp_buf: [256]u8 = undefined;
    const reply = ctlOrExit(sock, parsed.target_session, .tab_create, parsed.text_arg, &resp_buf);
    if (reply.status != 0) {
        reportError(reply.body);
        std.process.exit(1);
    }
    // Stay quiet on success, matching the window-side `tab create`.
}

fn list(sock: []const u8, parsed: IpcRequest, kind: dproto.CtlListKind) void {
    const op_body = [_]u8{@intFromEnum(kind)};
    var resp_buf: [16384]u8 = undefined;
    const reply = ctlOrExit(sock, parsed.target_session, .list, &op_body, &resp_buf);
    if (reply.status != 0) {
        reportError(reply.body);
        std.process.exit(1);
    }
    printBody(reply.body);
}

/// `list agents -s N`. op_body = [format:u8][pane_filter:u32 LE]; the daemon
/// builds the same JSON/TSV records as the window-side `list agents`.
fn listAgents(sock: []const u8, parsed: IpcRequest) void {
    var op_body: [5]u8 = undefined;
    op_body[0] = if (parsed.json_output) 1 else 0;
    std.mem.writeInt(u32, op_body[1..5], parsed.pane_id, .little);
    var resp_buf: [16384]u8 = undefined;
    const reply = ctlOrExit(sock, parsed.target_session, .list_agents, &op_body, &resp_buf);
    if (reply.status != 0) {
        reportError(reply.body);
        std.process.exit(1);
    }
    printBody(reply.body);
}

/// `watch agents -s N`. Connects to the daemon, parks the connection as a
/// watcher for the target session, then streams agent_event frames as NDJSON
/// until the daemon closes the stream (or the user Ctrl-Cs). Mirrors the
/// window-side client_watch.run, but speaks the daemon protocol.
pub fn watchAgents(parsed: IpcRequest) void {
    var sock_buf: [256]u8 = undefined;
    const sock = session_connect.getSocketPath(&sock_buf) orelse {
        stderr("error: cannot locate attyx daemon socket\n");
        std.process.exit(1);
    };

    // Request payload: [target_session:u32 LE][pane_filter:u32 LE].
    var req_payload: [8]u8 = undefined;
    std.mem.writeInt(u32, req_payload[0..4], parsed.target_session, .little);
    std.mem.writeInt(u32, req_payload[4..8], parsed.pane_id, .little);
    var frame_buf: [dproto.header_size + 8]u8 = undefined;
    const frame = dproto.encodeMessage(&frame_buf, .watch_agents, &req_payload) catch {
        stderr("error: failed to build watch request\n");
        std.process.exit(1);
    };

    const fd = client.connectToSocket(sock) catch {
        stderr("error: cannot reach attyx daemon\n");
        std.process.exit(1);
    };
    defer io.closeFd(fd);
    io.writeAll(fd, frame) catch {
        stderr("error: failed to reach attyx daemon\n");
        std.process.exit(1);
    };

    const stdout = std.fs.File.stdout();
    var hdr: [dproto.header_size]u8 = undefined;
    var payload_buf: [65536]u8 = undefined;
    while (true) {
        io.readExact(fd, &hdr) catch return; // EOF / disconnect ends the stream
        const h = dproto.decodeHeader(&hdr) catch return;
        if (h.payload_len > payload_buf.len) return;
        if (h.payload_len > 0) io.readExact(fd, payload_buf[0..h.payload_len]) catch return;
        switch (h.msg_type) {
            .agent_event => {
                if (h.payload_len > 0) {
                    stdout.writeAll(payload_buf[0..h.payload_len]) catch return;
                    if (payload_buf[h.payload_len - 1] != '\n') stdout.writeAll("\n") catch return;
                }
            },
            .err => {
                const e = dproto.decodeError(payload_buf[0..h.payload_len]) catch {
                    stderr("error: watch failed\n");
                    std.process.exit(1);
                };
                reportError(e.msg);
                std.process.exit(1);
            },
            else => {},
        }
    }
}

const CtlReply = struct { status: u8, body: []const u8 };

/// One ctl_request → ctl_response round-trip over a fresh daemon connection.
/// The reply body is a slice into `resp_buf`.
fn ctl(
    sock: []const u8,
    target_session: u32,
    op: dproto.CtlOp,
    op_body: []const u8,
    resp_buf: []u8,
) !CtlReply {
    var payload_buf: [5 + 8192]u8 = undefined;
    const payload = try dproto.encodeCtlRequest(&payload_buf, target_session, @intFromEnum(op), op_body);
    var frame_buf: [dproto.header_size + 5 + 8192]u8 = undefined;
    const frame = try dproto.encodeMessage(&frame_buf, .ctl_request, payload);

    const fd = try client.connectToSocket(sock);
    defer io.closeFd(fd);
    io.writeAll(fd, frame) catch return error.SocketError;

    var hdr: [dproto.header_size]u8 = undefined;
    try readExactTimeout(fd, &hdr, ctl_read_timeout_ms);
    const plen = std.mem.readInt(u32, hdr[0..4], .little);
    if (hdr[4] != @intFromEnum(dproto.MessageType.ctl_response)) return error.InvalidResponse;
    if (plen == 0 or plen > resp_buf.len) return error.InvalidResponse;
    try readExactTimeout(fd, resp_buf[0..plen], ctl_read_timeout_ms);
    return .{ .status = resp_buf[0], .body = resp_buf[1..plen] };
}

const ReadTimeoutError = error{ Timeout, ReadFailed };

/// Like protocol.readExact but bounded: poll for readability before each read
/// so an unresponsive (or outdated) daemon yields error.Timeout rather than
/// blocking forever. Falls back to a blocking read on Windows named pipes (the
/// explicit error set keeps Timeout in `ctl`'s signature on every platform so
/// ctlOrExit's switch compiles).
fn readExactTimeout(fd: std.posix.fd_t, out: []u8, timeout_ms: i32) ReadTimeoutError!void {
    if (comptime builtin.os.tag == .windows) {
        io.readExact(fd, out) catch return error.ReadFailed;
        return;
    }
    const POLLIN: i16 = 0x0001;
    var total: usize = 0;
    while (total < out.len) {
        var fds = [1]std.posix.pollfd{.{ .fd = fd, .events = POLLIN, .revents = 0 }};
        const ready = std.posix.poll(&fds, timeout_ms) catch return error.ReadFailed;
        if (ready == 0) return error.Timeout;
        const n = std.posix.read(fd, out[total..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return error.ReadFailed,
        };
        if (n == 0) return error.ReadFailed;
        total += n;
    }
}

/// Perform a ctl round-trip, printing a clear message and exiting on failure.
/// Used by the one-shot commands; the wait-stable poll loop uses `ctl` directly
/// so a transient miss just retries.
fn ctlOrExit(
    sock: []const u8,
    target_session: u32,
    op: dproto.CtlOp,
    op_body: []const u8,
    resp_buf: []u8,
) CtlReply {
    return ctl(sock, target_session, op, op_body, resp_buf) catch |err| {
        switch (err) {
            error.Timeout => stderr("error: no response from attyx daemon (it may be an older version — restart Attyx)\n"),
            else => stderr("error: failed to reach attyx daemon\n"),
        }
        std.process.exit(1);
    };
}

fn sendKeys(sock: []const u8, parsed: IpcRequest) void {
    var iter = keys.KeyTokenIter{ .input = parsed.text_arg };
    var tok_buf: [4096]u8 = undefined;
    var resp_buf: [256]u8 = undefined;

    while (iter.next(&tok_buf)) |token| {
        const processed = tok_buf[0..token.len];
        var op_body: [4 + 4096]u8 = undefined;
        std.mem.writeInt(u32, op_body[0..4], parsed.pane_id, .little);
        const n = @min(processed.len, op_body.len - 4);
        @memcpy(op_body[4 .. 4 + n], processed[0..n]);

        const reply = ctlOrExit(sock, parsed.target_session, .write_input, op_body[0 .. 4 + n], &resp_buf);
        if (reply.status != 0) {
            reportError(reply.body);
            std.process.exit(1);
        }
        // Pause after named keys so the target TUI can process and redraw
        // before the next token (e.g. {Down}{Enter} hitting the right item).
        if (token.is_named_key) std.Thread.sleep(inter_key_delay_ns);
    }

    if (parsed.wait_stable_ms > 0) waitStable(sock, parsed);
}

fn getText(sock: []const u8, parsed: IpcRequest) void {
    var op_body: [8]u8 = undefined;
    std.mem.writeInt(u32, op_body[0..4], parsed.pane_id, .little);
    std.mem.writeInt(u32, op_body[4..8], parsed.lines, .little);

    // With --lines the screen + scrollback can be large; heap-allocate.
    var heap: ?[]u8 = null;
    defer if (heap) |h| std.heap.page_allocator.free(h);
    var stack_buf: [65536]u8 = undefined;
    const resp_buf: []u8 = if (parsed.lines > 0) blk: {
        const b = std.heap.page_allocator.alloc(u8, 8 * 1024 * 1024) catch {
            stderr("error: out of memory for response buffer\n");
            std.process.exit(1);
        };
        heap = b;
        break :blk b;
    } else stack_buf[0..];

    const reply = ctlOrExit(sock, parsed.target_session, .get_text, &op_body, resp_buf);
    if (reply.status != 0) {
        reportError(reply.body);
        std.process.exit(1);
    }
    printBody(reply.body);
}

/// Poll get-text until the visible screen stops changing for `wait_stable_ms`,
/// then print it. Hard timeout at 30s. Mirrors client.waitStable.
fn waitStable(sock: []const u8, parsed: IpcRequest) void {
    const poll_interval_ms: u64 = 50;
    const hard_timeout_ms: u64 = 30_000;
    var elapsed_ms: u64 = 0;
    var stable_since_ms: u64 = 0;
    var prev_hash: u64 = 0;
    var has_prev = false;

    var op_body: [8]u8 = undefined;
    std.mem.writeInt(u32, op_body[0..4], parsed.pane_id, .little);
    std.mem.writeInt(u32, op_body[4..8], 0, .little); // visible screen only

    var resp_buf: [65536]u8 = undefined;
    var last: [65536]u8 = undefined;
    var last_len: usize = 0;

    while (elapsed_ms < hard_timeout_ms) {
        std.Thread.sleep(poll_interval_ms * 1_000_000);
        elapsed_ms += poll_interval_ms;

        const reply = ctl(sock, parsed.target_session, .get_text, &op_body, &resp_buf) catch continue;
        if (reply.status != 0) continue;

        const hash = std.hash.Wyhash.hash(0, reply.body);
        if (has_prev and hash == prev_hash) {
            stable_since_ms += poll_interval_ms;
            if (stable_since_ms >= parsed.wait_stable_ms) {
                printBody(reply.body);
                return;
            }
        } else {
            stable_since_ms = 0;
            prev_hash = hash;
            has_prev = true;
        }
        @memcpy(last[0..reply.body.len], reply.body);
        last_len = reply.body.len;
    }

    stderr("warning: --wait-stable timed out after 30s\n");
    printBody(last[0..last_len]);
}

fn printBody(body: []const u8) void {
    if (body.len == 0) return;
    const out = std.fs.File.stdout();
    out.writeAll(body) catch {};
    if (body[body.len - 1] != '\n') out.writeAll("\n") catch {};
}

fn reportError(body: []const u8) void {
    stderr("error: ");
    std.fs.File.stderr().writeAll(body) catch {};
    stderr("\n");
}

fn stderr(msg: []const u8) void {
    std.fs.File.stderr().writeAll(msg) catch {};
}

// ---------------------------------------------------------------------------
// Tests — buildOp encodes each routable command to the documented op_body.
// ---------------------------------------------------------------------------

test "buildOp get_text encodes pane + lines" {
    var buf: [4 + 4096]u8 = undefined;
    const r = buildOp(.{ .command = .get_text, .pane_id = 3, .lines = 10 }, &buf).?;
    try std.testing.expectEqual(dproto.CtlOp.get_text, r.op);
    try std.testing.expectEqual(@as(usize, 8), r.body.len);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, r.body[0..4], .little));
    try std.testing.expectEqual(@as(u32, 10), std.mem.readInt(u32, r.body[4..8], .little));
}

test "buildOp list kinds map to the list op" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(@as(u8, 1), buildOp(.{ .command = .list_tabs }, &buf).?.body[0]);
    try std.testing.expectEqual(@as(u8, 2), buildOp(.{ .command = .list_splits }, &buf).?.body[0]);
    const all = buildOp(.{ .command = .list }, &buf).?;
    try std.testing.expectEqual(dproto.CtlOp.list, all.op);
    try std.testing.expectEqual(@as(u8, 0), all.body[0]);
}

test "buildOp list_agents encodes format + pane filter" {
    var buf: [16]u8 = undefined;
    const r = buildOp(.{ .command = .list_agents, .json_output = true, .pane_id = 7 }, &buf).?;
    try std.testing.expectEqual(dproto.CtlOp.list_agents, r.op);
    try std.testing.expectEqual(@as(u8, 1), r.body[0]);
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, r.body[1..5], .little));
}

test "buildOp tab_rename keeps active sentinel and name" {
    var buf: [4 + 4096]u8 = undefined;
    const r = buildOp(.{ .command = .tab_rename, .text_arg = "logs" }, &buf).?;
    try std.testing.expectEqual(dproto.CtlOp.tab_rename, r.op);
    try std.testing.expectEqual(@as(u8, 0xFF), r.body[0]);
    try std.testing.expectEqualStrings("logs", r.body[1..]);
}

test "buildOp split encodes direction + command" {
    var buf: [4 + 4096]u8 = undefined;
    const r = buildOp(.{ .command = .split_horizontal, .text_arg = "htop" }, &buf).?;
    try std.testing.expectEqual(dproto.CtlOp.split, r.op);
    try std.testing.expectEqual(@as(u8, 1), r.body[0]);
    try std.testing.expectEqualStrings("htop", r.body[1..]);
}

test "buildOp scroll encodes pane + kind" {
    var buf: [16]u8 = undefined;
    const r = buildOp(.{ .command = .scroll_page_down, .pane_id = 2 }, &buf).?;
    try std.testing.expectEqual(dproto.CtlOp.scroll, r.op);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, r.body[0..4], .little));
    try std.testing.expectEqual(@as(u8, 3), r.body[4]);
}

test "buildOp returns null for multi-token and window-only ops" {
    var buf: [16]u8 = undefined;
    try std.testing.expect(buildOp(.{ .command = .send_keys }, &buf) == null);
    try std.testing.expect(buildOp(.{ .command = .split_zoom }, &buf) == null);
}
