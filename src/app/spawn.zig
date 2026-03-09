/// Cross-platform process spawning, safe in multithreaded programs.
///
/// fork() from a background thread corrupts os_once_t on macOS (SIGTRAP
/// in _notify_fork_child). This module uses posix_spawnp which avoids
/// running atfork handlers in the child process.
const std = @import("std");
const builtin = @import("builtin");

// On Linux, Zig std doesn't expose posix_spawn, so we declare it here.
// On macOS, we use std.c.posix_spawnp (declared in std/c/darwin.zig).
const linux_ffi = if (!builtin.os.tag.isDarwin()) struct {
    extern "c" fn posix_spawnp(
        pid: *std.c.pid_t,
        file: [*:0]const u8,
        file_actions: ?*anyopaque,
        attrp: ?*anyopaque,
        argv: [*:null]const ?[*:0]const u8,
        envp: [*:null]const ?[*:0]const u8,
    ) c_int;
} else struct {};

pub const SpawnResult = struct {
    pid: std.c.pid_t,
    ok: bool,
};

/// Spawn a process using posix_spawnp. Returns the child PID on success.
/// If `setsid` is true, the child gets its own session (on platforms that
/// support POSIX_SPAWN_SETSID; the daemon also calls setsid() itself as
/// a fallback for platforms that don't).
pub fn spawnp(
    file: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    setsid: bool,
) SpawnResult {
    return spawnpEnv(file, argv, setsid, std.c.environ);
}

/// Like spawnp but with a custom environment.
pub fn spawnpEnv(
    file: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    setsid: bool,
    envp: [*:null]const ?[*:0]const u8,
) SpawnResult {
    if (comptime builtin.os.tag.isDarwin()) {
        const c = std.c;
        var attr: c.posix_spawnattr_t = undefined;
        if (c.posix_spawnattr_init(&attr) != 0) return .{ .pid = 0, .ok = false };
        defer _ = c.posix_spawnattr_destroy(&attr);

        if (setsid) {
            if (c.posix_spawnattr_setflags(&attr, c.POSIX_SPAWN.SETSID) != 0)
                return .{ .pid = 0, .ok = false };
        }

        var pid: c.pid_t = 0;
        if (c.posix_spawnp(&pid, file, null, &attr, argv, envp) != 0)
            return .{ .pid = 0, .ok = false };
        return .{ .pid = pid, .ok = true };
    } else {
        var pid: std.c.pid_t = 0;
        if (linux_ffi.posix_spawnp(&pid, file, null, null, argv, envp) != 0)
            return .{ .pid = 0, .ok = false };
        return .{ .pid = pid, .ok = true };
    }
}

/// Spawn a detached thread that waits for `pid` to exit, preventing zombies.
pub fn reapAsync(pid: std.c.pid_t) void {
    _ = std.Thread.spawn(.{}, reapChild, .{pid}) catch {};
}

fn reapChild(pid: std.c.pid_t) void {
    _ = std.c.waitpid(pid, null, 0);
}

// ── Environment helpers ──

extern "c" fn getuid() c_uint;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// Build a copy of environ with TMUX auto-detected and injected.
/// Returns null if TMUX is already set or detection fails.
/// Caller must free with `freeEnvp`.
pub fn buildEnvWithTmux(allocator: std.mem.Allocator) ?[*:null]const ?[*:0]const u8 {
    if (getenv("TMUX") != null) return null;

    const uid = getuid();
    const base = getenv("TMUX_TMPDIR") orelse "/tmp";
    var socket_buf: [256]u8 = undefined;
    const sp = std.fmt.bufPrintZ(&socket_buf, "{s}/tmux-{d}/default", .{ base, uid }) catch return null;
    if (access(sp, 0) != 0) return null;

    var tmux_env_buf: [512]u8 = undefined;
    const tmux_val = std.fmt.bufPrintZ(&tmux_env_buf, "TMUX={s},0,0", .{sp}) catch return null;

    // Count existing env entries
    var count: usize = 0;
    const env = std.c.environ;
    while (env[count] != null) : (count += 1) {}

    // Allocate new envp: existing + TMUX + sentinel
    const new_envp = allocator.alloc(?[*:0]const u8, count + 2) catch return null;
    for (0..count) |i| new_envp[i] = env[i];
    new_envp[count] = @ptrCast(allocator.dupeZ(u8, tmux_val) catch {
        allocator.free(new_envp);
        return null;
    });
    new_envp[count + 1] = null;
    return @ptrCast(new_envp.ptr);
}

/// Free an envp allocated by `buildEnvWithTmux`.
pub fn freeEnvp(allocator: std.mem.Allocator, envp: [*:null]const ?[*:0]const u8) void {
    var count: usize = 0;
    while (envp[count] != null) : (count += 1) {}
    if (count > 0) {
        const tmux_entry = envp[count - 1].?;
        const len = std.mem.len(tmux_entry);
        allocator.free(tmux_entry[0 .. len + 1]);
    }
    const slice: []const ?[*:0]const u8 = @as([*]const ?[*:0]const u8, @ptrCast(envp))[0 .. count + 1];
    allocator.free(slice);
}
