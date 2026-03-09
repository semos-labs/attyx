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

/// Spawn a process using posix_spawnp. Returns true on success.
/// On macOS, if `setsid` is true the child gets its own session.
/// On Linux, setsid is ignored — the daemon should call setsid() itself.
pub fn spawnp(
    file: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    setsid: bool,
) bool {
    if (comptime builtin.os.tag.isDarwin()) {
        const c = std.c;
        var attr: c.posix_spawnattr_t = undefined;
        if (c.posix_spawnattr_init(&attr) != 0) return false;
        defer _ = c.posix_spawnattr_destroy(&attr);

        if (setsid) {
            _ = c.posix_spawnattr_setflags(&attr, c.POSIX_SPAWN.SETSID);
        }

        var pid: c.pid_t = 0;
        return c.posix_spawnp(&pid, file, null, &attr, argv, std.c.environ) == 0;
    } else {
        var pid: std.c.pid_t = 0;
        return linux_ffi.posix_spawnp(&pid, file, null, null, argv, std.c.environ) == 0;
    }
}
