//! Terminal control for the dashboard TUI: raw mode, alt screen, size query,
//! and — most importantly — a `restore` that is idempotent and safe to call
//! from any exit path (normal quit, signal handler, error). Leaving the user's
//! terminal wedged is the one unacceptable failure, so restore is defensive.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const TIOCGWINSZ: c_ulong = switch (builtin.os.tag) {
    .macos => 0x40087468,
    else => 0x5413, // linux
};

extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

const Winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };

pub const Size = struct { rows: u16 = 24, cols: u16 = 80 };

pub const Term = struct {
    in_fd: posix.fd_t,
    out_fd: posix.fd_t,
    orig: posix.termios,
    raw_active: bool = false,
    alt_active: bool = false,

    pub fn init() !Term {
        const in_fd = posix.STDIN_FILENO;
        return .{
            .in_fd = in_fd,
            .out_fd = posix.STDOUT_FILENO,
            .orig = try posix.tcgetattr(in_fd),
        };
    }

    pub fn enterRaw(self: *Term) !void {
        var raw = self.orig;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false; // Ctrl-C arrives as a 0x03 byte, handled in the loop
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.oflag.OPOST = false; // we position explicitly with CSI, no NL translation
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(self.in_fd, .FLUSH, raw);
        self.raw_active = true;
    }

    pub fn enterAlt(self: *Term) void {
        self.write("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H"); // alt screen, hide cursor, clear
        self.alt_active = true;
    }

    /// Idempotent teardown — safe from defer, signal handler, and error paths.
    pub fn restore(self: *Term) void {
        if (self.alt_active) {
            self.write("\x1b[?25h\x1b[?1049l"); // show cursor, leave alt screen
            self.alt_active = false;
        }
        if (self.raw_active) {
            posix.tcsetattr(self.in_fd, .FLUSH, self.orig) catch {};
            self.raw_active = false;
        }
    }

    pub fn write(self: *Term, bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = posix.write(self.out_fd, bytes[off..]) catch return;
            if (n == 0) return;
            off += n;
        }
    }

    pub fn size(self: *Term) Size {
        var ws: Winsize = undefined;
        if (ioctl(self.out_fd, TIOCGWINSZ, &ws) == 0 and ws.ws_row > 0 and ws.ws_col > 0) {
            return .{ .rows = ws.ws_row, .cols = ws.ws_col };
        }
        return .{};
    }
};

pub fn isTty(fd: posix.fd_t) bool {
    return posix.isatty(fd);
}
