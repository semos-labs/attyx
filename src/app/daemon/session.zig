const std = @import("std");
const posix = std.posix;
const Pty = @import("../pty.zig").Pty;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;

/// A daemon-managed session wrapping a PTY process and replay buffer.
pub const DaemonSession = struct {
    id: u32,
    name: [64]u8 = .{0} ** 64,
    name_len: u8 = 0,
    pty: Pty,
    replay: RingBuffer,
    rows: u16,
    cols: u16,
    alive: bool = true,
    exit_code: ?u8 = null,

    pub fn spawn(
        allocator: std.mem.Allocator,
        id: u32,
        name: []const u8,
        rows: u16,
        cols: u16,
        replay_capacity: usize,
    ) !DaemonSession {
        var session = DaemonSession{
            .id = id,
            .pty = try Pty.spawn(.{ .rows = rows, .cols = cols }),
            .replay = try RingBuffer.init(allocator, replay_capacity),
            .rows = rows,
            .cols = cols,
        };
        const nlen = @min(name.len, 64);
        @memcpy(session.name[0..nlen], name[0..nlen]);
        session.name_len = @intCast(nlen);
        return session;
    }

    /// Non-blocking read from PTY master. Stores data in replay buffer.
    /// Returns number of bytes read, or 0 if nothing available.
    pub fn readPty(self: *DaemonSession, buf: []u8) !usize {
        const n = try self.pty.read(buf);
        if (n > 0) {
            self.replay.write(buf[0..n]);
        }
        return n;
    }

    /// Write input bytes to PTY master (keystrokes from client).
    pub fn writeInput(self: *DaemonSession, bytes: []const u8) !void {
        _ = try self.pty.writeToPty(bytes);
    }

    /// Resize the PTY.
    pub fn resize(self: *DaemonSession, rows: u16, cols: u16) !void {
        try self.pty.resize(rows, cols);
        self.rows = rows;
        self.cols = cols;
    }

    /// Non-blocking check if child process has exited.
    /// Returns exit code if exited, null if still running.
    pub fn checkExit(self: *DaemonSession) ?u8 {
        if (self.exit_code) |code| return code;
        if (self.pty.childExited()) {
            const code = self.pty.exitCode() orelse 1;
            self.exit_code = code;
            self.alive = false;
            return code;
        }
        return null;
    }

    pub fn getName(self: *const DaemonSession) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn deinit(self: *DaemonSession) void {
        self.pty.deinit();
        self.replay.deinit();
        self.* = undefined;
    }
};
