// Windows-specific constants and platform behavior.
// Phase 0 stub — provides the same interface as macos.zig / linux.zig
// so that comptime dispatch in platform.zig compiles.

const std = @import("std");

// Placeholder ioctls — Windows uses DeviceIoControl, not ioctl.
// These values are unused; the PTY layer will use Windows ConPTY instead.
pub const TIOCSWINSZ: c_ulong = 0;
pub const TIOCSCTTY: c_ulong = 0;
pub const O_NONBLOCK: usize = 0;

pub const ConfigPaths = struct {
    config_dir: []const u8,
    state_dir: []const u8,
    cache_dir: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ConfigPaths) void {
        self.allocator.free(self.config_dir);
        self.allocator.free(self.state_dir);
        self.allocator.free(self.cache_dir);
    }
};

/// Build a path: %ENV_VAR%\attyx, falling back to %USERPROFILE%\fallback_suffix\attyx.
fn getWindowsDir(allocator: std.mem.Allocator, env_var: []const u8, fallback_suffix: []const u8) ![]const u8 {
    const val = std.process.getEnvVarOwned(allocator, env_var) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            const home = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch return error.NoHomeDir;
            defer allocator.free(home);
            return std.fmt.allocPrint(allocator, "{s}\\{s}\\attyx", .{ home, fallback_suffix });
        },
        else => return err,
    };
    defer allocator.free(val);
    if (val.len == 0) {
        const home = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch return error.NoHomeDir;
        defer allocator.free(home);
        return std.fmt.allocPrint(allocator, "{s}\\{s}\\attyx", .{ home, fallback_suffix });
    }
    return std.fmt.allocPrint(allocator, "{s}\\attyx", .{val});
}

/// Windows config paths:
///   config_dir: %APPDATA%\attyx       (roaming app data)
///   state_dir:  %LOCALAPPDATA%\attyx   (local app data)
///   cache_dir:  %LOCALAPPDATA%\attyx\cache
pub fn getConfigPaths(allocator: std.mem.Allocator) !ConfigPaths {
    const config_dir = try getWindowsDir(allocator, "APPDATA", "AppData\\Roaming");
    errdefer allocator.free(config_dir);
    const state_dir = try getWindowsDir(allocator, "LOCALAPPDATA", "AppData\\Local");
    errdefer allocator.free(state_dir);
    const cache_dir = try std.fmt.allocPrint(allocator, "{s}\\cache", .{state_dir});

    return .{
        .config_dir = config_dir,
        .state_dir = state_dir,
        .cache_dir = cache_dir,
        .allocator = allocator,
    };
}

/// Stub — Windows doesn't have tcgetpgrp; foreground process
/// detection will use NtQueryInformationProcess or ToolHelp32 in Phase 1+.
pub fn getPtyForegroundPid(_: i32) ?i32 {
    return null;
}

/// Stub — Windows process name lookup (Phase 1+).
pub fn getProcessName(_: i32, _: *[256]u8) ?[]const u8 {
    return null;
}

/// Stub — Windows CWD lookup (Phase 1+).
pub fn getCwdForPid(_: std.mem.Allocator, _: i32) ?[]const u8 {
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "stubs return null" {
    var buf: [256]u8 = undefined;
    try std.testing.expect(getPtyForegroundPid(0) == null);
    try std.testing.expect(getProcessName(1, &buf) == null);
    try std.testing.expect(getCwdForPid(std.testing.allocator, 1) == null);
}

test "getWindowsDir falls back to USERPROFILE" {
    const allocator = std.testing.allocator;
    // Use a non-existent env var to force the USERPROFILE fallback path.
    const result = getWindowsDir(allocator, "ATTYX_TEST_NONEXISTENT_12345", "FallbackDir") catch |err| {
        if (err == error.NoHomeDir) return; // no USERPROFILE either — skip
        return err;
    };
    defer allocator.free(result);
    try std.testing.expect(std.mem.endsWith(u8, result, "attyx"));
    try std.testing.expect(result.len > 5);
}

test "getConfigPaths returns valid paths" {
    const allocator = std.testing.allocator;
    const paths = getConfigPaths(allocator) catch |err| {
        if (err == error.NoHomeDir) return; // no env vars set — skip
        return err;
    };
    defer {
        var p = paths;
        p.deinit();
    }
    try std.testing.expect(std.mem.endsWith(u8, paths.config_dir, "attyx"));
    try std.testing.expect(std.mem.endsWith(u8, paths.state_dir, "attyx"));
    try std.testing.expect(std.mem.endsWith(u8, paths.cache_dir, "cache"));
    try std.testing.expect(paths.config_dir.len > 5);
    try std.testing.expect(paths.state_dir.len > 5);
    try std.testing.expect(paths.cache_dir.len > 5);
}
