const std = @import("std");
const protocol = @import("protocol.zig");
const DaemonSession = @import("session.zig").DaemonSession;
const DaemonClient = @import("client.zig").DaemonClient;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;

const max_sessions: usize = 32;
const replay_capacity: usize = RingBuffer.default_capacity;

pub fn handleMessage(
    cl: *DaemonClient,
    msg: DaemonClient.Message,
    sessions: *[max_sessions]?DaemonSession,
    session_count: *usize,
    next_id: *u32,
    allocator: std.mem.Allocator,
) void {
    switch (msg.msg_type) {
        .create => handleCreate(cl, msg.payload, sessions, session_count, next_id, allocator),
        .list => cl.sendSessionListFromSlots(sessions),
        .attach => handleAttach(cl, msg.payload, sessions),
        .detach => { cl.attached_session = null; },
        .kill => handleKill(msg.payload, sessions, session_count),

        // V2 pane-multiplexed messages
        .create_pane => handleCreatePane(cl, msg.payload, sessions, allocator),
        .close_pane => handleClosePane(cl, msg.payload, sessions),
        .focus_panes => handleFocusPanes(cl, msg.payload, sessions),
        .pane_input => handlePaneInput(cl, msg.payload, sessions),
        .pane_resize => handlePaneResize(cl, msg.payload, sessions),
        .save_layout => handleSaveLayout(cl, msg.payload, sessions),

        // Ignore server→client messages
        else => {},
    }
}

fn handleCreate(
    cl: *DaemonClient,
    payload: []const u8,
    sessions: *[max_sessions]?DaemonSession,
    session_count: *usize,
    next_id: *u32,
    allocator: std.mem.Allocator,
) void {
    const create = protocol.decodeCreate(payload) catch {
        cl.sendError(1, "invalid create payload");
        return;
    };
    if (session_count.* >= max_sessions) {
        cl.sendError(2, "max sessions reached");
        return;
    }
    const slot_idx = for (sessions, 0..) |*slot, i| {
        if (slot.* == null) break i;
    } else {
        cl.sendError(2, "max sessions reached");
        return;
    };
    const id = next_id.*;
    next_id.* += 1;
    sessions[slot_idx] = DaemonSession.spawn(
        allocator,
        id,
        create.name,
        create.rows,
        create.cols,
        replay_capacity,
    ) catch {
        cl.sendError(3, "spawn failed");
        return;
    };
    session_count.* += 1;
    // Set non-blocking on initial pane's PTY master
    if (sessions[slot_idx].?.firstPane()) |pane| {
        setNonBlocking(pane.pty.master);
    }
    cl.sendCreated(id);
}

fn handleAttach(
    cl: *DaemonClient,
    payload: []const u8,
    sessions: *[max_sessions]?DaemonSession,
) void {
    const attach = protocol.decodeAttach(payload) catch {
        cl.sendError(1, "invalid attach payload");
        return;
    };
    const session = findSession(sessions, attach.session_id) orelse {
        cl.sendError(4, "session not found");
        return;
    };
    cl.attached_session = attach.session_id;
    session.resize(attach.rows, attach.cols) catch {};
    // Send V2 attached with layout blob and pane IDs.
    // Replay is NOT sent here — the client requests it via focus_panes.
    cl.sendAttachedV2(session);
}

fn handleKill(
    payload: []const u8,
    sessions: *[max_sessions]?DaemonSession,
    session_count: *usize,
) void {
    const kill_id = protocol.decodeKill(payload) catch return;
    for (sessions) |*slot| {
        if (slot.*) |*s| {
            if (s.id == kill_id) {
                s.deinit();
                slot.* = null;
                session_count.* -= 1;
                break;
            }
        }
    }
}

// ── V2 pane-multiplexed handlers ──

fn handleCreatePane(
    cl: *DaemonClient,
    payload: []const u8,
    sessions: *[max_sessions]?DaemonSession,
    allocator: std.mem.Allocator,
) void {
    const msg = protocol.decodeCreatePane(payload) catch {
        cl.sendError(1, "invalid create_pane payload");
        return;
    };
    const session = getAttachedSession(cl, sessions) orelse return;
    const pane_id = session.addPane(allocator, msg.rows, msg.cols, replay_capacity) catch {
        cl.sendError(3, "create pane failed");
        return;
    };
    // Set non-blocking on new pane's PTY
    if (session.findPane(pane_id)) |pane| {
        setNonBlocking(pane.pty.master);
    }
    cl.sendPaneCreated(pane_id);
}

fn handleClosePane(
    cl: *DaemonClient,
    payload: []const u8,
    sessions: *[max_sessions]?DaemonSession,
) void {
    const pane_id = protocol.decodeClosePane(payload) catch {
        cl.sendError(1, "invalid close_pane payload");
        return;
    };
    const session = getAttachedSession(cl, sessions) orelse return;
    _ = session.removePane(pane_id);
}

fn handleFocusPanes(
    cl: *DaemonClient,
    payload: []const u8,
    sessions: *[max_sessions]?DaemonSession,
) void {
    const msg = protocol.decodeFocusPanes(payload) catch {
        cl.sendError(1, "invalid focus_panes payload");
        return;
    };
    const session = getAttachedSession(cl, sessions) orelse return;

    // Determine which panes are newly active (weren't in old set)
    const old_count = cl.active_pane_count;
    const old_panes = cl.active_panes;

    // Update active panes set
    cl.active_pane_count = msg.count;
    for (0..msg.count) |i| {
        cl.active_panes[i] = msg.pane_ids[i];
    }

    // Send replay for newly-active panes
    for (0..msg.count) |i| {
        const new_id = msg.pane_ids[i];
        var was_active = false;
        for (0..old_count) |j| {
            if (old_panes[j] == new_id) {
                was_active = true;
                break;
            }
        }
        if (!was_active) {
            if (session.findPane(new_id)) |pane| {
                cl.sendPaneReplay(pane);
            }
        }
    }
}

fn handlePaneInput(
    cl: *DaemonClient,
    payload: []const u8,
    sessions: *[max_sessions]?DaemonSession,
) void {
    const msg = protocol.decodePaneInput(payload) catch return;
    const session = getAttachedSession(cl, sessions) orelse return;
    if (session.findPane(msg.pane_id)) |pane| {
        pane.writeInput(msg.bytes) catch {};
    }
}

fn handlePaneResize(
    cl: *DaemonClient,
    payload: []const u8,
    sessions: *[max_sessions]?DaemonSession,
) void {
    const msg = protocol.decodePaneResize(payload) catch return;
    const session = getAttachedSession(cl, sessions) orelse return;
    if (session.findPane(msg.pane_id)) |pane| {
        pane.resize(msg.rows, msg.cols) catch {};
    }
}

fn handleSaveLayout(
    cl: *DaemonClient,
    payload: []const u8,
    sessions: *[max_sessions]?DaemonSession,
) void {
    const session = getAttachedSession(cl, sessions) orelse return;
    const len: u16 = @intCast(@min(payload.len, session.layout_data.len));
    @memcpy(session.layout_data[0..len], payload[0..len]);
    session.layout_len = len;
}

// ── Helpers ──

fn getAttachedSession(cl: *DaemonClient, sessions: *[max_sessions]?DaemonSession) ?*DaemonSession {
    const sid = cl.attached_session orelse {
        cl.sendError(5, "not attached");
        return null;
    };
    return findSession(sessions, sid) orelse {
        cl.sendError(4, "session not found");
        return null;
    };
}

fn findSession(sessions: *[max_sessions]?DaemonSession, id: u32) ?*DaemonSession {
    for (sessions) |*slot| {
        if (slot.*) |*s| {
            if (s.id == id) return s;
        }
    }
    return null;
}

fn setNonBlocking(fd: std.posix.fd_t) void {
    const F_GETFL: i32 = 3;
    const F_SETFL: i32 = 4;
    const platform = @import("../../platform/platform.zig");
    const flags = std.posix.fcntl(fd, F_GETFL, 0) catch return;
    _ = std.posix.fcntl(fd, F_SETFL, flags | platform.O_NONBLOCK) catch {};
}
