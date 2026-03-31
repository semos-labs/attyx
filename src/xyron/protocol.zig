// protocol.zig — Binary protocol client for Xyron headless communication.
//
// Mirrors the protocol defined in xyron/src/protocol.zig.
// Frame format: [4B payload_len LE][1B msg_type][payload...]

const std = @import("std");
const posix = std.posix;

pub const header_size: usize = 5;
pub const MAX_PAYLOAD: usize = 65536;

// -------------------------------------------------------------------------
// Message types
// -------------------------------------------------------------------------

pub const MsgType = enum(u8) {
    // Requests: Attyx → Xyron
    init_session = 0x01,
    run_command = 0x02,
    send_input = 0x03,
    interrupt = 0x04,
    suspend_job = 0x05,
    resume_job = 0x06,
    list_jobs = 0x07,
    get_history = 0x08,
    get_shell_state = 0x09,
    inspect_job = 0x0A,
    get_prompt = 0x0B,
    resize = 0x0C,
    query_history = 0x0D,
    get_completions = 0x10,
    get_ghost = 0x11,

    // Responses: Xyron → Attyx
    resp_success = 0x80,
    resp_error = 0x81,

    // Events: Xyron → Attyx
    evt_command_started = 0xA0,
    evt_command_finished = 0xA1,
    evt_output_chunk = 0xA2,
    evt_cwd_changed = 0xA3,
    evt_env_changed = 0xA4,
    evt_job_started = 0xA5,
    evt_job_finished = 0xA6,
    evt_job_suspended = 0xA7,
    evt_job_resumed = 0xA8,
    evt_history_recorded = 0xA9,
    evt_ready = 0xAA,
    evt_prompt = 0xAB,
    evt_block_started = 0xAC,
    evt_block_finished = 0xAD,
};

pub const Frame = struct {
    msg_type: MsgType,
    payload: []const u8,
};

// -------------------------------------------------------------------------
// Non-blocking frame read (for poll-driven event loop)
// -------------------------------------------------------------------------

pub const FrameReader = struct {
    hdr: [header_size]u8 = undefined,
    hdr_pos: usize = 0,
    payload_buf: [MAX_PAYLOAD]u8 = undefined,
    payload_len: usize = 0,
    payload_pos: usize = 0,
    state: enum { reading_header, reading_payload } = .reading_header,

    /// Try to read a complete frame. Returns null if no complete frame yet
    /// (EAGAIN / partial read). Returns a Frame when complete, then resets
    /// internal state for the next frame. Returns error on EOF/broken pipe.
    pub fn tryRead(self: *FrameReader, fd: posix.fd_t) !?Frame {
        while (true) {
            switch (self.state) {
                .reading_header => {
                    const n = posix.read(fd, self.hdr[self.hdr_pos..header_size]) catch |err| switch (err) {
                        error.WouldBlock => return null,
                        else => return err,
                    };
                    if (n == 0) return error.BrokenPipe;
                    self.hdr_pos += n;
                    if (self.hdr_pos < header_size) return null;

                    self.payload_len = std.mem.readInt(u32, self.hdr[0..4], .little);
                    if (self.payload_len > MAX_PAYLOAD) {
                        self.reset();
                        return error.InvalidData;
                    }
                    if (self.payload_len == 0) {
                        const msg_type: MsgType = @enumFromInt(self.hdr[4]);
                        self.reset();
                        return Frame{ .msg_type = msg_type, .payload = &.{} };
                    }
                    self.state = .reading_payload;
                    self.payload_pos = 0;
                },
                .reading_payload => {
                    const n = posix.read(fd, self.payload_buf[self.payload_pos..self.payload_len]) catch |err| switch (err) {
                        error.WouldBlock => return null,
                        else => return err,
                    };
                    if (n == 0) return error.BrokenPipe;
                    self.payload_pos += n;
                    if (self.payload_pos < self.payload_len) return null;

                    const msg_type: MsgType = @enumFromInt(self.hdr[4]);
                    const payload = self.payload_buf[0..self.payload_len];
                    self.reset();
                    return Frame{ .msg_type = msg_type, .payload = payload };
                },
            }
        }
    }

    fn reset(self: *FrameReader) void {
        self.hdr_pos = 0;
        self.payload_pos = 0;
        self.payload_len = 0;
        self.state = .reading_header;
    }
};

// -------------------------------------------------------------------------
// Frame write (blocking, for sending requests)
// -------------------------------------------------------------------------

pub fn writeFrame(fd: posix.fd_t, msg_type: MsgType, payload: []const u8) void {
    var hdr: [header_size]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(payload.len), .little);
    hdr[4] = @intFromEnum(msg_type);
    _ = posix.write(fd, &hdr) catch return;
    if (payload.len > 0) _ = posix.write(fd, payload) catch {};
}

// -------------------------------------------------------------------------
// Payload encoding helpers (TLV: [u16 len][bytes...] for strings, [i64 LE])
// -------------------------------------------------------------------------

pub const PayloadWriter = struct {
    buf: []u8,
    pos: usize = 0,

    pub fn init(buf: []u8) PayloadWriter {
        return .{ .buf = buf };
    }

    pub fn writeStr(self: *PayloadWriter, s: []const u8) void {
        const len: u16 = @intCast(@min(s.len, std.math.maxInt(u16)));
        if (self.pos + 2 + len > self.buf.len) return;
        std.mem.writeInt(u16, self.buf[self.pos..][0..2], len, .little);
        self.pos += 2;
        @memcpy(self.buf[self.pos..][0..len], s[0..len]);
        self.pos += len;
    }

    pub fn writeInt(self: *PayloadWriter, v: i64) void {
        if (self.pos + 8 > self.buf.len) return;
        std.mem.writeInt(i64, self.buf[self.pos..][0..8], v, .little);
        self.pos += 8;
    }

    pub fn writeU8(self: *PayloadWriter, v: u8) void {
        if (self.pos >= self.buf.len) return;
        self.buf[self.pos] = v;
        self.pos += 1;
    }

    pub fn written(self: *const PayloadWriter) []const u8 {
        return self.buf[0..self.pos];
    }
};

pub const PayloadReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) PayloadReader {
        return .{ .data = data };
    }

    pub fn readStr(self: *PayloadReader) []const u8 {
        if (self.pos + 2 > self.data.len) return "";
        const len = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        if (self.pos + len > self.data.len) return "";
        const s = self.data[self.pos..][0..len];
        self.pos += len;
        return s;
    }

    pub fn readInt(self: *PayloadReader) i64 {
        if (self.pos + 8 > self.data.len) return 0;
        const v = std.mem.readInt(i64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }

    pub fn readU8(self: *PayloadReader) u8 {
        if (self.pos >= self.data.len) return 0;
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }
};

// -------------------------------------------------------------------------
// Convenience request builders
// -------------------------------------------------------------------------

pub fn sendInitSession(fd: posix.fd_t, req_id: i64) void {
    var buf: [16]u8 = undefined;
    var w = PayloadWriter.init(&buf);
    w.writeInt(req_id);
    writeFrame(fd, .init_session, w.written());
}

pub fn sendRunCommand(fd: posix.fd_t, req_id: i64, command: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = PayloadWriter.init(&buf);
    w.writeInt(req_id);
    w.writeStr(command);
    writeFrame(fd, .run_command, w.written());
}

pub fn sendInput(fd: posix.fd_t, data: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = PayloadWriter.init(&buf);
    w.writeStr(data);
    writeFrame(fd, .send_input, w.written());
}

pub fn sendResize(fd: posix.fd_t, rows: u16, cols: u16) void {
    var buf: [16]u8 = undefined;
    var w = PayloadWriter.init(&buf);
    w.writeInt(@intCast(rows));
    w.writeInt(@intCast(cols));
    writeFrame(fd, .resize, w.written());
}

pub fn sendInterrupt(fd: posix.fd_t, req_id: i64) void {
    var buf: [16]u8 = undefined;
    var w = PayloadWriter.init(&buf);
    w.writeInt(req_id);
    writeFrame(fd, .interrupt, w.written());
}
