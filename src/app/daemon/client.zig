const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol.zig");
const DaemonSession = @import("session.zig").DaemonSession;
const DaemonPane = @import("pane.zig").DaemonPane;

/// A connected client being served by the daemon.
pub const DaemonClient = struct {
    socket_fd: posix.fd_t,
    read_buf: [65536]u8 = undefined,
    read_len: usize = 0,
    msg_buf: [65536]u8 = undefined, // stable copy for nextMessage payloads
    attached_session: ?u32 = null,
    dead: bool = false,
    /// V2: active panes set (panes the client is currently displaying)
    active_panes: [32]u32 = .{0} ** 32,
    active_pane_count: u8 = 0,

    pub fn init(fd: posix.fd_t) DaemonClient {
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
        const n = posix.read(self.socket_fd, space) catch |err| switch (err) {
            error.WouldBlock => return true,
            else => return false,
        };
        if (n == 0) return false; // EOF
        self.read_len += n;
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
    /// The socket is non-blocking; on WouldBlock we briefly poll for
    /// writability.  If the client can't drain data within ~200ms the
    /// connection is considered dead (prevents the daemon from blocking
    /// indefinitely when a client's recv buffer is full).
    fn writeAll(self: *DaemonClient, data: []const u8) void {
        const POLLOUT: i16 = 0x0004;
        var offset: usize = 0;
        var stalls: u32 = 0;
        while (offset < data.len) {
            const n = posix.write(self.socket_fd, data[offset..]) catch |err| {
                if (err == error.WouldBlock) {
                    stalls += 1;
                    if (stalls > 20) { // 20 × 10ms = 200ms
                        self.dead = true;
                        return;
                    }
                    var fds = [1]posix.pollfd{.{ .fd = self.socket_fd, .events = POLLOUT, .revents = 0 }};
                    _ = posix.poll(&fds, 10) catch {};
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
        if (slices.first.len > 0) self.sendPaneOutput(pane.id, slices.first);
        if (slices.second.len > 0) self.sendPaneOutput(pane.id, slices.second);
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

    /// Skip past a partial CSI escape sequence at the start of replay data.
    /// Returns the number of bytes to skip (0 if no partial sequence detected).
    fn skipPartialEscape(data: []const u8) usize {
        if (data.len == 0) return 0;
        var i: usize = 0;

        // `[` at start means ESC was the last byte before the wrap point.
        if (data[0] == '[') i = 1;

        // Expect CSI parameter bytes (0x30-0x3F: digits, ;, ?, etc.)
        if (i >= data.len or data[i] < 0x30 or data[i] > 0x3f) return 0;

        const limit = @min(data.len, 64);
        while (i < limit) : (i += 1) {
            const b = data[i];
            if (b >= 0x30 and b <= 0x3f) continue; // CSI param
            if (b >= 0x20 and b <= 0x2f) continue; // CSI intermediate
            if (b >= 0x40 and b <= 0x7e) return i + 1; // CSI final byte
            return 0; // Not a CSI sequence
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
        var buf: [protocol.header_size + 5]u8 = undefined;
        var payload: [5]u8 = undefined;
        _ = protocol.encodePaneDied(&payload, pane_id, exit_code) catch return;
        _ = protocol.encodeMessage(&buf, .pane_died, &payload) catch return;
        self.sendRaw(&buf);
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

    /// Send a HelloAck response with daemon's version string.
    pub fn sendHelloAck(self: *DaemonClient, version: []const u8) void {
        var payload: [256]u8 = undefined;
        const p = protocol.encodeHello(&payload, version) catch return;
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
        posix.close(self.socket_fd);
        self.* = undefined;
    }
};
