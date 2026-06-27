// Attyx — streaming watch client
//
// The `attyx watch agents` command, split out from client.zig (one-shot
// request/response) because it has a fundamentally different lifecycle: it
// holds the connection open and reads framed NDJSON responses until the
// instance closes the stream. Blocks indefinitely — the user Ctrl-Cs or pipes
// it into another tool.

const std = @import("std");
const protocol = @import("protocol.zig");
const client = @import("client.zig");
const agents = @import("agents.zig");
const IpcRequest = @import("../config/cli_ipc.zig").IpcRequest;

const max_payload = 65536;

pub fn run(socket_path: []const u8, parsed: IpcRequest) void {
    // The watch request payload is [pane_filter:u32 LE] (0 = all agents);
    // wrap it in a session envelope when -s targeted a specific session.
    var req_buf: [protocol.header_size + 16]u8 = undefined;
    const request = buildRequest(&req_buf, parsed.command, parsed.pane_id, parsed.target_session) catch {
        writeStderr("error: failed to build request\n");
        std.process.exit(1);
    };

    const fd = client.connectToSocket(socket_path) catch {
        writeStderr("error: no running Attyx instance found\n");
        std.process.exit(1);
    };
    defer protocol.closeFd(fd);

    protocol.writeAll(fd, request) catch {
        writeStderr("error: failed to communicate with Attyx instance\n");
        std.process.exit(1);
    };

    const stdout = std.fs.File.stdout();
    // Plain mode prints the same table as `list agents`, just streamed: a header
    // once, then a humanized row per update. `--json` streams the raw NDJSON.
    const color = client.shouldColor(parsed.color_mode);
    if (!parsed.json_output) writeRowHeader(stdout, color);
    var hdr: [protocol.header_size]u8 = undefined;
    var payload_buf: [max_payload]u8 = undefined;
    while (true) {
        // EOF / disconnect ends the stream cleanly.
        protocol.readExact(fd, &hdr) catch return;
        const h = protocol.decodeHeader(&hdr) catch return;
        if (h.payload_len > payload_buf.len) return;
        if (h.payload_len > 0) {
            protocol.readExact(fd, payload_buf[0..h.payload_len]) catch return;
        }
        switch (h.msg_type) {
            .success => {
                if (h.payload_len > 0) {
                    if (parsed.json_output) {
                        stdout.writeAll(payload_buf[0..h.payload_len]) catch return;
                        if (payload_buf[h.payload_len - 1] != '\n') stdout.writeAll("\n") catch return;
                    } else {
                        writeRow(stdout, payload_buf[0..h.payload_len], color);
                    }
                }
            },
            .err => {
                writeStderr("error: ");
                std.fs.File.stderr().writeAll(payload_buf[0..h.payload_len]) catch {};
                std.fs.File.stderr().writeAll("\n") catch {};
                std.process.exit(1);
            },
            else => {},
        }
    }
}

/// Encode the watch request. Inner payload is [pane_filter:u32 LE] (0 = all).
/// When a session is targeted, wrap it in a session envelope:
///   session_envelope([session_id:u32 LE][inner_msg_type:u8][pane_filter:u32 LE])
fn buildRequest(buf: []u8, command: @import("../config/cli_ipc.zig").IpcCommand, pane_filter: u32, target_session: u32) ![]u8 {
    const msg_type: protocol.MessageType = switch (command) {
        .watch_agents => .watch_agents,
        else => return error.UnsupportedCommand,
    };
    var inner_payload: [4]u8 = undefined;
    std.mem.writeInt(u32, &inner_payload, pane_filter, .little);

    if (target_session == 0) {
        return protocol.encodeMessage(buf, msg_type, &inner_payload);
    }
    // Envelope: [4B len][session_envelope][session_id:u32][inner_type:u8][inner_payload...]
    const payload_len: usize = 4 + 1 + inner_payload.len;
    if (buf.len < protocol.header_size + payload_len) return error.BufferTooSmall;
    protocol.encodeHeader(buf[0..protocol.header_size], .session_envelope, @intCast(payload_len));
    std.mem.writeInt(u32, buf[protocol.header_size..][0..4], target_session, .little);
    buf[protocol.header_size + 4] = @intFromEnum(msg_type);
    @memcpy(buf[protocol.header_size + 5 ..][0..inner_payload.len], &inner_payload);
    return buf[0 .. protocol.header_size + payload_len];
}

fn writeStderr(msg: []const u8) void {
    std.fs.File.stderr().writeAll(msg) catch {};
}

pub fn writeRowHeader(stdout: std.fs.File, color: bool) void {
    var buf: [256]u8 = undefined;
    var s = std.io.fixedBufferStream(&buf);
    agents.writeAgentTableHeader(s.writer(), color) catch return;
    stdout.writeAll(s.getWritten()) catch {};
}

/// Reformat one NDJSON frame into the shared human table row (same as `list
/// agents`), so the stream and the snapshot look identical.
pub fn writeRow(stdout: std.fs.File, json_line: []const u8, color: bool) void {
    var out_buf: [1024]u8 = undefined;
    var s = std.io.fixedBufferStream(&out_buf);
    var fba_buf: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    agents.writeAgentRowFromJson(s.writer(), fba.allocator(), json_line, color) catch return;
    stdout.writeAll(s.getWritten()) catch {};
}

test "watch request carries pane filter" {
    var buf: [32]u8 = undefined;
    const req = try buildRequest(&buf, .watch_agents, 5, 0);
    const h = try protocol.decodeHeader(req[0..protocol.header_size]);
    try std.testing.expectEqual(protocol.MessageType.watch_agents, h.msg_type);
    try std.testing.expectEqual(@as(u32, 4), h.payload_len);
    try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, req[protocol.header_size..][0..4], .little));
}

test "watch request with session wraps filter in envelope" {
    var buf: [32]u8 = undefined;
    const req = try buildRequest(&buf, .watch_agents, 5, 7);
    const h = try protocol.decodeHeader(req[0..protocol.header_size]);
    try std.testing.expectEqual(protocol.MessageType.session_envelope, h.msg_type);
    const sid = std.mem.readInt(u32, req[protocol.header_size..][0..4], .little);
    try std.testing.expectEqual(@as(u32, 7), sid);
    try std.testing.expectEqual(@intFromEnum(protocol.MessageType.watch_agents), req[protocol.header_size + 4]);
    try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, req[protocol.header_size + 5 ..][0..4], .little));
}
