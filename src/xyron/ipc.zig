// ipc.zig — Xyron IPC client for sideband queries and push events.
//
// Two modes of communication:
// 1. Per-request: connect, send request, read response, close (for queries)
// 2. Persistent: keep a fd open, poll for push events from xyron
//    (overlay show/update/dismiss events)

const std = @import("std");
const posix = std.posix;
const proto = @import("protocol.zig");

pub const IpcClient = struct {
    socket_path: [256]u8 = undefined,
    socket_path_len: usize = 0,

    /// Persistent connection fd for receiving push events (null = not connected)
    event_fd: ?posix.fd_t = null,

    /// Non-blocking frame reader for the persistent connection
    reader: proto.FrameReader = .{},

    pub fn init(path: []const u8) IpcClient {
        var c = IpcClient{};
        const len = @min(path.len, c.socket_path.len);
        @memcpy(c.socket_path[0..len], path[0..len]);
        c.socket_path_len = len;
        return c;
    }

    pub fn pathSlice(self: *const IpcClient) []const u8 {
        return self.socket_path[0..self.socket_path_len];
    }

    // -----------------------------------------------------------------
    // Persistent event connection
    // -----------------------------------------------------------------

    /// Open a persistent connection to xyron for receiving push events.
    pub fn connectEvents(self: *IpcClient) bool {
        if (self.event_fd != null) return true; // already connected
        const fd = self.connectSocket() orelse return false;
        // Set non-blocking for poll-driven reading
        const c_fcntl = struct {
            extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
        };
        const flags = c_fcntl.fcntl(fd, 3); // F_GETFL
        _ = c_fcntl.fcntl(fd, 4, flags | @as(c_int, 0x0004)); // F_SETFL | O_NONBLOCK
        self.event_fd = fd;
        return true;
    }

    /// Fd to add to poll set for receiving push events.
    pub fn eventPollFd(self: *const IpcClient) ?posix.fd_t {
        return self.event_fd;
    }

    /// Try to read the next push event frame. Non-blocking.
    /// Returns null if no complete frame available.
    pub fn readEvent(self: *IpcClient) ?proto.Frame {
        const fd = self.event_fd orelse return null;
        return self.reader.tryRead(fd) catch |err| {
            // Connection broken — close and reset
            if (err == error.BrokenPipe) {
                posix.close(fd);
                self.event_fd = null;
            }
            return null;
        };
    }

    pub fn disconnectEvents(self: *IpcClient) void {
        if (self.event_fd) |fd| {
            posix.close(fd);
            self.event_fd = null;
        }
    }

    // -----------------------------------------------------------------
    // Per-request queries (connect, send, recv, close)
    // -----------------------------------------------------------------

    fn connectSocket(self: *const IpcClient) ?posix.fd_t {
        const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return null;

        const tv = posix.timeval{ .sec = 0, .usec = 100_000 };
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};

        var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        const path_bytes = self.socket_path[0..self.socket_path_len];
        @memcpy(addr.path[0..path_bytes.len], path_bytes);

        posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch {
            posix.close(fd);
            return null;
        };
        return fd;
    }

    fn request(self: *const IpcClient, msg_type: proto.MsgType, payload: []const u8, resp_buf: []u8) ?[]const u8 {
        const fd = self.connectSocket() orelse return null;
        defer posix.close(fd);

        proto.writeFrame(fd, msg_type, payload);

        var hdr: [proto.header_size]u8 = undefined;
        var hdr_read: usize = 0;
        while (hdr_read < proto.header_size) {
            const n = posix.read(fd, hdr[hdr_read..proto.header_size]) catch return null;
            if (n == 0) return null;
            hdr_read += n;
        }
        const resp_len = std.mem.readInt(u32, hdr[0..4], .little);
        if (resp_len > resp_buf.len) return null;

        var resp_read: usize = 0;
        while (resp_read < resp_len) {
            const n = posix.read(fd, resp_buf[resp_read..resp_len]) catch return null;
            if (n == 0) return null;
            resp_read += n;
        }
        return resp_buf[0..resp_len];
    }

    /// Send a frame on the persistent event connection (for responses to xyron).
    pub fn sendEvent(self: *const IpcClient, msg_type: proto.MsgType, payload: []const u8) void {
        const fd = self.event_fd orelse return;
        proto.writeFrame(fd, msg_type, payload);
    }

    // -----------------------------------------------------------------
    // Handshake
    // -----------------------------------------------------------------

    pub const HandshakeResult = struct {
        xyron_socket: []const u8,
        name: []const u8,
        version: []const u8,
    };

    pub fn sendHandshake(self: *const IpcClient, attyx_socket: []const u8, pane_id: []const u8) ?HandshakeResult {
        var buf: [512]u8 = undefined;
        var w = proto.PayloadWriter.init(&buf);
        w.writeStr(attyx_socket);
        w.writeStr(pane_id);

        var resp_buf: [1024]u8 = undefined;
        const resp = self.request(.handshake, w.written(), &resp_buf) orelse return null;

        var r = proto.PayloadReader.init(resp);
        return .{
            .xyron_socket = r.readStr(),
            .name = r.readStr(),
            .version = r.readStr(),
        };
    }

    // -----------------------------------------------------------------
    // Queries
    // -----------------------------------------------------------------

    pub const ShellState = struct {
        cwd: []const u8,
        last_exit_code: u8,
        job_count: i64,
    };

    pub fn getShellState(self: *const IpcClient, req_id: i64) ?ShellState {
        var buf: [32]u8 = undefined;
        var w = proto.PayloadWriter.init(&buf);
        w.writeInt(req_id);

        var resp_buf: [4096]u8 = undefined;
        const resp = self.request(.get_shell_state, w.written(), &resp_buf) orelse return null;

        var r = proto.PayloadReader.init(resp);
        _ = r.readInt();
        return .{
            .cwd = r.readStr(),
            .last_exit_code = r.readU8(),
            .job_count = r.readInt(),
        };
    }

    pub const Completion = struct {
        text: []const u8,
        description: []const u8,
        kind: u8,
        score: i64,
    };

    pub const CompletionResult = struct {
        context_kind: u8,
        word_start: i64,
        word_end: i64,
        candidates: [50]Completion,
        count: usize,
    };

    pub fn getCompletions(self: *const IpcClient, req_id: i64, buffer: []const u8, cursor: usize) ?CompletionResult {
        var buf: [4096]u8 = undefined;
        var w = proto.PayloadWriter.init(&buf);
        w.writeInt(req_id);
        w.writeStr(buffer);
        w.writeInt(@intCast(cursor));

        var resp_buf: [proto.MAX_PAYLOAD]u8 = undefined;
        const resp = self.request(.get_completions, w.written(), &resp_buf) orelse return null;

        var r = proto.PayloadReader.init(resp);
        _ = r.readInt();
        var result = CompletionResult{
            .context_kind = r.readU8(),
            .word_start = r.readInt(),
            .word_end = r.readInt(),
            .candidates = undefined,
            .count = 0,
        };
        const count: usize = @intCast(@max(r.readInt(), 0));
        result.count = @min(count, 50);
        for (0..result.count) |i| {
            result.candidates[i] = .{
                .text = r.readStr(),
                .description = r.readStr(),
                .kind = r.readU8(),
                .score = r.readInt(),
            };
        }
        return result;
    }

    pub fn getGhostText(self: *const IpcClient, req_id: i64, buffer: []const u8) ?[]const u8 {
        var buf: [4096]u8 = undefined;
        var w = proto.PayloadWriter.init(&buf);
        w.writeInt(req_id);
        w.writeStr(buffer);

        var resp_buf: [4096]u8 = undefined;
        const resp = self.request(.get_ghost, w.written(), &resp_buf) orelse return null;

        var r = proto.PayloadReader.init(resp);
        _ = r.readInt();
        const has = r.readU8();
        if (has != 1) return null;
        return r.readStr();
    }

    pub const HistoryEntry = struct {
        id: i64,
        raw_input: []const u8,
        cwd: []const u8,
        exit_code: i64,
        started_at: i64,
    };

    pub fn getHistory(self: *const IpcClient, req_id: i64, limit: i64) ?struct { entries: [50]HistoryEntry, count: usize } {
        var buf: [32]u8 = undefined;
        var w = proto.PayloadWriter.init(&buf);
        w.writeInt(req_id);
        w.writeInt(limit);

        var resp_buf: [proto.MAX_PAYLOAD]u8 = undefined;
        const resp = self.request(.get_history, w.written(), &resp_buf) orelse return null;

        var r = proto.PayloadReader.init(resp);
        _ = r.readInt();
        const count: usize = @intCast(@min(@max(r.readInt(), 0), 50));
        var result: struct { entries: [50]HistoryEntry, count: usize } = .{ .entries = undefined, .count = count };
        for (0..count) |i| {
            result.entries[i] = .{
                .id = r.readInt(),
                .raw_input = r.readStr(),
                .cwd = r.readStr(),
                .exit_code = r.readInt(),
                .started_at = r.readInt(),
            };
        }
        return result;
    }
};
