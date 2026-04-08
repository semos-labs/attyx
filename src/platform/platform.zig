const std = @import("std");
const builtin = @import("builtin");
const logging = @import("../logging/log.zig");

const is_posix = builtin.os.tag != .windows;

const impl = switch (builtin.os.tag) {
    .macos => @import("macos.zig"),
    .linux => @import("linux.zig"),
    .windows => @import("windows.zig"),
    else => @compileError("Unsupported platform"),
};

// POSIX ioctl constants — windows.zig provides zero placeholders.
// Callers that use these must be gated behind is_posix checks.
pub const TIOCSWINSZ = impl.TIOCSWINSZ;
pub const TIOCSCTTY = impl.TIOCSCTTY;
pub const O_NONBLOCK = impl.O_NONBLOCK;

pub const ConfigPaths = impl.ConfigPaths;
pub const getConfigPaths = impl.getConfigPaths;

// POSIX-only extern declarations — guarded because these symbols don't
// exist on Windows and std.posix.pid_t is unavailable.
const posix_ffi = if (is_posix) struct {
    extern "c" fn tcgetsid(fd: c_int) std.posix.pid_t;
    extern "c" fn getsid(pid: std.posix.pid_t) std.posix.pid_t;
    extern "c" fn attyx_should_quit() c_int;
} else struct {};

/// Well-known tmux binary locations (Homebrew Apple Silicon, Homebrew Intel,
/// system, MacPorts). Checked in order so we don't depend on PATH.
const tmux_search_paths = [_][:0]const u8{
    "/opt/homebrew/bin/tmux",
    "/usr/local/bin/tmux",
    "/usr/bin/tmux",
    "/opt/local/bin/tmux",
};

/// Find a tmux binary on disk.
fn findTmuxBinary() ?[:0]const u8 {
    for (&tmux_search_paths) |p| {
        const f = std.fs.openFileAbsolute(p, .{}) catch continue;
        f.close();
        return p;
    }
    return null;
}

/// Query tmux for the pane CWD of a client running in our PTY session.
/// Uses `list-clients` and matches by session ID so we only pick up the
/// tmux instance running inside Attyx, ignoring unrelated tmux servers.
fn getTmuxPaneCwdForSession(allocator: std.mem.Allocator, tmux_bin: [:0]const u8, our_sid: std.posix.pid_t) ?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ tmux_bin, "list-clients", "-F", "#{client_pid}:#{pane_current_path}" },
    }) catch return null;
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    switch (result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const sep = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const pid_str = line[0..sep];
        const path = line[sep + 1..];
        if (path.len == 0) continue;

        const client_pid = std.fmt.parseInt(std.posix.pid_t, pid_str, 10) catch continue;
        const client_sid = posix_ffi.getsid(client_pid);
        if (client_sid == our_sid) {
            logging.info("cwd", "tmux client pid {d} in our session, pane cwd: {s}", .{ client_pid, path });
            return allocator.dupe(u8, path) catch null;
        }
    }

    return null;
}

/// Return the foreground process name on the given PTY (e.g. "zsh", "vim").
/// Writes into a caller-provided buffer; returns a slice or null.
/// POSIX-only — on Windows, always returns null.
pub fn getForegroundProcessName(master_fd: std.posix.fd_t, buf: *[256]u8) ?[]const u8 {
    if (!is_posix) return null;
    const fg_pid = impl.getPtyForegroundPid(master_fd) orelse return null;
    return impl.getProcessName(fg_pid, buf);
}

/// Query the foreground process's CWD. First checks if a tmux client is
/// running inside our PTY session and resolves the active pane's CWD.
/// Falls back to a direct pid-to-cwd lookup for plain shells.
/// POSIX-only — on Windows, always returns null.
pub fn getForegroundCwd(allocator: std.mem.Allocator, master_fd: std.posix.fd_t) ?[]const u8 {
    if (!is_posix) return null;

    // Bail out during shutdown — forking a child while the parent is
    // tearing down causes "os_once_t is corrupt" crashes on macOS.
    if (posix_ffi.attyx_should_quit() != 0) return null;

    const fg_pid = impl.getPtyForegroundPid(master_fd) orelse return null;

    // Scope tmux lookup to our PTY session only.
    const our_sid = posix_ffi.tcgetsid(master_fd);
    if (our_sid > 0) {
        if (findTmuxBinary()) |tmux_bin| {
            if (getTmuxPaneCwdForSession(allocator, tmux_bin, our_sid)) |cwd| return cwd;
        }
    }

    // Direct lookup — works when the fg process is a plain shell.
    return impl.getCwdForPid(allocator, fg_pid);
}

/// Non-allocating foreground CWD lookup — writes into a caller-provided buffer.
/// Skips tmux detection (too expensive for periodic polling).
/// POSIX-only — on Windows, always returns null.
pub fn getForegroundCwdBuf(master_fd: std.posix.fd_t, buf: []u8) ?[]const u8 {
    if (!is_posix) return null;
    const fg_pid = impl.getPtyForegroundPid(master_fd) orelse return null;
    return impl.getCwdForPidBuf(fg_pid, buf);
}
