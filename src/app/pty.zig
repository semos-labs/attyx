const std = @import("std");
const posix = std.posix;
const platform = @import("../platform/platform.zig");
const ShellIntegration = @import("shell_integration.zig");

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
extern "c" fn tcgetpgrp(fd: c_int) posix.pid_t;
extern "c" fn getuid() c_uint;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn readlink(path: [*:0]const u8, buf: [*]u8, bufsiz: usize) isize;
extern "c" fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;

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
        /// When true, skip ZDOTDIR override and shell integration setup.
        /// Popup one-shot commands don't need integration hooks, and the
        /// ZDOTDIR trick can cause init scripts to rebuild PATH.
        skip_shell_integration: bool = false,
        /// Command to execute after shell initialization completes.
        /// Set as __ATTYX_STARTUP_CMD env var; shell integration scripts
        /// pick it up and eval it after all rc files are sourced, ensuring
        /// the user's full PATH is available.
        startup_cmd: ?[*:0]const u8 = null,
    };

    /// Wrap an existing PTY master fd and child pid (e.g. inherited across exec).
    /// Does NOT spawn a new process — the caller must ensure fd and pid are valid.
    pub fn fromExisting(master: posix.fd_t, pid: posix.pid_t) Pty {
        return .{ .master = master, .pid = pid };
    }

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

        // Format Attyx PID before fork so the child can set ATTYX_PID
        var pid_buf: [16]u8 = undefined;
        const attyx_pid = std.fmt.bufPrintZ(&pid_buf, "{d}", .{std.posix.system.getpid()}) catch "0";

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

            if (opts.cwd) |dir|
                _ = chdir(dir);

            _ = setenv("TERM", "xterm-256color", 1);
            _ = setenv("COLORTERM", "truecolor", 1);
            _ = setenv("TERM_PROGRAM", "attyx", 1);
            _ = setenv("ATTYX", "1", 1);
            _ = setenv("ATTYX_PID", attyx_pid, 1);

            // Set startup command for shell integration to execute after init.
            // This ensures the command runs with the user's full PATH loaded.
            if (opts.startup_cmd) |cmd| {
                _ = setenv("__ATTYX_STARTUP_CMD", cmd, 1);
            }

            var argv_override: ShellIntegration.ArgvOverride = .{};
            if (!opts.skip_shell_integration) {
                argv_override = ShellIntegration.setup();
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

            // Build argv with override entries inserted after argv[0]
            var argv_ptrs: [33]?[*:0]const u8 = .{null} ** 33;
            argv_ptrs[0] = argv[0].ptr;
            var pos: usize = 1;
            // Insert extra args from shell integration (e.g. --rcfile for bash)
            for (0..argv_override.count) |oi| {
                if (pos >= 32) break;
                argv_ptrs[pos] = argv_override.extra[oi];
                pos += 1;
            }
            // Append remaining original argv entries
            for (argv[1..]) |arg| {
                if (pos >= 32) break;
                argv_ptrs[pos] = arg.ptr;
                pos += 1;
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

        // Non-blocking reads on stdout capture pipe (if present)
        if (stdout_pipe[0] != -1) {
            const sflags = std.posix.fcntl(stdout_pipe[0], F_GETFL, 0) catch 0;
            _ = std.posix.fcntl(stdout_pipe[0], F_SETFL, sflags | platform.O_NONBLOCK) catch {};
        }

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

    /// Send SIGWINCH to the PTY's foreground process group.
    /// Used after session switch to force TUI apps to repaint even
    /// when the terminal size hasn't changed.
    pub fn sendSigwinch(self: *Pty) void {
        const pgrp = tcgetpgrp(self.master);
        if (pgrp > 0) {
            posix.kill(-pgrp, posix.SIG.WINCH) catch {};
        }
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
