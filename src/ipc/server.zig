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

/// Returns true if the IPC server started successfully.
pub fn isStarted() bool {
    return listener_fd != -1;
}

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

    // Ensure state dir exists with owner-only permissions (0700)
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| {
        const dir_path = path[0..i];
        std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        // Restrict directory to owner-only (defense against permissive umask)
        var dir = std.fs.openDirAbsolute(dir_path, .{}) catch null;
        if (dir) |*d| {
            posix.fchmod(d.fd, 0o700) catch {};
            d.close();
        }
    }

    // Remove stale socket
    std.fs.deleteFileAbsolute(path) catch {};

    // Create + bind + listen with restrictive permissions
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);

    // Set umask to restrict socket file to owner-only (0600)
    const old_umask = std.c.umask(0o177);
    var addr = std.net.Address.initUnix(path) catch {
        _ = std.c.umask(old_umask);
        return error.PathTooLong;
    };
    posix.bind(fd, &addr.any, addr.getOsSockLen()) catch |err| {
        _ = std.c.umask(old_umask);
        return err;
    };
    _ = std.c.umask(old_umask);

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
        var err_buf: [128]u8 = undefined;
        const err_msg = protocol.encodeMessage(&err_buf, .err, "payload too large") catch return;
        _ = posix.write(fd, err_msg) catch {};
        return;
    }

    // Duplicate the client fd for the PTY thread to write the response.
    // The PTY handler owns and closes this dup when done, so we can return
    // from handleClient without having to poll for completion.
    const response_fd = posix.dup(fd) catch {
        var err_buf: [128]u8 = undefined;
        const err_msg = protocol.encodeMessage(&err_buf, .err, "internal error") catch return;
        _ = posix.write(fd, err_msg) catch {};
        return;
    };

    var cmd = queue.IpcCommand{
        .msg_type = @intFromEnum(h.msg_type),
        .payload = undefined,
        .payload_len = @intCast(h.payload_len),
        .response_fd = response_fd,
    };

    // Read payload
    if (h.payload_len > 0) {
        protocol.readExact(fd, cmd.payload[0..h.payload_len]) catch {
            posix.close(response_fd);
            return;
        };
    }

    // Enqueue for PTY thread
    if (!queue.enqueue(cmd)) {
        posix.close(response_fd);
        var err_buf: [128]u8 = undefined;
        const err_msg = protocol.encodeMessage(&err_buf, .err, "command queue full") catch return;
        _ = posix.write(fd, err_msg) catch {};
        return;
    }

    // The PTY thread now owns response_fd — it will write the response
    // and close the fd when done. We return immediately; the defer
    // closes the original client fd.
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
