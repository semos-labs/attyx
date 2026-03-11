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
const terminal = @import("terminal.zig");
const c = terminal.c;

/// Minimum interval between PTY resize (TIOCSWINSZ/SIGWINCH) signals.
/// During continuous window resizing, the engine state is updated every
/// frame for correct display, but SIGWINCH is throttled to avoid flooding
/// the shell with prompt redraws that create ghost content.
const pty_resize_debounce_ns: i128 = 80 * std.time.ns_per_ms;

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
    /// Foreground process name reported by the daemon (for title fallback).
    daemon_proc_name: [64]u8 = undefined,
    daemon_proc_name_len: u8 = 0,
    /// User-set custom title (via IPC `tab rename`). Overrides all other title sources.
    custom_title_buf: [128]u8 = undefined,
    custom_title_len: u8 = 0,
    /// IPC --wait: fd to write exit code to when this pane's process exits.
    /// Set by IPC handler when a client requests --wait. The fd is owned by
    /// this pane: deinit writes the exit code response and closes it.
    ipc_wait_fd: posix.fd_t = -1,
    /// Stored exit code for daemon-backed panes (set from pane_died message).
    stored_exit_code: ?u8 = null,
    /// Captured stdout for --wait mode. When set, stdout_read_fd is drained
    /// here and sent to the IPC client alongside the exit code.
    captured_stdout: ?*std.ArrayList(u8) = null,
    /// Debounced PTY resize: pending dimensions and timestamp of last TIOCSWINSZ.
    pending_pty_rows: u16 = 0,
    pending_pty_cols: u16 = 0,
    pending_pty_resize: bool = false,
    last_pty_resize_ns: i128 = 0,

    pub fn getDaemonProcName(self: *const Pane) ?[]const u8 {
        if (self.daemon_proc_name_len == 0) return null;
        return self.daemon_proc_name[0..self.daemon_proc_name_len];
    }

    pub fn getCustomTitle(self: *const Pane) ?[]const u8 {
        if (self.custom_title_len == 0) return null;
        return self.custom_title_buf[0..self.custom_title_len];
    }

    pub fn setCustomTitle(self: *Pane, name: []const u8) void {
        const len: u8 = @intCast(@min(name.len, self.custom_title_buf.len));
        @memcpy(self.custom_title_buf[0..len], name[0..len]);
        self.custom_title_len = len;
    }

    pub fn spawn(
        allocator: Allocator,
        rows: u16,
        cols: u16,
        argv: ?[]const [:0]const u8,
        cwd: ?[*:0]const u8,
        scrollback_lines: usize,
    ) !Pane {
        return spawnOpts(allocator, rows, cols, argv, cwd, scrollback_lines, .{});
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
        scrollback_lines: usize,
        opts: SpawnOpts,
    ) !Pane {
        var engine = try Engine.init(allocator, rows, cols, scrollback_lines);
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
    pub fn initDaemonBacked(allocator: Allocator, rows: u16, cols: u16, scrollback_lines: usize) !Pane {
        const engine = try Engine.init(allocator, rows, cols, scrollback_lines);
        return .{
            .engine = engine,
            .pty = .{ .master = -1, .pid = 0 },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Pane) void {
        // Drain any remaining stdout before sending exit response.
        self.drainCapturedStdout();

        // Notify any IPC --wait client with the exit code before cleanup.
        if (self.ipc_wait_fd != -1) {
            const exit_code: u8 = self.stored_exit_code orelse
                if (self.daemon_pane_id == null) (self.pty.exitCode() orelse 1) else 1;
            const stdout_data = if (self.captured_stdout) |cs| cs.items else &[_]u8{};
            const payload_len: u32 = 1 + @as(u32, @intCast(stdout_data.len));
            // Send exit_code response: [payload_len:4 LE][msg_type 0xA2][code:1][stdout...]
            var resp_hdr: [6]u8 = undefined;
            std.mem.writeInt(u32, resp_hdr[0..4], payload_len, .little);
            resp_hdr[4] = 0xA2; // exit_code message type
            resp_hdr[5] = exit_code;
            const ipc_protocol = @import("../ipc/protocol.zig");
            ipc_protocol.writeAll(self.ipc_wait_fd, &resp_hdr) catch {};
            if (stdout_data.len > 0) {
                ipc_protocol.writeAll(self.ipc_wait_fd, stdout_data) catch {};
            }
            posix.close(self.ipc_wait_fd);
            self.ipc_wait_fd = -1;
        }
        if (self.captured_stdout) |cs| {
            cs.deinit(self.allocator);
            self.allocator.destroy(cs);
            self.captured_stdout = null;
        }
        if (self.daemon_pane_id == null) {
            _ = std.posix.kill(self.pty.pid, std.posix.SIG.HUP) catch {};
            self.pty.deinit();
        }
        self.engine.deinit();
    }

    /// Non-blocking drain of stdout capture pipe into captured_stdout buffer.
    pub fn drainCapturedStdout(self: *Pane) void {
        const cs = self.captured_stdout orelse return;
        if (self.pty.stdout_read_fd == -1) return;
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = posix.read(self.pty.stdout_read_fd, &buf) catch break;
            if (n == 0) break;
            cs.appendSlice(self.allocator, buf[0..n]) catch break;
        }
    }

    pub fn feed(self: *Pane, data: []const u8) void {
        self.engine.feed(data);
        if (self.engine.state.drainResponse()) |resp| {
            _ = self.pty.writeToPty(resp) catch {};
        }
        if (self.engine.state.drainNotification()) |notif| {
            // Build null-terminated strings for C
            var title_buf: [257]u8 = undefined;
            var body_buf: [513]u8 = undefined;
            @memcpy(title_buf[0..notif.title.len], notif.title);
            title_buf[notif.title.len] = 0;
            @memcpy(body_buf[0..notif.body.len], notif.body);
            body_buf[notif.body.len] = 0;
            c.attyx_platform_notify(&title_buf, &body_buf);
        }
    }

    pub fn resize(self: *Pane, rows: u16, cols: u16) void {
        const old_rows = self.engine.state.ring.screen_rows;
        const old_cols = self.engine.state.ring.cols;
        self.engine.state.resize(rows, cols) catch |err| {
            logging.err("resize", "state.resize({d}x{d}) failed: {}", .{ cols, rows, err });
        };
        // Trailing-edge debounce: always defer TIOCSWINSZ during active
        // resizing. The event loop's flushPtyResize() sends it once no
        // resize has occurred for the debounce interval. This prevents
        // the shell from being flooded with SIGWINCHs that cause prompt
        // redraws to pile up as ghost content.
        if (rows != old_rows or cols != old_cols) {
            self.pending_pty_rows = rows;
            self.pending_pty_cols = cols;
            self.pending_pty_resize = true;
            self.last_pty_resize_ns = std.time.nanoTimestamp();
        }
    }

    /// Send any deferred PTY resize once resizing has stopped (no resize
    /// events for the debounce interval). Called from the event loop.
    pub fn flushPtyResize(self: *Pane) void {
        if (!self.pending_pty_resize) return;
        const now = std.time.nanoTimestamp();
        if (now - self.last_pty_resize_ns >= pty_resize_debounce_ns) {
            self.pty.resize(self.pending_pty_rows, self.pending_pty_cols) catch {};
            self.pending_pty_resize = false;
        }
    }

    /// Force TIOCSWINSZ even if engine dimensions match. Used after split
    /// to guarantee SIGWINCH delivery to child processes like vim.
    pub fn forceNotifySize(self: *Pane) void {
        const rows: u16 = @intCast(self.engine.state.ring.screen_rows);
        const cols: u16 = @intCast(self.engine.state.ring.cols);
        self.pty.resize(rows, cols) catch {};
    }

    pub fn childExited(self: *Pane) bool {
        // Session-backed panes: the local PTY is idle — ignore its exit.
        // The daemon pane lifecycle is managed via the session socket.
        if (self.daemon_pane_id != null) return false;
        return self.pty.childExited();
    }
};
