/// Session picker lifecycle — session switching, creation, and killing.
const std = @import("std");
const logging = @import("../../logging/log.zig");
const split_layout_mod = @import("../split_layout.zig");
const layout_codec = @import("../layout_codec.zig");
const SessionClient = @import("../session_client.zig").SessionClient;
const TabManager = @import("../tab_manager.zig").TabManager;
const Pane = @import("../pane.zig").Pane;
const session_connect = @import("../session_connect.zig");

const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const c = terminal.c;
const publish = @import("publish.zig");
const actions = @import("actions.zig");
const session_grid_prime = @import("session_grid_prime.zig");
const statusbar = @import("../statusbar.zig");

// ---------------------------------------------------------------------------
// Layout persistence
// ---------------------------------------------------------------------------

/// Persist the current tab/split layout to the daemon.
pub fn saveSessionLayout(ctx: *PtyThreadCtx) void {
    const sc = ctx.session_client orelse return;
    var buf: [4096]u8 = undefined;
    const len = ctx.tab_mgr.serializeLayout(&buf) catch return;
    if (len > 0) {
        sc.sendSaveLayout(buf[0..len]) catch {};
    }
}

// ---------------------------------------------------------------------------
// Focus pane management
// ---------------------------------------------------------------------------

/// Send focus_panes for all daemon-backed panes in the active tab.
/// Reinitializes engines for panes that weren't in the previous focus set,
/// since the daemon will replay their scrollback into the engine.
/// Tell the daemon which panes we want pane_output messages for.  We claim
/// ALL daemon-backed panes across ALL tabs as "active" so the daemon keeps
/// streaming output to us continuously, including for panes the user can't
/// currently see.  The cost is a little extra socket bandwidth for inactive
/// panes; the win is huge: tab switches don't need a focus_panes round-trip
/// or a scrollback replay because every pane's engine is already up-to-date.
///
/// The pane set only changes when the user creates or closes panes/tabs, so
/// most calls are no-ops (we de-dup against the previous set).  Replay still
/// fires for genuinely new panes (first time the daemon sees them in our
/// active set) — which is correct, since those engines really are blank.
pub fn sendActiveFocusPanes(ctx: *PtyThreadCtx) void {
    const sc = ctx.session_client orelse return;
    var pane_ids: [split_layout_mod.max_panes * @import("../tab_manager.zig").max_tabs]u32 = undefined;
    var count: usize = 0;

    // Collect daemon-backed panes from every tab (not just the active one).
    for (ctx.tab_mgr.tabs[0..ctx.tab_mgr.count]) |*maybe_layout| {
        if (maybe_layout.*) |*lay| {
            var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
            const lc = lay.collectLeaves(&leaves);
            for (leaves[0..lc]) |leaf| {
                if (leaf.pane.daemon_pane_id) |dpid| {
                    if (count >= pane_ids.len) break;
                    pane_ids[count] = dpid;
                    count += 1;

                    // Arm shadow-replay routing only for the legacy byte-replay
                    // path. Grid-sync sends authoritative cell snapshots, not
                    // replay_end, so setting needs_engine_reinit there strands
                    // future updates in a shadow engine and can leave tabs blank.
                    if (!sc.hasGridSync()) {
                        var was_focused = false;
                        for (ctx.last_focus_panes[0..ctx.last_focus_count]) |old_id| {
                            if (old_id == dpid) {
                                was_focused = true;
                                break;
                            }
                        }
                        if (!was_focused) {
                            if (leaf.pane.shadow_engine) |*s| {
                                s.deinit();
                                leaf.pane.shadow_engine = null;
                            }
                            leaf.pane.needs_engine_reinit = true;
                        }
                    }
                }
            }
        }
    }

    // Skip the IPC round-trip entirely if the pane set hasn't changed.
    var same_set = (count == ctx.last_focus_count);
    if (same_set) {
        outer: for (pane_ids[0..count]) |new_id| {
            for (ctx.last_focus_panes[0..ctx.last_focus_count]) |old_id| {
                if (new_id == old_id) continue :outer;
            }
            same_set = false;
            break;
        }
    }
    if (same_set) return;

    // Pane set changed — update tracking and tell the daemon.
    for (0..count) |i| {
        ctx.last_focus_panes[i] = pane_ids[i];
    }
    ctx.last_focus_count = @intCast(count);

    if (count > 0) {
        sc.sendFocusPanes(pane_ids[0..count]) catch {};
    }
}

/// Grid-sync recovery path for tab/session switches: make the daemon treat the
/// active tab as newly focused so it sends an authoritative grid snapshot even
/// if the pane was already in the warm all-panes focus set.
pub fn forceActiveTabGridSnapshot(ctx: *PtyThreadCtx) void {
    const sc = ctx.session_client orelse return;
    if (!sc.hasGridSync() or ctx.tab_mgr.count == 0) {
        sendActiveFocusPanes(ctx);
        return;
    }

    var pane_ids: [split_layout_mod.max_panes * @import("../tab_manager.zig").max_tabs]u32 = undefined;
    var count: usize = 0;

    const active_layout = ctx.tab_mgr.activeLayout();
    var active_leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
    const active_lc = active_layout.collectLeaves(&active_leaves);
    for (active_leaves[0..active_lc]) |leaf| {
        if (leaf.pane.daemon_pane_id) |dpid| {
            pane_ids[count] = dpid;
            count += 1;
        }
    }
    if (count == 0) return;

    // Keep every pane warm, but move the active tab's panes to the front. The
    // daemon treats changed slots as needing a fresh snapshot, without the old
    // clear-then-refocus dance that briefly left no panes active and flickered.
    for (ctx.tab_mgr.tabs[0..ctx.tab_mgr.count]) |*maybe_layout| {
        if (maybe_layout.*) |*lay| {
            var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
            const lc = lay.collectLeaves(&leaves);
            for (leaves[0..lc]) |leaf| {
                const dpid = leaf.pane.daemon_pane_id orelse continue;
                var already_added = false;
                for (pane_ids[0..count]) |existing| {
                    if (existing == dpid) {
                        already_added = true;
                        break;
                    }
                }
                if (!already_added and count < pane_ids.len) {
                    pane_ids[count] = dpid;
                    count += 1;
                }
            }
        }
    }

    for (0..count) |i| ctx.last_focus_panes[i] = pane_ids[i];
    ctx.last_focus_count = @intCast(count);
    sc.sendFocusPanes(pane_ids[0..count]) catch {};
}

fn synthesizeTabsFromAttachedPanes(
    mgr: *TabManager,
    pane_ids: []const u32,
    rows: u16,
    cols: u16,
    scrollback_lines: usize,
) bool {
    mgr.reset();
    mgr.active = 0;
    var tab_count: u8 = 0;
    for (pane_ids) |pane_id| {
        if (tab_count >= @import("../tab_manager.zig").max_tabs) break;
        const pane = mgr.allocator.create(Pane) catch return tab_count > 0;
        pane.* = Pane.initDaemonBacked(mgr.allocator, rows, cols, scrollback_lines) catch {
            mgr.allocator.destroy(pane);
            return tab_count > 0;
        };
        pane.daemon_pane_id = pane_id;
        mgr.assignIpcId(pane);
        mgr.tabs[tab_count] = split_layout_mod.SplitLayout.init(pane);
        tab_count += 1;
    }
    mgr.count = tab_count;
    return tab_count > 0;
}

fn attachPaneSlice(pane_ids: *const [32]u32, pane_count: u8) []const u32 {
    return pane_ids[0..@as(usize, pane_count)];
}

pub fn doSessionSwitch(ctx: *PtyThreadCtx, session_id: u32) void {
    const sc = ctx.session_client orelse return;
    const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
    const pty_cols: u16 = @intCast(@max(1, @as(i32, ctx.grid_cols) - terminal.g_grid_left_offset - terminal.g_grid_right_offset));

    if (sc.attached_session_id) |current| {
        if (current == session_id) return;
    }

    saveSessionLayout(ctx);

    // Attach first, but keep the old tab manager/rendered frame alive until the
    // replacement manager has been reconstructed and hydrated from daemon grid
    // snapshots. This is the key difference from the old destructive switch:
    // no blank client-side placeholder engine ever becomes the active renderer.
    sc.attach(session_id, pty_rows, pty_cols) catch return;
    const attach_result = sc.waitForAttach(3000) catch return;
    const attached_panes = attachPaneSlice(&attach_result.pane_ids, attach_result.pane_count);

    var next_mgr = TabManager{
        .allocator = ctx.tab_mgr.allocator,
        .split_gap_h = ctx.tab_mgr.split_gap_h,
        .split_gap_v = ctx.tab_mgr.split_gap_v,
        .next_ipc_id = ctx.tab_mgr.next_ipc_id,
    };
    var repaired_layout = false;

    if (sc.layout_len > 0) {
        if (layout_codec.deserialize(sc.layout_buf[0..sc.layout_len])) |info| {
            if (layout_codec.paneSetMatches(&info, attached_panes)) {
                next_mgr.reconstructFromLayout(&info, pty_rows, pty_cols, ctx.applied_scrollback_lines) catch {
                    repaired_layout = synthesizeTabsFromAttachedPanes(&next_mgr, attached_panes, pty_rows, pty_cols, ctx.applied_scrollback_lines);
                };
            } else {
                logging.warn("session-picker", "discarding stale layout for session {d}: layout pane set does not match {d} live panes", .{ session_id, attach_result.pane_count });
                repaired_layout = synthesizeTabsFromAttachedPanes(&next_mgr, attached_panes, pty_rows, pty_cols, ctx.applied_scrollback_lines);
            }
        } else |_| {
            repaired_layout = synthesizeTabsFromAttachedPanes(&next_mgr, attached_panes, pty_rows, pty_cols, ctx.applied_scrollback_lines);
        }
    }
    if (next_mgr.count == 0 and attached_panes.len > 0) {
        repaired_layout = synthesizeTabsFromAttachedPanes(&next_mgr, attached_panes, pty_rows, pty_cols, ctx.applied_scrollback_lines);
    }
    if (next_mgr.count == 0) return;

    // Compute rects and resize daemon PTYs before the first snapshot request so
    // daemon/client dimensions agree for the initial frame.
    for (next_mgr.tabs[0..next_mgr.count]) |*maybe_layout| {
        if (maybe_layout.*) |*lay| {
            lay.layout(pty_rows, pty_cols);
            var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
            const lc = lay.collectLeaves(&leaves);
            for (leaves[0..lc]) |leaf| {
                if (leaf.pane.daemon_pane_id) |dpid| {
                    sc.sendPaneResize(dpid, leaf.rect.rows, leaf.rect.cols) catch {};
                }
            }
        }
    }

    // Ask the daemon for the new session's active tab, then synchronously drain
    // its first real frame into next_mgr while the old manager remains visible.
    var active_ids: [split_layout_mod.max_panes]u32 = undefined;
    const active_count = session_grid_prime.activePaneIds(&next_mgr, &active_ids);
    if (active_count > 0) sc.sendFocusPanes(active_ids[0..active_count]) catch {};
    session_grid_prime.primeManager(ctx, &next_mgr, 1200);

    ctx.tab_mgr.reset();
    ctx.tab_mgr.* = next_mgr;
    ctx.last_focus_count = 0;

    const ap = ctx.tab_mgr.activePane();
    terminal.g_engine = &ap.engine;
    terminal.g_pty_master = ap.pty.master;
    terminal.g_active_daemon_pane_id = ap.daemon_pane_id orelse 0;

    actions.switchActiveTab(ctx);
    if (repaired_layout) saveSessionLayout(ctx);

    if (ctx.statusbar) |sb| sb.resetWidgets();
    publish.generateTabBar(ctx);
    publish.generateStatusbar(ctx);
    publish.publishOverlays(ctx);

    session_connect.saveLastSession(session_id);
    logging.info("session-picker", "switched to session {d}", .{session_id});
}

/// Move the active tab (and all its split panes) to another session, then
/// switch to that session and land on the moved tab. The panes keep running —
/// the daemon transfers them live rather than killing and respawning.
pub fn doMoveActiveTabToSession(ctx: *PtyThreadCtx, dest_session_id: u32) void {
    const sc = ctx.session_client orelse return;
    if (ctx.tab_mgr.count == 0) return;
    if (sc.attached_session_id) |current| {
        if (current == dest_session_id) return; // can't move to the same session
    }

    // Serialize the active tab's split tree into a one-tab blob for the daemon.
    var tab_buf: [4096]u8 = undefined;
    const tab_len = ctx.tab_mgr.serializeActiveTab(&tab_buf) catch return;
    if (tab_len == 0) return;

    // Collect the active tab's daemon-backed pane IDs.
    var pane_ids: [split_layout_mod.max_panes]u32 = undefined;
    var pane_count: u8 = 0;
    if (ctx.tab_mgr.tabs[ctx.tab_mgr.active]) |*lay| {
        var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
        const lc = lay.collectLeaves(&leaves);
        for (leaves[0..lc]) |leaf| {
            if (leaf.pane.daemon_pane_id) |dpid| {
                pane_ids[pane_count] = dpid;
                pane_count += 1;
            }
        }
    }
    if (pane_count == 0) return;

    // Hand the live panes + the tab layout to the daemon and wait for it to
    // confirm. We only mutate local state on success, so a rejection (e.g. the
    // destination is at its tab/pane cap) leaves the tab exactly where it is
    // rather than orphaning the running processes.
    sc.sendMovePanes(dest_session_id, pane_ids[0..pane_count], tab_buf[0..tab_len]) catch return;
    if (!sc.waitForMoveResult(5000)) {
        logging.info("session-picker", "move to session {d} rejected", .{dest_session_id});
        return;
    }

    // Drop the tab locally WITHOUT a close_pane round-trip — the daemon now
    // owns those panes in the destination session, so closing them would kill
    // the very processes we just moved.
    ctx.tab_mgr.closeTab(ctx.tab_mgr.active);

    // Switch to the destination. doSessionSwitch saves the (now tab-less)
    // source layout, attaches the destination, and reconstructs from its
    // layout — which the daemon just made end on the moved tab.
    doSessionSwitch(ctx, dest_session_id);
    logging.info("session-picker", "moved tab to session {d}", .{dest_session_id});
}

pub fn doSessionCreate(ctx: *PtyThreadCtx, cwd: []const u8) void {
    const sc = ctx.session_client orelse return;
    const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
    const pty_cols: u16 = @intCast(@max(1, @as(i32, ctx.grid_cols) - terminal.g_grid_left_offset - terminal.g_grid_right_offset));
    const name = if (std.mem.lastIndexOfScalar(u8, cwd, '/')) |i|
        if (i + 1 < cwd.len) cwd[i + 1 ..] else cwd
    else
        cwd;
    const session_name = if (name.len > 0) name else "shell";
    // Use xyron with --ipc if detected, otherwise default shell.
    var xyron_buf: [4200]u8 = undefined;
    const shell: []const u8 = if (ctx.xyron_path) |xp|
        std.fmt.bufPrint(&xyron_buf, "{s} --ipc", .{xp}) catch @as([]const u8, xp)
    else
        "";
    const new_id = sc.createSession(session_name, pty_rows, pty_cols, cwd, shell) catch |err| {
        logging.err("session-picker", "create failed: {}", .{err});
        return;
    };
    // Log before switching: doSessionSwitch re-attaches and can invalidate the
    // buffer `cwd` aliases (e.g. a pane's daemon fg_cwd), so reading it after
    // the switch is a use-after-free.
    logging.info("session-picker", "created session {d} in {s}", .{ new_id, cwd });
    doSessionSwitch(ctx, new_id);
}

/// Create a new session directly (from keybind, without picker).
pub fn createSessionDirect(ctx: *PtyThreadCtx) void {
    var osc7_buf: [statusbar.max_output_len]u8 = undefined;
    const resolved = actions.resolveFocusedCwd(ctx, &osc7_buf);
    defer if (resolved.owned) if (resolved.cwd) |cwd| ctx.allocator.free(cwd);
    doSessionCreate(ctx, resolved.cwd orelse "/tmp");
}

/// Try to switch to another alive session. Returns true if switched, false if
/// no other sessions exist (caller should quit).
pub fn switchToNextSession(ctx: *PtyThreadCtx) bool {
    const sc = ctx.session_client orelse return false;
    const current_id = sc.attached_session_id orelse return false;
    sc.requestListSync(2000) catch return false;
    for (sc.pending_list[0..sc.pending_list_count]) |entry| {
        if (entry.alive and entry.id != current_id) {
            doSessionSwitch(ctx, entry.id);
            if (ctx.tab_mgr.count > 0) return true;
            // Switch failed (attach error), try next session
        }
    }
    return false;
}

/// Handle layout_sync broadcast from daemon (another window changed tabs/splits).
pub fn handleLayoutSync(ctx: *PtyThreadCtx, layout_data: []const u8) void {
    if (layout_data.len == 0) return;
    const info = layout_codec.deserialize(layout_data) catch return;

    const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
    const pty_cols: u16 = @intCast(@max(1, @as(i32, ctx.grid_cols) - terminal.g_grid_left_offset - terminal.g_grid_right_offset));

    ctx.tab_mgr.syncFromLayout(&info, pty_rows, pty_cols, ctx.applied_scrollback_lines) catch return;

    if (ctx.tab_mgr.count == 0) {
        c.attyx_request_quit();
        return;
    }

    // Resize daemon PTYs to match each pane's layout dimensions
    if (ctx.session_client) |sc| {
        for (ctx.tab_mgr.tabs[0..ctx.tab_mgr.count]) |*maybe_layout| {
            if (maybe_layout.*) |*lay| {
                var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
                const lc = lay.collectLeaves(&leaves);
                for (leaves[0..lc]) |leaf| {
                    if (leaf.pane.daemon_pane_id) |dpid|
                        sc.sendPaneResize(dpid, leaf.rect.rows, leaf.rect.cols) catch {};
                }
            }
        }
    }

    // Update globals and focus
    const ap = ctx.tab_mgr.activePane();
    terminal.g_engine = &ap.engine;
    terminal.g_pty_master = ap.pty.master;
    terminal.g_active_daemon_pane_id = ap.daemon_pane_id orelse 0;

    ctx.last_focus_count = 0;
    actions.switchActiveTab(ctx);

    actions.g_force_full_redraw = true;
    c.attyx_mark_all_dirty();
    // Reset cached widget state; next periodic tick refreshes (avoids the
    // 50–70ms synchronous git/cwd fork/exec on this code path too).
    if (ctx.statusbar) |sb| {
        sb.resetWidgets();
    }
    publish.generateTabBar(ctx);
    publish.generateStatusbar(ctx);
    publish.publishOverlays(ctx);

    logging.info("layout-sync", "synced layout from another window", .{});
}

/// Switch to the hidden "default" session, creating it if needed.
pub fn doSwitchToDefault(ctx: *PtyThreadCtx) void {
    const sc = ctx.session_client orelse return;

    // Look for an existing alive "default" session.
    sc.requestListSync(2000) catch return;
    for (sc.pending_list[0..sc.pending_list_count]) |entry| {
        if (entry.alive and std.mem.eql(u8, entry.getName(), "default")) {
            doSessionSwitch(ctx, entry.id);
            return;
        }
    }

    // No alive "default" session — create one and rename it.
    const home = std.posix.getenv("HOME") orelse "/tmp";
    doSessionCreate(ctx, home);
    if (sc.attached_session_id) |sid| {
        sc.renameSession(sid, "default") catch {};
    }
}

pub fn doSessionKill(ctx: *PtyThreadCtx, session_id: u32) void {
    const sc = ctx.session_client orelse return;
    sc.killSession(session_id) catch |err| {
        logging.err("session-picker", "kill failed: {}", .{err});
        return;
    };

    // If we killed the current session, switch to another
    if (sc.attached_session_id) |current| {
        if (current == session_id) {
            // Request list to find another session
            sc.requestListSync(2000) catch return;
            for (sc.pending_list[0..sc.pending_list_count]) |entry| {
                if (entry.alive and entry.id != session_id) {
                    doSessionSwitch(ctx, entry.id);
                    return;
                }
            }
        }
    }
    logging.info("session-picker", "killed session {d}", .{session_id});
}
