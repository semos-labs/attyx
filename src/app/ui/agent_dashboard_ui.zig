//! Agent dashboard UI integration — wires the pure dashboard overlay
//! (state + panel) to the overlay manager. Enumerates the attached window's
//! panes, resolves each agent's usage (+ estimated cost), builds display rows,
//! and renders a live table. Opened/closed via the toggle keybind / command
//! palette; refreshed on each event-loop wake while open.
//!
//! v1 covers the attached window's panes. Cross-session aggregation (daemon
//! agent_watch) and Esc-to-close (native input routing) are follow-ups.
const std = @import("std");

const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const publish = @import("publish.zig");
const session_picker_ui = @import("session_picker_ui.zig");
const command_palette_ui = @import("command_palette_ui.zig");
const theme_picker_ui = @import("theme_picker_ui.zig");
const tab_picker_ui = @import("tab_picker_ui.zig");
const input = @import("input.zig");
const pricing = @import("../agent_pricing.zig");
const split_layout_mod = @import("../split_layout.zig");
const tab_bar_mod = @import("../tab_bar.zig");

const attyx = @import("attyx");
const dash = attyx.overlay_agent_dashboard;
const dash_panel = attyx.overlay_agent_dashboard_panel;
const overlay_mod = attyx.overlay_mod;
const DashboardState = dash.DashboardState;

var g_state: ?DashboardState = null;
/// Fingerprint of the last-rendered state, so refresh() skips a redraw when
/// nothing changed (the loop wakes on every byte of pane output).
var g_fingerprint: u64 = 0;

pub fn openAgentDashboard(ctx: *PtyThreadCtx) void {
    // Close other modals (single-modal invariant).
    if (terminal.g_session_picker_active != 0) session_picker_ui.closeSessionPicker(ctx);
    if (terminal.g_command_palette_active != 0) command_palette_ui.closeCommandPalette(ctx);
    if (terminal.g_theme_picker_active != 0) theme_picker_ui.closeThemePicker(ctx);
    if (terminal.g_tab_picker_active != 0) tab_picker_ui.closeTabPicker(ctx);

    g_state = buildState(ctx);
    g_fingerprint = fingerprint(&g_state.?);
    @atomicStore(i32, &terminal.g_agent_dashboard_active, 1, .seq_cst);
    renderAndPublish(ctx);
}

pub fn closeAgentDashboard(ctx: *PtyThreadCtx) void {
    g_state = null;
    @atomicStore(i32, &terminal.g_agent_dashboard_active, 0, .seq_cst);
    if (ctx.overlay_mgr) |mgr| mgr.hide(.agent_dashboard);
    publish.publishOverlays(ctx);
}

/// Rebuild from current pane state and redraw only if the table changed.
pub fn refresh(ctx: *PtyThreadCtx) void {
    if (terminal.g_agent_dashboard_active == 0) return;
    const st = buildState(ctx);
    const fp = fingerprint(&st);
    if (fp == g_fingerprint and g_state != null) return;
    g_state = st;
    g_fingerprint = fp;
    renderAndPublish(ctx);
}

pub fn relayout(ctx: *PtyThreadCtx) void {
    if (terminal.g_agent_dashboard_active == 0) return;
    renderAndPublish(ctx);
}

/// Drain the shared picker input rings while the dashboard is open. It's a
/// read-only view, so characters are discarded and only Esc / Enter (cmd 7 / 8)
/// close it. Returns true if it closed. Native input routes keys here when
/// `g_agent_dashboard_active` is set (same gate as the pickers).
pub fn consumeInput(ctx: *PtyThreadCtx) bool {
    // Discard any buffered characters (no filtering in this view).
    while (true) {
        const r = @atomicLoad(u32, &input.g_picker_char_read, .seq_cst);
        const w = @atomicLoad(u32, &input.g_picker_char_write, .seq_cst);
        if (r == w) break;
        @atomicStore(u32, &input.g_picker_char_read, r +% 1, .seq_cst);
    }
    while (true) {
        const r = @atomicLoad(u32, &input.g_picker_cmd_read, .seq_cst);
        const w = @atomicLoad(u32, &input.g_picker_cmd_write, .seq_cst);
        if (r == w) break;
        const cmd = input.g_picker_cmd_ring[r % 16];
        @atomicStore(u32, &input.g_picker_cmd_read, r +% 1, .seq_cst);
        if (cmd == 7 or cmd == 8) { // Esc / Enter
            closeAgentDashboard(ctx);
            return true;
        }
    }
    return false;
}

/// Enumerate the attached window's panes and build display rows.
fn buildState(ctx: *PtyThreadCtx) DashboardState {
    var st = DashboardState{};
    var titles: tab_bar_mod.TabTitles = undefined;
    var name_bufs: [tab_bar_mod.max_tabs][256]u8 = undefined;
    publish.resolveTabTitlesOnly(ctx, &titles, &name_bufs);

    const mgr = ctx.tab_mgr;
    for (0..mgr.count) |i| {
        const layout = &(mgr.tabs[i] orelse continue);
        var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
        const lc = layout.collectLeaves(&leaves);
        for (leaves[0..lc]) |leaf| {
            const status = leaf.pane.engine.state.agent_status;
            if (status == .none) continue;
            const usage = pricing.withEstimate(leaf.pane.engine.state.agentUsage());
            var row = dash.Row{
                .pane_id = leaf.pane.ipc_id,
                .status = status,
                .input_tokens = usage.input_tokens,
                .output_tokens = usage.output_tokens,
                .context_used = usage.context_used,
                .context_max = usage.context_max,
                .cost_usd = usage.cost_usd,
                .cost_is_estimate = usage.cost_is_estimate,
            };
            row.session_len = dash.copyField(&row.session_buf, titles[i] orelse "shell");
            if (usage.model) |m| row.model_len = dash.copyField(&row.model_buf, m);
            if (usage.effort) |e| row.effort_len = dash.copyField(&row.effort_buf, e);
            if (status == .input) row.note_len = dash.copyField(&row.note_buf, "needs input");
            st.addRow(row);
        }
    }
    return st;
}

/// Cheap order-sensitive fingerprint of the table for change detection.
/// Collisions only cost a skipped redraw (rare, harmless).
fn fingerprint(st: *const DashboardState) u64 {
    var h: u64 = 1469598103934665603; // FNV offset basis
    const mix = struct {
        fn f(acc: u64, v: u64) u64 {
            return (acc ^ v) *% 1099511628211;
        }
    }.f;
    h = mix(h, st.row_count);
    for (st.rowsSlice()) |*r| {
        h = mix(h, r.pane_id);
        h = mix(h, @intFromEnum(r.status));
        h = mix(h, r.input_tokens orelse 0);
        h = mix(h, r.output_tokens orelse 0);
        for (r.effort()) |ch| h = mix(h, ch);
        h = mix(h, r.context_used orelse 0);
        h = mix(h, @as(u64, @bitCast(r.cost_usd orelse 0)));
    }
    return h;
}

fn renderAndPublish(ctx: *PtyThreadCtx) void {
    const state = &(g_state orelse return);
    const mgr = ctx.overlay_mgr orelse return;

    const result = dash_panel.renderAgentDashboard(
        ctx.allocator,
        state,
        ctx.grid_cols,
        ctx.grid_rows,
        publish.overlayThemeFromTheme(&ctx.active_theme),
    ) catch return;
    if (result.width == 0 or result.height == 0) return;

    mgr.setContent(.agent_dashboard, result.col, result.row, result.width, result.height, result.cells) catch {};
    mgr.show(.agent_dashboard);
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.agent_dashboard)].backdrop_alpha = 100;
    ctx.allocator.free(result.cells);

    publish.publishOverlays(ctx);
}
