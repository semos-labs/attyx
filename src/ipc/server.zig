// Attyx — IPC control socket server
//
// Listens on ~/.local/state/attyx/ctl-<pid>.sock for incoming control
// commands. Runs on a dedicated thread; enqueues commands into the lockfree
// ring buffer for the PTY thread to drain.

const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol.zig");
const queue = @import("queue.zig");

pub var g_ipc_shutdown: i32 = 0;

var listener_fd: posix.fd_t = -1;
var socket_path_buf: [256]u8 = undefined;
var socket_path_len: usize = 0;

/// Start the IPC server: bind, listen, and return the listener fd.
/// Call `run()` on a dedicated thread after this.
pub fn start() !void {
    const suffix = if (comptime @import("builtin").mode == .Debug) "-dev" else "";
    const pid = std.posix.system.getpid();

    var path_buf: [256]u8 = undefined;
    const path = blk: {
        if (std.posix.getenv("XDG_STATE_HOME")) |sh| {
            if (sh.len > 0)
                break :blk std.fmt.bufPrint(&path_buf, "{s}/attyx/ctl-{d}{s}.sock", .{ sh, pid, suffix }) catch return error.PathTooLong;
        }
        const home = std.posix.getenv("HOME") orelse return error.NoHome;
        break :blk std.fmt.bufPrint(&path_buf, "{s}/.local/state/attyx/ctl-{d}{s}.sock", .{ home, pid, suffix }) catch return error.PathTooLong;
    };

    // Ensure state dir exists
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| {
        std.fs.makeDirAbsolute(path[0..i]) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    // Remove stale socket
    std.fs.deleteFileAbsolute(path) catch {};

    // Create + bind + listen
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);

    var addr = std.net.Address.initUnix(path) catch return error.PathTooLong;
    try posix.bind(fd, &addr.any, addr.getOsSockLen());
    try posix.listen(fd, 4);

    listener_fd = fd;
    @memcpy(socket_path_buf[0..path.len], path);
    socket_path_len = path.len;
}

/// Accept loop — run on a dedicated thread.
pub fn run() void {
    const fd = listener_fd;
    if (fd == -1) return;

    while (@atomicLoad(i32, &g_ipc_shutdown, .seq_cst) == 0) {
        // Poll with timeout so we can check shutdown flag
        var pfd = [1]posix.pollfd{.{
            .fd = fd,
            .events = 0x0001, // POLLIN
            .revents = 0,
        }};
        const ready = posix.poll(&pfd, 200) catch continue;
        if (ready == 0) continue; // timeout
        if (pfd[0].revents & 0x0001 == 0) continue;

        // Accept
        const client_fd = posix.accept(fd, null, null, 0) catch continue;

        // Read one request (header + payload), enqueue, wait for response
        handleClient(client_fd);
    }
}

fn handleClient(fd: posix.fd_t) void {
    defer posix.close(fd);

    // Read header
    var hdr: [protocol.header_size]u8 = undefined;
    protocol.readExact(fd, &hdr) catch return;
    const h = protocol.decodeHeader(&hdr) catch return;

    if (h.payload_len > queue.max_payload) {
        // Too large — send error and close
        var err_buf: [128]u8 = undefined;
        const err_msg = protocol.encodeErrorResponse(&err_buf, "payload too large") catch return;
        _ = posix.write(fd, err_msg) catch {};
        return;
    }

    // Build command
    var cmd = queue.IpcCommand{
        .msg_type = @intFromEnum(h.msg_type),
        .payload = undefined,
        .payload_len = @intCast(h.payload_len),
        .response_fd = fd,
    };

    // Read payload
    if (h.payload_len > 0) {
        protocol.readExact(fd, cmd.payload[0..h.payload_len]) catch return;
    }

    // Enqueue for PTY thread
    if (!queue.enqueue(cmd)) {
        var err_buf: [128]u8 = undefined;
        const err_msg = protocol.encodeErrorResponse(&err_buf, "command queue full") catch return;
        _ = posix.write(fd, err_msg) catch {};
        return;
    }

    // Wait for response: the PTY thread will write to response_fd and we
    // detect it's done by poll-reading the fd. The handler closes its dup
    // and we detect EOF. But simpler: we just block here waiting for
    // the PTY thread to write the response to this fd. The client_fd stays
    // open because we're still in handleClient — we only close on defer.
    //
    // Actually, the PTY thread writes the response directly to response_fd.
    // We need to wait until the PTY thread is done before we close the fd.
    // We do this by polling until the PTY thread signals completion by
    // setting response_fd to -1 in the command struct.
    //
    // Simpler approach: just sleep-poll the queue slot until it's consumed.
    // The response is written directly to the client fd by the handler.
    // We wait up to 5 seconds.
    var attempts: u32 = 0;
    while (attempts < 500) : (attempts += 1) {
        if (@atomicLoad(i32, &g_ipc_shutdown, .seq_cst) != 0) return;
        if (@atomicLoad(i32, &cmd.done, .seq_cst) != 0) return;
        posix.nanosleep(0, 10_000_000); // 10ms
    }
    // Timeout — response never came. The fd closes on return.
}

/// Shutdown: signal the listener thread, close fd, unlink socket.
pub fn shutdown() void {
    @atomicStore(i32, &g_ipc_shutdown, 1, .seq_cst);
    if (listener_fd != -1) {
        posix.close(listener_fd);
        listener_fd = -1;
    }
    if (socket_path_len > 0) {
        // Null-terminate for deleteFileAbsolute
        const path = socket_path_buf[0..socket_path_len];
        std.fs.deleteFileAbsolute(path) catch {};
        socket_path_len = 0;
    }
}
