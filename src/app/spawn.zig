/// Cross-platform process spawning, safe in multithreaded programs.
///
/// On POSIX: uses posix_spawnp to avoid fork() atfork handler issues.
/// On Windows: uses CreateProcessW (Phase 1+, currently stubs).
const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

// ── POSIX implementation ──

// On Linux, Zig std doesn't expose posix_spawn, so we declare it here.
// On macOS, we use std.c.posix_spawnp (declared in std/c/darwin.zig).
const linux_ffi = if (!is_windows and !builtin.os.tag.isDarwin()) struct {
    extern "c" fn posix_spawnp(
        pid: *std.c.pid_t,
        file: [*:0]const u8,
        file_actions: ?*anyopaque,
        attrp: ?*anyopaque,
        argv: [*:null]const ?[*:0]const u8,
        envp: [*:null]const ?[*:0]const u8,
    ) c_int;
} else struct {};

pub const PidType = if (is_windows) u32 else std.c.pid_t;

pub const SpawnResult = struct {
    pid: PidType,
    ok: bool,
};

/// Spawn a process using posix_spawnp (POSIX) or CreateProcessW (Windows).
/// Returns the child PID on success.
/// If `setsid` is true, the child gets its own session (POSIX only).
pub fn spawnp(
    file: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    setsid_flag: bool,
) SpawnResult {
    if (comptime is_windows) {
        return spawnWindows(file, argv);
    }
    return spawnpEnv(file, argv, setsid_flag, std.c.environ);
}

/// Like spawnp but with a custom environment. POSIX only.
pub fn spawnpEnv(
    file: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    setsid_flag: bool,
    envp: [*:null]const ?[*:0]const u8,
) SpawnResult {
    if (comptime is_windows) return spawnWindows(file, argv);
    if (comptime builtin.os.tag.isDarwin()) {
        const c = std.c;
        var attr: c.posix_spawnattr_t = undefined;
        if (c.posix_spawnattr_init(&attr) != 0) return .{ .pid = 0, .ok = false };
        defer _ = c.posix_spawnattr_destroy(&attr);

        if (setsid_flag) {
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

/// Windows process spawn via CreateProcessW.
/// Phase 0 stub — returns failure. Full implementation in Phase 1+.
fn spawnWindows(
    _: [*:0]const u8,
    _: [*:null]const ?[*:0]const u8,
) SpawnResult {
    // TODO(windows): implement CreateProcessW spawn
    return .{ .pid = 0, .ok = false };
}

/// Spawn a detached thread that waits for `pid` to exit, preventing zombies.
/// On Windows, process handles are closed by the caller; this is a no-op.
pub fn reapAsync(pid: PidType) void {
    if (comptime is_windows) return;
    _ = std.Thread.spawn(.{}, reapChild, .{pid}) catch {};
}

fn reapChild(pid: std.c.pid_t) void {
    _ = std.c.waitpid(pid, null, 0);
}

// ── Environment helpers (POSIX only) ──

const posix_env = if (!is_windows) struct {
    extern "c" fn getuid() c_uint;
    extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
} else struct {};

/// Build a copy of environ with TMUX auto-detected and injected.
/// Returns null if TMUX is already set or detection fails.
/// Caller must free with `freeEnvp`. POSIX only — always returns null on Windows.
pub fn buildEnvWithTmux(allocator: std.mem.Allocator) ?[*:null]const ?[*:0]const u8 {
    if (comptime is_windows) return null;

    if (posix_env.getenv("TMUX") != null) return null;

    const uid = posix_env.getuid();
    const base = posix_env.getenv("TMUX_TMPDIR") orelse "/tmp";
    var socket_buf: [256]u8 = undefined;
    const sp = std.fmt.bufPrintZ(&socket_buf, "{s}/tmux-{d}/default", .{ base, uid }) catch return null;
    if (posix_env.access(sp, 0) != 0) return null;

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
    if (comptime is_windows) return;
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
