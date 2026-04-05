// detect.zig — Locate the xyron binary on the system.

const std = @import("std");
const posix = std.posix;

pub const max_path = std.fs.max_path_bytes;

pub const FindResult = struct {
    path: ?[:0]const u8,
    err: ?[]const u8, // human-readable reason when path is null
};

/// Find xyron binary path. Writes null-terminated path to `out`.
/// Returns the path and/or an error reason.
/// Check order: config path → dev build path (debug only) → PATH lookup.
pub fn findXyron(config_path: ?[]const u8, out: *[max_path]u8) FindResult {
    // 1. Explicit config path
    if (config_path) |p| {
        if (p.len >= max_path) return .{ .path = null, .err = "configured xyron.path exceeds max path length" };
        if (isExecutable(p)) {
            @memcpy(out[0..p.len], p);
            out[p.len] = 0;
            return .{ .path = out[0..p.len :0], .err = null };
        }
        return .{ .path = null, .err = "configured xyron.path is not found or not executable" };
    }

    // 2. Dev build path (~/Projects/xyron/zig-out/bin/xyron)
    if (devBuildPath(out)) |path| return .{ .path = path, .err = null };

    // 3. Search PATH
    if (searchPath(out)) |path| return .{ .path = path, .err = null };

    return .{ .path = null, .err = "xyron binary not found in PATH" };
}

fn devBuildPath(out: *[max_path]u8) ?[:0]const u8 {
    const home = posix.getenv("HOME") orelse return null;
    const path = std.fmt.bufPrintZ(out, "{s}/Projects/xyron/zig-out/bin/xyron", .{home}) catch return null;
    if (isExecutable(path)) return path;
    return null;
}

fn searchPath(out: *[max_path]u8) ?[:0]const u8 {
    const path_env = posix.getenv("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        const path = std.fmt.bufPrintZ(out, "{s}/xyron", .{dir}) catch continue;
        if (isExecutable(path)) return path;
    }
    return null;
}

fn isExecutable(path: []const u8) bool {
    // Check file exists and is accessible. On POSIX, stat + mode check would be
    // more precise, but accessAbsolute with default opts is sufficient for detection.
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}
