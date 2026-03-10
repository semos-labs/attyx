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
    pub fn fromRestored(
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
        // If a command is given, start a normal interactive shell with
        // __ATTYX_STARTUP_CMD set. The shell integration scripts execute
        // it after full init (precmd/PROMPT_COMMAND), so the user's PATH
        // and environment are fully loaded. This avoids the old $SHELL -c
        // approach where non-interactive shells skip .zshrc/.bashrc.
        var shell_argv: [1][:0]const u8 = undefined;
        const argv: ?[]const [:0]const u8 = if (shell) |s| blk: {
            shell_argv[0] = std.mem.sliceTo(s, 0);
            break :blk &shell_argv;
        } else null;

        const startup_cmd: ?[*:0]const u8 = if (cmd) |c| c else null;

        var pane = DaemonPane{
            .id = id,
            .pty = try Pty.spawn(.{
                .rows = rows,
                .cols = cols,
                .cwd = cwd,
                .argv = argv,
                .startup_cmd = startup_cmd,
                .capture_stdout = capture_stdout,
            }),
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

    /// Force a full repaint by nudging the PTY size by one column.
    /// Many TUI frameworks (Node.js, ncurses, React-based) only trigger
    /// a full redraw on an actual size change — a same-size SIGWINCH is
    /// silently ignored. We bump cols+1 here; the client restores the
    /// correct size on replay_end, providing a second SIGWINCH after the
    /// round-trip delay ensures the app has processed the first one.
    pub fn notifyRedraw(self: *DaemonPane) void {
        const nudged = if (self.cols < std.math.maxInt(u16)) self.cols + 1 else self.cols - 1;
        self.pty.resize(self.rows, nudged) catch {};
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

            // APC kitty graphics query: ESC _ G ... ESC \
            // Applications send `a=q` to detect kitty graphics support.
            if (data[i + 1] == '_') {
                if (i + 2 < data.len and data[i + 2] == 'G') {
                    // Find the APC terminator: ESC \ (ST)
                    var j = i + 3;
                    while (j + 1 < data.len) : (j += 1) {
                        if (data[j] == '\x1b' and data[j + 1] == '\\') break;
                    }
                    if (j + 1 < data.len) {
                        const params = data[i + 3 .. j];
                        if (isGraphicsQuery(params)) {
                            const gfx_id = parseGraphicsId(params);
                            self.respondGraphicsOk(gfx_id);
                        }
                        i = j + 2;
                        continue;
                    }
                }
            }

            // OSC sequences: ESC ] <num> ; ? <terminator>
            if (data[i + 1] == ']') {
                var j = i + 2;
                // Parse OSC number
                var osc_num: u16 = 0;
                var has_osc_digits = false;
                while (j < data.len and data[j] >= '0' and data[j] <= '9') : (j += 1) {
                    osc_num = osc_num *% 10 +% @as(u16, data[j] - '0');
                    has_osc_digits = true;
                }
                if (has_osc_digits and j < data.len and data[j] == ';') {
                    j += 1; // skip ';'
                    // Find terminator to get the rest payload
                    const payload_start = j;
                    var term_end: usize = j;
                    var found_term = false;
                    while (term_end < data.len) : (term_end += 1) {
                        if (data[term_end] == 0x07) {
                            found_term = true;
                            break;
                        }
                        if (data[term_end] == '\x1b' and term_end + 1 < data.len and data[term_end + 1] == '\\') {
                            found_term = true;
                            break;
                        }
                    }
                    if (found_term) {
                        const rest = data[payload_start..term_end];
                        const advanced = if (data[term_end] == 0x07) term_end + 1 else term_end + 2;
                        switch (osc_num) {
                            10 => if (std.mem.eql(u8, rest, "?")) {
                                self.respondOscColor(10, self.theme_fg);
                                i = advanced;
                                continue;
                            },
                            11 => if (std.mem.eql(u8, rest, "?")) {
                                self.respondOscColor(11, self.theme_bg);
                                i = advanced;
                                continue;
                            },
                            12 => if (std.mem.eql(u8, rest, "?")) {
                                const c = if (self.theme_cursor_set) self.theme_cursor else self.theme_fg;
                                self.respondOscColor(12, c);
                                i = advanced;
                                continue;
                            },
                            4 => {
                                // OSC 4;N;? — palette query
                                if (self.parseAndRespondPaletteQuery(rest)) {
                                    i = advanced;
                                    continue;
                                }
                            },
                            else => {},
                        }
                    }
                }
            }

            i += 1;
        }
    }

    /// Check if a kitty graphics APC payload contains `a=q` (query action).
    fn isGraphicsQuery(params: []const u8) bool {
        // params is the content between 'G' and 'ESC \', e.g. "a=q,i=31,s=1,v=1,f=24;AAAA"
        // The key-value part is before the ';' (if any).
        const kv = if (std.mem.indexOfScalar(u8, params, ';')) |semi| params[0..semi] else params;
        // Look for "a=q" as a key-value pair.
        var iter = std.mem.splitScalar(u8, kv, ',');
        while (iter.next()) |pair| {
            if (std.mem.eql(u8, pair, "a=q")) return true;
        }
        return false;
    }

    /// Parse the image_id (`i=N`) from a kitty graphics parameter string.
    fn parseGraphicsId(params: []const u8) u32 {
        const kv = if (std.mem.indexOfScalar(u8, params, ';')) |semi| params[0..semi] else params;
        var iter = std.mem.splitScalar(u8, kv, ',');
        while (iter.next()) |pair| {
            if (pair.len > 2 and pair[0] == 'i' and pair[1] == '=') {
                return std.fmt.parseInt(u32, pair[2..], 10) catch 0;
            }
        }
        return 0;
    }

    /// Respond to a kitty graphics query with OK.
    fn respondGraphicsOk(self: *DaemonPane, image_id: u32) void {
        var buf: [64]u8 = undefined;
        const resp = std.fmt.bufPrint(&buf, "\x1b_Gi={d};OK\x1b\\", .{image_id}) catch return;
        _ = self.pty.writeToPty(resp) catch {};
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

    /// Format and write an OSC color response: ESC ] <num> ; rgb:RRRR/GGGG/BBBB BEL.
    /// Uses BEL (0x07) terminator for maximum compatibility — some libraries
    /// (e.g. termbg, terminal-colorsaurus) only parse BEL-terminated responses.
    fn respondOscColor(self: *DaemonPane, osc_num: u8, rgb: [3]u8) void {
        var buf: [64]u8 = undefined;
        const resp = std.fmt.bufPrint(&buf, "\x1b]{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x07", .{
            osc_num,
            rgb[0], rgb[0],
            rgb[1], rgb[1],
            rgb[2], rgb[2],
        }) catch return;
        _ = self.pty.writeToPty(resp) catch {};
    }

    /// Parse "N;?" from an OSC 4 payload and respond with the palette color.
    fn parseAndRespondPaletteQuery(self: *DaemonPane, rest: []const u8) bool {
        const semi = std.mem.indexOfScalar(u8, rest, ';') orelse return false;
        if (!std.mem.eql(u8, rest[semi + 1 ..], "?")) return false;
        const idx = std.fmt.parseInt(u8, rest[0..semi], 10) catch return false;
        const rgb = paletteRgb(idx);
        var buf: [64]u8 = undefined;
        const resp = std.fmt.bufPrint(&buf, "\x1b]4;{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x07", .{
            idx,
            rgb[0], rgb[0],
            rgb[1], rgb[1],
            rgb[2], rgb[2],
        }) catch return false;
        _ = self.pty.writeToPty(resp) catch return false;
        return true;
    }

    /// Standard 256-color palette lookup.
    fn paletteRgb(n: u8) [3]u8 {
        if (n < 16) return ansi16[n];
        if (n < 232) {
            const idx = n - 16;
            return .{ cubeComp(idx / 36), cubeComp((idx / 6) % 6), cubeComp(idx % 6) };
        }
        const g: u8 = @intCast(@as(u16, 8) + @as(u16, n - 232) * 10);
        return .{ g, g, g };
    }

    fn cubeComp(idx: u8) u8 {
        if (idx == 0) return 0;
        return @intCast(@as(u16, 55) + @as(u16, idx) * 40);
    }

    const ansi16 = [16][3]u8{
        .{ 0, 0, 0 },
        .{ 170, 0, 0 },
        .{ 0, 170, 0 },
        .{ 170, 85, 0 },
        .{ 0, 0, 170 },
        .{ 170, 0, 170 },
        .{ 0, 170, 170 },
        .{ 170, 170, 170 },
        .{ 85, 85, 85 },
        .{ 255, 85, 85 },
        .{ 85, 255, 85 },
        .{ 255, 255, 85 },
        .{ 85, 85, 255 },
        .{ 255, 85, 255 },
        .{ 85, 255, 255 },
        .{ 255, 255, 255 },
    };

    /// Non-blocking drain of stdout capture pipe into captured_stdout buffer.
    pub fn drainCapturedStdout(self: *DaemonPane) void {
        const cs = self.captured_stdout orelse return;
        const alloc = self.stdout_allocator orelse return;
        if (self.pty.stdout_read_fd == -1) return;
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = posix.read(self.pty.stdout_read_fd, &buf) catch break;
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
};
