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

/// If fg_pid is a tmux client, query that client's active pane CWD via
/// `tmux list-clients`. Returns allocator-owned path, or null if fg_pid
/// is not found among tmux clients or on any failure.
fn getTmuxClientPaneCwd(allocator: std.mem.Allocator, fg_pid: std.posix.pid_t) ?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tmux", "list-clients", "-F", "#{client_pid}:#{pane_current_path}" },
    }) catch return null;
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    switch (result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    // Format: "<pid>:<path>\n" per client. Find the line matching fg_pid.
    var pid_buf: [20]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}:", .{fg_pid}) catch return null;

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, pid_str)) {
            const path = line[pid_str.len..];
            if (path.len == 0) return null;
            logging.debug("cwd", "tmux client pid {d} pane cwd: {s}", .{ fg_pid, path });
            return allocator.dupe(u8, path) catch null;
        }
    }

    return null;
}

/// Query the foreground process's CWD. When inside tmux, checks whether the
/// PTY foreground process is itself a tmux client and resolves that client's
/// active pane CWD. Otherwise falls back to a direct pid-to-cwd lookup.
pub fn getForegroundCwd(allocator: std.mem.Allocator, master_fd: std.posix.fd_t) ?[]const u8 {
    const fg_pid = impl.getPtyForegroundPid(master_fd) orelse return null;

    // If inside tmux, check whether fg_pid is a tmux client.
    if (std.posix.getenv("TMUX") != null) {
        if (getTmuxClientPaneCwd(allocator, fg_pid)) |cwd| return cwd;
    }

    // Direct lookup — works when the fg process is a plain shell.
    return impl.getCwdForPid(allocator, fg_pid);
}
