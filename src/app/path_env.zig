const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;
pub const path_separator: u8 = if (is_windows) ';' else ':';

const posix_ffi = if (!is_windows) struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    extern "c" fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;
    extern "c" fn readlink(path: [*:0]const u8, buf: [*]u8, bufsiz: usize) isize;
} else struct {};

pub fn pathContainsDir(path: []const u8, dir: []const u8) bool {
    if (dir.len == 0) return false;
    var iter = std.mem.splitScalar(u8, path, path_separator);
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry, dir)) return true;
    }
    return false;
}

pub fn prependDir(allocator: std.mem.Allocator, base_path: []const u8, dir: []const u8) ![]u8 {
    if (dir.len == 0 or pathContainsDir(base_path, dir)) {
        return allocator.dupe(u8, base_path);
    }
    if (base_path.len == 0) return allocator.dupe(u8, dir);
    return std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ dir, path_separator, base_path });
}

pub fn allocPathWithAttyxBinDir(allocator: std.mem.Allocator, base_path: ?[]const u8) ?[]u8 {
    var exe_buf: [1024]u8 = undefined;
    if (getExeDir(&exe_buf)) |dir| {
        return prependDir(allocator, base_path orelse "", dir) catch null;
    }
    if (base_path) |path| return allocator.dupe(u8, path) catch null;
    return null;
}

pub fn prependAttyxBinDirToEnv() void {
    if (comptime is_windows) return;

    var exe_buf: [1024]u8 = undefined;
    const exe_dir = getExeDir(&exe_buf) orelse return;
    const existing = std.mem.sliceTo(posix_ffi.getenv("PATH") orelse "/usr/bin:/bin", 0);
    if (pathContainsDir(existing, exe_dir)) return;

    var path_buf: [4096]u8 = undefined;
    const new_path = if (existing.len == 0)
        std.fmt.bufPrintZ(&path_buf, "{s}", .{exe_dir}) catch return
    else
        std.fmt.bufPrintZ(&path_buf, "{s}:{s}", .{ exe_dir, existing }) catch return;
    _ = posix_ffi.setenv("PATH", new_path, 1);
}

pub fn getExeDir(buf: *[1024]u8) ?[]const u8 {
    const exe_path = getExePath(buf) orelse return null;
    var last_slash: usize = 0;
    for (exe_path, 0..) |ch, i| {
        if (ch == '/') last_slash = i;
    }
    if (last_slash == 0) return null;
    return exe_path[0..last_slash];
}

fn getExePath(buf: *[1024]u8) ?[]const u8 {
    if (comptime builtin.os.tag == .macos) {
        var size: u32 = buf.len;
        if (posix_ffi._NSGetExecutablePath(buf, &size) == 0) {
            return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(buf)), 0);
        }
    } else if (comptime is_windows) {
        return null;
    } else {
        const n = posix_ffi.readlink("/proc/self/exe", buf, buf.len);
        if (n > 0) return buf[0..@intCast(n)];
    }
    return null;
}

test "pathContainsDir matches complete path entries" {
    try std.testing.expect(pathContainsDir("/bin:/opt/attyx/bin:/usr/bin", "/opt/attyx/bin"));
    try std.testing.expect(!pathContainsDir("/bin:/opt/attyx/bin-extra:/usr/bin", "/opt/attyx/bin"));
}

test "prependDir prepends only when missing" {
    const allocator = std.testing.allocator;

    const added = try prependDir(allocator, "/usr/bin:/bin", "/opt/attyx/bin");
    defer allocator.free(added);
    try std.testing.expectEqualStrings("/opt/attyx/bin:/usr/bin:/bin", added);

    const unchanged = try prependDir(allocator, "/opt/attyx/bin:/usr/bin", "/opt/attyx/bin");
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings("/opt/attyx/bin:/usr/bin", unchanged);
}
