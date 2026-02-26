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

/// Query the active pane CWD from a running tmux instance.
/// `tmux_bin` is the full path to the tmux binary (avoids PATH issues).
/// Returns allocator-owned path, or null on any failure.
fn getTmuxClientPaneCwd(allocator: std.mem.Allocator, tmux_bin: [:0]const u8, fg_pid: std.posix.pid_t) ?[]const u8 {
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

/// Query the foreground process's CWD. If the foreground process is a tmux
/// client, resolves that client's active pane CWD using the tmux binary found
/// via the process's own exe path (avoids PATH lookup issues when Attyx is
/// launched as a standalone app). Falls back to a direct pid-to-cwd lookup.
pub fn getForegroundCwd(allocator: std.mem.Allocator, master_fd: std.posix.fd_t) ?[]const u8 {
    const fg_pid = impl.getPtyForegroundPid(master_fd) orelse return null;

    // If the foreground process is tmux, use its exe path to run list-clients.
    var exe_buf: [1024]u8 = undefined;
    if (impl.getProcessExePath(fg_pid, &exe_buf)) |exe_path| {
        const basename = std.fs.path.basename(exe_path);
        if (std.mem.eql(u8, basename, "tmux")) tmux: {
            const tmux_z = allocator.dupeZ(u8, exe_path) catch break :tmux;
            defer allocator.free(tmux_z);
            if (getTmuxClientPaneCwd(allocator, tmux_z, fg_pid)) |cwd| return cwd;
        }
    }

    // Direct lookup — works when the fg process is a plain shell.
    return impl.getCwdForPid(allocator, fg_pid);
}
