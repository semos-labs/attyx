// Attyx — Pane: Engine + PTY pair with lifecycle methods
//
// A Pane bundles a terminal Engine (parser + state) with a PTY.
// Shared by popups, tabs, and splits.

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const posix = if (!is_windows) std.posix else struct {};
const Allocator = std.mem.Allocator;
const attyx = @import("attyx");
const Engine = attyx.Engine;
const Pty = @import("pty.zig").Pty;
const IpcClient = @import("../xyron/ipc.zig").IpcClient;
pub const ViewerState = @import("viewer_state.zig").ViewerState;
const logging = @import("../logging/log.zig");
const c = @cImport({
    @cInclude("bridge.h");
});

/// Platform-appropriate invalid fd sentinel for ipc_wait_fd.
const ipc_invalid_fd: std.posix.fd_t = if (is_windows)
    std.os.windows.INVALID_HANDLE_VALUE
else
    -1;

/// Minimum interval between PTY resize (TIOCSWINSZ/SIGWINCH) signals.
/// During continuous window resizing, the engine state is updated every
/// frame for correct display, but SIGWINCH is throttled to avoid flooding
/// the shell with prompt redraws that create ghost content.
const pty_resize_throttle_ns: i128 = 80 * std.time.ns_per_ms;

pub const Pane = struct {
    engine: Engine,
    pty: Pty,
    allocator: Allocator,
    /// Stable IPC identifier. Assigned by TabManager on creation, monotonically
    /// increasing, never reused within a session. Used by all IPC targeting.
    ipc_id: u32 = 0,
    /// Daemon pane ID. When set, this pane is backed by a daemon PTY and
    /// the local PTY is idle — I/O goes through the shared session socket.
    daemon_pane_id: ?u32 = null,
    /// Session client for sending resize to daemon (set for daemon-backed panes).
    session_client: ?*@import("session_client.zig").SessionClient = null,
    /// When true, the next incoming pane_output for this pane belongs to a
    /// daemon replay burst.  Bytes are routed into `shadow_engine` (allocated
    /// lazily on the first replay byte) instead of the live `engine`, so the
    /// last known visible state stays on screen during catch-up.  On the
    /// matching `replay_end` message, `shadow_engine` is swapped into
    /// `engine` atomically — single visual transition, no blank-gap,
    /// no "Tab N" fallback, no stacked duplicate content.
    needs_engine_reinit: bool = false,
    shadow_engine: ?Engine = null,
    /// Foreground process name reported by the daemon (for title fallback).
    daemon_proc_name: [64]u8 = undefined,
    daemon_proc_name_len: u8 = 0,
    /// Foreground process CWD reported by the daemon (for popup CWD).
    daemon_fg_cwd: [512]u8 = undefined,
    daemon_fg_cwd_len: u16 = 0,
    /// IPC --wait: fd to write exit code to when this pane's process exits.
    /// Set by IPC handler when a client requests --wait. The fd is owned by
    /// this pane: deinit writes the exit code response and closes it.
    ipc_wait_fd: std.posix.fd_t = ipc_invalid_fd,
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
    /// Xyron IPC: persistent event connection for this pane (completions, etc.)
    xyron_ipc: ?*IpcClient = null,
    /// Xyron IPC: whether handshake has been completed for this pane.
    xyron_handshake_done: bool = false,
    /// Per-viewer UI state (scrollback offset, future: per-client overlays).
    /// Phase 1: scaffolding. Not yet read by consumers — viewport still lives
    /// in engine.state.viewport_offset until Phase 2 wires grid-sync.
    viewer: ViewerState = .{},
    /// Grid-sync: scrollback count at which we last fired a
    /// `get_scrollback_range` RPC. Gate to avoid spamming requests each
    /// poll tick while the user holds PgUp. Reset whenever a
    /// `scrollback_range` reply lands (growing scrollbackCount).
    last_scrollback_rpc_sb: u32 = 0,

    pub const daemon_backed_placeholder_id: u32 = 0xFFFF_FFFF;

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
        scrollback_lines: usize,
    ) !Pane {
        return spawnOpts(allocator, rows, cols, argv, cwd, scrollback_lines, .{});
    }

    pub const SpawnOpts = struct {
        capture_stdout: bool = false,
        preserve_tmux: bool = false,
        skip_shell_integration: bool = false,
        shell: if (builtin.os.tag == .windows) Pty.ShellType else void = if (builtin.os.tag == .windows) .auto else {},
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

        const spawn_opts: Pty.SpawnOpts = blk: {
            var so: Pty.SpawnOpts = .{
                .rows = rows,
                .cols = cols,
                .argv = argv,
                .cwd = cwd,
                .capture_stdout = opts.capture_stdout,
                .preserve_tmux = opts.preserve_tmux,
                .skip_shell_integration = opts.skip_shell_integration,
            };
            if (comptime builtin.os.tag == .windows) {
                so.shell = opts.shell;
            }
            break :blk so;
        };
        const pty = if (builtin.os.tag == .windows)
            try Pty.spawn(allocator, spawn_opts)
        else
            try Pty.spawn(spawn_opts);

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
            .pty = Pty.initInactive(),
            .allocator = allocator,
            .daemon_pane_id = daemon_backed_placeholder_id,
        };
    }

    pub fn deinit(self: *Pane) void {
        // Drain any remaining stdout before sending exit response.
        self.drainCapturedStdout();

        // Notify any IPC --wait client with the exit code before cleanup.
        if (self.ipc_wait_fd != ipc_invalid_fd) {
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
            ipc_protocol.closeFd(self.ipc_wait_fd);
            self.ipc_wait_fd = ipc_invalid_fd;
        }
        if (self.captured_stdout) |cs| {
            cs.deinit(self.allocator);
            self.allocator.destroy(cs);
            self.captured_stdout = null;
        }
        // Clean up xyron IPC connection for this pane.
        if (self.xyron_ipc) |xi| {
            xi.disconnectEvents();
            self.allocator.destroy(xi);
            self.xyron_ipc = null;
        }
        if (self.daemon_pane_id == null) {
            if (!is_windows) {
                _ = std.posix.kill(self.pty.pid, std.posix.SIG.HUP) catch {};
            }
            self.pty.deinit();
        }
        self.engine.deinit();
        if (self.shadow_engine) |*s| s.deinit();
    }

    /// Non-blocking drain of stdout capture pipe into captured_stdout buffer.
    pub fn drainCapturedStdout(self: *Pane) void {
        if (is_windows) return;
        const cs = self.captured_stdout orelse return;
        if (self.pty.stdout_read_fd == -1) return;
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = std.posix.read(self.pty.stdout_read_fd, &buf) catch break;
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
        // Keep shadow engine dimensions in sync so the pending swap at
        // replay_end lands at the right size.
        if (self.shadow_engine) |*s| {
            s.state.resize(rows, cols) catch {};
        }
        // Leading-edge throttle: record pending dimensions but don't reset
        // the timer. flushPtyResize() fires immediately on the first event,
        // then at most once per throttle interval during continuous resizing.
        if (rows != old_rows or cols != old_cols) {
            self.pending_pty_rows = rows;
            self.pending_pty_cols = cols;
            self.pending_pty_resize = true;
        }
    }

    /// Send pending PTY resize if the throttle interval has elapsed since
    /// the last send. Called from the event loop every iteration.
    pub fn flushPtyResize(self: *Pane) void {
        if (!self.pending_pty_resize) return;
        const now = std.time.nanoTimestamp();
        if (now - self.last_pty_resize_ns < pty_resize_throttle_ns) return;

        if (self.daemon_pane_id) |dpid| {
            if (self.session_client) |sc| {
                sc.sendPaneResize(dpid, self.pending_pty_rows, self.pending_pty_cols) catch {};
            }
        } else {
            self.pty.resize(self.pending_pty_rows, self.pending_pty_cols) catch {};
        }
        self.pending_pty_resize = false;
        self.last_pty_resize_ns = now;
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
