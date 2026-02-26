const std = @import("std");
const builtin = @import("builtin");
const logging = @import("../logging/log.zig");

const impl = switch (builtin.os.tag) {
    .macos => @import("macos.zig"),
    .linux => @import("linux.zig"),
    else => @compileError("Unsupported platform"),
};

pub const TIOCSWINSZ = impl.TIOCSWINSZ;
pub const TIOCSCTTY = impl.TIOCSCTTY;
pub const O_NONBLOCK = impl.O_NONBLOCK;

pub const ConfigPaths = impl.ConfigPaths;
pub const getConfigPaths = impl.getConfigPaths;

extern "c" fn tcgetsid(fd: c_int) std.posix.pid_t;
extern "c" fn getsid(pid: std.posix.pid_t) std.posix.pid_t;

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
        const client_sid = getsid(client_pid);
        if (client_sid == our_sid) {
            logging.info("cwd", "tmux client pid {d} in our session, pane cwd: {s}", .{ client_pid, path });
            return allocator.dupe(u8, path) catch null;
        }
    }

    return null;
}

/// Query the foreground process's CWD. First checks if a tmux client is
/// running inside our PTY session and resolves the active pane's CWD.
/// Falls back to a direct pid-to-cwd lookup for plain shells.
pub fn getForegroundCwd(allocator: std.mem.Allocator, master_fd: std.posix.fd_t) ?[]const u8 {
    const fg_pid = impl.getPtyForegroundPid(master_fd) orelse return null;

    // Scope tmux lookup to our PTY session only.
    const our_sid = tcgetsid(master_fd);
    if (our_sid > 0) {
        if (findTmuxBinary()) |tmux_bin| {
            if (getTmuxPaneCwdForSession(allocator, tmux_bin, our_sid)) |cwd| return cwd;
        }
    }

    // Direct lookup — works when the fg process is a plain shell.
    return impl.getCwdForPid(allocator, fg_pid);
}
