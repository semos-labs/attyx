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
        .send_keys, .get_text, .list, .list_tabs, .list_splits => true,
        .tab_create, .tab_select, .tab_next, .tab_prev => true,
        .tab_close, .tab_move_left, .tab_move_right, .tab_rename => true,
        .split_vertical, .split_horizontal, .split_close, .split_rotate => true,
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
        // Zoom is a per-window view state (not part of the session's layout),
        // so it has no headless meaning.
        .split_zoom => {
            stderr("error: 'split zoom' is a window-only view and isn't available with -s\n");
            std.process.exit(2);
        },
        else => unreachable, // guarded by isRoutable
    }
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

/// Like protocol.readExact but bounded: poll for readability before each read
/// so an unresponsive (or outdated) daemon yields error.Timeout rather than
/// blocking forever. Falls back to the blocking read on Windows named pipes.
fn readExactTimeout(fd: std.posix.fd_t, out: []u8, timeout_ms: i32) !void {
    if (comptime builtin.os.tag == .windows) return io.readExact(fd, out);
    const POLLIN: i16 = 0x0001;
    var total: usize = 0;
    while (total < out.len) {
        var fds = [1]std.posix.pollfd{.{ .fd = fd, .events = POLLIN, .revents = 0 }};
        const ready = std.posix.poll(&fds, timeout_ms) catch return error.SocketError;
        if (ready == 0) return error.Timeout;
        const n = std.posix.read(fd, out[total..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return error.ConnectionClosed;
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
