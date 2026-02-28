// Attyx — Pane: Engine + PTY pair with lifecycle methods
//
// A Pane bundles a terminal Engine (parser + state) with a PTY.
// Shared by popups, tabs, and splits.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const attyx = @import("attyx");
const Engine = attyx.Engine;
const Pty = @import("pty.zig").Pty;
const logging = @import("../logging/log.zig");

pub const Pane = struct {
    engine: Engine,
    pty: Pty,
    allocator: Allocator,

    pub fn spawn(
        allocator: Allocator,
        rows: u16,
        cols: u16,
        argv: ?[]const [:0]const u8,
        cwd: ?[*:0]const u8,
    ) !Pane {
        var engine = try Engine.init(allocator, rows, cols);
        errdefer engine.deinit();

        const pty = try Pty.spawn(.{
            .rows = rows,
            .cols = cols,
            .argv = argv,
            .cwd = cwd,
        });

        return .{
            .engine = engine,
            .pty = pty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Pane) void {
        _ = std.posix.kill(self.pty.pid, std.posix.SIG.HUP) catch {};
        self.pty.deinit();
        self.engine.deinit();
    }

    pub fn feed(self: *Pane, data: []const u8) void {
        self.engine.feed(data);
        if (self.engine.state.drainResponse()) |resp| {
            _ = self.pty.writeToPty(resp) catch {};
        }
    }

    pub fn resize(self: *Pane, rows: u16, cols: u16) void {
        const old_rows = self.engine.state.grid.rows;
        const old_cols = self.engine.state.grid.cols;
        self.engine.state.resize(rows, cols) catch |err| {
            logging.err("resize", "state.resize({d}x{d}) failed: {}", .{ cols, rows, err });
        };
        // Only send TIOCSWINSZ when the size actually changed to avoid
        // redundant SIGWINCHs (splitPane + layout both call resize).
        if (rows != old_rows or cols != old_cols) {
            self.pty.resize(rows, cols) catch {};
        }
    }

    pub fn childExited(self: *Pane) bool {
        return self.pty.childExited();
    }
};
