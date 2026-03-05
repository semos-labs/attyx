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
    /// Daemon pane ID. When set, this pane is backed by a daemon PTY and
    /// the local PTY is idle — I/O goes through the shared session socket.
    daemon_pane_id: ?u32 = null,
    /// When true, the engine will be reinitialized before the next data feed
    /// (deferred reinit to prevent blank-screen gap between focus and replay).
    needs_engine_reinit: bool = false,
    /// When true, discard terminal responses instead of sending them.
    /// Set during scrollback replay to prevent duplicate DA/DECRPM/etc.
    suppress_responses: bool = false,
    /// Foreground process name reported by the daemon (for title fallback).
    daemon_proc_name: [64]u8 = undefined,
    daemon_proc_name_len: u8 = 0,

    pub fn getDaemonProcName(self: *const Pane) ?[]const u8 {
        if (self.daemon_proc_name_len == 0) return null;
        return self.daemon_proc_name[0..self.daemon_proc_name_len];
    }

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
        skip_shell_integration: bool = false,
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
            .skip_shell_integration = opts.skip_shell_integration,
        });

        return .{
            .engine = engine,
            .pty = pty,
            .allocator = allocator,
        };
    }

    /// Create a Pane backed by a daemon PTY (engine only, no local PTY spawn).
    /// I/O goes through the shared session socket. The local PTY fields are
    /// unused and deinit skips PTY cleanup when daemon_pane_id is set.
    pub fn initDaemonBacked(allocator: Allocator, rows: u16, cols: u16) !Pane {
        const engine = try Engine.init(allocator, rows, cols);
        return .{
            .engine = engine,
            .pty = .{ .master = -1, .pid = 0 },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Pane) void {
        if (self.daemon_pane_id == null) {
            _ = std.posix.kill(self.pty.pid, std.posix.SIG.HUP) catch {};
            self.pty.deinit();
        }
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
        // Session-backed panes: the local PTY is idle — ignore its exit.
        // The daemon pane lifecycle is managed via the session socket.
        if (self.daemon_pane_id != null) return false;
        return self.pty.childExited();
    }
};
