// Attyx — daemon-side agent status watch
//
// Streaming counterpart to the `list_agents` ctl op. A `watch_agents` message
// parks the client connection (see DaemonClient.watch_session) and is fed one
// `agent_event` frame per status transition. This is the cross-session path:
// the daemon holds every session's live engine, so `attyx watch agents -s N`
// works no matter which session a window is attached to (or whether any is).
//
// Mirrors the window-side src/ipc/watch.zig, but the registry is just the
// daemon's existing client array — watchers are ordinary DaemonClients flagged
// with a watch_session, so no separate parking structure is needed.

const std = @import("std");
const builtin = @import("builtin");
const session_mod = @import("session.zig");
const DaemonSession = session_mod.DaemonSession;
const DaemonClient = @import("client.zig").DaemonClient;
const layout_codec = @import("../layout_codec.zig");
const agents = @import("../../ipc/agents.zig");

const max_clients: usize = 16;

/// Sentinel `watch_session` meaning "every session" — the dashboard's
/// cross-session feed. A watcher set to this receives every session's agent
/// transitions, each record self-tagged with its `session` id in the NDJSON.
pub const all_sessions: u32 = 0xFFFFFFFF;

/// Push current agent status + usage for every agent pane in `session` to a
/// freshly attached grid-sync client (the window). Tab indicators are driven by
/// per-pane agent status, but the live broadcast only ships it for the *active*
/// pane — so without this, a window attaching at launch shows no dots for agents
/// in background tabs until each is focused (which makes its agent redraw and
/// re-emit). This sends the typed pane_agent_status/usage messages the window
/// already applies by daemon pane id, regardless of focus.
pub fn sendStatusSnapshotToClient(cl: *DaemonClient, session: *DaemonSession) void {
    var ids: [session_mod.max_panes_per_session]u32 = undefined;
    const n = session.collectPaneIds(&ids);
    for (ids[0..n]) |pid| {
        const pane = session.findPane(pid) orelse continue;
        const eng = pane.engine orelse continue;
        if (eng.state.agent_status == .none) continue;
        cl.sendPaneAgentStatus(pid, @intFromEnum(eng.state.agent_status), eng.state.agentMsg());
        cl.sendPaneAgentUsage(pid, eng.state.agentUsage());
    }
}

/// Send the current set of active agents (status != none) in `session` to a
/// freshly-parked watcher, so it has full state without waiting for the next
/// transition. Honors the watcher's pane filter.
pub fn sendSnapshot(cl: *DaemonClient, session: *DaemonSession) void {
    var ids: [session_mod.max_panes_per_session]u32 = undefined;
    const n = session.collectPaneIds(&ids);
    for (ids[0..n]) |pid| {
        if (cl.watch_pane_filter != 0 and cl.watch_pane_filter != pid) continue;
        const pane = session.findPane(pid) orelse continue;
        const eng = pane.engine orelse continue;
        if (eng.state.agent_status == .none) continue;
        sendOne(cl, session, pane, pid);
    }
}

/// Broadcast one pane's current agent status to every watcher of its session
/// (the pane filter is applied per watcher). Called from the event loop when a
/// pane's agent_status_changed flag fires — including the transition to `.none`
/// when an agent exits, so watchers see agents leave.
pub fn broadcast(
    clients: *[max_clients]?DaemonClient,
    session: *DaemonSession,
    pane: anytype,
) void {
    for (clients) |*slot| {
        if (slot.*) |*cl| {
            // All-sessions watchers (sentinel) receive every session's events;
            // others only their own session.
            if (cl.watch_session != all_sessions and cl.watch_session != session.id) continue;
            if (cl.watch_pane_filter != 0 and cl.watch_pane_filter != pane.id) continue;
            sendOne(cl, session, pane, pane.id);
        }
    }
}

fn sendOne(cl: *DaemonClient, session: *DaemonSession, pane: anytype, pane_id: u32) void {
    const eng = pane.engine orelse return;
    var json_buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&json_buf);
    // No POSIX pty master fd on Windows → PID is unavailable (0 = unknown).
    const pid: u32 = if (comptime builtin.os.tag == .windows) 0 else agents.panePid(pane.pty.master);
    var tab_name_buf: [layout_codec.max_title_len]u8 = undefined;
    var tab_name = tabNameForPane(session, pane_id, &tab_name_buf);
    // No serialized layout title (session never viewed, or daemon-backed pane
    // with no stored title) → fall back to this pane's own title.
    if (tab_name.len == 0) tab_name = eng.state.title orelse "";
    agents.writeAgentJson(
        stream.writer(),
        pane_id,
        tabIdForPane(session, pane_id),
        tab_name,
        session.id,
        pid,
        eng.state.agent_status,
        eng.state.agentMsg(),
        eng.state.agentUsage(),
    ) catch return;
    cl.sendAgentEvent(stream.getWritten());
}

/// The tab handle (its focused pane's id) for the tab containing `pane_id`,
/// matching what `list`/`list_agents` report. Falls back to the pane itself
/// when there's no layout yet (a session created but never viewed).
pub fn tabIdForPane(session: *DaemonSession, pane_id: u32) u32 {
    if (session.layout_len == 0) return pane_id;
    const info = layout_codec.deserialize(session.layout_data[0..session.layout_len]) catch return pane_id;
    for (0..info.tab_count) |ti| {
        const tab = &info.tabs[ti];
        for (0..tab.node_count) |ni| {
            const node = tab.nodes[ni];
            if (node.tag == .leaf and node.pane_id == pane_id) {
                return tabFocusedPane(tab);
            }
        }
    }
    return pane_id;
}

/// The tab's effective title (explicit name, else the serialized fallback —
/// the focused pane's process/title) for the tab containing `pane_id`, copied
/// into `buf`. Empty when there's no layout or title. Mirrors tabIdForPane.
pub fn tabNameForPane(session: *DaemonSession, pane_id: u32, buf: []u8) []const u8 {
    if (session.layout_len == 0) return "";
    const info = layout_codec.deserialize(session.layout_data[0..session.layout_len]) catch return "";
    for (0..info.tab_count) |ti| {
        const tab = &info.tabs[ti];
        for (0..tab.node_count) |ni| {
            const node = tab.nodes[ni];
            if (node.tag == .leaf and node.pane_id == pane_id) {
                const title = tab.getTitle() orelse return "";
                const n = @min(title.len, buf.len);
                @memcpy(buf[0..n], title[0..n]);
                return buf[0..n];
            }
        }
    }
    return "";
}

fn tabFocusedPane(tab: *const layout_codec.TabLayout) u32 {
    if (tab.focused_idx >= tab.node_count) return 0;
    const node = tab.nodes[tab.focused_idx];
    return if (node.tag == .leaf) node.pane_id else 0;
}
