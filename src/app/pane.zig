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
const CmdCapture = @import("cmd_capture.zig").CmdCapture;

pub const Pane = struct {
    engine: Engine,
    pty: Pty,
    allocator: Allocator,
    cmd_capture: ?*CmdCapture = null,

    pub fn spawn(
        allocator: Allocator,
        rows: u16,
        cols: u16,
        argv: ?[]const [:0]const u8,
        cwd: ?[*:0]const u8,
    ) !Pane {
        return spawnOpts(allocator, rows, cols, argv, cwd, .{});
    }

    pub const SpawnOpts = struct {
        capture_stdout: bool = false,
        preserve_tmux: bool = false,
    };

    pub fn spawnOpts(
        allocator: Allocator,
        rows: u16,
        cols: u16,
        argv: ?[]const [:0]const u8,
        cwd: ?[*:0]const u8,
        opts: SpawnOpts,
    ) !Pane {
        var engine = try Engine.init(allocator, rows, cols);
        errdefer engine.deinit();

        const pty = try Pty.spawn(.{
            .rows = rows,
            .cols = cols,
            .argv = argv,
            .cwd = cwd,
            .capture_stdout = opts.capture_stdout,
            .preserve_tmux = opts.preserve_tmux,
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
        if (self.cmd_capture) |cap| {
            cap.notifyOutput(data, tsNow());
        }
        self.engine.feed(data);
        if (self.engine.state.drainExitCode()) |code| {
            if (self.cmd_capture) |cap| cap.notifyExitCode(code);
        }
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

fn tsNow() u64 {
    const ts = std.time.nanoTimestamp();
    return if (ts < 0) 0 else @intCast(ts);
}
