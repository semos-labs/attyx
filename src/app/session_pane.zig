/// SessionPane — Pane variant backed by a SessionClient instead of a direct PTY.
/// Wraps a local Engine (for rendering) + a daemon connection (for I/O).
const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const attyx = @import("attyx");
const Engine = attyx.Engine;
const SessionClient = @import("session_client.zig").SessionClient;
const logging = @import("../logging/log.zig");

pub const SessionPane = struct {
    engine: Engine,
    client: *SessionClient,
    session_id: u32,
    allocator: Allocator,

    pub fn init(
        allocator: Allocator,
        client: *SessionClient,
        session_id: u32,
        rows: u16,
        cols: u16,
    ) !SessionPane {
        var engine = try Engine.init(allocator, rows, cols);
        errdefer engine.deinit();

        return .{
            .engine = engine,
            .client = client,
            .session_id = session_id,
            .allocator = allocator,
        };
    }

    /// Feed raw PTY output bytes into the local engine (from daemon Output messages).
    pub fn feed(self: *SessionPane, data: []const u8) void {
        self.engine.feed(data);
        // Drain any response the engine generates (DSR, DA, etc.) and send to daemon
        if (self.engine.state.drainResponse()) |resp| {
            self.client.sendInput(resp) catch {};
        }
    }

    /// Resize local engine and notify daemon.
    pub fn resize(self: *SessionPane, rows: u16, cols: u16) void {
        self.engine.state.resize(rows, cols) catch |err| {
            logging.err("session", "resize failed: {}", .{err});
        };
        self.client.sendResize(rows, cols) catch {};
    }

    /// Returns the socket fd for the event loop poll array.
    pub fn pollFd(self: *const SessionPane) posix.fd_t {
        return self.client.pollFd();
    }

    /// Send input bytes to the daemon (keystrokes).
    pub fn sendInput(self: *SessionPane, bytes: []const u8) void {
        self.client.sendInput(bytes) catch {};
    }

    pub fn deinit(self: *SessionPane) void {
        self.client.detach() catch {};
        self.engine.deinit();
    }
};
