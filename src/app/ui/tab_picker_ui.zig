/// Tab picker UI integration — wires the overlay-based tab picker
/// state machine to the overlay manager and tab switching.
const std = @import("std");

const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const c = terminal.c;
const publish = @import("publish.zig");
const input = @import("input.zig");
const session_picker_ui = @import("session_picker_ui.zig");
const command_palette_ui = @import("command_palette_ui.zig");
const theme_picker_ui = @import("theme_picker_ui.zig");

const attyx = @import("attyx");
const picker_state_mod = attyx.overlay_tab_picker;
const TabPickerState = picker_state_mod.TabPickerState;
const TabEntry = picker_state_mod.TabEntry;
const picker_panel = attyx.overlay_tab_picker_panel;
const overlay_mod = attyx.overlay_mod;
const tab_bar_mod = @import("../tab_bar.zig");
const logging = @import("../../logging/log.zig");

var g_picker_state: ?TabPickerState = null;

pub fn openTabPicker(ctx: *PtyThreadCtx) void {
    // Close other modals
    if (terminal.g_session_picker_active != 0) session_picker_ui.closeSessionPicker(ctx);
    if (terminal.g_command_palette_active != 0) command_palette_ui.closeCommandPalette(ctx);
    if (terminal.g_theme_picker_active != 0) theme_picker_ui.closeThemePicker(ctx);

    const panel_h = @as(u16, @intCast(@max(3, ctx.grid_rows))) / 2;
    const visible = if (panel_h > 4) @as(u8, @intCast(panel_h - 4)) else 3;

    var state = TabPickerState{};
    state.visible_rows = visible;
    state.current_tab = @intCast(ctx.tab_mgr.active);

    // Populate entries from current tabs
    var titles: tab_bar_mod.TabTitles = undefined;
    var name_bufs: [tab_bar_mod.max_tabs][256]u8 = undefined;
    publish.resolveTabTitlesOnly(ctx, &titles, &name_bufs);

    const zoomed = computeZoomedTabs(ctx);

    for (0..ctx.tab_mgr.count) |i| {
        if (i >= picker_state_mod.max_tabs) break;
        var entry = TabEntry{};
        entry.index = @intCast(i);
        entry.is_zoomed = (zoomed & (@as(u16, 1) << @intCast(i))) != 0;
        const title = titles[i] orelse "shell";
        const nlen: u8 = @intCast(@min(title.len, 64));
        @memcpy(entry.name[0..nlen], title[0..nlen]);
        entry.name_len = nlen;
        state.entries[i] = entry;
    }
    state.entry_count = @intCast(ctx.tab_mgr.count);
    state.applyFilter();

    // Pre-select the current tab
    for (0..state.filtered_count) |i| {
        if (state.entries[state.filtered_indices[i]].index == state.current_tab) {
            state.selected = @intCast(i);
            state.adjustScroll();
            break;
        }
    }

    g_picker_state = state;
    @atomicStore(i32, &terminal.g_tab_picker_active, 1, .seq_cst);

    renderAndPublish(ctx);
    logging.info("tab-picker", "opened tab picker", .{});
}

fn computeZoomedTabs(ctx: *PtyThreadCtx) u16 {
    var mask: u16 = 0;
    for (0..ctx.tab_mgr.count) |i| {
        const layout = &(ctx.tab_mgr.tabs[i] orelse continue);
        if (layout.isZoomed()) mask |= @as(u16, 1) << @intCast(i);
    }
    return mask;
}

/// Drain picker input rings and process actions. Returns true if any input consumed.
pub fn consumePickerInput(ctx: *PtyThreadCtx) bool {
    var state = &(g_picker_state orelse return false);
    var consumed = false;

    // Drain char ring (shared with other pickers)
    while (true) {
        const r = @atomicLoad(u32, &input.g_picker_char_read, .seq_cst);
        const w = @atomicLoad(u32, &input.g_picker_char_write, .seq_cst);
        if (r == w) break;
        const cp = input.g_picker_char_ring[r % 32];
        @atomicStore(u32, &input.g_picker_char_read, r +% 1, .seq_cst);
        consumed = true;

        const action = state.handleChar(cp);
        if (processAction(ctx, action)) return true;
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
        if (processAction(ctx, action)) return true;
    }

    if (consumed) renderAndPublish(ctx);
    return consumed;
}

fn processAction(ctx: *PtyThreadCtx, action: picker_state_mod.PickerAction) bool {
    switch (action) {
        .none => return false,
        .close => {
            closeTabPicker(ctx);
            return true;
        },
        .switch_tab => |idx| {
            closeTabPicker(ctx);
            // Switch to the selected tab
            if (idx < ctx.tab_mgr.count and idx != ctx.tab_mgr.active) {
                ctx.tab_mgr.switchTo(idx);
                publish.generateTabBar(ctx);
                publish.generateStatusbar(ctx);
            }
            return true;
        },
    }
}

pub fn closeTabPicker(ctx: *PtyThreadCtx) void {
    g_picker_state = null;
    @atomicStore(i32, &terminal.g_tab_picker_active, 0, .seq_cst);
    if (ctx.overlay_mgr) |mgr| mgr.hide(.tab_picker);
    publish.publishOverlays(ctx);
    logging.info("tab-picker", "closed tab picker", .{});
}

pub fn relayout(ctx: *PtyThreadCtx) void {
    const state = &(g_picker_state orelse return);
    const mgr = ctx.overlay_mgr orelse return;

    const panel_h = @as(u16, @intCast(@max(3, ctx.grid_rows))) / 2;
    state.visible_rows = if (panel_h > 4) @as(u8, @intCast(panel_h - 4)) else 3;
    state.adjustScroll();

    const result = picker_panel.renderTabPicker(
        ctx.allocator,
        state,
        ctx.grid_cols,
        ctx.grid_rows,
        publish.overlayThemeFromTheme(&ctx.active_theme),
    ) catch return;

    if (result.width == 0 or result.height == 0) return;

    mgr.setContent(.tab_picker, result.col, result.row, result.width, result.height, result.cells) catch {};
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.tab_picker)].backdrop_alpha = 100;
    ctx.allocator.free(result.cells);
}

fn renderAndPublish(ctx: *PtyThreadCtx) void {
    const state = &(g_picker_state orelse return);
    const mgr = ctx.overlay_mgr orelse return;

    const result = picker_panel.renderTabPicker(
        ctx.allocator,
        state,
        ctx.grid_cols,
        ctx.grid_rows,
        publish.overlayThemeFromTheme(&ctx.active_theme),
    ) catch return;

    if (result.width == 0 or result.height == 0) return;

    mgr.setContent(.tab_picker, result.col, result.row, result.width, result.height, result.cells) catch {};
    mgr.show(.tab_picker);
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.tab_picker)].backdrop_alpha = 100;
    ctx.allocator.free(result.cells);

    publish.publishOverlays(ctx);
}
