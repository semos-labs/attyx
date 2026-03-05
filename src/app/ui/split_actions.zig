// Attyx — Split pane action helpers
// Extracted from actions.zig to keep file size under 600 lines.

const std = @import("std");
const split_layout_mod = @import("../split_layout.zig");
const SplitLayout = split_layout_mod.SplitLayout;
const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const c = terminal.c;
const publish = @import("publish.zig");
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

pub fn doSplit(ctx: *PtyThreadCtx, layout: *SplitLayout, dir: split_layout_mod.Direction) void {
    const Pane = @import("../pane.zig").Pane;

    if (ctx.sessions_enabled) {
        const sc = ctx.session_client orelse return;
        const sz = layout.splitChildSize(dir, layout.pool[layout.focused].rect) orelse return;
        var osc7_buf: [statusbar.max_output_len]u8 = undefined;
        const resolved = actions.resolveFocusedCwd(ctx, &osc7_buf);
        defer if (resolved.owned) if (resolved.cwd) |cwd_alloc| ctx.allocator.free(cwd_alloc);
        sc.sendCreatePane(sz.rows, sz.cols, resolved.cwd orelse "") catch return;
        const pane_id = sc.waitForPaneCreated(5000) catch return;
        const new_pane = ctx.allocator.create(Pane) catch return;
        new_pane.* = Pane.initDaemonBacked(ctx.allocator, sz.rows, sz.cols, ctx.applied_scrollback_lines) catch {
            ctx.allocator.destroy(new_pane);
            return;
        };
        new_pane.daemon_pane_id = pane_id;
        layout.splitPaneWith(dir, new_pane) catch {
            new_pane.deinit();
            ctx.allocator.destroy(new_pane);
            return;
        };
    } else {
        layout.splitPane(dir, ctx.allocator, publish.ctxPty(ctx).master, ctx.applied_scrollback_lines) catch return;
    }

    const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
    layout.layout(pty_rows, ctx.grid_cols);
    actions.updateSplitActive(ctx);
    actions.switchActiveTab(ctx);
    actions.saveSessionLayout(ctx);
}
