/// Connection helpers for the session daemon client.
/// Extracted from session_client.zig to reduce file size.
const std = @import("std");
const posix = std.posix;
const protocol = @import("daemon/protocol.zig");
const platform = @import("../platform/platform.zig");
const spawn = @import("spawn.zig");

extern "c" fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;
extern "c" fn readlink(path: [*:0]const u8, b: [*]u8, bufsiz: usize) isize;

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

/// Build a path under the attyx state directory.
/// Uses XDG_STATE_HOME if set, otherwise ~/.local/state/attyx.
/// `name` must contain one `{s}` placeholder for the dev-mode suffix.
pub fn statePath(buf: []u8, comptime name: []const u8) ?[]const u8 {
    const suffix = if (comptime @import("builtin").mode == .Debug) "-dev" else "";
    if (std.posix.getenv("XDG_STATE_HOME")) |sh| {
        if (sh.len > 0)
            return std.fmt.bufPrint(buf, "{s}/attyx/" ++ name, .{ sh, suffix }) catch null;
    }
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/state/attyx/" ++ name, .{ home, suffix }) catch null;
}

pub fn getSocketPath(buf: *[256]u8) ?[]const u8 {
    return statePath(buf, "sessions{s}.sock");
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
    var exe_buf: [1024]u8 = undefined;
    const exe = getExePath(&exe_buf) orelse "/usr/local/bin/attyx";
    var exe_z_buf: [1024]u8 = undefined;
    const exe_z: [*:0]const u8 = std.fmt.bufPrintZ(&exe_z_buf, "{s}", .{exe}) catch return error.SpawnFailed;

    const daemon_str: [*:0]const u8 = "daemon";
    const argv: [3:null]?[*:0]const u8 = .{ exe_z, daemon_str, null };

    // posix_spawn instead of fork+exec — safe in multithreaded processes.
    if (!spawn.spawnp(exe_z, &argv, true).ok) return error.SpawnFailed;
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

pub fn getLastSessionPath(buf: *[256]u8) ?[]const u8 {
    return statePath(buf, "last-session{s}");
}

pub fn saveLastSession(session_id: u32) void {
    var path_buf: [256]u8 = undefined;
    const path = getLastSessionPath(&path_buf) orelse return;
    var id_buf: [16]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{session_id}) catch return;
    const file = std.fs.createFileAbsolute(path, .{}) catch return;
    defer file.close();
    file.writeAll(id_str) catch {};
}

pub fn loadLastSession() ?u32 {
    var path_buf: [256]u8 = undefined;
    const path = getLastSessionPath(&path_buf) orelse return null;
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    var buf: [16]u8 = undefined;
    const n = file.read(&buf) catch return null;
    if (n == 0) return null;
    return std.fmt.parseInt(u32, buf[0..n], 10) catch null;
}

// ── One-time migration: move runtime files from config dir to state dir ──

/// Migrate runtime files from ~/.config/attyx/ to the XDG state directory.
/// Idempotent — silently skips files that don't exist or already moved.
pub fn migrateToStateDir() void {
    // Only release builds migrate — dev builds must not move files
    // that the production app still expects in the old location.
    if (comptime @import("builtin").mode == .Debug) return;

    const home = std.posix.getenv("HOME") orelse return;
    const suffix = if (comptime @import("builtin").mode == .Debug) "-dev" else "";

    // Old location: config dir
    var old_buf: [256]u8 = undefined;
    const old_dir = blk: {
        const xdg = std.posix.getenv("XDG_CONFIG_HOME") orelse "";
        if (xdg.len > 0)
            break :blk std.fmt.bufPrint(&old_buf, "{s}/attyx", .{xdg}) catch return;
        break :blk std.fmt.bufPrint(&old_buf, "{s}/.config/attyx", .{home}) catch return;
    };

    // New location: state dir
    var new_buf: [256]u8 = undefined;
    const new_dir = blk: {
        const xdg = std.posix.getenv("XDG_STATE_HOME") orelse "";
        if (xdg.len > 0)
            break :blk std.fmt.bufPrint(&new_buf, "{s}/attyx", .{xdg}) catch return;
        break :blk std.fmt.bufPrint(&new_buf, "{s}/.local/state/attyx", .{home}) catch return;
    };

    // Ensure state dir exists (create parent + dir)
    if (std.mem.lastIndexOfScalar(u8, new_dir, '/')) |i| {
        std.fs.makeDirAbsolute(new_dir[0..i]) catch {};
    }
    std.fs.makeDirAbsolute(new_dir) catch {};

    // Move each runtime file
    const files = [_][]const u8{
        "sessions" ++ suffix ++ ".sock",
        "last-session" ++ suffix,
        "daemon" ++ suffix ++ ".version",
        "upgrade" ++ suffix ++ ".bin",
        "auth.json",
    };
    for (files) |name| {
        moveFile(old_dir, new_dir, name);
    }

    // macOS: also migrate recent.json from ~/Library/Application Support/attyx/
    if (comptime @import("builtin").os.tag == .macos) {
        var macos_buf: [512]u8 = undefined;
        const macos_dir = std.fmt.bufPrint(&macos_buf, "{s}/Library/Application Support/attyx", .{home}) catch return;
        moveFile(macos_dir, new_dir, "recent" ++ suffix ++ ".json");
    }
}

fn moveFile(old_dir: []const u8, new_dir: []const u8, name: []const u8) void {
    var src_buf: [512]u8 = undefined;
    var dst_buf: [512]u8 = undefined;
    const src = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ old_dir, name }) catch return;
    const dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ new_dir, name }) catch return;
    std.fs.renameAbsolute(src, dst) catch {};
}

pub fn setNonBlocking(fd: posix.fd_t) void {
    const F_GETFL: i32 = 3;
    const F_SETFL: i32 = 4;
    const flags = std.posix.fcntl(fd, F_GETFL, 0) catch return;
    _ = std.posix.fcntl(fd, F_SETFL, flags | platform.O_NONBLOCK) catch {};
}
