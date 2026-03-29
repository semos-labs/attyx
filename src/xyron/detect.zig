// detect.zig — Locate the xyron binary on the system.

const std = @import("std");
const posix = std.posix;

pub const max_path = std.fs.max_path_bytes;

/// Find xyron binary path. Writes null-terminated path to `out`.
/// Returns the path slice (without null), or null if not found.
/// Check order: config path → dev build path (debug only) → PATH lookup.
pub fn findXyron(config_path: ?[]const u8, out: *[max_path]u8) ?[:0]const u8 {
    // 1. Explicit config path
    if (config_path) |p| {
        if (p.len < max_path and isExecutable(p)) {
            @memcpy(out[0..p.len], p);
            out[p.len] = 0;
            return out[0..p.len :0];
        }
    }

    // 2. Dev build path (~/Projects/xyron/zig-out/bin/xyron)
    if (devBuildPath(out)) |path| return path;

    // 3. Search PATH
    return searchPath(out);
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
