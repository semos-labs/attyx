const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const protocol = @import("protocol.zig");
const grid_sync = @import("grid_sync.zig");
const DaemonSession = @import("session.zig").DaemonSession;
const DaemonPane = @import("pane.zig").DaemonPane;

// Windows API imports for named pipe I/O.
const win32 = if (is_windows) struct {
    const windows = std.os.windows;
    const HANDLE = windows.HANDLE;
    const DWORD = windows.DWORD;
    const BOOL = windows.BOOL;

    extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nRead: DWORD, lpBytesRead: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nWrite: DWORD, lpWritten: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn PeekNamedPipe(hPipe: HANDLE, lpBuf: ?[*]u8, nBufSize: DWORD, lpRead: ?*DWORD, lpAvail: ?*DWORD, lpLeft: ?*DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;
} else struct {};

/// A connected client being served by the daemon.
pub const DaemonClient = struct {
    socket_fd: std.posix.fd_t,
    read_buf: [65536]u8 = undefined,
    read_len: usize = 0,
    msg_buf: [65536]u8 = undefined, // stable copy for nextMessage payloads
    attached_session: ?u32 = null,
    dead: bool = false,
    /// V2: active panes set (panes the client is currently displaying)
    active_panes: [32]u32 = .{0} ** 32,
    active_pane_count: u8 = 0,
    /// Last engine_generation shipped to this client per active pane,
    /// parallel-indexed with `active_panes`. 0 means "nothing sent yet" →
    /// next emission will be a full snapshot. Reset when the slot is
    /// reassigned to a different pane_id in handleFocusPanes.
    active_pane_last_gen: [32]u64 = .{0} ** 32,
    /// Capability bits advertised by this client in its hello payload.
    /// 0 for legacy clients that didn't send caps. Daemon uses this to
    /// decide whether it can ship grid_snapshot/grid_delta or must fall
    /// back to the legacy byte-stream (pane_output) path.
    peer_caps: u32 = 0,

    pub fn init(fd: std.posix.fd_t) DaemonClient {
        return .{ .socket_fd = fd };
    }

    /// Read available data from socket into read_buf. Returns false if connection closed/broken.
    pub fn recvData(self: *DaemonClient) bool {
        const space = self.read_buf[self.read_len..];
        if (space.len == 0) {
            // Buffer full with no complete message extractable — the client
            // sent an oversized or malformed message. Kill the connection
            // rather than discarding data (which would desync the stream).
            return false;
        }
        if (comptime is_windows) {
            // Non-blocking read: peek first, then read if data available.
            var avail: win32.DWORD = 0;
            if (win32.PeekNamedPipe(self.socket_fd, null, 0, null, &avail, null) == 0) return false;
            if (avail == 0) return true; // no data yet
            const to_read: win32.DWORD = @intCast(@min(avail, space.len));
            var bytes_read: win32.DWORD = 0;
            if (win32.ReadFile(self.socket_fd, space.ptr, to_read, &bytes_read, null) == 0) return false;
            if (bytes_read == 0) return false;
            self.read_len += bytes_read;
        } else {
            const n = std.posix.read(self.socket_fd, space) catch |err| switch (err) {
                error.WouldBlock => return true,
                else => return false,
            };
            if (n == 0) return false; // EOF
            self.read_len += n;
        }
        return true;
    }

    /// Parsed message from client.
    pub const Message = struct {
        msg_type: protocol.MessageType,
        payload: []const u8,
    };

    /// Maximum payload size we accept. Messages larger than this are from
    /// a buggy or hostile client — disconnect rather than spin forever.
    const max_payload_size: u32 = 60000; // well under 65536 read_buf

    /// Try to extract the next complete message from the read buffer.
    /// Returns null if no complete message is available yet.
    /// Marks client as dead if the message is malformed/oversized.
    pub fn nextMessage(self: *DaemonClient) ?Message {
        if (self.read_len < protocol.header_size) return null;

        // Read payload length from header (first 4 bytes) before decoding
        // the message type, so we can skip unknown messages cleanly.
        const payload_len = std.mem.readInt(u32, self.read_buf[0..4], .little);

        // Reject oversized payloads — they'd never fit in our buffer and
        // would cause the daemon to spin forever waiting for more data.
        if (payload_len > max_payload_size) {
            self.dead = true;
            return null;
        }

        const total = protocol.header_size + @as(usize, payload_len);
        if (self.read_len < total) return null;

        const header = protocol.decodeHeader(self.read_buf[0..protocol.header_size]) catch {
            // Unknown message type — skip the entire message (header + payload)
            // to keep the stream in sync.
            self.consumeBytes(total);
            return null;
        };

        const payload = self.read_buf[protocol.header_size..total];
        // Copy payload to stable msg_buf before consuming,
        // since consumeBytes shifts read_buf and invalidates the slice.
        const len = payload.len;
        @memcpy(self.msg_buf[0..len], payload);
        self.consumeBytes(total);
        return Message{
            .msg_type = header.msg_type,
            .payload = self.msg_buf[0..len],
        };
    }

    fn consumeBytes(self: *DaemonClient, n: usize) void {
        const remaining = self.read_len - n;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.read_buf[0..remaining], self.read_buf[n .. n + remaining]);
        }
        self.read_len = remaining;
    }

    /// Send a raw pre-encoded message to the client.
    pub fn sendRaw(self: *DaemonClient, data: []const u8) void {
        self.writeAll(data);
    }

    /// Max payload per output message. Must be well under the client's 65536-byte
    /// read buffer so a complete message (header + payload) always fits.
    const max_output_chunk = 32768;

    /// Write all bytes to the client socket, handling partial writes.
    /// POSIX: non-blocking socket with poll for writability. If the client
    /// can't drain data within ~2s the connection is considered dead.
    /// The generous timeout combined with enlarged SO_SNDBUF (256KB) prevents
    /// killing clients during rapid output bursts (e.g. nx test runners).
    /// Windows: synchronous WriteFile on named pipe.
    fn writeAll(self: *DaemonClient, data: []const u8) void {
        if (comptime is_windows) {
            var offset: usize = 0;
            var stalls: u32 = 0;
            while (offset < data.len) {
                var written: win32.DWORD = 0;
                if (win32.WriteFile(self.socket_fd, data[offset..].ptr, @intCast(data.len - offset), &written, null) == 0) {
                    stalls += 1;
                    if (stalls > 200) { // 200 × 10ms = 2s
                        self.dead = true;
                        return;
                    }
                    win32.Sleep(10);
                    continue;
                }
                if (written == 0) {
                    self.dead = true;
                    return;
                }
                stalls = 0;
                offset += written;
            }
        } else {
            const POLLOUT: i16 = 0x0004;
            var offset: usize = 0;
            var stalls: u32 = 0;
            while (offset < data.len) {
                const n = std.posix.write(self.socket_fd, data[offset..]) catch |err| {
                    if (err == error.WouldBlock) {
                        stalls += 1;
                        if (stalls > 200) { // 200 × 10ms = 2s
                            self.dead = true;
                            return;
                        }
                        var fds = [1]std.posix.pollfd{.{ .fd = self.socket_fd, .events = POLLOUT, .revents = 0 }};
                        _ = std.posix.poll(&fds, 10) catch {};
                        continue;
                    }
                    self.dead = true;
                    return;
                };
                if (n == 0) {
                    self.dead = true;
                    return;
                }
                stalls = 0; // reset on progress
                offset += n;
            }
        }
    }

    /// Send a Created response.
    pub fn sendCreated(self: *DaemonClient, session_id: u32) void {
        var buf: [protocol.header_size + 4]u8 = undefined;
        var payload: [4]u8 = undefined;
        _ = protocol.encodeCreated(&payload, session_id) catch return;
        _ = protocol.encodeMessage(&buf, .created, &payload) catch return;
        self.sendRaw(&buf);
    }

    /// Send an Error response.
    pub fn sendError(self: *DaemonClient, code: u8, msg: []const u8) void {
        var buf: [protocol.header_size + 259]u8 = undefined; // max: 1+2+256 = 259
        var payload: [259]u8 = undefined;
        const p = protocol.encodeError(&payload, code, msg) catch return;
        const m = protocol.encodeMessage(&buf, .err, p) catch return;
        self.sendRaw(m);
    }

    // sendSessionList removed — use sendSessionListFromSlots instead.

    /// Send replay data from a pane's ring buffer as pane_output messages.
    /// Prepends mode-restore sequences so the engine starts in the correct
    /// state even if the ring buffer no longer contains the original switches.
    pub fn sendPaneReplay(self: *DaemonClient, pane: *DaemonPane) void {
        var slices = pane.replay.readSlices();
        if (slices.first.len == 0 and slices.second.len == 0) return;

        // Skip any partial escape sequence at the ring buffer start.
        // When the buffer wraps, the boundary can split a CSI like
        // \x1b[48;2;30;30;40m — the tail "48;2;30;30;40m" would be
        // displayed as literal text without this fixup.
        const skip = skipPartialEscape(slices.first);
        slices.first = slices.first[skip..];

        // Build a mode-restore prefix: SGR reset + cursor visibility + alt screen.
        var prefix: [32]u8 = undefined;
        var plen: usize = 0;
        // SGR reset
        @memcpy(prefix[plen..][0..4], "\x1b[0m");
        plen += 4;
        // Alternate screen
        if (pane.alt_screen) {
            @memcpy(prefix[plen..][0..8], "\x1b[?1049h");
            plen += 8;
        }
        // Cursor visibility (send after replay data so it takes final effect)
        self.sendPaneOutput(pane.id, prefix[0..plen]);
        var in_osc7337 = false;
        if (slices.first.len > 0) self.sendReplayStripped(pane.id, slices.first, &in_osc7337);
        if (slices.second.len > 0) self.sendReplayStripped(pane.id, slices.second, &in_osc7337);
        // Apply cursor visibility after replay — the replay may toggle it,
        // but the tracked state reflects the most recent value.
        if (!pane.cursor_visible) {
            self.sendPaneOutput(pane.id, "\x1b[?25l");
        }
        // Restore OSC 7 (working directory) if tracked — the replay ring
        // buffer may no longer contain the original sequence (e.g. TUI tabs
        // where the shell prompt hasn't re-emitted it).
        if (pane.osc7_cwd_len > 0) {
            var osc7_buf: [512 + 8]u8 = undefined;
            const osc7 = std.fmt.bufPrint(&osc7_buf, "\x1b]7;{s}\x07", .{pane.osc7_cwd[0..pane.osc7_cwd_len]}) catch null;
            if (osc7) |seq| self.sendPaneOutput(pane.id, seq);
        }
        // Restore OSC 7337;set-path (shell PATH) similarly.
        if (pane.osc7337_path_len > 0) {
            var path_buf: [2048 + 20]u8 = undefined;
            const osc = std.fmt.bufPrint(&path_buf, "\x1b]7337;set-path;{s}\x07", .{pane.osc7337_path[0..pane.osc7337_path_len]}) catch null;
            if (osc) |seq| self.sendPaneOutput(pane.id, seq);
        }
    }

    /// Send replay data, stripping OSC 7337;set-path sequences.
    /// `in_osc` tracks cross-slice state (true = mid-sequence from previous call).
    fn sendReplayStripped(self: *DaemonClient, pane_id: u32, data: []const u8, in_osc: *bool) void {
        var i: usize = 0;
        var last: usize = 0;

        // Continue skipping if previous slice ended mid-OSC-7337.
        if (in_osc.*) {
            while (i < data.len) : (i += 1) {
                if (data[i] == 0x07) { i += 1; break; }
                if (data[i] == '\x1b' and i + 1 < data.len and data[i + 1] == '\\') {
                    i += 2;
                    break;
                }
            }
            in_osc.* = (i >= data.len);
            last = i;
        }

        while (i < data.len) {
            if (data[i] == '\x1b' and i + 6 < data.len and data[i + 1] == ']' and
                data[i + 2] == '7' and data[i + 3] == '3' and
                data[i + 4] == '3' and data[i + 5] == '7' and data[i + 6] == ';')
            {
                if (i > last) self.sendPaneOutput(pane_id, data[last..i]);
                var j = i + 7;
                while (j < data.len) : (j += 1) {
                    if (data[j] == 0x07) { j += 1; break; }
                    if (data[j] == '\x1b' and j + 1 < data.len and data[j + 1] == '\\') {
                        j += 2;
                        break;
                    }
                }
                if (j >= data.len) in_osc.* = true;
                last = j;
                i = j;
                continue;
            }
            i += 1;
        }
        if (last < data.len) self.sendPaneOutput(pane_id, data[last..]);
    }

    /// Skip past a partial escape sequence at the start of replay data.
    /// The ring buffer can wrap mid-sequence, leaving a tail without the
    /// leading ESC. We detect CSI (`[`), OSC (`]`), DCS (`P`), and APC (`_`)
    /// tails so they aren't rendered as literal text.
    /// Returns the number of bytes to skip (0 if no partial sequence detected).
    fn skipPartialEscape(data: []const u8) usize {
        if (data.len == 0) return 0;
        const first = data[0];

        // CSI tail: `[` followed by parameter/intermediate/final bytes.
        // ESC was the last byte before the wrap point.
        if (first == '[') {
            var i: usize = 1;
            const limit = @min(data.len, 64);
            while (i < limit) : (i += 1) {
                const b = data[i];
                if (b >= 0x30 and b <= 0x3f) continue; // CSI param
                if (b >= 0x20 and b <= 0x2f) continue; // CSI intermediate
                if (b >= 0x40 and b <= 0x7e) return i + 1; // CSI final byte
                return 0;
            }
            return 0;
        }

        // OSC tail (`]`), DCS tail (`P`), APC tail (`_`):
        // These are string-type sequences terminated by BEL (0x07) or ST (ESC \).
        // Skip everything up to and including the terminator.
        if (first == ']' or first == 'P' or first == '_') {
            var i: usize = 1;
            const limit = @min(data.len, 4096); // OSC can be long (e.g. base64 images)
            while (i < limit) : (i += 1) {
                if (data[i] == 0x07) return i + 1; // BEL terminator
                if (data[i] == 0x1b and i + 1 < data.len and data[i + 1] == '\\') return i + 2; // ST
            }
            // No terminator found within limit — skip the entire prefix to
            // avoid dumping a huge partial sequence as literal text.
            return @min(data.len, limit);
        }

        return 0;
    }

    /// Send a V2 Attached response with layout blob and pane IDs.
    pub fn sendAttachedV2(self: *DaemonClient, session: *DaemonSession) void {
        var pane_ids: [32]u32 = undefined;
        const pane_count = session.collectPaneIds(&pane_ids);
        var payload_buf: [4096 + 140]u8 = undefined; // 4+2+4096+1+32*4
        const payload = protocol.encodeAttachedV2(
            &payload_buf,
            session.id,
            session.layout_data[0..session.layout_len],
            pane_ids[0..pane_count],
        ) catch return;
        var hdr: [protocol.header_size]u8 = undefined;
        protocol.encodeHeader(&hdr, .attached, @intCast(payload.len));
        self.writeAll(&hdr);
        if (!self.dead) self.writeAll(payload);
    }

    /// Send a layout_sync broadcast (same payload as attached, different msg type).
    pub fn sendLayoutSync(self: *DaemonClient, session: *DaemonSession) void {
        var pane_ids: [32]u32 = undefined;
        const pane_count = session.collectPaneIds(&pane_ids);
        var payload_buf: [4096 + 140]u8 = undefined;
        const payload = protocol.encodeAttachedV2(
            &payload_buf,
            session.id,
            session.layout_data[0..session.layout_len],
            pane_ids[0..pane_count],
        ) catch return;
        var hdr: [protocol.header_size]u8 = undefined;
        protocol.encodeHeader(&hdr, .layout_sync, @intCast(payload.len));
        self.writeAll(&hdr);
        if (!self.dead) self.writeAll(payload);
    }

    /// Send session list directly from session slots (avoids copying large structs).
    pub fn sendSessionListFromSlots(self: *DaemonClient, sessions: *[32]?DaemonSession) void {
        var entries: [32]protocol.SessionEntry = undefined;
        var count: usize = 0;
        for (sessions) |*slot| {
            if (slot.*) |*s| {
                if (count >= 32) break;
                entries[count] = .{
                    .id = s.id,
                    .name = s.getName(),
                    .alive = s.alive,
                };
                count += 1;
            }
        }

        var payload_buf: [4096]u8 = undefined;
        const payload = protocol.encodeSessionList(&payload_buf, entries[0..count]) catch return;

        var msg_buf: [4096 + protocol.header_size]u8 = undefined;
        const msg = protocol.encodeMessage(&msg_buf, .session_list, payload) catch return;
        self.sendRaw(msg);
    }

    // ── V2 send helpers ──

    /// Send a PaneCreated response.
    pub fn sendPaneCreated(self: *DaemonClient, pane_id: u32) void {
        var buf: [protocol.header_size + 4]u8 = undefined;
        var payload: [4]u8 = undefined;
        _ = protocol.encodePaneCreated(&payload, pane_id) catch return;
        _ = protocol.encodeMessage(&buf, .pane_created, &payload) catch return;
        self.sendRaw(&buf);
    }

    /// Send a PaneOutput message (pane-multiplexed PTY output).
    /// Large payloads are split into multiple messages.
    pub fn sendPaneOutput(self: *DaemonClient, pane_id: u32, pty_data: []const u8) void {
        var offset: usize = 0;
        while (offset < pty_data.len and !self.dead) {
            const remaining = pty_data.len - offset;
            const chunk_len: u32 = @intCast(@min(remaining, max_output_chunk - 4));
            const payload_len: u32 = 4 + chunk_len;
            var hdr: [protocol.header_size]u8 = undefined;
            protocol.encodeHeader(&hdr, .pane_output, payload_len);
            self.writeAll(&hdr);
            if (self.dead) break;
            var id_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &id_buf, pane_id, .little);
            self.writeAll(&id_buf);
            if (self.dead) break;
            self.writeAll(pty_data[offset .. offset + chunk_len]);
            offset += chunk_len;
        }
    }

    /// Send a PaneDied notification.
    pub fn sendPaneDied(self: *DaemonClient, pane_id: u32, exit_code: u8) void {
        self.sendPaneDiedWithStdout(pane_id, exit_code, &[_]u8{});
    }

    pub fn sendPaneDiedWithStdout(self: *DaemonClient, pane_id: u32, exit_code: u8, stdout_data: []const u8) void {
        if (stdout_data.len == 0) {
            // Small fixed-size message for common case
            var buf: [protocol.header_size + 5]u8 = undefined;
            var payload: [5]u8 = undefined;
            _ = protocol.encodePaneDied(&payload, pane_id, exit_code) catch return;
            _ = protocol.encodeMessage(&buf, .pane_died, &payload) catch return;
            self.sendRaw(&buf);
        } else {
            // Variable-size: header + pane_id(4) + exit_code(1) + stdout_len(4) + stdout_data
            const payload_len: u32 = @intCast(5 + 4 + stdout_data.len);
            var hdr: [protocol.header_size]u8 = undefined;
            protocol.encodeHeader(&hdr, .pane_died, payload_len);
            self.sendRaw(&hdr);
            var meta: [9]u8 = undefined;
            std.mem.writeInt(u32, meta[0..4], pane_id, .little);
            meta[4] = exit_code;
            std.mem.writeInt(u32, meta[5..9], @intCast(stdout_data.len), .little);
            self.sendRaw(&meta);
            self.sendRaw(stdout_data);
        }
    }

    /// True if this client negotiated grid-sync mode in its hello caps.
    pub fn hasGridSync(self: *const DaemonClient) bool {
        return self.peer_caps & protocol.Capabilities.GRID_SYNC != 0;
    }

    /// Find the index of pane_id in active_panes, or null.
    pub fn findActivePaneSlot(self: *const DaemonClient, pane_id: u32) ?usize {
        for (self.active_panes[0..self.active_pane_count], 0..) |id, i| {
            if (id == pane_id) return i;
        }
        return null;
    }

    /// Ship the pane's current engine cell grid to this client as one or
    /// more grid_snapshot chunks. No-op if the pane has no engine.
    /// Updates active_pane_last_gen on success. `force` sends even if
    /// the generation hasn't advanced (used by handleFocusPanes to prime
    /// a newly-active slot).
    pub fn sendGridSnapshot(self: *DaemonClient, pane: *DaemonPane, force: bool) void {
        const eng = pane.engine orelse {
            std.log.scoped(.grid).info("sendGridSnapshot: pane {d} has no engine", .{pane.id});
            return;
        };
        const slot = self.findActivePaneSlot(pane.id) orelse {
            std.log.scoped(.grid).info("sendGridSnapshot: pane {d} not in active set", .{pane.id});
            return;
        };
        const gen = pane.engine_generation;
        if (!force and self.active_pane_last_gen[slot] == gen) return;

        const rows = pane.rows;
        const cols = pane.cols;
        if (rows == 0 or cols == 0) {
            std.log.scoped(.grid).warn("sendGridSnapshot: pane {d} has zero dims ({d}x{d})", .{ pane.id, rows, cols });
            return;
        }
        std.log.scoped(.grid).info("sendGridSnapshot: pane {d} gen={d} force={} {d}x{d}", .{ pane.id, gen, force, rows, cols });
        // Dump first row non-space cells to verify engine state.
        var non_space: u16 = 0;
        for (0..cols) |c2| {
            const cell = eng.state.ring.getScreenCell(0, c2);
            if (cell.char != ' ' and cell.char != 0) non_space += 1;
        }
        std.log.scoped(.grid).info("  row0 non-space cells: {d}, cursor=({d},{d})", .{ non_space, eng.state.cursor.row, eng.state.cursor.col });

        // Chunk size limit: keep message payload under ~32KB so it fits
        // the 64KB client read buffer with headroom.
        const max_chunk_payload: usize = 32 * 1024;
        const row_bytes: usize = @as(usize, cols) * @sizeOf(grid_sync.PackedCell);
        if (row_bytes == 0) return;
        const rows_per_chunk_usize: usize = @max(1, (max_chunk_payload - grid_sync.snapshot_header_size) / row_bytes);
        const rows_per_chunk: u16 = @intCast(@min(rows_per_chunk_usize, rows));

        var scratch_buf: [max_chunk_payload + protocol.header_size]u8 align(4) = undefined;

        var start: u16 = 0;
        while (start < rows) {
            const this_rows = @min(rows_per_chunk, rows - start);
            const final = (start + this_rows) >= rows;
            const payload_len: u32 = @intCast(grid_sync.snapshot_header_size + @as(usize, this_rows) * row_bytes);
            protocol.encodeHeader(scratch_buf[0..protocol.header_size], .grid_snapshot, payload_len);

            const payload_off = protocol.header_size;
            _ = grid_sync.encodeSnapshotHeader(scratch_buf[payload_off..], .{
                .pane_id = pane.id,
                .generation = gen,
                .rows = rows,
                .cols = cols,
                .cursor_row = @intCast(@min(eng.state.cursor.row, std.math.maxInt(u16))),
                .cursor_col = @intCast(@min(eng.state.cursor.col, std.math.maxInt(u16))),
                .cursor_visible = eng.state.cursor_visible,
                .cursor_shape = @intFromEnum(eng.state.cursor_shape),
                .alt_active = eng.state.alt_active,
                .start_row = start,
                .row_count = this_rows,
                .final_chunk = final,
            }) catch return;

            // Pack cells into the scratch buffer via memcpy — the wire
            // framing (5-byte msg header + 28-byte snapshot header = 33)
            // puts the cell region at an unaligned offset, so pointer
            // casts are unsafe on arm64.
            const cells_off = payload_off + grid_sync.snapshot_header_size;
            const cell_bytes_len = @as(usize, this_rows) * row_bytes;
            const cell_buf = scratch_buf[cells_off .. cells_off + cell_bytes_len];
            var out_idx: usize = 0;
            for (start..start + this_rows) |row| {
                for (0..cols) |col| {
                    const cell = eng.state.ring.getScreenCell(row, col);
                    grid_sync.writePackedCell(cell_buf, out_idx, grid_sync.packCell(cell));
                    out_idx += 1;
                }
            }

            const total_len = protocol.header_size + @as(usize, payload_len);
            self.sendRaw(scratch_buf[0..total_len]);
            if (self.dead) return;
            start += this_rows;
        }

        self.active_pane_last_gen[slot] = gen;
    }

    /// Send a ReplayEnd notification for a pane, signaling that scrollback
    /// replay is complete and real-time data follows.
    pub fn sendReplayEnd(self: *DaemonClient, pane_id: u32) void {
        var buf: [protocol.header_size + 4]u8 = undefined;
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u32, &payload, pane_id, .little);
        _ = protocol.encodeMessage(&buf, .replay_end, &payload) catch return;
        self.sendRaw(&buf);
    }

    /// Send a PaneProcName notification.
    pub fn sendPaneProcName(self: *DaemonClient, pane_id: u32, name: []const u8) void {
        var buf: [protocol.header_size + 4 + 1 + 64]u8 = undefined;
        var payload: [4 + 1 + 64]u8 = undefined;
        const p = protocol.encodePaneProcName(&payload, pane_id, name) catch return;
        const m = protocol.encodeMessage(&buf, .pane_proc_name, p) catch return;
        self.sendRaw(m);
    }

    /// Send a PaneFgCwd notification.
    pub fn sendPaneFgCwd(self: *DaemonClient, pane_id: u32, cwd: []const u8) void {
        var buf: [protocol.header_size + 4 + 2 + 512]u8 = undefined;
        var payload: [4 + 2 + 512]u8 = undefined;
        const p = protocol.encodePaneFgCwd(&payload, pane_id, cwd) catch return;
        const m = protocol.encodeMessage(&buf, .pane_fg_cwd, p) catch return;
        self.sendRaw(m);
    }

    /// Send a HelloAck response with daemon's version string and capability bits.
    pub fn sendHelloAck(self: *DaemonClient, version: []const u8, caps: u32) void {
        var payload: [256]u8 = undefined;
        const p = protocol.encodeHello(&payload, version, caps) catch return;
        var buf: [protocol.header_size + 256]u8 = undefined;
        const m = protocol.encodeMessage(&buf, .hello_ack, p) catch return;
        self.sendRaw(m);
    }

    /// Check if a pane_id is in this client's active panes set.
    pub fn isPaneActive(self: *const DaemonClient, pane_id: u32) bool {
        for (self.active_panes[0..self.active_pane_count]) |id| {
            if (id == pane_id) return true;
        }
        return false;
    }

    pub fn deinit(self: *DaemonClient) void {
        if (comptime is_windows) {
            _ = win32.CloseHandle(self.socket_fd);
        } else {
            std.posix.close(self.socket_fd);
        }
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// Tests for skipPartialEscape
// ---------------------------------------------------------------------------

test "skipPartialEscape: empty data" {
    try std.testing.expectEqual(@as(usize, 0), DaemonClient.skipPartialEscape(""));
}

test "skipPartialEscape: plain text" {
    try std.testing.expectEqual(@as(usize, 0), DaemonClient.skipPartialEscape("hello world"));
}

test "skipPartialEscape: CSI tail with [" {
    // ESC was before wrap, data starts with "[0m" (SGR reset)
    try std.testing.expectEqual(@as(usize, 3), DaemonClient.skipPartialEscape("[0m"));
    // CSI with params: "[48;2;30;30;40m"
    try std.testing.expectEqual(@as(usize, 15), DaemonClient.skipPartialEscape("[48;2;30;30;40m"));
    // CSI cursor home: "[H"
    try std.testing.expectEqual(@as(usize, 2), DaemonClient.skipPartialEscape("[H"));
    // CSI with ? param: "[?25l"
    try std.testing.expectEqual(@as(usize, 5), DaemonClient.skipPartialEscape("[?25l"));
}

test "skipPartialEscape: CSI tail not a CSI" {
    // [ followed by a control byte (not param/intermediate/final)
    try std.testing.expectEqual(@as(usize, 0), DaemonClient.skipPartialEscape("[\x01hello"));
}

test "skipPartialEscape: OSC tail" {
    // ESC was before wrap, data starts with "]" (OSC)
    // OSC 7 with BEL terminator: "]7;file:///tmp" = 14 bytes, BEL at 14 → skip 15
    try std.testing.expectEqual(@as(usize, 15), DaemonClient.skipPartialEscape("]7;file:///tmp\x07abc"));
    // OSC with ST terminator (ESC \): BEL replaced by ESC \ → skip 16
    try std.testing.expectEqual(@as(usize, 16), DaemonClient.skipPartialEscape("]7;file:///tmp\x1b\\abc"));
}

test "skipPartialEscape: DCS tail" {
    // "Pq#0" = 4 bytes, then ESC \ at indices 4-5 → skip 6
    try std.testing.expectEqual(@as(usize, 6), DaemonClient.skipPartialEscape("Pq#0\x1b\\xy"));
}

test "skipPartialEscape: APC tail" {
    try std.testing.expectEqual(@as(usize, 6), DaemonClient.skipPartialEscape("_test\x07rest"));
}

test "skipPartialEscape: digit at start is not a false CSI match" {
    // Plain text starting with digits must NOT be treated as a CSI tail
    try std.testing.expectEqual(@as(usize, 0), DaemonClient.skipPartialEscape("123abc"));
    try std.testing.expectEqual(@as(usize, 0), DaemonClient.skipPartialEscape("42"));
}
