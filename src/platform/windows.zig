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

/// Not applicable on Windows — POSIX uses tcgetpgrp on master fd.
/// Use getDeepestChildName() with a host PID instead.
pub fn getPtyForegroundPid(_: i32) ?i32 {
    return null;
}

/// Get process name by PID via ToolHelp32 snapshot.
pub fn getProcessName(pid: i32, buf: *[256]u8) ?[]const u8 {
    if (pid <= 0) return null;
    return getProcessNameByPid(@intCast(pid), buf);
}

/// Stub — Windows CWD lookup (Phase 1+).
pub fn getCwdForPid(_: std.mem.Allocator, _: i32) ?[]const u8 {
    return null;
}

/// Stub — non-allocating CWD lookup.
pub fn getCwdForPidBuf(_: i32, _: []u8) ?[]const u8 {
    return null;
}

// ── ToolHelp32 process tree walking ──

const windows = std.os.windows;
const HANDLE = windows.HANDLE;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;

const TH32CS_SNAPPROCESS: DWORD = 0x00000002;
const MAX_PATH = 260;

const PROCESSENTRY32W = extern struct {
    dwSize: DWORD = @sizeOf(PROCESSENTRY32W),
    cntUsage: DWORD = 0,
    th32ProcessID: DWORD = 0,
    th32DefaultHeapID: usize = 0,
    th32ModuleID: DWORD = 0,
    cntThreads: DWORD = 0,
    th32ParentProcessID: DWORD = 0,
    pcPriClassBase: i32 = 0,
    dwFlags: DWORD = 0,
    szExeFile: [MAX_PATH]u16 = .{0} ** MAX_PATH,
};

extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: DWORD, th32ProcessID: DWORD) callconv(.winapi) HANDLE;
extern "kernel32" fn Process32FirstW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
extern "kernel32" fn Process32NextW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;

/// Find the deepest leaf descendant of `root_pid` and return its exe name.
/// Walks the process tree via ToolHelp32 snapshot. If no children, returns
/// the root process's own name. Returns null on failure.
pub fn getDeepestChildName(root_pid: u32, buf: *[256]u8) ?[]const u8 {
    if (root_pid == 0) return null;

    const snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return null;
    defer _ = CloseHandle(snap);

    // Walk the tree: start at root_pid, find child, recurse.
    // Limit depth to avoid infinite loops from circular parent references.
    var current_pid = root_pid;
    var depth: u8 = 0;
    while (depth < 16) : (depth += 1) {
        const child = findChildPid(snap, current_pid) orelse break;
        current_pid = child;
    }

    // Get the name of the deepest process found.
    return exeNameFromSnapshot(snap, current_pid, buf);
}

/// Find the first child process of `parent_pid` in the snapshot.
fn findChildPid(snap: HANDLE, parent_pid: u32) ?u32 {
    var entry: PROCESSENTRY32W = .{};
    entry.dwSize = @sizeOf(PROCESSENTRY32W);
    if (Process32FirstW(snap, &entry) == 0) return null;

    while (true) {
        if (entry.th32ParentProcessID == parent_pid and entry.th32ProcessID != parent_pid) {
            return entry.th32ProcessID;
        }
        if (Process32NextW(snap, &entry) == 0) break;
    }
    return null;
}

/// Get the exe filename (without path) for a PID from the snapshot.
fn exeNameFromSnapshot(snap: HANDLE, pid: u32, buf: *[256]u8) ?[]const u8 {
    var entry: PROCESSENTRY32W = .{};
    entry.dwSize = @sizeOf(PROCESSENTRY32W);
    if (Process32FirstW(snap, &entry) == 0) return null;

    while (true) {
        if (entry.th32ProcessID == pid) {
            // Convert wide exe name to UTF-8, strip path and .exe extension.
            var utf8_len: usize = 0;
            for (entry.szExeFile) |cp| {
                if (cp == 0) break;
                const n = std.unicode.utf8Encode(@intCast(cp), buf[utf8_len..]) catch break;
                utf8_len += n;
            }
            if (utf8_len == 0) return null;
            var name = buf[0..utf8_len];
            // Strip path (take after last backslash)
            if (std.mem.lastIndexOfScalar(u8, name, '\\')) |i| name = name[i + 1 ..];
            // Strip .exe suffix for cleaner display
            if (std.mem.endsWith(u8, name, ".exe")) name = name[0 .. name.len - 4];
            return name;
        }
        if (Process32NextW(snap, &entry) == 0) break;
    }
    return null;
}

fn getProcessNameByPid(pid: u32, buf: *[256]u8) ?[]const u8 {
    const snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return null;
    defer _ = CloseHandle(snap);
    return exeNameFromSnapshot(snap, pid, buf);
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
