// Linux-specific constants and platform behavior.

const std = @import("std");

pub const TIOCSWINSZ: c_ulong = 0x5414;
pub const TIOCSCTTY: c_ulong = 0x540E;
pub const O_NONBLOCK: usize = 0x0800;

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

fn getEnvOrHome(allocator: std.mem.Allocator, env_var: []const u8, fallback_suffix: []const u8) ![]const u8 {
    if (std.posix.getenv(env_var)) |val| {
        if (val.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}/attyx", .{val});
        }
    }
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    return std.fmt.allocPrint(allocator, "{s}/{s}/attyx", .{ home, fallback_suffix });
}

// ---------------------------------------------------------------------------
// Foreground process cwd lookup (/proc/<pid>/cwd)
// ---------------------------------------------------------------------------

extern "c" fn tcgetpgrp(fd: c_int) std.posix.pid_t;

/// Look up a process's name by PID using /proc/<pid>/comm.
/// Returns a slice into `buf`, or null on failure.
pub fn getProcessName(pid: std.posix.pid_t, buf: *[256]u8) ?[]const u8 {
    var path_buf: [64:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/comm", .{pid}) catch return null;
    const file = std.fs.openFileAbsoluteZ(path, .{}) catch return null;
    defer file.close();
    const n = file.read(buf) catch return null;
    if (n == 0) return null;
    // /proc/pid/comm has a trailing newline
    const len = if (n > 0 and buf[n - 1] == '\n') n - 1 else n;
    if (len == 0) return null;
    return buf[0..len];
}

/// Look up a process's CWD by PID using /proc/<pid>/cwd.
/// Returns an allocator-owned slice, or null on failure.
pub fn getCwdForPid(allocator: std.mem.Allocator, pid: std.posix.pid_t) ?[]const u8 {
    var link_path_buf: [64:0]u8 = undefined;
    const link_path = std.fmt.bufPrintZ(&link_path_buf, "/proc/{d}/cwd", .{pid}) catch return null;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = std.posix.readlinkZ(
        link_path,
        &buf,
    ) catch return null;
    if (target.len == 0) return null;

    return allocator.dupe(u8, target) catch null;
}

/// Return the foreground process group PID on the given PTY master fd.
pub fn getPtyForegroundPid(master_fd: std.posix.fd_t) ?std.posix.pid_t {
    const pid = tcgetpgrp(master_fd);
    if (pid < 0) return null;
    return pid;
}

/// XDG-compatible paths per the XDG Base Directory spec.
pub fn getConfigPaths(allocator: std.mem.Allocator) !ConfigPaths {
    const config_dir = try getEnvOrHome(allocator, "XDG_CONFIG_HOME", ".config");
    errdefer allocator.free(config_dir);
    const state_dir = try getEnvOrHome(allocator, "XDG_STATE_HOME", ".local/state");
    errdefer allocator.free(state_dir);
    const cache_dir = try getEnvOrHome(allocator, "XDG_CACHE_HOME", ".cache");

    return .{
        .config_dir = config_dir,
        .state_dir = state_dir,
        .cache_dir = cache_dir,
        .allocator = allocator,
    };
}
