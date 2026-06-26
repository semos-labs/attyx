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
const agents = @import("../../ipc/agents.zig");

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
        .scroll => handleScroll(cl, session, req.body),
        .list_agents => handleListAgents(cl, session, req.body),
    }
}

/// List the session's panes running an agent (status != none), built from the
/// daemon's own live engines. body = [format:u8][pane_filter:u32 LE]; format 1
/// = JSON array, else TSV rows; pane_filter != 0 restricts output to that pane.
/// Mirrors the window-side handler_query.buildAgentList so the two surfaces
/// produce identical records.
fn handleListAgents(cl: *DaemonClient, session: *DaemonSession, body: []const u8) void {
    const as_json = body.len >= 1 and body[0] == 1;
    const pane_filter: u32 = if (body.len >= 5)
        std.mem.readInt(u32, body[1..5], .little)
    else
        0;

    var buf: [8192]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();

    if (as_json) w.writeAll("[") catch {} else agents.writeAgentTableHeader(w) catch {};
    var first = true;

    // Walk the stored layout so each agent's tab_id matches `list`'s tab handle
    // (the tab's focused pane id). Fall back to a flat scan for sessions created
    // but never viewed, where tab 1 groups every pane.
    var used_layout = false;
    if (session.layout_len > 0) {
        if (layout_codec.deserialize(session.layout_data[0..session.layout_len])) |info_const| {
            var info = info_const;
            for (0..info.tab_count) |ti| {
                const tab = &info.tabs[ti];
                const tab_id = tabFocusedPane(tab);
                var leaf_ids: [layout_codec.max_nodes_per_tab]u32 = undefined;
                const lc = tabLeaves(tab, &leaf_ids);
                for (leaf_ids[0..lc]) |pid| {
                    writeAgentRow(w, session, pid, tab_id, as_json, pane_filter, &first);
                }
            }
            used_layout = true;
        } else |_| {}
    }
    if (!used_layout) {
        var ids: [session_mod.max_panes_per_session]u32 = undefined;
        const n = session.collectPaneIds(&ids);
        const tab_id: u32 = if (n > 0) ids[0] else 0;
        for (ids[0..n]) |pid| {
            writeAgentRow(w, session, pid, tab_id, as_json, pane_filter, &first);
        }
    }

    if (as_json) w.writeAll("]") catch {};
    cl.sendCtlResponse(0, stream.getWritten());
}

/// Emit one agent record for `pane_id` if it's running an agent and passes the
/// pane filter. `first` tracks JSON comma placement across calls.
fn writeAgentRow(
    w: anytype,
    session: *DaemonSession,
    pane_id: u32,
    tab_id: u32,
    as_json: bool,
    pane_filter: u32,
    first: *bool,
) void {
    if (pane_filter != 0 and pane_filter != pane_id) return;
    const pane = session.findPane(pane_id) orelse return;
    const eng = pane.engine orelse return;
    const status = eng.state.agent_status;
    if (status == .none) return;
    // No POSIX pty master fd on Windows → PID is unavailable (0 = unknown).
    const pid: u32 = if (comptime builtin.os.tag == .windows) 0 else agents.panePid(pane.pty.master);
    if (as_json) {
        if (!first.*) w.writeAll(",") catch return;
        agents.writeAgentJson(w, pane_id, tab_id, session.id, pid, status, eng.state.agentMsg(), eng.state.agentUsage()) catch return;
    } else {
        agents.writeAgentRow(w, pane_id, tab_id, session.id, pid, status, eng.state.agentMsg(), eng.state.agentUsage()) catch return;
    }
    first.* = false;
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

/// Move a pane's IPC-private scroll cursor. body = [pane_id:u32][kind:u8].
/// This only affects what headless get-text returns — never a window's view.
fn handleScroll(cl: *DaemonClient, session: *DaemonSession, body: []const u8) void {
    if (body.len < 5) {
        cl.sendCtlResponse(1, "invalid scroll request");
        return;
    }
    const pane_id = std.mem.readInt(u32, body[0..4], .little);
    const kind = std.meta.intToEnum(protocol.CtlScrollKind, body[4]) catch {
        cl.sendCtlResponse(1, "invalid scroll kind");
        return;
    };
    const pane = selectPane(session, pane_id) orelse {
        cl.sendCtlResponse(1, "pane not found");
        return;
    };
    ensureActive(pane, session);
    const eng = pane.engine orelse {
        cl.sendCtlResponse(1, "pane has no screen yet");
        return;
    };
    const sb = eng.state.ring.scrollbackCount();
    const page = eng.state.ring.screen_rows;
    const off = computeScrollOffset(kind, pane.ipc_viewport_offset, sb, page);
    pane.ipc_viewport_offset = off;

    var reply_buf: [16]u8 = undefined;
    const reply = std.fmt.bufPrint(&reply_buf, "{d}", .{off}) catch "";
    cl.sendCtlResponse(0, reply);
}

/// Pure scroll-offset transition (rows back from the live bottom), clamped to
/// the available scrollback. `page` is the screen height.
fn computeScrollOffset(kind: protocol.CtlScrollKind, cur: usize, sb: usize, page: usize) usize {
    const off = @min(cur, sb);
    return switch (kind) {
        .top => sb,
        .bottom => 0,
        .page_up => @min(off + page, sb),
        .page_down => if (off >= page) off - page else 0,
    };
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
    // own engine grid. The visible-screen view (lines == 0) follows the
    // IPC scroll cursor; an explicit --lines range is always tail-relative.
    const ring = &eng.state.ring;
    const cols = ring.cols;
    const total_rows: usize = if (lines == 0) ring.screen_rows else @min(@as(usize, lines), ring.count);
    const scroll_off = @min(pane.ipc_viewport_offset, ring.scrollbackCount());
    const start_abs: usize = if (lines == 0) ring.scrollbackCount() - scroll_off else ring.count - total_rows;

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

test "computeScrollOffset transitions and clamps" {
    const sb: usize = 100;
    const page: usize = 24;
    // page-up accumulates and clamps at sb
    try std.testing.expectEqual(@as(usize, 24), computeScrollOffset(.page_up, 0, sb, page));
    try std.testing.expectEqual(@as(usize, 48), computeScrollOffset(.page_up, 24, sb, page));
    try std.testing.expectEqual(sb, computeScrollOffset(.page_up, 90, sb, page));
    // page-down decrements and floors at 0
    try std.testing.expectEqual(@as(usize, 0), computeScrollOffset(.page_down, 24, sb, page));
    try std.testing.expectEqual(@as(usize, 0), computeScrollOffset(.page_down, 10, sb, page));
    try std.testing.expectEqual(@as(usize, 76), computeScrollOffset(.page_down, 100, sb, page));
    // top / bottom are absolute
    try std.testing.expectEqual(sb, computeScrollOffset(.top, 0, sb, page));
    try std.testing.expectEqual(@as(usize, 0), computeScrollOffset(.bottom, sb, sb, page));
    // a stale offset beyond sb is clamped to sb before stepping
    try std.testing.expectEqual(sb, computeScrollOffset(.page_up, 999, sb, page));
}
