/// Session picker lifecycle — popup-based session switching, creation, and killing.
const std = @import("std");
const logging = @import("../../logging/log.zig");
const popup_mod = @import("../popup.zig");
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

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn setenvSlice(allocator: std.mem.Allocator, name: [*:0]const u8, value: []const u8) void {
    const z = allocator.dupeZ(u8, value) catch return;
    defer allocator.free(z);
    _ = setenv(name, z, 1);
}

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
                leaf.pane.needs_engine_reinit = true;
                leaf.pane.suppress_responses = true;
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

// ---------------------------------------------------------------------------
// Session picker (popup-based)
// ---------------------------------------------------------------------------

/// Spawn the session picker popup via `attyx _session-picker`.
pub fn spawnSessionPicker(ctx: *PtyThreadCtx) void {
    // Close existing popup if any
    if (ctx.popup_state != null) actions.closePopup(ctx);

    // Resolve attyx executable path
    var exe_buf: [1024]u8 = undefined;
    const exe_path = session_connect.getExePath(&exe_buf) orelse "attyx";

    // Build command: "<exe> _session-picker"
    var cmd_buf: [1100]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "{s} _session-picker", .{exe_path}) catch return;

    const cfg = popup_mod.PopupConfig{
        .command = cmd,
        .width_pct = 50,
        .height_pct = 50,
        .border_style = .rounded,
        .border_fg = .{ 80, 80, 120 },
        .capture_stdout = true,
        .direct_exec = true,
        .pad = .{ .top = 0, .bottom = 0, .left = 1, .right = 1 },
        .bg_color = .{ 20, 20, 30 },
        .bg_opacity = 230,
    };

    const grid_cols: u16 = ctx.grid_cols;
    const grid_rows: u16 = ctx.grid_rows;
    var osc7_buf: [statusbar.max_output_len]u8 = undefined;
    const resolved = actions.resolveFocusedCwd(ctx, &osc7_buf);
    defer if (resolved.owned) if (resolved.cwd) |cwd| ctx.allocator.free(cwd);

    var ps = ctx.allocator.create(popup_mod.PopupState) catch return;

    // Set env vars for the picker before spawn
    // ATTYX_SESSION_ID tells the picker which session is current
    if (ctx.session_client) |sc| {
        if (sc.attached_session_id) |sid| {
            var sid_buf: [16]u8 = undefined;
            const sid_str = std.fmt.bufPrint(&sid_buf, "{d}", .{sid}) catch "";
            if (sid_str.len > 0) {
                const sid_z = ctx.allocator.dupeZ(u8, sid_str) catch null;
                if (sid_z) |z| {
                    defer ctx.allocator.free(z);
                    _ = setenv("ATTYX_SESSION_ID", z, 1);
                }
            }
        }
    }
    // ATTYX_PICKER_CWD tells the picker what CWD to use for "create"
    if (resolved.cwd) |cwd| {
        const cwd_z = ctx.allocator.dupeZ(u8, cwd) catch null;
        if (cwd_z) |z| {
            defer ctx.allocator.free(z);
            _ = setenv("ATTYX_PICKER_CWD", z, 1);
        }
    }

    // Pass icon config to the picker subprocess
    setenvSlice(ctx.allocator, "ATTYX_ICON_FILTER", ctx.session_icon_filter);
    setenvSlice(ctx.allocator, "ATTYX_ICON_SESSION", ctx.session_icon_session);
    setenvSlice(ctx.allocator, "ATTYX_ICON_NEW", ctx.session_icon_new);
    setenvSlice(ctx.allocator, "ATTYX_ICON_ACTIVE", ctx.session_icon_active);
    setenvSlice(ctx.allocator, "ATTYX_ICON_RECENT", ctx.session_icon_recent);

    // Pass cursor config — DECSCUSR value: block=1/2, underline=3/4, bar=5/6 (odd=blink)
    {
        const base: u8 = switch (ctx.applied_cursor_shape) {
            .block => 1,
            .underline => 3,
            .beam => 5,
        };
        const decscusr = if (ctx.applied_cursor_blink) base else base + 1;
        var cbuf: [4]u8 = undefined;
        const cstr = std.fmt.bufPrint(&cbuf, "{d}", .{decscusr}) catch "1";
        setenvSlice(ctx.allocator, "ATTYX_CURSOR_STYLE", cstr);
    }

    ps.* = popup_mod.PopupState.spawn(ctx.allocator, cfg, grid_cols, grid_rows, resolved.cwd, null) catch |err| {
        logging.err("session-picker", "spawn failed: {}", .{err});
        ctx.allocator.destroy(ps);
        return;
    };
    ps.config_index = 0;
    ctx.popup_state = ps;
    ctx.session_picker_active = true;
    terminal.g_popup_pty_master = ps.pane.pty.master;
    terminal.g_popup_engine = &ps.pane.engine;
    @atomicStore(i32, @as(*i32, @ptrCast(@volatileCast(&c.g_popup_active))), 1, .seq_cst);
    ps.publishCells(&ctx.active_theme, cfg);
    ps.publishImagePlacements(cfg);
    logging.info("session-picker", "spawned", .{});
}

/// Handle the result from the session picker popup.
/// The picker prefixes output with 0x1F (Unit Separator) so we can locate it
/// even when `$SHELL -i -c '...'` shell init scripts prepend noise to stdout.
pub fn handleSessionPickerResult(ctx: *PtyThreadCtx, text: []const u8) void {
    logging.info("session-picker", "result: \"{s}\"", .{text});

    // Find the marker — everything after it is the picker's actual output.
    const cmd = if (std.mem.lastIndexOfScalar(u8, text, 0x1F)) |idx|
        text[idx + 1 ..]
    else
        text; // fallback: no marker (shouldn't happen but be safe)

    if (std.mem.startsWith(u8, cmd, "switch ")) {
        const id_str = std.mem.trimRight(u8, cmd["switch ".len..], "\r\n ");
        const id = std.fmt.parseInt(u32, id_str, 10) catch return;
        doSessionSwitch(ctx, id);
    } else if (std.mem.startsWith(u8, cmd, "create ")) {
        const cwd = std.mem.trimRight(u8, cmd["create ".len..], "\r\n ");
        doSessionCreate(ctx, cwd);
    } else if (std.mem.startsWith(u8, cmd, "kill ")) {
        const id_str = std.mem.trimRight(u8, cmd["kill ".len..], "\r\n ");
        const id = std.fmt.parseInt(u32, id_str, 10) catch return;
        doSessionKill(ctx, id);
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
    if (ctx.statusbar) |sb| sb.resetWidgets();
    publish.generateTabBar(ctx);
    publish.generateStatusbar(ctx);
    publish.publishOverlays(ctx);

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
