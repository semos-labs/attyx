const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const posix = std.posix;
const Pty = @import("../pty.zig").Pty;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;
const platform = @import("../../platform/platform.zig");
const HostConnection = if (is_windows) @import("host_pipe.zig").HostConnection else void;
const host_pipe = if (is_windows) @import("host_pipe.zig") else struct {};
const attyx = if (is_windows) @import("attyx") else struct {};

const win32_sleep = if (is_windows) struct {
    extern "kernel32" fn Sleep(dwMilliseconds: std.os.windows.DWORD) callconv(.winapi) void;
} else struct {};


/// A daemon-managed pane wrapping a PTY process and replay buffer.
/// Multiple DaemonPanes live inside a DaemonSession.
pub const DaemonPane = struct {
    id: u32,
    pty: Pty,
    /// Windows host process connection (replaces direct PTY access).
    /// When set, I/O goes through the host pipe instead of pty directly.
    host_conn: if (is_windows) ?*HostConnection else void = if (is_windows) null else {},
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
    /// Tracked OSC 7 working directory (file:// URI) for replay restoration.
    osc7_cwd: [512]u8 = .{0} ** 512,
    osc7_cwd_len: u16 = 0,
    /// Tracked OSC 7337;set-path shell PATH for replay restoration.
    osc7337_path: [2048]u8 = .{0} ** 2048,
    osc7337_path_len: u16 = 0,

    /// Heap-allocated captured stdout for --wait mode.
    /// Only allocated when capture_stdout is requested at spawn time.
    captured_stdout: ?*std.ArrayList(u8) = null,
    stdout_allocator: ?std.mem.Allocator = null,

    /// Theme colors for OSC 10/11/12/4 query responses.
    /// Defaults match Theme.default(). Updated by the client via protocol.
    theme_fg: [3]u8 = .{ 220, 220, 220 },
    theme_bg: [3]u8 = .{ 30, 30, 36 },
    theme_cursor: [3]u8 = .{ 220, 220, 220 },
    theme_cursor_set: bool = false,

    /// Restore a pane from deserialized state (inherited PTY fd across exec).
    /// POSIX only — Windows hot-upgrade builds panes directly in upgrade_windows.zig.
    pub const fromRestored = if (!is_windows) fromRestoredImpl else @compileError("fromRestored not available on Windows");

    fn fromRestoredImpl(
        allocator: std.mem.Allocator,
        id: u32,
        pty_fd: posix.fd_t,
        pty_pid: posix.pid_t,
        rows: u16,
        cols: u16,
        alive: bool,
        exit_code: ?u8,
        cursor_visible: bool,
        alt_screen: bool,
        proc_name_slice: []const u8,
        ring_data: []const u8,
        replay_capacity: usize,
    ) !DaemonPane {
        var pane = DaemonPane{
            .id = id,
            .pty = Pty.fromExisting(pty_fd, pty_pid),
            .replay = try RingBuffer.init(allocator, replay_capacity),
            .rows = rows,
            .cols = cols,
            .alive = alive,
            .exit_code = exit_code,
            .cursor_visible = cursor_visible,
            .alt_screen = alt_screen,
        };
        // Restore process name
        const nlen: u8 = @intCast(@min(proc_name_slice.len, 64));
        @memcpy(pane.proc_name[0..nlen], proc_name_slice[0..nlen]);
        pane.proc_name_len = nlen;
        // Restore ring buffer contents
        if (ring_data.len > 0) pane.replay.write(ring_data);
        return pane;
    }

    pub fn spawn(
        allocator: std.mem.Allocator,
        id: u32,
        rows: u16,
        cols: u16,
        replay_capacity: usize,
        cwd: ?[*:0]const u8,
        shell: ?[*:0]const u8,
        cmd: ?[*:0]const u8,
        capture_stdout: bool,
    ) !DaemonPane {
        if (comptime is_windows) {
            return spawnViaHost(allocator, id, rows, cols, replay_capacity, cwd, shell, cmd);
        }
        // POSIX path: spawn PTY directly.
        // Shell may contain space-separated args (e.g. "xyron --ipc").
        // Split on spaces to construct multi-element argv.
        var shell_argv: [4][:0]const u8 = undefined;
        var shell_argc: usize = 0;
        var shell_split_buf: [257]u8 = undefined;
        const argv: ?[]const [:0]const u8 = if (shell) |s| blk: {
            const shell_str = std.mem.sliceTo(s, 0);
            if (shell_str.len == 0) break :blk null;
            @memcpy(shell_split_buf[0..shell_str.len], shell_str);
            var pos: usize = 0;
            while (pos < shell_str.len and shell_argc < shell_argv.len) {
                while (pos < shell_str.len and shell_split_buf[pos] == ' ') pos += 1;
                if (pos >= shell_str.len) break;
                const start = pos;
                while (pos < shell_str.len and shell_split_buf[pos] != ' ') pos += 1;
                shell_split_buf[pos] = 0;
                shell_argv[shell_argc] = shell_split_buf[start..pos :0];
                shell_argc += 1;
                if (pos < shell_str.len) pos += 1;
            }
            if (shell_argc > 0) break :blk shell_argv[0..shell_argc] else break :blk null;
        } else null;

        const startup_cmd: ?[*:0]const u8 = if (cmd) |c| c else null;

        const pty_opts = Pty.SpawnOpts{
            .rows = rows,
            .cols = cols,
            .cwd = cwd,
            .argv = argv,
            .startup_cmd = startup_cmd,
            .capture_stdout = capture_stdout,
        };
        var pane = DaemonPane{
            .id = id,
            .pty = try Pty.spawn(pty_opts),
            .replay = try RingBuffer.init(allocator, replay_capacity),
            .rows = rows,
            .cols = cols,
        };

        if (capture_stdout) {
            const cs = allocator.create(std.ArrayList(u8)) catch null;
            if (cs) |c| c.* = .empty;
            pane.captured_stdout = cs;
            pane.stdout_allocator = allocator;
        }

        return pane;
    }

    /// Windows: spawn a host process and connect to it via named pipe.
    fn spawnViaHost(
        allocator: std.mem.Allocator,
        id: u32,
        rows: u16,
        cols: u16,
        replay_capacity: usize,
        cwd: ?[*:0]const u8,
        shell: ?[*:0]const u8,
        cmd: ?[*:0]const u8,
    ) !DaemonPane {
        const shell_type = if (shell) |s| deriveShellType(std.mem.sliceTo(s, 0)) else "auto";
        const is_dev = comptime !std.mem.eql(u8, attyx.env, "production");

        const host_pid = host_pipe.spawnHostProcess(id, shell_type, rows, cols, cwd, cmd, is_dev);
        if (host_pid == 0) return error.HostSpawnFailed;

        // Connect to the host's named pipe.
        const conn = try allocator.create(HostConnection);
        conn.* = host_pipe.HostConnection.connect(id, is_dev) orelse {
            allocator.destroy(conn);
            return error.HostConnectFailed;
        };

        // Wait for READY frame.
        if (!host_pipe.waitForReady(conn, 10_000)) {
            conn.deinit();
            allocator.destroy(conn);
            return error.HostReadyTimeout;
        }
        conn.host_pid = host_pid;

        return DaemonPane{
            .id = id,
            .pty = Pty.initInactive(),
            .host_conn = conn,
            .replay = try RingBuffer.init(allocator, replay_capacity),
            .rows = rows,
            .cols = cols,
        };
    }

    fn deriveShellType(shell_str: []const u8) []const u8 {
        if (std.mem.indexOf(u8, shell_str, "wsl") != null) return "wsl";
        if (std.mem.indexOf(u8, shell_str, "zsh") != null) return "zsh";
        if (std.mem.indexOf(u8, shell_str, "bash") != null) return "bash";
        if (std.mem.indexOf(u8, shell_str, "pwsh") != null) return "pwsh";
        if (std.mem.indexOf(u8, shell_str, "powershell") != null) return "pwsh";
        if (std.mem.indexOf(u8, shell_str, "cmd") != null) return "cmd";
        return "auto";
    }

    /// Process data already in the output buffer (from host pipe frames).
    /// Updates replay buffer and mode tracking without copying.
    pub fn absorbHostOutput(self: *DaemonPane, data: []const u8) void {
        if (data.len > 0) {
            if (findLastEraseScrollback(data)) |pos| {
                self.replay.clear();
                self.replay.write(data[pos..]);
            } else {
                self.replay.write(data);
            }
            self.trackModes(data);
            self.trackOsc(data);
            self.interceptQueries(data);
        }
    }

    /// Process already-read PTY data (from async read completion).
    /// Copies into `out_buf`, updates replay buffer and mode tracking.
    /// Returns the number of bytes copied.
    pub fn absorbPtyData(self: *DaemonPane, data: []const u8, out_buf: []u8) usize {
        const n = @min(data.len, out_buf.len);
        @memcpy(out_buf[0..n], data[0..n]);
        if (n > 0) {
            const slice = out_buf[0..n];
            if (findLastEraseScrollback(slice)) |pos| {
                self.replay.clear();
                self.replay.write(slice[pos..]);
            } else {
                self.replay.write(slice);
            }
            self.trackModes(slice);
            self.trackOsc(slice);
            self.interceptQueries(slice);
        }
        return n;
    }

    /// Non-blocking read from PTY master. Stores data in replay buffer.
    /// Returns number of bytes read, or 0 if nothing available.
    pub fn readPty(self: *DaemonPane, buf: []u8) !usize {
        const n = try self.pty.read(buf);
        if (n > 0) {
            const data = buf[0..n];
            // Detect CSI 3J (Erase Saved Lines) and truncate the replay
            // buffer so replayed sessions don't resurrect cleared scrollback.
            if (findLastEraseScrollback(data)) |pos| {
                self.replay.clear();
                self.replay.write(data[pos..]);
            } else {
                self.replay.write(data);
            }
            self.trackModes(data);
            self.trackOsc(data);
            self.interceptQueries(data);
        }
        return n;
    }

    /// Scan for the last occurrence of CSI 3 J (`\x1b[3J`) in `data`.
    /// Returns the byte offset just past the sequence, or null if not found.
    fn findLastEraseScrollback(data: []const u8) ?usize {
        if (data.len < 4) return null;
        var found: ?usize = null;
        var i: usize = 0;
        while (i + 3 < data.len) : (i += 1) {
            if (data[i] == '\x1b' and data[i + 1] == '[' and data[i + 2] == '3' and data[i + 3] == 'J') {
                found = i + 4;
                i += 3; // skip past, loop will +1
            }
        }
        return found;
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

    /// Scan output for OSC sequences we need to restore on replay.
    /// Tracks OSC 7 (working directory) and OSC 7337;set-path (shell PATH).
    fn trackOsc(self: *DaemonPane, data: []const u8) void {
        const esc = '\x1b';
        var i: usize = 0;
        while (i + 1 < data.len) : (i += 1) {
            if (data[i] != esc or data[i + 1] != ']') continue;
            // Found ESC ] — parse OSC number
            var j = i + 2;
            var num: u16 = 0;
            var has_digits = false;
            while (j < data.len and data[j] >= '0' and data[j] <= '9') : (j += 1) {
                num = num *% 10 +% @as(u16, data[j] - '0');
                has_digits = true;
            }
            if (!has_digits) continue;
            if (j >= data.len or data[j] != ';') continue;
            j += 1; // skip ';'
            // Find the OSC terminator: BEL (0x07) or ST (ESC \)
            const payload_start = j;
            while (j < data.len) : (j += 1) {
                if (data[j] == 0x07) break;
                if (data[j] == esc and j + 1 < data.len and data[j + 1] == '\\') break;
            }
            if (j >= data.len) continue;
            const payload = data[payload_start..j];

            switch (num) {
                7 => {
                    const len: u16 = @intCast(@min(payload.len, self.osc7_cwd.len));
                    @memcpy(self.osc7_cwd[0..len], payload[0..len]);
                    self.osc7_cwd_len = len;
                },
                7337 => {
                    const prefix = "set-path;";
                    if (payload.len >= prefix.len and std.mem.eql(u8, payload[0..prefix.len], prefix)) {
                        const path = payload[prefix.len..];
                        const len: u16 = @intCast(@min(path.len, self.osc7337_path.len));
                        @memcpy(self.osc7337_path[0..len], path[0..len]);
                        self.osc7337_path_len = len;
                    }
                },
                else => {},
            }
            i = j;
        }
    }

    /// Route bytes to PTY input — via host pipe on Windows, direct on POSIX.
    pub fn writeToPtyInput(self: *DaemonPane, bytes: []const u8) void {
        if (comptime is_windows) {
            if (self.host_conn) |hc| {
                _ = hc.sendDataIn(bytes);
                return;
            }
        }
        _ = self.pty.writeToPty(bytes) catch {};
    }

    /// Write input bytes to PTY master (keystrokes from client).
    /// Handles short writes and WouldBlock on non-blocking PTY fds
    /// by retrying with a brief sleep (bounded to avoid stalling the
    /// daemon event loop for too long).
    pub fn writeInput(self: *DaemonPane, bytes: []const u8) !void {
        if (comptime is_windows) {
            if (self.host_conn) |hc| {
                if (!hc.sendDataIn(bytes)) return error.WriteFailed;
                return;
            }
        }
        var offset: usize = 0;
        var retries: u32 = 0;
        const max_retries: u32 = 50; // 50ms max stall
        while (offset < bytes.len) {
            const n = self.pty.writeToPty(bytes[offset..]) catch |err| {
                if (err == error.WouldBlock) {
                    retries += 1;
                    if (retries >= max_retries) return; // give up, don't stall daemon
                    if (comptime is_windows) {
                        win32_sleep.Sleep(1); // 1ms
                    } else {
                        posix.nanosleep(0, 1_000_000); // 1ms
                    }
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
        if (comptime is_windows) {
            if (self.host_conn) |hc| {
                if (!hc.sendResize(rows, cols)) return error.ResizeFailed;
                self.rows = rows;
                self.cols = cols;
                return;
            }
        }
        try self.pty.resize(rows, cols);
        self.rows = rows;
        self.cols = cols;
    }

    /// Force a full repaint by nudging the PTY size by one column.
    pub fn notifyRedraw(self: *DaemonPane) void {
        const nudged = if (self.cols < std.math.maxInt(u16)) self.cols + 1 else self.cols - 1;
        if (comptime is_windows) {
            if (self.host_conn) |hc| {
                _ = hc.sendResize(self.rows, nudged);
                return;
            }
        }
        self.pty.resize(self.rows, nudged) catch {};
    }

    /// Non-blocking check if child process has exited.
    /// On Windows with host process, exit is detected via EXITED frame
    /// (set externally by daemon_windows.zig polling code).
    pub fn checkExit(self: *DaemonPane) ?u8 {
        if (self.exit_code) |code| return code;
        if (comptime is_windows) {
            if (self.host_conn != null) return null; // Exit detected via EXITED frame
        }
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
        const name = if (comptime is_windows) blk: {
            // Windows: walk the process tree from the host PID to find the
            // deepest leaf (the actual foreground command like vim, git, etc.)
            const win_plat = @import("../../platform/windows.zig");
            const pid = if (self.host_conn) |hc| hc.host_pid else 0;
            break :blk win_plat.getDeepestChildName(pid, &buf);
        } else platform.getForegroundProcessName(self.pty.master, &buf);

        const resolved = name orelse return null;
        const len: u8 = @intCast(@min(resolved.len, 64));
        if (len == self.proc_name_len and std.mem.eql(u8, self.proc_name[0..len], resolved[0..len])) {
            return null; // unchanged
        }
        @memcpy(self.proc_name[0..len], resolved[0..len]);
        self.proc_name_len = len;
        return self.proc_name[0..len];
    }

    const pane_queries = @import("pane_queries.zig");

    /// Scan PTY output for terminal queries and write immediate responses.
    fn interceptQueries(self: *DaemonPane, data: []const u8) void {
        pane_queries.interceptQueries(self, data);
    }

    /// Non-blocking drain of stdout capture pipe into captured_stdout buffer.
    pub fn drainCapturedStdout(self: *DaemonPane) void {
        if (comptime is_windows) return; // stdout capture not supported on Windows yet
        const cs = self.captured_stdout orelse return;
        const alloc = self.stdout_allocator orelse return;
        if (self.pty.stdout_read_fd == -1) return;
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = std.posix.read(self.pty.stdout_read_fd, &buf) catch break;
            if (n == 0) break;
            cs.appendSlice(alloc, buf[0..n]) catch break;
        }
    }

    /// Get captured stdout data (if any).
    pub fn getCapturedStdout(self: *const DaemonPane) []const u8 {
        if (self.captured_stdout) |cs| return cs.items;
        return &[_]u8{};
    }

    pub fn deinit(self: *DaemonPane) void {
        self.deinitHost();
        if (self.captured_stdout) |cs| {
            if (self.stdout_allocator) |alloc| {
                cs.deinit(alloc);
                alloc.destroy(cs);
            }
        }
        self.pty.deinit();
        self.replay.deinit();
        self.* = undefined;
    }

    fn deinitHost(self: *DaemonPane) void {
        if (comptime !is_windows) return;
        if (self.host_conn) |hc| {
            if (self.alive) _ = hc.sendKill();
            hc.deinit();
            // Note: allocator for HostConnection is not stored here.
            // The caller (daemon) is responsible for freeing if heap-allocated.
        }
    }
};
