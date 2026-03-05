/// Connection helpers for the session daemon client.
/// Extracted from session_client.zig to reduce file size.
const std = @import("std");
const posix = std.posix;
const protocol = @import("daemon/protocol.zig");
const platform = @import("../platform/platform.zig");

extern "c" fn setsid() c_int;
extern "c" fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;
extern "c" fn readlink(path: [*:0]const u8, b: [*]u8, bufsiz: usize) isize;
extern "c" fn execvp(file: [*:0]const u8, argv: [*]const ?[*:0]const u8) c_int;
extern "c" fn _exit(status: c_int) noreturn;

pub fn connectToSocket() !posix.fd_t {
    var path_buf: [256]u8 = undefined;
    const socket_path = getSocketPath(&path_buf) orelse return error.NoHome;

    // First attempt — connect and verify the daemon is alive
    if (tryConnect(socket_path)) |fd| {
        if (probeAlive(fd)) return fd;
        posix.close(fd);
    }

    // Remove stale socket file before starting daemon.
    std.fs.deleteFileAbsolute(socket_path) catch {};

    // Auto-start daemon
    try startDaemon();

    // Retry with backoff: 100ms, 200ms, 400ms, 800ms, 1600ms (total ~3.1s)
    var delay_ns: u64 = 100_000_000;
    for (0..5) |_| {
        posix.nanosleep(0, delay_ns);
        if (tryConnect(socket_path)) |fd| return fd;
        delay_ns *= 2;
    }

    return error.DaemonConnectFailed;
}

pub fn getSocketPath(buf: *[256]u8) ?[]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    const suffix = if (comptime @import("builtin").mode == .Debug) "-dev" else "";
    return std.fmt.bufPrint(buf, "{s}/.config/attyx/sessions{s}.sock", .{ home, suffix }) catch null;
}

fn probeAlive(fd: posix.fd_t) bool {
    var buf: [protocol.header_size]u8 = undefined;
    protocol.encodeHeader(&buf, .list, 0);
    _ = posix.write(fd, &buf) catch return false;
    var fds = [1]posix.pollfd{.{ .fd = fd, .events = 0x0001, .revents = 0 }};
    _ = posix.poll(&fds, 500) catch return false;
    if (fds[0].revents & (0x0010 | 0x0008) != 0) return false;
    if (fds[0].revents & 0x0001 != 0) return true;
    return false;
}

fn tryConnect(path: []const u8) ?posix.fd_t {
    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return null;
    const addr = std.net.Address.initUnix(path) catch {
        posix.close(fd);
        return null;
    };
    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch {
        posix.close(fd);
        return null;
    };
    return fd;
}

fn startDaemon() !void {
    const pid = try posix.fork();
    if (pid == 0) {
        const pid2 = posix.fork() catch posix.abort();
        if (pid2 == 0) {
            _ = setsid();
            var exe_buf: [1024]u8 = undefined;
            const exe = getExePath(&exe_buf) orelse "/usr/local/bin/attyx";
            var exe_z_buf: [1024]u8 = undefined;
            const exe_z = std.fmt.bufPrintZ(&exe_z_buf, "{s}", .{exe}) catch posix.abort();
            const daemon_str: [*:0]const u8 = "daemon";
            const argv = [_]?[*:0]const u8{ exe_z, daemon_str, null };
            _ = execvp(exe_z, &argv);
            posix.abort();
        }
        _exit(0);
    }
    _ = posix.waitpid(pid, 0);
}

pub fn getExePath(buf: *[1024]u8) ?[]const u8 {
    if (comptime @import("builtin").os.tag == .macos) {
        var size: u32 = buf.len;
        if (_NSGetExecutablePath(buf, &size) == 0) {
            return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(buf)), 0);
        }
    } else {
        const n = readlink("/proc/self/exe", buf, buf.len);
        if (n > 0) return buf[0..@intCast(n)];
    }
    return null;
}

pub fn setNonBlocking(fd: posix.fd_t) void {
    const F_GETFL: i32 = 3;
    const F_SETFL: i32 = 4;
    const flags = std.posix.fcntl(fd, F_GETFL, 0) catch return;
    _ = std.posix.fcntl(fd, F_SETFL, flags | platform.O_NONBLOCK) catch {};
}
