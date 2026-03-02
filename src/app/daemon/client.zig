const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol.zig");
const DaemonSession = @import("session.zig").DaemonSession;

/// A connected client being served by the daemon.
pub const DaemonClient = struct {
    socket_fd: posix.fd_t,
    read_buf: [65536]u8 = undefined,
    read_len: usize = 0,
    attached_session: ?u32 = null,
    dead: bool = false,

    pub fn init(fd: posix.fd_t) DaemonClient {
        return .{ .socket_fd = fd };
    }

    /// Read available data from socket into read_buf. Returns false if connection closed.
    pub fn recvData(self: *DaemonClient) bool {
        const space = self.read_buf[self.read_len..];
        if (space.len == 0) {
            // Buffer full — discard old data to prevent deadlock
            self.read_len = 0;
            return true;
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

    /// Try to extract the next complete message from the read buffer.
    /// Returns null if no complete message is available yet.
    pub fn nextMessage(self: *DaemonClient) ?Message {
        if (self.read_len < protocol.header_size) return null;

        const header = protocol.decodeHeader(self.read_buf[0..protocol.header_size]) catch {
            // Invalid header — skip one byte and try again
            self.consumeBytes(1);
            return null;
        };

        const total = protocol.header_size + header.payload_len;
        if (self.read_len < total) return null;

        const payload = self.read_buf[protocol.header_size..total];
        const msg = Message{
            .msg_type = header.msg_type,
            .payload = payload,
        };

        // Shift remaining data forward
        self.consumeBytes(total);
        return msg;
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
        _ = posix.write(self.socket_fd, data) catch {
            self.dead = true;
            return;
        };
    }

    /// Send an Output message (raw PTY bytes) to the client.
    pub fn sendOutput(self: *DaemonClient, pty_data: []const u8) void {
        var hdr: [protocol.header_size]u8 = undefined;
        protocol.encodeHeader(&hdr, .output, @intCast(pty_data.len));
        _ = posix.write(self.socket_fd, &hdr) catch {
            self.dead = true;
            return;
        };
        _ = posix.write(self.socket_fd, pty_data) catch {
            self.dead = true;
            return;
        };
    }

    /// Send a Created response.
    pub fn sendCreated(self: *DaemonClient, session_id: u32) void {
        var buf: [protocol.header_size + 4]u8 = undefined;
        var payload: [4]u8 = undefined;
        _ = protocol.encodeCreated(&payload, session_id) catch return;
        _ = protocol.encodeMessage(&buf, .created, &payload) catch return;
        self.sendRaw(&buf);
    }

    /// Send an Attached response.
    pub fn sendAttached(self: *DaemonClient, session_id: u32) void {
        var buf: [protocol.header_size + 4]u8 = undefined;
        var payload: [4]u8 = undefined;
        _ = protocol.encodeAttached(&payload, session_id) catch return;
        _ = protocol.encodeMessage(&buf, .attached, &payload) catch return;
        self.sendRaw(&buf);
    }

    /// Send a SessionDied notification.
    pub fn sendSessionDied(self: *DaemonClient, session_id: u32, exit_code: u8) void {
        var buf: [protocol.header_size + 5]u8 = undefined;
        var payload: [5]u8 = undefined;
        _ = protocol.encodeSessionDied(&payload, session_id, exit_code) catch return;
        _ = protocol.encodeMessage(&buf, .session_died, &payload) catch return;
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

    /// Send a SessionList response.
    pub fn sendSessionList(self: *DaemonClient, sessions: []DaemonSession) void {
        var entries: [32]protocol.SessionEntry = undefined;
        var count: usize = 0;
        for (sessions) |*s| {
            if (count >= 32) break;
            entries[count] = .{
                .id = s.id,
                .name = s.getName(),
                .alive = s.alive,
            };
            count += 1;
        }

        var payload_buf: [4096]u8 = undefined;
        const payload = protocol.encodeSessionList(&payload_buf, entries[0..count]) catch return;

        var msg_buf: [4096 + protocol.header_size]u8 = undefined;
        const msg = protocol.encodeMessage(&msg_buf, .session_list, payload) catch return;
        self.sendRaw(msg);
    }

    /// Send replay data from a session's ring buffer as Output messages.
    pub fn sendReplay(self: *DaemonClient, session: *DaemonSession) void {
        const slices = session.replay.readSlices();
        if (slices.first.len > 0) self.sendOutput(slices.first);
        if (slices.second.len > 0) self.sendOutput(slices.second);
    }

    pub fn deinit(self: *DaemonClient) void {
        posix.close(self.socket_fd);
        self.* = undefined;
    }
};
