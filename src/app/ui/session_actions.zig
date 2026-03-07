/// Session picker lifecycle — session switching, creation, and killing.
const std = @import("std");
const logging = @import("../../logging/log.zig");
const split_layout_mod = @import("../split_layout.zig");
const layout_codec = @import("../layout_codec.zig");
const SessionClient = @import("../session_client.zig").SessionClient;
const session_connect = @import("../session_connect.zig");

const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const c = terminal.c;
const publish = @import("publish.zig");
const actions = @import("actions.zig");
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
pub fn sendActiveFocusPanes(ctx: *PtyThreadCtx) void {
    const sc = ctx.session_client orelse return;
    const layout = ctx.tab_mgr.activeLayout();
    var pane_ids: [split_layout_mod.max_panes]u32 = undefined;
    var count: usize = 0;
    var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
    const lc = layout.collectLeaves(&leaves);
    for (leaves[0..lc]) |leaf| {
        if (leaf.pane.daemon_pane_id) |dpid| {
            pane_ids[count] = dpid;
            count += 1;

            // If this pane wasn't in the previous focus set, the daemon will
            // replay its scrollback. Reinit the engine so replay doesn't
            // stack on top of stale content from a prior focus cycle.
            var was_focused = false;
            for (ctx.last_focus_panes[0..ctx.last_focus_count]) |old_id| {
                if (old_id == dpid) {
                    was_focused = true;
                    break;
                }
            }
            if (!was_focused) {
                // Defer the engine reinit until the first replay byte
                // arrives (handled in event_loop.zig). This keeps the
                // old engine content visible during the tab switch,
                // avoiding a blank flash before the daemon replay
                // populates the altscreen/content.
                leaf.pane.needs_engine_reinit = true;
            }
        }
    }

    // Update tracking
    for (0..count) |i| {
        ctx.last_focus_panes[i] = pane_ids[i];
    }
    ctx.last_focus_count = @intCast(count);

    if (count > 0) {
        sc.sendFocusPanes(pane_ids[0..count]) catch {};
    }
}

pub fn doSessionSwitch(ctx: *PtyThreadCtx, session_id: u32) void {
    const sc = ctx.session_client orelse return;
    const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));

    // Skip if already attached to this session
    if (sc.attached_session_id) |current| {
        if (current == session_id) return;
    }

    // Save current layout
    saveSessionLayout(ctx);

    // Detach from current session
    sc.detach() catch {};

    // Teardown current tabs
    ctx.tab_mgr.reset();
    terminal.g_engine = null;
    terminal.g_pty_master = -1;

    // Attach to new session
    sc.attach(session_id, pty_rows, ctx.grid_cols) catch return;
    const attach_result = sc.waitForAttach(3000) catch return;

    // Reconstruct tabs from layout blob
    if (sc.layout_len > 0) {
        if (layout_codec.deserialize(sc.layout_buf[0..sc.layout_len])) |info| {
            ctx.tab_mgr.reconstructFromLayout(&info, pty_rows, ctx.grid_cols, ctx.applied_scrollback_lines) catch {};
        } else |_| {}
    }

    // Fallback: single-pane tab
    if (ctx.tab_mgr.count == 0 and attach_result.pane_count > 0) {
        const Pane = @import("../pane.zig").Pane;
        const pane = ctx.tab_mgr.allocator.create(Pane) catch return;
        pane.* = Pane.initDaemonBacked(ctx.tab_mgr.allocator, pty_rows, ctx.grid_cols, ctx.applied_scrollback_lines) catch {
            ctx.tab_mgr.allocator.destroy(pane);
            return;
        };
        pane.daemon_pane_id = attach_result.pane_ids[0];
        ctx.tab_mgr.tabs[0] = split_layout_mod.SplitLayout.init(pane);
        ctx.tab_mgr.count = 1;
        ctx.tab_mgr.active = 0;
    }

    // Update globals
    if (ctx.tab_mgr.count > 0) {
        const ap = ctx.tab_mgr.activePane();
        terminal.g_engine = &ap.engine;
        terminal.g_pty_master = ap.pty.master;
        terminal.g_active_daemon_pane_id = ap.daemon_pane_id orelse 0;
    }

    // Compute rects and resize daemon PTYs to match each pane's dimensions.
    if (ctx.tab_mgr.count > 0) {
        for (ctx.tab_mgr.tabs[0..ctx.tab_mgr.count]) |*maybe_layout| {
            if (maybe_layout.*) |*lay| {
                lay.layout(pty_rows, ctx.grid_cols);
                var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
                const lc = lay.collectLeaves(&leaves);
                for (leaves[0..lc]) |leaf| {
                    if (leaf.pane.daemon_pane_id) |dpid| {
                        sc.sendPaneResize(dpid, leaf.rect.rows, leaf.rect.cols) catch {};
                    }
                }
            }
        }
    }

    if (ctx.tab_mgr.count == 0) return;

    ctx.last_focus_count = 0;
    actions.switchActiveTab(ctx);

    // Force full redraw so the new session's content appears immediately.
    actions.g_force_full_redraw = true;
    c.attyx_mark_all_dirty();
    // Reset cached cwd pointers so tick detects the new pane's cwd and
    // refreshes immediately — avoids a flash of stale/empty widgets.
    if (ctx.statusbar) |sb| {
        sb.resetWidgets();
        if (sb.config.enabled) {
            _ = sb.tick(std.time.timestamp(), publish.ctxPty(ctx).master, publish.ctxEngine(ctx).state.working_directory);
        }
    }
    publish.generateTabBar(ctx);
    publish.generateStatusbar(ctx);
    publish.publishOverlays(ctx);

    session_connect.saveLastSession(session_id);
    logging.info("session-picker", "switched to session {d}", .{session_id});
}

pub fn doSessionCreate(ctx: *PtyThreadCtx, cwd: []const u8) void {
    const sc = ctx.session_client orelse return;
    const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
    const name = if (std.mem.lastIndexOfScalar(u8, cwd, '/')) |i|
        if (i + 1 < cwd.len) cwd[i + 1 ..] else cwd
    else
        cwd;
    const session_name = if (name.len > 0) name else "shell";
    const new_id = sc.createSession(session_name, pty_rows, ctx.grid_cols, cwd, "") catch |err| {
        logging.err("session-picker", "create failed: {}", .{err});
        return;
    };
    doSessionSwitch(ctx, new_id);
    logging.info("session-picker", "created session {d} in {s}", .{ new_id, cwd });
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

    ctx.tab_mgr.syncFromLayout(&info, pty_rows, ctx.grid_cols, ctx.applied_scrollback_lines) catch return;

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
    if (ctx.statusbar) |sb| {
        sb.resetWidgets();
        if (sb.config.enabled) {
            _ = sb.tick(std.time.timestamp(), publish.ctxPty(ctx).master, publish.ctxEngine(ctx).state.working_directory);
        }
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
