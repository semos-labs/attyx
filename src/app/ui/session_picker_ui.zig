/// Session picker UI integration — wires the overlay-based session picker
/// state machine to the daemon client and overlay manager.
const std = @import("std");
const posix = std.posix;
const logging = @import("../../logging/log.zig");


const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const c = terminal.c;
const publish = @import("publish.zig");
const input = @import("input.zig");
const session_actions = @import("session_actions.zig");
const actions = @import("actions.zig");
const statusbar = @import("../statusbar.zig");

const attyx = @import("attyx");
const picker_state_mod = attyx.overlay_session_picker;
const SessionPickerState = picker_state_mod.SessionPickerState;
const picker_panel = attyx.overlay_session_picker_panel;

var g_picker_state: ?SessionPickerState = null;

pub fn openSessionPicker(ctx: *PtyThreadCtx) void {
    // Close existing popup if any
    if (ctx.popup_state != null) actions.closePopup(ctx);

    // Fetch session list via session client
    const sc = ctx.session_client orelse return;
    sc.requestListSync(2000) catch return;

    // Initialize state
    var state = SessionPickerState{};
    const count = sc.pending_list_count;

    for (0..count) |i| {
        const le = &sc.pending_list[i];
        state.entries[i] = .{
            .id = le.id,
            .name_len = le.name_len,
            .alive = le.alive,
        };
        @memcpy(state.entries[i].name[0..le.name_len], le.name[0..le.name_len]);
    }

    // Compute visible rows from grid
    const panel_h = @as(u16, @intCast(@max(3, ctx.grid_rows))) / 2;
    const visible = if (panel_h > 5) @as(u8, @intCast(panel_h - 5)) else 3;

    state.entry_count = count;
    state.current_session_id = if (sc.attached_session_id) |sid| sid else null;
    state.visible_rows = visible;
    state.applyFilter();

    // Pre-select first non-current alive session
    var found_preselect = false;
    for (0..state.filtered_count) |i| {
        const e = &state.entries[state.filtered_indices[i]];
        if (e.alive and (state.current_session_id == null or e.id != state.current_session_id.?)) {
            state.selected = @intCast(i);
            found_preselect = true;
            break;
        }
    }
    if (!found_preselect) state.selected = 0;
    state.adjustScroll();

    g_picker_state = state;
    @atomicStore(i32, &terminal.g_session_picker_active, 1, .seq_cst);

    renderAndPublish(ctx);
    logging.info("session-picker", "opened overlay picker", .{});
}

/// Drain picker input rings and process actions. Returns true if any input consumed.
pub fn consumePickerInput(ctx: *PtyThreadCtx) bool {
    var state = &(g_picker_state orelse return false);
    var consumed = false;

    // Drain char ring
    while (true) {
        const r = @atomicLoad(u32, &input.g_picker_char_read, .seq_cst);
        const w = @atomicLoad(u32, &input.g_picker_char_write, .seq_cst);
        if (r == w) break;
        const cp = input.g_picker_char_ring[r % 32];
        @atomicStore(u32, &input.g_picker_char_read, r +% 1, .seq_cst);
        consumed = true;

        const action = state.handleChar(cp);
        if (processAction(ctx, state, action)) return true;
    }

    // Drain cmd ring
    while (true) {
        const r = @atomicLoad(u32, &input.g_picker_cmd_read, .seq_cst);
        const w = @atomicLoad(u32, &input.g_picker_cmd_write, .seq_cst);
        if (r == w) break;
        const cmd = input.g_picker_cmd_ring[r % 16];
        @atomicStore(u32, &input.g_picker_cmd_read, r +% 1, .seq_cst);
        consumed = true;

        const action = state.handleCmd(cmd);
        if (processAction(ctx, state, action)) return true;
    }

    if (consumed) renderAndPublish(ctx);
    return consumed;
}

/// Process a PickerAction returned by the state machine.
/// Returns true if the picker was closed (caller should stop processing).
fn processAction(ctx: *PtyThreadCtx, state: *SessionPickerState, action: picker_state_mod.PickerAction) bool {
    switch (action) {
        .none => return false,
        .close => {
            closeSessionPicker(ctx);
            return true;
        },
        .switch_session => |id| {
            closeSessionPicker(ctx);
            session_actions.doSessionSwitch(ctx, id);
            return true;
        },
        .create_session => {
            closeSessionPicker(ctx);
            var osc7_buf: [statusbar.max_output_len]u8 = undefined;
            const resolved = actions.resolveFocusedCwd(ctx, &osc7_buf);
            defer if (resolved.owned) if (resolved.cwd) |cwd| ctx.allocator.free(cwd);
            session_actions.doSessionCreate(ctx, resolved.cwd orelse "/tmp");
            return true;
        },
        .kill_session => |id| {
            const sc = ctx.session_client orelse return false;
            sc.killSession(id) catch {};
            // Re-fetch list and update state
            refreshList(ctx, state);
            renderAndPublish(ctx);
            return false;
        },
        .rename_session => |rs| {
            const sc = ctx.session_client orelse return false;
            sc.renameSession(rs.id, rs.name) catch {};
            // Re-fetch list and update state
            refreshList(ctx, state);
            renderAndPublish(ctx);
            return false;
        },
    }
}

/// Re-fetch session list and update the picker state.
fn refreshList(ctx: *PtyThreadCtx, state: *SessionPickerState) void {
    const sc = ctx.session_client orelse return;
    // Small delay for daemon to process the kill/rename
    var no_fds = [0]posix.pollfd{};
    _ = posix.poll(&no_fds, 50) catch {};
    sc.requestListSync(2000) catch return;
    const count = sc.pending_list_count;
    for (0..count) |i| {
        const le = &sc.pending_list[i];
        state.entries[i] = .{
            .id = le.id,
            .name_len = le.name_len,
            .alive = le.alive,
        };
        @memcpy(state.entries[i].name[0..le.name_len], le.name[0..le.name_len]);
    }
    state.entry_count = count;
    state.applyFilter();
    const total = state.totalCount();
    if (state.selected >= total) {
        state.selected = if (state.filtered_count > 0) state.filtered_count - 1 else 0;
    }
    state.adjustScroll();
}

pub fn closeSessionPicker(ctx: *PtyThreadCtx) void {
    g_picker_state = null;
    @atomicStore(i32, &terminal.g_session_picker_active, 0, .seq_cst);
    if (ctx.overlay_mgr) |mgr| mgr.hide(.session_picker);
    publish.publishOverlays(ctx);
    logging.info("session-picker", "closed overlay picker", .{});
}

/// Re-render the session picker at the current grid size without publishing.
/// Called from handleResize so the panel re-centers after window size changes.
pub fn relayout(ctx: *PtyThreadCtx) void {
    const state = &(g_picker_state orelse return);
    const mgr = ctx.overlay_mgr orelse return;

    // Recompute visible rows from new grid size
    const panel_h = @as(u16, @intCast(@max(3, ctx.grid_rows))) / 2;
    state.visible_rows = if (panel_h > 5) @as(u8, @intCast(panel_h - 5)) else 3;
    state.adjustScroll();

    const overlay_mod = @import("attyx").overlay_mod;

    const icons = picker_panel.Icons{
        .filter = ctx.session_icon_filter,
        .session = ctx.session_icon_session,
        .new = ctx.session_icon_new,
        .active = ctx.session_icon_active,
    };

    const result = picker_panel.renderSessionPicker(
        ctx.allocator,
        state,
        ctx.grid_cols,
        ctx.grid_rows,
        icons,
    ) catch return;

    if (result.width == 0 or result.height == 0) return;

    mgr.setContent(
        .session_picker,
        result.col,
        result.row,
        result.width,
        result.height,
        result.cells,
    ) catch {};
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.session_picker)].backdrop_alpha = 100;
    ctx.allocator.free(result.cells);
}

fn renderAndPublish(ctx: *PtyThreadCtx) void {
    const state = &(g_picker_state orelse return);
    const mgr = ctx.overlay_mgr orelse return;

    const icons = picker_panel.Icons{
        .filter = ctx.session_icon_filter,
        .session = ctx.session_icon_session,
        .new = ctx.session_icon_new,
        .active = ctx.session_icon_active,
    };

    const result = picker_panel.renderSessionPicker(
        ctx.allocator,
        state,
        ctx.grid_cols,
        ctx.grid_rows,
        icons,
    ) catch return;

    if (result.width == 0 or result.height == 0) return;

    mgr.setContent(
        .session_picker,
        result.col,
        result.row,
        result.width,
        result.height,
        result.cells,
    ) catch {};
    mgr.show(.session_picker);
    mgr.layers[@intFromEnum(@import("attyx").overlay_mod.OverlayId.session_picker)].backdrop_alpha = 100;
    ctx.allocator.free(result.cells);

    publish.publishOverlays(ctx);
}
