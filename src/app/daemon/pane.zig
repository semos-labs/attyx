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
    /// Cached foreground process name for change detection.
    proc_name: [64]u8 = .{0} ** 64,
    proc_name_len: u8 = 0,

    pub fn spawn(
        allocator: std.mem.Allocator,
        id: u32,
        rows: u16,
        cols: u16,
        replay_capacity: usize,
    ) !DaemonPane {
        return .{
            .id = id,
            .pty = try Pty.spawn(.{ .rows = rows, .cols = cols }),
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
        }
        return n;
    }

    /// Write input bytes to PTY master (keystrokes from client).
    pub fn writeInput(self: *DaemonPane, bytes: []const u8) !void {
        _ = try self.pty.writeToPty(bytes);
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

    pub fn deinit(self: *DaemonPane) void {
        self.pty.deinit();
        self.replay.deinit();
        self.* = undefined;
    }
};
