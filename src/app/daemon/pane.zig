const std = @import("std");
const posix = std.posix;
const Pty = @import("../pty.zig").Pty;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;
const platform = @import("../../platform/platform.zig");

/// A daemon-managed pane wrapping a PTY process and replay buffer.
/// Multiple DaemonPanes live inside a DaemonSession.
pub const DaemonPane = struct {
    id: u32,
    pty: Pty,
    replay: RingBuffer,
    rows: u16,
    cols: u16,
    alive: bool = true,
    exit_code: ?u8 = null,
    /// Tracked terminal modes for replay restoration.
    cursor_visible: bool = true,
    alt_screen: bool = false,
    /// Cached foreground process name for change detection.
    proc_name: [64]u8 = .{0} ** 64,
    proc_name_len: u8 = 0,

    pub fn spawn(
        allocator: std.mem.Allocator,
        id: u32,
        rows: u16,
        cols: u16,
        replay_capacity: usize,
        cwd: ?[*:0]const u8,
        shell: ?[*:0]const u8,
    ) !DaemonPane {
        // Build argv from shell if configured, otherwise PTY falls back to $SHELL.
        var shell_argv: [1][:0]const u8 = undefined;
        const argv: ?[]const [:0]const u8 = if (shell) |s| blk: {
            shell_argv[0] = std.mem.sliceTo(s, 0);
            break :blk &shell_argv;
        } else null;
        return .{
            .id = id,
            .pty = try Pty.spawn(.{ .rows = rows, .cols = cols, .cwd = cwd, .argv = argv }),
            .replay = try RingBuffer.init(allocator, replay_capacity),
            .rows = rows,
            .cols = cols,
        };
    }

    /// Non-blocking read from PTY master. Stores data in replay buffer.
    /// Returns number of bytes read, or 0 if nothing available.
    pub fn readPty(self: *DaemonPane, buf: []u8) !usize {
        const n = try self.pty.read(buf);
        if (n > 0) {
            self.replay.write(buf[0..n]);
            self.trackModes(buf[0..n]);
            self.interceptQueries(buf[0..n]);
        }
        return n;
    }

    /// Scan output for terminal mode changes we need to restore on replay.
    fn trackModes(self: *DaemonPane, data: []const u8) void {
        // Look for CSI ? sequences: ESC [ ? <number> h/l
        const esc = '\x1b';
        var i: usize = 0;
        while (i + 3 < data.len) : (i += 1) {
            if (data[i] != esc or data[i + 1] != '[' or data[i + 2] != '?') continue;
            // Parse the number and final byte (h = set, l = reset)
            var j = i + 3;
            var num: u32 = 0;
            while (j < data.len and data[j] >= '0' and data[j] <= '9') : (j += 1) {
                num = num * 10 + (data[j] - '0');
            }
            if (j >= data.len) break;
            const final = data[j];
            if (final == 'h' or final == 'l') {
                const set = final == 'h';
                switch (num) {
                    25 => self.cursor_visible = set,
                    1049, 47 => self.alt_screen = set,
                    else => {},
                }
            }
            i = j;
        }
    }

    /// Write input bytes to PTY master (keystrokes from client).
    /// Handles short writes and WouldBlock on non-blocking PTY fds
    /// by retrying with a brief sleep (bounded to avoid stalling the
    /// daemon event loop for too long).
    pub fn writeInput(self: *DaemonPane, bytes: []const u8) !void {
        var offset: usize = 0;
        var retries: u32 = 0;
        const max_retries: u32 = 50; // 50ms max stall
        while (offset < bytes.len) {
            const n = self.pty.writeToPty(bytes[offset..]) catch |err| {
                if (err == error.WouldBlock) {
                    retries += 1;
                    if (retries >= max_retries) return; // give up, don't stall daemon
                    posix.nanosleep(0, 1_000_000); // 1ms
                    continue;
                }
                return err;
            };
            offset += n;
            retries = 0;
        }
    }

    /// Resize the PTY.
    pub fn resize(self: *DaemonPane, rows: u16, cols: u16) !void {
        try self.pty.resize(rows, cols);
        self.rows = rows;
        self.cols = cols;
    }

    /// Non-blocking check if child process has exited.
    /// Returns exit code if exited, null if still running.
    pub fn checkExit(self: *DaemonPane) ?u8 {
        if (self.exit_code) |code| return code;
        if (self.pty.childExited()) {
            const code = self.pty.exitCode() orelse 1;
            self.exit_code = code;
            self.alive = false;
            return code;
        }
        return null;
    }

    /// Check if the foreground process name changed. Returns the new name if changed, null otherwise.
    pub fn checkProcNameChanged(self: *DaemonPane) ?[]const u8 {
        var buf: [256]u8 = undefined;
        const name = platform.getForegroundProcessName(self.pty.master, &buf) orelse return null;
        const len: u8 = @intCast(@min(name.len, 64));
        if (len == self.proc_name_len and std.mem.eql(u8, self.proc_name[0..len], name[0..len])) {
            return null; // unchanged
        }
        @memcpy(self.proc_name[0..len], name[0..len]);
        self.proc_name_len = len;
        return self.proc_name[0..len];
    }

    /// Scan PTY output for terminal queries and write immediate responses.
    /// This eliminates round-trip latency through the client, preventing
    /// shells from displaying stale responses as raw text.
    fn interceptQueries(self: *DaemonPane, data: []const u8) void {
        var i: usize = 0;
        while (i < data.len) {
            if (data[i] != '\x1b') {
                i += 1;
                continue;
            }
            if (i + 1 >= data.len) break;

            if (data[i + 1] == '[') {
                // CSI sequences
                if (i + 2 >= data.len) break;
                const b2 = data[i + 2];

                // DA1: ESC [ c
                if (b2 == 'c') {
                    _ = self.pty.writeToPty("\x1b[?62c") catch {};
                    i += 3;
                    continue;
                }
                // DA1: ESC [ 0 c
                if (b2 == '0' and i + 3 < data.len and data[i + 3] == 'c') {
                    _ = self.pty.writeToPty("\x1b[?62c") catch {};
                    i += 4;
                    continue;
                }

                // DA2: ESC [ > c or ESC [ > 0 c
                if (b2 == '>') {
                    if (i + 3 < data.len and data[i + 3] == 'c') {
                        _ = self.pty.writeToPty("\x1b[>0;10;1c") catch {};
                        i += 4;
                        continue;
                    }
                    if (i + 4 < data.len and data[i + 3] == '0' and data[i + 4] == 'c') {
                        _ = self.pty.writeToPty("\x1b[>0;10;1c") catch {};
                        i += 5;
                        continue;
                    }
                }

                // DSR device status: ESC [ 5 n
                if (b2 == '5' and i + 3 < data.len and data[i + 3] == 'n') {
                    _ = self.pty.writeToPty("\x1b[0n") catch {};
                    i += 4;
                    continue;
                }

                // CSI ? sequences: DECRQM or kitty keyboard query
                if (b2 == '?') {
                    var j = i + 3;

                    // Kitty keyboard query: ESC [ ? u
                    if (j < data.len and data[j] == 'u') {
                        _ = self.pty.writeToPty("\x1b[?0u") catch {};
                        i = j + 1;
                        continue;
                    }

                    // DECRQM: ESC [ ? <digits> $ p
                    var num: u32 = 0;
                    var has_digits = false;
                    while (j < data.len and data[j] >= '0' and data[j] <= '9') : (j += 1) {
                        num = num * 10 + (data[j] - '0');
                        has_digits = true;
                    }
                    if (has_digits and j + 1 < data.len and data[j] == '$' and data[j + 1] == 'p') {
                        self.respondDECRPM(@intCast(num));
                        i = j + 2;
                        continue;
                    }
                }
            }

            i += 1;
        }
    }

    fn respondDECRPM(self: *DaemonPane, mode: u16) void {
        // Return "not recognized" (0) for most modes.
        // Mode 2026 (synchronized output): return 2 (reset) as safe default.
        const pm: u8 = switch (mode) {
            2026 => 2,
            else => 0,
        };
        var buf: [32]u8 = undefined;
        const resp = std.fmt.bufPrint(&buf, "\x1b[?{d};{d}$y", .{ mode, pm }) catch return;
        _ = self.pty.writeToPty(resp) catch {};
    }

    pub fn deinit(self: *DaemonPane) void {
        self.pty.deinit();
        self.replay.deinit();
        self.* = undefined;
    }
};
