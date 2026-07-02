//! Window IPC helpers for dashboard actions.
const std = @import("std");
const client = @import("../client.zig");
const io = @import("../protocol.zig");
const ipc_proto = @import("../protocol.zig");

const max_reply = 8192;

const Reply = struct {
    msg_type: ipc_proto.MessageType,
    body: []const u8,
};

fn request(msg_type: ipc_proto.MessageType, payload: []const u8, body_buf: []u8) ?Reply {
    var sock_buf: [256]u8 = undefined;
    const sock = client.discoverSocket(&sock_buf, null) orelse return null;
    const fd = client.connectToSocket(sock) catch return null;
    defer io.closeFd(fd);

    var frame_buf: [ipc_proto.header_size + 256]u8 = undefined;
    if (payload.len > frame_buf.len - ipc_proto.header_size) return null;
    const frame = ipc_proto.encodeMessage(&frame_buf, msg_type, payload) catch return null;
    io.writeAll(fd, frame) catch return null;

    var hdr: [ipc_proto.header_size]u8 = undefined;
    io.readExact(fd, &hdr) catch return null;
    const h = ipc_proto.decodeHeader(&hdr) catch return null;
    if (h.payload_len > body_buf.len) return null;
    io.readExact(fd, body_buf[0..h.payload_len]) catch return null;
    return .{ .msg_type = h.msg_type, .body = body_buf[0..h.payload_len] };
}

fn requestOk(msg_type: ipc_proto.MessageType, payload: []const u8, body_buf: []u8) bool {
    const reply = request(msg_type, payload, body_buf) orelse return false;
    return reply.msg_type == .success;
}

/// Switch the attached window to the given session, then select the tab that
/// owns `tab_id` using the normal tab_select IPC path. Finally focus the agent's
/// pane inside that tab (for split tabs). Best-effort; callers intentionally get
/// no UI error because the dashboard exits after dispatch.
pub fn jumpToAgent(session: u32, tab_id: u32, pane_id: u32) void {
    var body_buf: [max_reply]u8 = undefined;
    var p1: [4]u8 = undefined;
    std.mem.writeInt(u32, &p1, session, .little);
    if (!requestOk(.session_switch, &p1, &body_buf)) return;

    if (tabIndexForTabId(tab_id, &body_buf)) |idx1| {
        const tab_payload = [_]u8{idx1};
        if (!requestOk(.tab_select, &tab_payload, &body_buf)) return;
    }

    var p2: [4]u8 = undefined;
    std.mem.writeInt(u32, &p2, pane_id, .little);
    _ = requestOk(.pane_focus_targeted, &p2, &body_buf);
}

/// Switch to `session`, then send a pane-targeted operation. Used for close.
pub fn paneOp(session: u32, pane_id: u32, op: ipc_proto.MessageType) void {
    var body_buf: [max_reply]u8 = undefined;
    var p1: [4]u8 = undefined;
    std.mem.writeInt(u32, &p1, session, .little);
    if (!requestOk(.session_switch, &p1, &body_buf)) return;

    var p2: [4]u8 = undefined;
    std.mem.writeInt(u32, &p2, pane_id, .little);
    _ = requestOk(op, &p2, &body_buf);
}

fn tabIndexForTabId(tab_id: u32, body_buf: []u8) ?u8 {
    if (tab_id == 0) return null;
    const reply = request(.list, "", body_buf) orelse return null;
    if (reply.msg_type != .success) return null;
    return tabIndexForTabIdFromList(reply.body, tab_id);
}

fn tabIndexForTabIdFromList(list: []const u8, tab_id: u32) ?u8 {
    var lines = std.mem.splitScalar(u8, list, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == ' ') continue; // skip split-pane child rows
        const first_tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const idx1 = std.fmt.parseInt(u8, line[0..first_tab], 10) catch continue;
        const marker = "\tpane:";
        const p = std.mem.indexOf(u8, line, marker) orelse continue;
        const start = p + marker.len;
        var end = start;
        while (end < line.len and line[end] >= '0' and line[end] <= '9') : (end += 1) {}
        const id = std.fmt.parseInt(u32, line[start..end], 10) catch continue;
        if (id == tab_id) return idx1;
    }
    return null;
}

const testing = std.testing;

test "tab index resolves from list output by focused pane id" {
    const list =
        "1\tshell\tpane:10\n" ++
        "2\tagent\t*\tpane:42\t2 panes\n" ++
        "  41\tvim\t80x20\n" ++
        "  99\tclaude\t*\t80x20\n";
    try testing.expectEqual(@as(?u8, 2), tabIndexForTabIdFromList(list, 42));
    try testing.expectEqual(@as(?u8, null), tabIndexForTabIdFromList(list, 99));
}
