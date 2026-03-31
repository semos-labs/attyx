// ipc.zig — Xyron IPC client for sideband queries.
//
// Connects to xyron's Unix domain socket and sends binary protocol
// requests for completions, ghost text, history, shell state, etc.
// The socket path is discovered via OSC 7339 ipc_ready event.

const std = @import("std");
const posix = std.posix;
const proto = @import("protocol.zig");

pub const IpcClient = struct {
    socket_path: [256]u8 = undefined,
    socket_path_len: usize = 0,

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

    /// Connect to the Unix socket, send a request, read the response.
    /// Returns response payload or null on error.
    fn request(self: *const IpcClient, msg_type: proto.MsgType, payload: []const u8, resp_buf: []u8) ?[]const u8 {
        // Build null-terminated socket path
        var path_z: [257]u8 = undefined;
        @memcpy(path_z[0..self.socket_path_len], self.socket_path[0..self.socket_path_len]);
        path_z[self.socket_path_len] = 0;

        // Connect with short timeout to avoid blocking the event loop
        const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return null;
        defer posix.close(fd);

        // Set socket receive timeout (100ms)
        const tv = posix.timeval{ .sec = 0, .usec = 100_000 };
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};

        var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        const path_bytes = self.socket_path[0..self.socket_path_len];
        @memcpy(addr.path[0..path_bytes.len], path_bytes);

        posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch return null;

        // Send request frame
        proto.writeFrame(fd, msg_type, payload);

        // Read response frame (blocking)
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

    // -----------------------------------------------------------------
    // Query methods
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
        _ = r.readInt(); // req_id echo
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
        _ = r.readInt(); // req_id
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
        _ = r.readInt(); // req_id
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
        _ = r.readInt(); // req_id
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
