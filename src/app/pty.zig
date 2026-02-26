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
extern "c" fn execvp(file: [*:0]const u8, argv: [*]const ?[*:0]const u8) c_int;
extern "c" fn chdir(path: [*:0]const u8) c_int;

pub const Pty = struct {
    master: posix.fd_t,
    pid: posix.pid_t,

    pub const SpawnOpts = struct {
        rows: u16 = 24,
        cols: u16 = 80,
        argv: ?[]const [:0]const u8 = null,
        cwd: ?[*:0]const u8 = null,
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

        const pid = try posix.fork();

        if (pid == 0) {
            // ── child ──
            posix.close(master);
            _ = setsid();
            _ = ioctl(slave, platform.TIOCSCTTY, @as(c_int, 0));

            posix.dup2(slave, 0) catch posix.abort();
            posix.dup2(slave, 1) catch posix.abort();
            posix.dup2(slave, 2) catch posix.abort();
            if (slave > 2) posix.close(slave);

            if (opts.cwd) |dir| _ = chdir(dir);

            _ = setenv("TERM", "xterm-256color", 1);
            _ = setenv("TERM_PROGRAM", "attyx", 1);
            // Prevent child processes from thinking they're inside tmux.
            // When Attyx is launched from a tmux session, TMUX is inherited
            // but Attyx doesn't support DCS tmux passthrough, so apps that
            // wrap escape sequences for tmux (e.g. Kitty graphics) break.
            _ = unsetenv("TMUX");
            _ = unsetenv("TMUX_PANE");

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

        // Non-blocking reads on master fd
        const F_GETFL: i32 = 3;
        const F_SETFL: i32 = 4;
        const current = std.posix.fcntl(master, F_GETFL, 0) catch 0;
        _ = std.posix.fcntl(master, F_SETFL, current | platform.O_NONBLOCK) catch {};

        return .{ .master = master, .pid = pid };
    }

    pub fn deinit(self: *Pty) void {
        posix.close(self.master);
        _ = posix.waitpid(self.pid, std.posix.W.NOHANG);
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

    pub fn childExited(self: *Pty) bool {
        const result = posix.waitpid(self.pid, std.posix.W.NOHANG);
        return result.pid != 0;
    }
};
