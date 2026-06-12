// Attyx — daemon headless layout mutations
//
// Layout-changing ctl ops (tab create/close/move/rename, split, pane close/
// rotate). These make the daemon authoritative over a session's tab/split tree
// for headless control: the daemon spawns/kills the pane, edits the serialized
// layout, and broadcasts layout_sync so any attached window re-renders live.
// Pure tree surgery lives in layout_ops.zig.

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const session_mod = @import("session.zig");
const DaemonSession = session_mod.DaemonSession;
const DaemonClient = @import("client.zig").DaemonClient;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;
const layout_codec = @import("../layout_codec.zig");
const platform = @import("../../platform/platform.zig");
const ops = @import("layout_ops.zig");

const max_clients: usize = 16;
const replay_capacity: usize = RingBuffer.default_capacity;
const default_rows: u16 = 24;
const default_cols: u16 = 80;

pub const TabStep = enum { next, prev };
pub const TabMoveDir = enum { left, right };

/// Spawn a new pane as a new tab in `session`. `body` is an optional command to
/// run in the pane (like `attyx run <cmd>`); empty means a plain shell.
pub fn tabCreate(
    cl: *DaemonClient,
    session: *DaemonSession,
    body: []const u8,
    next_pane_id: *u32,
    allocator: std.mem.Allocator,
    clients: *[max_clients]?DaemonClient,
) void {
    if (@as(usize, session.pane_count) + 1 > session_mod.max_panes_per_session) {
        cl.sendCtlResponse(1, "session is full");
        return;
    }

    // Snapshot existing panes before spawning so we can synthesize tabs for
    // them if the session has no layout blob yet (created but never viewed).
    var existing: [session_mod.max_panes_per_session]u32 = undefined;
    const existing_count = session.collectPaneIds(&existing);

    const pane_id = spawnPane(session, allocator, next_pane_id, body) orelse {
        cl.sendCtlResponse(1, "create pane failed");
        return;
    };

    appendTabForPane(session, pane_id, existing[0..existing_count]);
    broadcastLayout(session, clients);

    var reply_buf: [16]u8 = undefined;
    const reply = std.fmt.bufPrint(&reply_buf, "{d}", .{pane_id}) catch "";
    cl.sendCtlResponse(0, reply);
}

/// Append a single-pane tab for `pane_id` to the session's layout and make it
/// active. If the session had no layout yet, first synthesize single-pane tabs
/// for the panes that already existed so they aren't dropped from the view.
fn appendTabForPane(session: *DaemonSession, pane_id: u32, existing: []const u32) void {
    var info: layout_codec.LayoutInfo = if (session.layout_len > 0)
        (layout_codec.deserialize(session.layout_data[0..session.layout_len]) catch layout_codec.LayoutInfo{})
    else
        layout_codec.LayoutInfo{};

    if (info.tab_count == 0) {
        for (existing) |pid| {
            if (pid == pane_id) continue;
            if (!ops.appendLeafTab(&info, pid)) break;
        }
    }

    if (!ops.appendLeafTab(&info, pane_id)) return;
    info.active_tab = info.tab_count - 1;
    info.focused_pane_id = pane_id;
    persist(session, &info);
}

/// Spawn a pane in `session` at the session's size (or a default), optionally
/// running `cmd_body` like `attyx run`. Returns the new pane id, or null on
/// failure. Bumps next_pane_id on success.
fn spawnPane(
    session: *DaemonSession,
    allocator: std.mem.Allocator,
    next_pane_id: *u32,
    cmd_body: []const u8,
) ?u32 {
    const rows: u16 = if (session.rows > 0) session.rows else default_rows;
    const cols: u16 = if (session.cols > 0) session.cols else default_cols;

    // Null-terminate the optional command into a static buffer (matches the
    // aarch64-Windows stack workaround used elsewhere in the daemon).
    const CmdBuf = struct {
        var z: [4097]u8 = undefined;
    };
    const cmd_z: ?[*:0]const u8 = if (cmd_body.len > 0 and cmd_body.len < CmdBuf.z.len) blk: {
        @memcpy(CmdBuf.z[0..cmd_body.len], cmd_body);
        CmdBuf.z[cmd_body.len] = 0;
        break :blk @ptrCast(&CmdBuf.z);
    } else null;

    const pane_id = session.addPaneWithId(allocator, next_pane_id.*, rows, cols, replay_capacity, null, null, cmd_z, false) catch return null;
    next_pane_id.* += 1;
    if (session.findPane(pane_id)) |pane| {
        if (comptime !is_windows) setNonBlocking(pane.pty.master);
    }
    return pane_id;
}

/// Split the active tab's focused pane, spawning a new pane beside it.
/// `body` = [dir:u8 (0=vertical, 1=horizontal)][cmd...].
pub fn split(
    cl: *DaemonClient,
    session: *DaemonSession,
    body: []const u8,
    next_pane_id: *u32,
    allocator: std.mem.Allocator,
    clients: *[max_clients]?DaemonClient,
) void {
    if (body.len < 1) {
        cl.sendCtlResponse(1, "missing split direction");
        return;
    }
    const dir: layout_codec.SplitDirection = if (body[0] == 1) .horizontal else .vertical;
    const cmd_body = body[1..];

    if (@as(usize, session.pane_count) + 1 > session_mod.max_panes_per_session) {
        cl.sendCtlResponse(1, "session is full");
        return;
    }

    var info = ensureLayout(session);
    if (info.tab_count == 0) {
        cl.sendCtlResponse(1, "no panes to split");
        return;
    }
    const tab = &info.tabs[info.active_tab];
    // A split converts the focused leaf into a branch with two leaf children,
    // so it needs two free node slots.
    if (@as(usize, tab.node_count) + 2 > layout_codec.max_nodes_per_tab) {
        cl.sendCtlResponse(1, "split limit reached");
        return;
    }

    const new_pane = spawnPane(session, allocator, next_pane_id, cmd_body) orelse {
        cl.sendCtlResponse(1, "create pane failed");
        return;
    };

    const li = ops.focusedLeafIdx(tab);
    const orig_pane = tab.nodes[li].pane_id;
    const a: u8 = tab.node_count;
    tab.nodes[a] = .{ .tag = .leaf, .pane_id = orig_pane };
    const b: u8 = a + 1;
    tab.nodes[b] = .{ .tag = .leaf, .pane_id = new_pane };
    tab.node_count += 2;
    tab.nodes[li] = .{ .tag = .branch, .direction = dir, .ratio_x100 = 50, .child_left = a, .child_right = b };
    tab.focused_idx = b;
    info.focused_pane_id = new_pane;

    persist(session, &info);
    broadcastLayout(session, clients);

    var reply_buf: [16]u8 = undefined;
    const reply = std.fmt.bufPrint(&reply_buf, "{d}", .{new_pane}) catch "";
    cl.sendCtlResponse(0, reply);
}

/// Close a pane. `body` = [pane_id:u32] (0 = the active tab's focused pane).
/// Removes the leaf (promoting its sibling), or removes the tab if it was the
/// last pane there, then kills the pane.
pub fn paneClose(
    cl: *DaemonClient,
    session: *DaemonSession,
    body: []const u8,
    clients: *[max_clients]?DaemonClient,
) void {
    var info = ensureLayout(session);
    if (info.tab_count == 0) {
        cl.sendCtlResponse(1, "no panes");
        return;
    }

    var target: u32 = if (body.len >= 4) std.mem.readInt(u32, body[0..4], .little) else 0;
    if (target == 0) {
        target = ops.tabFocusedPane(&info.tabs[info.active_tab]);
        if (target == 0) {
            cl.sendCtlResponse(1, "no focused pane");
            return;
        }
    }

    // Locate the tab + node holding the target pane.
    var tabi: ?usize = null;
    var ni: usize = 0;
    for (0..info.tab_count) |t| {
        if (ops.findLeafInTab(&info.tabs[t], target)) |idx| {
            tabi = t;
            ni = idx;
            break;
        }
    }
    const ti = tabi orelse {
        cl.sendCtlResponse(1, "pane not found");
        return;
    };

    const tab = &info.tabs[ti];
    if (ops.countLeaves(tab) <= 1) {
        ops.removeTab(&info, ti);
    } else {
        const new_focus = ops.removeLeafPromote(tab, ni);
        if (info.active_tab == ti) info.focused_pane_id = new_focus;
    }

    _ = session.removePane(target);

    if (info.tab_count == 0) {
        session.layout_len = 0;
    } else {
        persist(session, &info);
    }
    broadcastLayout(session, clients);
    cl.sendCtlResponse(0, "");
}

/// Rotate the panes in the active tab by one position. `body` is ignored.
pub fn paneRotate(
    cl: *DaemonClient,
    session: *DaemonSession,
    clients: *[max_clients]?DaemonClient,
) void {
    var info = ensureLayout(session);
    if (info.tab_count == 0) {
        cl.sendCtlResponse(0, "");
        return;
    }
    const tab = &info.tabs[info.active_tab];
    if (ops.countLeaves(tab) < 2) {
        cl.sendCtlResponse(0, ""); // nothing to rotate
        return;
    }
    ops.rotateLeaves(tab);
    info.focused_pane_id = ops.tabFocusedPane(tab);
    persist(session, &info);
    broadcastLayout(session, clients);
    cl.sendCtlResponse(0, "");
}

/// Close a whole tab (killing all its panes). `body` = [tab_idx:u8] where 0xFF
/// means the active tab and any other value is a 0-based index.
pub fn tabClose(
    cl: *DaemonClient,
    session: *DaemonSession,
    body: []const u8,
    clients: *[max_clients]?DaemonClient,
) void {
    var info = ensureLayout(session);
    if (info.tab_count == 0) {
        cl.sendCtlResponse(1, "no tabs");
        return;
    }
    const idx: usize = if (body.len >= 1 and body[0] != 0xFF) body[0] else info.active_tab;
    if (idx >= info.tab_count) {
        cl.sendCtlResponse(1, "no such tab");
        return;
    }

    var leaves: [layout_codec.max_nodes_per_tab]u32 = undefined;
    const n = ops.collectLeafPanes(&info.tabs[idx], &leaves);
    for (0..n) |k| _ = session.removePane(leaves[k]);

    ops.removeTab(&info, idx);
    if (info.tab_count == 0) {
        session.layout_len = 0;
    } else {
        persist(session, &info);
    }
    broadcastLayout(session, clients);
    cl.sendCtlResponse(0, "");
}

/// Move the active tab one slot. `body` = [dir:u8 (0=left, 1=right)].
pub fn tabMove(
    cl: *DaemonClient,
    session: *DaemonSession,
    body: []const u8,
    clients: *[max_clients]?DaemonClient,
) void {
    var info = loadInfo(session) orelse {
        cl.sendCtlResponse(0, ""); // single implicit tab — nothing to move
        return;
    };
    const right = body.len >= 1 and body[0] == 1;
    if (!ops.moveTab(&info, right)) {
        cl.sendCtlResponse(0, ""); // already at the edge
        return;
    }
    persist(session, &info);
    broadcastLayout(session, clients);
    cl.sendCtlResponse(0, "");
}

/// Rename a tab. `body` = [tab_idx:u8][name...] where tab_idx 0xFF means the
/// active tab and any other value is a 0-based index.
pub fn tabRename(
    cl: *DaemonClient,
    session: *DaemonSession,
    body: []const u8,
    clients: *[max_clients]?DaemonClient,
) void {
    if (body.len < 1) {
        cl.sendCtlResponse(1, "missing tab name");
        return;
    }
    var info = ensureLayout(session);
    if (info.tab_count == 0) {
        cl.sendCtlResponse(1, "no tabs");
        return;
    }
    const idx: usize = if (body[0] != 0xFF) body[0] else info.active_tab;
    if (idx >= info.tab_count) {
        cl.sendCtlResponse(1, "no such tab");
        return;
    }
    ops.setTabTitle(&info.tabs[idx], body[1..]);
    persist(session, &info);
    broadcastLayout(session, clients);
    cl.sendCtlResponse(0, "");
}

/// Make tab `index` (1-based) active.
pub fn tabSelect(
    cl: *DaemonClient,
    session: *DaemonSession,
    body: []const u8,
    clients: *[max_clients]?DaemonClient,
) void {
    const idx1: u8 = if (body.len >= 1) body[0] else 0;
    var info = loadInfo(session) orelse {
        // No layout blob → a single implicit tab; selecting tab 1 is a no-op.
        cl.sendCtlResponse(if (idx1 <= 1) @as(u8, 0) else 1, if (idx1 <= 1) "" else "no such tab");
        return;
    };
    if (idx1 == 0 or idx1 > info.tab_count) {
        cl.sendCtlResponse(1, "no such tab");
        return;
    }
    setActive(session, &info, idx1 - 1, clients);
    cl.sendCtlResponse(0, "");
}

/// Activate the next/previous tab, wrapping at the ends.
pub fn tabStep(
    cl: *DaemonClient,
    session: *DaemonSession,
    clients: *[max_clients]?DaemonClient,
    step: TabStep,
) void {
    var info = loadInfo(session) orelse {
        cl.sendCtlResponse(0, ""); // single implicit tab — nothing to step to
        return;
    };
    if (info.tab_count <= 1) {
        cl.sendCtlResponse(0, "");
        return;
    }
    const cur = info.active_tab;
    const cnt = info.tab_count;
    const new_active: u8 = switch (step) {
        .next => (cur + 1) % cnt,
        .prev => if (cur == 0) cnt - 1 else cur - 1,
    };
    setActive(session, &info, new_active, clients);
    cl.sendCtlResponse(0, "");
}

// ── Shared session-coupled helpers ──

/// Deserialize the session's layout, synthesizing single-pane tabs for any
/// existing panes if there's no (or an invalid) layout blob yet.
fn ensureLayout(session: *DaemonSession) layout_codec.LayoutInfo {
    if (session.layout_len > 0) {
        if (layout_codec.deserialize(session.layout_data[0..session.layout_len])) |info| {
            if (info.tab_count > 0) return info;
        } else |_| {}
    }
    var info = layout_codec.LayoutInfo{};
    var ids: [session_mod.max_panes_per_session]u32 = undefined;
    const n = session.collectPaneIds(&ids);
    for (0..n) |k| {
        if (!ops.appendLeafTab(&info, ids[k])) break;
    }
    if (info.tab_count > 0) {
        info.active_tab = 0;
        info.focused_pane_id = ids[0];
    }
    return info;
}

/// Deserialize the session's layout, or null if it has none/invalid.
fn loadInfo(session: *DaemonSession) ?layout_codec.LayoutInfo {
    if (session.layout_len == 0) return null;
    const info = layout_codec.deserialize(session.layout_data[0..session.layout_len]) catch return null;
    if (info.tab_count == 0) return null;
    return info;
}

/// Set the active tab, sync focused_pane_id to that tab's focused pane, persist,
/// and broadcast to attached windows.
fn setActive(
    session: *DaemonSession,
    info: *layout_codec.LayoutInfo,
    new_active: u8,
    clients: *[max_clients]?DaemonClient,
) void {
    info.active_tab = new_active;
    info.focused_pane_id = ops.tabFocusedPane(&info.tabs[new_active]);
    persist(session, info);
    broadcastLayout(session, clients);
}

/// Serialize `info` back into the session's stored layout blob.
fn persist(session: *DaemonSession, info: *const layout_codec.LayoutInfo) void {
    if (layout_codec.serialize(info, &session.layout_data)) |len| {
        session.layout_len = len;
    } else |_| {}
}

/// Push the session's current layout to every attached window so the change
/// appears without a reattach.
fn broadcastLayout(session: *DaemonSession, clients: *[max_clients]?DaemonClient) void {
    for (clients) |*cslot| {
        if (cslot.*) |*other| {
            if (other.attached_session) |sid| {
                if (sid == session.id) other.sendLayoutSync(session);
            }
        }
    }
}

fn setNonBlocking(fd: std.posix.fd_t) void {
    if (comptime is_windows) return;
    if (fd < 0) return;
    const F_GETFL: i32 = 3;
    const F_SETFL: i32 = 4;
    const flags = std.posix.fcntl(fd, F_GETFL, 0) catch return;
    _ = std.posix.fcntl(fd, F_SETFL, flags | platform.O_NONBLOCK) catch {};
}
