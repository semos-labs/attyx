const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const attyx = @import("attyx");
const protocol = @import("protocol.zig");
const DaemonSession = @import("session.zig").DaemonSession;
const DaemonClient = @import("client.zig").DaemonClient;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;
const layout_codec = @import("../layout_codec.zig");
const state_persist = @import("state_persist.zig");


const max_sessions: usize = 32;
const max_clients: usize = 16;
const replay_capacity: usize = RingBuffer.default_capacity;

pub fn handleMessage(
    cl: *DaemonClient,
    msg: DaemonClient.Message,
    sessions: *[max_sessions]?DaemonSession,
    session_count: *usize,
    next_id: *u32,
    next_pane_id: *u32,
    allocator: std.mem.Allocator,
    clients: *[max_clients]?DaemonClient,
    upgrade_requested: *bool,
) void {
    switch (msg.msg_type) {
        .create => handleCreate(cl, msg.payload, sessions, session_count, next_id, next_pane_id, allocator),
        .list => cl.sendSessionListFromSlots(sessions),
        .attach => handleAttach(cl, msg.payload, sessions, next_pane_id, allocator),
        .detach => {
            cl.attached_session = null;
            cl.active_pane_count = 0;
        },
        .kill => handleKill(msg.payload, sessions, session_count, next_id.*, next_pane_id.*),
        .rename => handleRename(msg.payload, sessions),
        .hello => handleHello(cl, msg.payload, upgrade_requested),

        // V2 pane-multiplexed messages
        .create_pane => handleCreatePane(cl, msg.payload, sessions, next_pane_id, allocator),
        .close_pane => handleClosePane(cl, msg.payload, sessions),
        .focus_panes => handleFocusPanes(cl, msg.payload, sessions),
        .pane_input => handlePaneInput(cl, msg.payload, sessions),
        .pane_resize => handlePaneResize(cl, msg.payload, sessions),
        .save_layout => handleSaveLayout(cl, msg.payload, sessions, clients),
        .set_theme_colors => handleSetThemeColors(cl, msg.payload, sessions),

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
    next_pane_id: *u32,
    allocator: std.mem.Allocator,
) void {
    const create = protocol.decodeCreate(payload) catch {
        cl.sendError(1, "invalid create payload");
        return;
    };
    if (session_count.* >= max_sessions) {
        // Try to evict a dead (recent) session to make room.
        var evicted = false;
        for (sessions) |*slot| {
            if (slot.*) |*s| {
                if (!s.alive) {
                    s.deinit();
                    slot.* = null;
                    session_count.* -= 1;
                    evicted = true;
                    break;
                }
            }
        }
        if (!evicted) {
            cl.sendError(2, "max sessions reached");
            return;
        }
    }
    const slot_idx = for (sessions, 0..) |*slot, i| {
        if (slot.* == null) break i;
    } else {
        // All slots occupied (shouldn't happen after eviction, but guard anyway).
        cl.sendError(2, "max sessions reached");
        return;
    };
    const id = next_id.*;
    next_id.* += 1;
    // Static buffers for null-terminating CWD/shell (aarch64 Windows stack workaround).
    const ZBufs = struct {
        var cwd_z_buf: [4097]u8 = undefined;
        var shell_z_buf: [257]u8 = undefined;
    };
    const cwd_z: ?[*:0]const u8 = if (create.cwd.len > 0 and create.cwd.len < ZBufs.cwd_z_buf.len) blk: {
        @memcpy(ZBufs.cwd_z_buf[0..create.cwd.len], create.cwd);
        ZBufs.cwd_z_buf[create.cwd.len] = 0;
        break :blk @ptrCast(&ZBufs.cwd_z_buf);
    } else null;
    const shell_z: ?[*:0]const u8 = if (create.shell.len > 0 and create.shell.len < ZBufs.shell_z_buf.len) blk: {
        @memcpy(ZBufs.shell_z_buf[0..create.shell.len], create.shell);
        ZBufs.shell_z_buf[create.shell.len] = 0;
        break :blk @ptrCast(&ZBufs.shell_z_buf);
    } else null;
    const initial_pane_id = next_pane_id.*;
    next_pane_id.* += 1;
    sessions[slot_idx] = DaemonSession.spawn(
        allocator,
        id,
        create.name,
        create.rows,
        create.cols,
        replay_capacity,
        cwd_z,
        initial_pane_id,
        shell_z,
    ) catch {
        cl.sendError(3, "spawn failed");
        return;
    };
    session_count.* += 1;
    // Set non-blocking on initial pane's PTY master
    if (sessions[slot_idx].?.firstPane()) |pane| {
        if (comptime !is_windows) setNonBlocking(pane.pty.master);
    }
    cl.sendCreated(id);
}

fn handleAttach(
    cl: *DaemonClient,
    payload: []const u8,
    sessions: *[max_sessions]?DaemonSession,
    next_pane_id: *u32,
    allocator: std.mem.Allocator,
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

    // Revive dead (recent) sessions by spawning fresh panes.
    if (!session.alive) {
        reviveSession(session, attach.rows, attach.cols, next_pane_id, allocator);
    }

    session.resize(attach.rows, attach.cols) catch {};
    // Send V2 attached with layout blob and pane IDs.
    // Replay is NOT sent here — the client requests it via focus_panes.
    cl.sendAttachedV2(session);
}

fn handleKill(
    payload: []const u8,
    sessions: *[max_sessions]?DaemonSession,
    session_count: *usize,
    next_session_id: u32,
    next_pane_id: u32,
) void {
    const kill_id = protocol.decodeKill(payload) catch return;
    for (sessions) |*slot| {
        if (slot.*) |*s| {
            if (s.id == kill_id) {
                if (s.alive) {
                    // Soft-kill: preserve session metadata, kill PTYs only.
                    // Session stays in its slot as a "recent" entry.
                    s.killAllPanes();
                    // Persist dead sessions to disk.
                    state_persist.save(sessions, next_session_id, next_pane_id);
                } else {
                    // Already dead — fully destroy it and free the slot.
                    s.deinit();
                    slot.* = null;
                    session_count.* -= 1;
                }
                break;
            }
        }
    }
}

fn handleRename(
    payload: []const u8,
    sessions: *[max_sessions]?DaemonSession,
) void {
    const msg = protocol.decodeRename(payload) catch return;
    const s = findSession(sessions, msg.session_id) orelse return;
    const nlen: u8 = @intCast(@min(msg.name.len, 64));
    @memcpy(s.name[0..nlen], msg.name[0..nlen]);
    s.name_len = nlen;
}

fn handleHello(cl: *DaemonClient, payload: []const u8, upgrade_requested: *bool) void {
    const daemon_version = attyx.version;
    const client_version = protocol.decodeHello(payload) catch {
        cl.sendHelloAck(daemon_version);
        return;
    };
    cl.sendHelloAck(daemon_version);
    if (!std.mem.eql(u8, client_version, daemon_version)) {
        upgrade_requested.* = true;
    }
}

// ── V2 pane-multiplexed handlers ──

fn handleCreatePane(
    cl: *DaemonClient,
    payload: []const u8,
    sessions: *[max_sessions]?DaemonSession,
    next_pane_id: *u32,
    allocator: std.mem.Allocator,
) void {
    const msg = protocol.decodeCreatePane(payload) catch {
        cl.sendError(1, "invalid create_pane payload");
        return;
    };
    const session = getAttachedSession(cl, sessions) orelse return;
    const pane_id_val = next_pane_id.*;
    next_pane_id.* += 1;
    // Use CWD from message if provided, otherwise fall back to session CWD.
    const PaneBufs = struct {
        var cwd_z_buf: [4097]u8 = undefined;
        var cmd_z_buf: [4097]u8 = undefined;
    };
    const cwd_z: ?[*:0]const u8 = if (msg.cwd.len > 0 and msg.cwd.len < PaneBufs.cwd_z_buf.len) blk: {
        @memcpy(PaneBufs.cwd_z_buf[0..msg.cwd.len], msg.cwd);
        PaneBufs.cwd_z_buf[msg.cwd.len] = 0;
        break :blk @ptrCast(&PaneBufs.cwd_z_buf);
    } else null;
    // Optional command override (e.g. from `attyx run htop`).
    const cmd_z: ?[*:0]const u8 = if (msg.cmd.len > 0 and msg.cmd.len < PaneBufs.cmd_z_buf.len) blk: {
        @memcpy(PaneBufs.cmd_z_buf[0..msg.cmd.len], msg.cmd);
        PaneBufs.cmd_z_buf[msg.cmd.len] = 0;
        break :blk @ptrCast(&PaneBufs.cmd_z_buf);
    } else null;
    const pane_id = session.addPaneWithId(allocator, pane_id_val, msg.rows, msg.cols, replay_capacity, cwd_z, cmd_z, msg.capture_stdout) catch {
        cl.sendError(3, "create pane failed");
        return;
    };
    // Set non-blocking on new pane's PTY (and stdout capture pipe if present)
    if (session.findPane(pane_id)) |pane| {
        if (comptime !is_windows) setNonBlocking(pane.pty.master);
        if (comptime !is_windows) {
            if (pane.pty.stdout_read_fd != -1) setNonBlocking(pane.pty.stdout_read_fd);
        }
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

    // Drain pending PTY data for newly-active panes before replaying.
    // This closes the race where the shell is still outputting startup
    // sequences (e.g. zsh PROMPT_EOL_MARK) that haven't been read yet.
    // Static drain buffer — avoids 8KB stack allocation that crashes
    // on aarch64 Windows (missing __chkstk probes).
    const DrainBuf = struct {
        var buf: [8192]u8 = undefined;
    };
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
                // Drain any buffered PTY output into the ring buffer
                while (true) {
                    const n = pane.readPty(&DrainBuf.buf) catch break;
                    if (n == 0) break;
                }
                cl.sendPaneReplay(pane);
                cl.sendReplayEnd(new_id);
            }
        }
    }
}

fn handleSetThemeColors(
    cl: *DaemonClient,
    payload: []const u8,
    sessions: *[max_sessions]?DaemonSession,
) void {
    const msg = protocol.decodeThemeColors(payload) catch return;
    const session = getAttachedSession(cl, sessions) orelse return;
    // Apply to all panes in the session
    for (&session.panes) |*slot| {
        if (slot.*) |*pane| {
            pane.theme_fg = msg.fg;
            pane.theme_bg = msg.bg;
            pane.theme_cursor = msg.cursor;
            pane.theme_cursor_set = msg.cursor_set;
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
    clients: *[max_clients]?DaemonClient,
) void {
    const session = getAttachedSession(cl, sessions) orelse return;
    const len: u16 = @intCast(@min(payload.len, session.layout_data.len));
    @memcpy(session.layout_data[0..len], payload[0..len]);
    session.layout_len = len;

    // Broadcast layout_sync to all OTHER clients attached to the same session.
    for (clients) |*cslot| {
        if (cslot.*) |*other| {
            if (other == cl) continue;
            if (other.attached_session == cl.attached_session) {
                other.sendLayoutSync(session);
            }
        }
    }
}

// ── Session revive ──

/// Revive a dead (recent) session by spawning fresh panes to match its layout.
/// Remaps old pane IDs in the layout blob to the newly spawned pane IDs.
fn reviveSession(
    session: *DaemonSession,
    rows: u16,
    cols: u16,
    next_pane_id: *u32,
    allocator: std.mem.Allocator,
) void {
    const cwd: ?[*:0]const u8 = if (session.cwd_len > 0)
        @as([*:0]const u8, session.cwd[0..session.cwd_len :0])
    else
        null;

    // Try to revive using the layout blob.
    if (session.layout_len > 0) {
        if (layout_codec.deserialize(session.layout_data[0..session.layout_len])) |*info_const| {
            var info = info_const.*;
            var old_ids: [layout_codec.max_tabs * layout_codec.max_nodes_per_tab]u32 = undefined;
            var new_ids: [layout_codec.max_tabs * layout_codec.max_nodes_per_tab]u32 = undefined;
            const leaf_count = layout_codec.collectLeafPaneIds(&info, &old_ids);

            // Spawn one pane per leaf.
            var spawned: u32 = 0;
            for (0..leaf_count) |i| {
                const pane_id = next_pane_id.*;
                next_pane_id.* += 1;
                new_ids[i] = pane_id;
                _ = session.addPaneWithId(allocator, pane_id, rows, cols, RingBuffer.default_capacity, cwd, null, false) catch continue;
                if (session.findPane(pane_id)) |pane| {
                    if (comptime !is_windows) setNonBlocking(pane.pty.master);
                }
                spawned += 1;
            }

            if (spawned > 0) {
                // Remap pane IDs in the layout and re-serialize.
                layout_codec.remapPaneIds(&info, old_ids[0..leaf_count], new_ids[0..leaf_count]);
                if (layout_codec.serialize(&info, &session.layout_data)) |len| {
                    session.layout_len = len;
                } else |_| {}
                session.alive = true;
                return;
            }
        } else |_| {}
    }

    // Fallback: spawn a single pane (no layout or deserialization failed).
    const pane_id = next_pane_id.*;
    next_pane_id.* += 1;
    _ = session.addPaneWithId(allocator, pane_id, rows, cols, RingBuffer.default_capacity, cwd, null, false) catch return;
    if (session.findPane(pane_id)) |pane| {
        if (comptime !is_windows) setNonBlocking(pane.pty.master);
    }
    session.alive = true;
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
    if (comptime is_windows) return; // Windows handles don't use fcntl
    const F_GETFL: i32 = 3;
    const F_SETFL: i32 = 4;
    const platform = @import("../../platform/platform.zig");
    const flags = std.posix.fcntl(fd, F_GETFL, 0) catch return;
    _ = std.posix.fcntl(fd, F_SETFL, flags | platform.O_NONBLOCK) catch {};
}
