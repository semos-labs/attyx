// Attyx — daemon headless control handler
//
// Executes ctl_request ops (write_input, get_text) against a target session
// directly, with no window attached. This is what lets background agents in
// different sessions drive their own session over IPC without switching the
// session any window is showing.

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const protocol = @import("protocol.zig");
const session_mod = @import("session.zig");
const DaemonSession = session_mod.DaemonSession;
const DaemonPane = @import("pane.zig").DaemonPane;
const DaemonClient = @import("client.zig").DaemonClient;
const platform = @import("../../platform/platform.zig");
const layout_codec = @import("../layout_codec.zig");
const handler_ctl_layout = @import("handler_ctl_layout.zig");

const max_sessions: usize = 32;
const max_clients: usize = 16;

/// Default grid size used when activating a deferred pane that has no real
/// dimensions yet (e.g. a session created in the background and never viewed).
const default_rows: u16 = 24;
const default_cols: u16 = 80;

pub fn handle(
    cl: *DaemonClient,
    payload: []const u8,
    sessions: *[max_sessions]?DaemonSession,
    next_pane_id: *u32,
    allocator: std.mem.Allocator,
    clients: *[max_clients]?DaemonClient,
) void {
    const req = protocol.decodeCtlRequest(payload) catch {
        cl.sendCtlResponse(1, "invalid ctl request");
        return;
    };
    const session = findSession(sessions, req.target_session) orelse {
        cl.sendCtlResponse(1, "session not found");
        return;
    };
    const op = std.meta.intToEnum(protocol.CtlOp, req.op) catch {
        cl.sendCtlResponse(1, "unsupported ctl op");
        return;
    };
    switch (op) {
        .write_input => handleWriteInput(cl, session, req.body),
        .get_text => handleGetText(cl, session, req.body, allocator),
        .list => handleList(cl, session, req.body),
        .tab_create => handler_ctl_layout.tabCreate(cl, session, req.body, next_pane_id, allocator, clients),
        .tab_select => handler_ctl_layout.tabSelect(cl, session, req.body, clients),
        .tab_next => handler_ctl_layout.tabStep(cl, session, clients, .next),
        .tab_prev => handler_ctl_layout.tabStep(cl, session, clients, .prev),
        .split => handler_ctl_layout.split(cl, session, req.body, next_pane_id, allocator, clients),
        .pane_close => handler_ctl_layout.paneClose(cl, session, req.body, clients),
        .pane_rotate => handler_ctl_layout.paneRotate(cl, session, clients),
        .tab_close => handler_ctl_layout.tabClose(cl, session, req.body, clients),
        .tab_move => handler_ctl_layout.tabMove(cl, session, req.body, clients),
        .tab_rename => handler_ctl_layout.tabRename(cl, session, req.body, clients),
    }
}

fn handleWriteInput(cl: *DaemonClient, session: *DaemonSession, body: []const u8) void {
    if (body.len < 4) {
        cl.sendCtlResponse(1, "missing pane id");
        return;
    }
    const pane_id = std.mem.readInt(u32, body[0..4], .little);
    const bytes = body[4..];
    const pane = selectPane(session, pane_id) orelse {
        cl.sendCtlResponse(1, "pane not found");
        return;
    };
    ensureActive(pane, session);
    pane.writeInput(bytes) catch {
        cl.sendCtlResponse(1, "write failed");
        return;
    };
    cl.sendCtlResponse(0, "");
}

fn handleGetText(
    cl: *DaemonClient,
    session: *DaemonSession,
    body: []const u8,
    allocator: std.mem.Allocator,
) void {
    if (body.len < 4) {
        cl.sendCtlResponse(1, "missing pane id");
        return;
    }
    const pane_id = std.mem.readInt(u32, body[0..4], .little);
    const lines: u32 = if (body.len >= 8) std.mem.readInt(u32, body[4..8], .little) else 0;
    const pane = selectPane(session, pane_id) orelse {
        cl.sendCtlResponse(1, "pane not found");
        return;
    };
    ensureActive(pane, session);
    const eng = pane.engine orelse {
        cl.sendCtlResponse(1, "pane has no screen yet");
        return;
    };

    // Same row selection + trailing-whitespace trim as the window-side
    // get-text (handler_query.writeScreenText), but against the daemon's
    // own engine grid.
    const ring = &eng.state.ring;
    const cols = ring.cols;
    const total_rows: usize = if (lines == 0) ring.screen_rows else @min(@as(usize, lines), ring.count);
    const start_abs: usize = if (lines == 0) ring.scrollbackCount() else ring.count - total_rows;

    const max_row_bytes = cols * 4 + 1;
    const buf_size = total_rows * max_row_bytes + 64;
    const buf = allocator.alloc(u8, buf_size) catch {
        cl.sendCtlResponse(1, "out of memory");
        return;
    };
    defer allocator.free(buf);
    var stream = std.io.fixedBufferStream(buf);
    const w = stream.writer();

    var i: usize = 0;
    while (i < total_rows) : (i += 1) {
        const row_cells = ring.getRow(start_abs + i);
        var last: usize = cols;
        while (last > 0 and row_cells[last - 1].char == ' ') last -= 1;
        for (row_cells[0..last]) |cell| {
            var cp: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cell.char, &cp) catch continue;
            w.writeAll(cp[0..len]) catch break;
        }
        w.writeAll("\n") catch break;
    }

    cl.sendCtlResponse(0, stream.getWritten());
}

fn handleList(cl: *DaemonClient, session: *DaemonSession, body: []const u8) void {
    const kind: protocol.CtlListKind = if (body.len >= 1)
        (std.meta.intToEnum(protocol.CtlListKind, body[0]) catch .all)
    else
        .all;

    var buf: [8192]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();

    // Prefer the stored tab/split layout; fall back to a flat pane list for
    // sessions created but never viewed (no layout blob yet).
    if (session.layout_len > 0) {
        if (layout_codec.deserialize(session.layout_data[0..session.layout_len])) |info_const| {
            var info = info_const;
            writeFromLayout(w, session, &info, kind);
            cl.sendCtlResponse(0, stream.getWritten());
            return;
        } else |_| {}
    }
    writeFlat(w, session, kind);
    cl.sendCtlResponse(0, stream.getWritten());
}

fn writeFromLayout(
    w: anytype,
    session: *DaemonSession,
    info: *const layout_codec.LayoutInfo,
    kind: protocol.CtlListKind,
) void {
    for (0..info.tab_count) |ti| {
        const tab = &info.tabs[ti];
        var leaf_ids: [layout_codec.max_nodes_per_tab]u32 = undefined;
        const lc = tabLeaves(tab, &leaf_ids);
        const active = (ti == info.active_tab);
        const focused_pane = tabFocusedPane(tab);

        if (kind == .panes) {
            // Panes of the active tab only — mirrors the window's `list panes`.
            if (!active) continue;
            for (leaf_ids[0..lc]) |pid| writePaneLine(w, session, pid, pid == focused_pane, false);
            continue;
        }

        const title = tab.getTitle() orelse paneTitle(session, if (lc > 0) leaf_ids[0] else 0);
        w.print("{d}\t{s}", .{ ti + 1, title }) catch return;
        if (active) w.writeAll("\t*") catch return;
        if (lc > 1) w.print("\t{d} panes", .{lc}) catch return;
        w.writeAll("\n") catch return;

        if (kind == .all and lc > 1) {
            for (leaf_ids[0..lc]) |pid| writePaneLine(w, session, pid, pid == focused_pane, true);
        }
    }
}

fn writeFlat(w: anytype, session: *DaemonSession, kind: protocol.CtlListKind) void {
    var ids: [session_mod.max_panes_per_session]u32 = undefined;
    const n = session.collectPaneIds(&ids);
    if (n == 0) return;

    if (kind == .panes) {
        for (ids[0..n]) |pid| writePaneLine(w, session, pid, pid == ids[0], false);
        return;
    }

    w.print("1\t{s}\t*", .{paneTitle(session, ids[0])}) catch return;
    if (n > 1) w.print("\t{d} panes", .{n}) catch return;
    w.writeAll("\n") catch return;

    if (kind == .all and n > 1) {
        for (ids[0..n]) |pid| writePaneLine(w, session, pid, pid == ids[0], true);
    }
}

fn writePaneLine(w: anytype, session: *DaemonSession, pane_id: u32, focused: bool, indent: bool) void {
    if (indent) w.writeAll("  ") catch return;
    w.print("{d}\t{s}", .{ pane_id, paneTitle(session, pane_id) }) catch return;
    if (focused) w.writeAll("\t*") catch return;
    w.writeAll("\n") catch return;
}

/// Collect a tab's leaf pane IDs in node order. Returns the count.
fn tabLeaves(tab: *const layout_codec.TabLayout, out: *[layout_codec.max_nodes_per_tab]u32) usize {
    var count: usize = 0;
    for (0..tab.node_count) |ni| {
        const node = tab.nodes[ni];
        if (node.tag == .leaf) {
            out[count] = node.pane_id;
            count += 1;
        }
    }
    return count;
}

/// The pane_id of a tab's focused node, or 0 if its focused node isn't a leaf.
fn tabFocusedPane(tab: *const layout_codec.TabLayout) u32 {
    if (tab.focused_idx >= tab.node_count) return 0;
    const node = tab.nodes[tab.focused_idx];
    return if (node.tag == .leaf) node.pane_id else 0;
}

/// Best-effort pane title: live engine title, else cached process name, else
/// a generic "shell".
fn paneTitle(session: *DaemonSession, pane_id: u32) []const u8 {
    const pane = session.findPane(pane_id) orelse return "shell";
    if (pane.engine) |eng| {
        if (eng.state.title) |t| {
            if (t.len > 0) return t;
        }
    }
    if (pane.proc_name_len > 0) return pane.proc_name[0..pane.proc_name_len];
    return "shell";
}

/// Resolve the pane a ctl op targets: an explicit id, or the session's first
/// pane when id is 0.
fn selectPane(session: *DaemonSession, pane_id: u32) ?*DaemonPane {
    if (pane_id == 0) return session.firstPane();
    return session.findPane(pane_id);
}

/// A session created but never viewed has a deferred initial pane (PTY not
/// yet spawned, no engine). Activate it at a sensible size so headless ops
/// have something to read/write. A later window attach resizes it to the real
/// window dims, so this only affects the very first prompt's width.
fn ensureActive(pane: *DaemonPane, session: *DaemonSession) void {
    if (pane.deferred == null) return;
    const rows: u16 = if (session.rows > 0) session.rows else default_rows;
    const cols: u16 = if (session.cols > 0) session.cols else default_cols;
    pane.resize(rows, cols) catch {};
    if (comptime !is_windows) setNonBlocking(pane.pty.master);
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
    if (comptime is_windows) return;
    if (fd < 0) return;
    const F_GETFL: i32 = 3;
    const F_SETFL: i32 = 4;
    const flags = std.posix.fcntl(fd, F_GETFL, 0) catch return;
    _ = std.posix.fcntl(fd, F_SETFL, flags | platform.O_NONBLOCK) catch {};
}
