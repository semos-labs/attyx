// macOS-specific constants and platform behavior.

const std = @import("std");
pub const TIOCSWINSZ: c_ulong = 0x80087467;
pub const TIOCSCTTY: c_ulong = 0x20007461;
pub const O_NONBLOCK: usize = 0x0004;

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
// Foreground process cwd lookup (Darwin proc_pidinfo)
// ---------------------------------------------------------------------------

extern "c" fn tcgetpgrp(fd: c_int) std.posix.pid_t;

const PROC_PIDVNODEPATHINFO: c_int = 9;
const MAXPATHLEN = 1024;

const VnodeInfoPath = extern struct {
    _pad: [152]u8, // vnode_info (vip_vi)
    path: [MAXPATHLEN]u8, // vip_path
};

const ProcVnodePathInfo = extern struct {
    cdir: VnodeInfoPath, // pvi_cdir
    rdir: VnodeInfoPath, // pvi_rdir
};

extern "c" fn proc_pidinfo(
    pid: c_int,
    flavor: c_int,
    arg: u64,
    buffer: *anyopaque,
    buffersize: c_int,
) c_int;

extern "c" fn proc_pidpath(pid: c_int, buffer: *anyopaque, buffersize: u32) c_int;

/// Look up a process's CWD by PID using Darwin proc_pidinfo.
/// Returns an allocator-owned slice, or null on failure.
pub fn getCwdForPid(allocator: std.mem.Allocator, pid: std.posix.pid_t) ?[]const u8 {
    var info: ProcVnodePathInfo = undefined;
    const ret = proc_pidinfo(
        @intCast(pid),
        PROC_PIDVNODEPATHINFO,
        0,
        @ptrCast(&info),
        @intCast(@sizeOf(ProcVnodePathInfo)),
    );
    if (ret <= 0) return null;

    const path_bytes = &info.cdir.path;
    const len = std.mem.indexOfScalar(u8, path_bytes, 0) orelse MAXPATHLEN;
    if (len == 0) return null;

    return allocator.dupe(u8, path_bytes[0..len]) catch null;
}

/// Look up a process's executable path by PID using Darwin proc_pidpath.
pub fn getProcessExePath(pid: std.posix.pid_t, buf: []u8) ?[]const u8 {
    if (buf.len < 2) return null;
    const ret = proc_pidpath(@intCast(pid), @ptrCast(buf.ptr), @intCast(buf.len));
    if (ret <= 0) return null;
    const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    if (len == 0) return null;
    return buf[0..len];
}

/// Return the foreground process group PID on the given PTY master fd.
pub fn getPtyForegroundPid(master_fd: std.posix.fd_t) ?std.posix.pid_t {
    const pid = tcgetpgrp(master_fd);
    if (pid < 0) return null;
    return pid;
}

/// XDG-compatible paths. macOS uses the same XDG scheme as Linux.
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
