const std = @import("std");
const posix = std.posix;
const platform = @import("../platform/platform.zig");

const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

extern "c" fn openpty(
    amaster: *c_int,
    aslave: *c_int,
    name: ?[*:0]u8,
    termp: ?*anyopaque,
    winp: ?*Winsize,
) c_int;

extern "c" fn setsid() c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn execvp(file: [*:0]const u8, argv: [*]const ?[*:0]const u8) c_int;
extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern "c" fn getuid() c_uint;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

pub const Pty = struct {
    master: posix.fd_t,
    pid: posix.pid_t,
    exit_status: ?c_int = null,
    /// Read end of stdout capture pipe (-1 when not capturing).
    stdout_read_fd: posix.fd_t = -1,

    pub const SpawnOpts = struct {
        rows: u16 = 24,
        cols: u16 = 80,
        argv: ?[]const [:0]const u8 = null,
        cwd: ?[*:0]const u8 = null,
        /// When true, child stdout goes to a pipe instead of the PTY.
        /// The parent can read captured output from stdout_read_fd.
        capture_stdout: bool = false,
        /// When true, keep TMUX/TMUX_PANE env vars in the child.
        /// Popup commands need these to interact with tmux.
        preserve_tmux: bool = false,
    };

    pub fn spawn(opts: SpawnOpts) !Pty {
        var win = Winsize{
            .ws_row = opts.rows,
            .ws_col = opts.cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        var master: c_int = undefined;
        var slave: c_int = undefined;

        if (openpty(&master, &slave, null, null, &win) != 0)
            return error.OpenPtyFailed;
        errdefer posix.close(master);

        // Optional stdout capture pipe
        var stdout_pipe: [2]posix.fd_t = .{ -1, -1 };
        if (opts.capture_stdout) {
            stdout_pipe = try posix.pipe();
        }
        errdefer {
            if (stdout_pipe[0] != -1) posix.close(stdout_pipe[0]);
            if (stdout_pipe[1] != -1) posix.close(stdout_pipe[1]);
        }

        const pid = try posix.fork();

        if (pid == 0) {
            // ── child ──
            posix.close(master);
            if (stdout_pipe[0] != -1) posix.close(stdout_pipe[0]); // close read end
            _ = setsid();
            _ = ioctl(slave, platform.TIOCSCTTY, @as(c_int, 0));

            posix.dup2(slave, 0) catch posix.abort();
            if (stdout_pipe[1] != -1) {
                posix.dup2(stdout_pipe[1], 1) catch posix.abort();
                if (stdout_pipe[1] > 2) posix.close(stdout_pipe[1]);
            } else {
                posix.dup2(slave, 1) catch posix.abort();
            }
            posix.dup2(slave, 2) catch posix.abort();
            if (slave > 2) posix.close(slave);

            if (opts.cwd) |dir| _ = chdir(dir);

            _ = setenv("TERM", "xterm-256color", 1);
            _ = setenv("TERM_PROGRAM", "attyx", 1);
            // Inject ~/.attyx/bin into PATH so the `attyx` CLI is available
            // inside the terminal session.
            if (getenv("HOME")) |home| {
                const existing_path = getenv("PATH") orelse "/usr/bin:/bin";
                var path_buf: [4096]u8 = undefined;
                const written = std.fmt.bufPrintZ(&path_buf, "{s}/.attyx/bin:{s}", .{ home, existing_path }) catch null;
                if (written) |new_path| {
                    _ = setenv("PATH", new_path, 1);
                }
            }

            // Prevent main shell children from thinking they're inside tmux.
            // When Attyx is launched from a tmux session, TMUX is inherited
            // but Attyx doesn't support DCS tmux passthrough, so apps that
            // wrap escape sequences for tmux (e.g. Kitty graphics) break.
            // Popup children preserve TMUX so tools like sesh/fzf can see sessions.
            if (!opts.preserve_tmux) {
                _ = unsetenv("TMUX");
                _ = unsetenv("TMUX_PANE");
            }

            // When preserving tmux but TMUX isn't already set (attyx launched
            // standalone), detect the default tmux socket and inject TMUX so
            // popup tools like sesh can discover running tmux sessions.
            if (opts.preserve_tmux and getenv("TMUX") == null) {
                const uid = getuid();
                const base = getenv("TMUX_TMPDIR") orelse "/tmp";
                var socket_buf: [256]u8 = undefined;
                const socket_path = std.fmt.bufPrintZ(&socket_buf, "{s}/tmux-{d}/default", .{ base, uid }) catch null;
                if (socket_path) |sp| {
                    // F_OK = 0: check if socket file exists
                    if (access(sp, 0) == 0) {
                        var env_buf: [512]u8 = undefined;
                        const tmux_val = std.fmt.bufPrintZ(&env_buf, "{s},0,0", .{sp}) catch null;
                        if (tmux_val) |tv| {
                            _ = setenv("TMUX", tv, 1);
                        }
                    }
                }
            }

            const argv = opts.argv orelse &[_][:0]const u8{
                std.posix.getenv("SHELL") orelse "/bin/sh",
            };

            var argv_ptrs: [33]?[*:0]const u8 = .{null} ** 33;
            for (argv, 0..) |arg, i| {
                if (i >= 32) break;
                argv_ptrs[i] = arg.ptr;
            }

            _ = execvp(argv_ptrs[0] orelse posix.abort(), @ptrCast(&argv_ptrs));
            posix.abort();
        }

        // ── parent ──
        posix.close(slave);
        if (stdout_pipe[1] != -1) posix.close(stdout_pipe[1]); // close write end

        // Non-blocking reads on master fd
        const F_GETFL: i32 = 3;
        const F_SETFL: i32 = 4;
        const current = std.posix.fcntl(master, F_GETFL, 0) catch 0;
        _ = std.posix.fcntl(master, F_SETFL, current | platform.O_NONBLOCK) catch {};

        return .{ .master = master, .pid = pid, .stdout_read_fd = stdout_pipe[0] };
    }

    pub fn deinit(self: *Pty) void {
        posix.close(self.master);
        if (self.stdout_read_fd != -1) posix.close(self.stdout_read_fd);
        // Use raw C waitpid to handle ECHILD gracefully.
        // std.posix.waitpid treats ECHILD as unreachable, which panics
        // if the child was already reaped (common on some Linux distros).
        _ = waitpid(self.pid, null, 1); // 1 = WNOHANG
    }

    pub fn read(self: *Pty, buf: []u8) !usize {
        return posix.read(self.master, buf) catch |err| switch (err) {
            error.WouldBlock => return 0,
            else => return err,
        };
    }

    pub fn writeToPty(self: *Pty, bytes: []const u8) !usize {
        return posix.write(self.master, bytes);
    }

    pub fn resize(self: *Pty, rows: u16, cols: u16) !void {
        var win = Winsize{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        if (ioctl(self.master, platform.TIOCSWINSZ, &win) != 0)
            return error.ResizeFailed;
    }

    /// Block until the child exits and store its exit status.
    /// Use after POLLHUP when the non-blocking childExited() may race.
    pub fn waitForExit(self: *Pty) void {
        if (self.exit_status != null) return;
        var status: c_int = undefined;
        const result = waitpid(self.pid, &status, 0); // blocking
        if (result > 0) self.exit_status = status;
    }

    pub fn childExited(self: *Pty) bool {
        if (self.exit_status != null) return true; // already reaped
        // Raw C waitpid: returns pid if reaped, 0 if still running, -1 on error.
        // ECHILD (-1) means already reaped — treat as exited.
        var status: c_int = undefined;
        const result = waitpid(self.pid, &status, 1); // 1 = WNOHANG
        if (result != 0) {
            // Store exit status only on successful reap (result > 0).
            // ECHILD (result < 0) means already reaped — no status available.
            if (result > 0) self.exit_status = status;
            return true;
        }
        return false;
    }

    /// Extract the process exit code (0-255), or 1 if killed by signal.
    /// Returns null if the child hasn't exited yet or status wasn't captured.
    pub fn exitCode(self: *const Pty) ?u8 {
        const status = self.exit_status orelse return null;
        // WIFEXITED: (status & 0x7f) == 0
        if ((status & 0x7f) == 0) {
            // WEXITSTATUS: (status >> 8) & 0xff
            return @intCast((status >> 8) & 0xff);
        }
        // Killed by signal — treat as non-zero exit
        return 1;
    }
};
