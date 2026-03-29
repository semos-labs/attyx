// Attyx — Split pane action helpers
// Extracted from actions.zig to keep file size under 600 lines.

const std = @import("std");
const split_layout_mod = @import("../split_layout.zig");
const SplitLayout = split_layout_mod.SplitLayout;
const publish = @import("publish.zig");
const c = publish.c;
const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const actions = @import("actions.zig");
const statusbar = @import("../statusbar.zig");

/// Compute split gap sizes from window padding and cell dimensions.
pub fn computeSplitGaps() struct { h: u16, v: u16 } {
    const cell_w: f32 = c.g_cell_w_pts;
    const cell_h: f32 = c.g_cell_h_pts;
    if (cell_w <= 0 or cell_h <= 0) return .{ .h = 1, .v = 1 };
    const pad_h: f32 = @floatFromInt(c.g_padding_left + c.g_padding_right);
    const pad_v: f32 = @floatFromInt(c.g_padding_top + c.g_padding_bottom);
    return .{
        .h = @max(1, @as(u16, @intFromFloat(@round(pad_h / cell_w)))),
        .v = @max(1, @as(u16, @intFromFloat(@round(pad_v / cell_h)))),
    };
}

/// Notify daemon of new pane dimensions after layout changes (split, close, resize, etc.).
/// For daemon-backed panes: sends resize via session protocol.
/// For local panes: forces TIOCSWINSZ (SIGWINCH) delivery.
pub fn notifyPaneSizes(ctx: *PtyThreadCtx, layout: *SplitLayout) void {
    var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
    const lc = layout.collectLeaves(&leaves);
    for (leaves[0..lc]) |leaf| {
        if (leaf.pane.daemon_pane_id) |dpid| {
            if (ctx.session_client) |sc| {
                sc.sendPaneResize(dpid, leaf.rect.rows, leaf.rect.cols) catch {};
            }
        } else {
            leaf.pane.forceNotifySize();
        }
    }
}

pub fn doSplit(ctx: *PtyThreadCtx, layout: *SplitLayout, dir: split_layout_mod.Direction) void {
    const Pane = @import("../pane.zig").Pane;

    if (ctx.sessions_enabled) {
        const sc = ctx.session_client orelse return;
        const sz = layout.splitChildSize(dir, layout.pool[layout.focused].rect) orelse return;
        var osc7_buf: [statusbar.max_output_len]u8 = undefined;
        const resolved = actions.resolveFocusedCwd(ctx, &osc7_buf);
        defer if (resolved.owned) if (resolved.cwd) |cwd_alloc| ctx.allocator.free(cwd_alloc);
        if (ctx.default_program) |prog| {
            sc.sendCreatePaneWithShell(sz.rows, sz.cols, resolved.cwd orelse "", prog) catch return;
        } else {
            sc.sendCreatePane(sz.rows, sz.cols, resolved.cwd orelse "") catch return;
        }
        const pane_id = sc.waitForPaneCreated(5000) catch return;
        const new_pane = ctx.allocator.create(Pane) catch return;
        new_pane.* = Pane.initDaemonBacked(ctx.allocator, sz.rows, sz.cols, ctx.applied_scrollback_lines) catch {
            ctx.allocator.destroy(new_pane);
            return;
        };
        new_pane.daemon_pane_id = pane_id;
        ctx.tab_mgr.assignIpcId(new_pane);
        layout.splitPaneWith(dir, new_pane) catch {
            new_pane.deinit();
            ctx.allocator.destroy(new_pane);
            return;
        };
    } else {
        // Resolve CWD with full fallback chain (platform lookup + OSC 7).
        // splitPane's internal getForegroundCwd has no OSC 7 fallback, which
        // caused new splits to start in $HOME when the platform lookup failed.
        var osc7_buf_local: [statusbar.max_output_len]u8 = undefined;
        const resolved = actions.resolveFocusedCwd(ctx, &osc7_buf_local);
        defer if (resolved.owned) if (resolved.cwd) |cwd_alloc| ctx.allocator.free(cwd_alloc);
        layout.splitPaneResolved(dir, ctx.allocator, resolved.cwd, ctx.applied_scrollback_lines) catch return;
    }

    // Set theme colors and assign IPC ID on the newly created pane.
    if (layout.focused != 0xFF) {
        if (layout.pool[layout.focused].pane) |pane| {
            if (pane.ipc_id == 0) ctx.tab_mgr.assignIpcId(pane);
            pane.engine.state.theme_colors = publish.themeToEngineColors(&ctx.active_theme);
        }
    }

    const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
    layout.layout(pty_rows, ctx.grid_cols);

    notifyPaneSizes(ctx, layout);

    actions.updateSplitActive(ctx);
    actions.switchActiveTab(ctx);
    actions.saveSessionLayout(ctx);
}
