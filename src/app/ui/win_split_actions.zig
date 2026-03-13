// Windows split pane actions — resize, click-to-focus, drag.
// Extracted from event_loop_windows.zig to stay under the 600 line limit.

const std = @import("std");
const attyx = @import("attyx");
const publish = @import("publish.zig");
const c = publish.c;
const ws = @import("../windows_stubs.zig");
const split_layout_mod = @import("../split_layout.zig");
const SplitLayout = split_layout_mod.SplitLayout;
const Pane = @import("../pane.zig").Pane;
const keybinds_mod = @import("../../config/keybinds.zig");
const Action = keybinds_mod.Action;
const event_loop = @import("event_loop_windows.zig");
const WinCtx = event_loop.WinCtx;

// ── Split actions (keybind-driven) ──

pub fn processSplitActions(ctx: *WinCtx) void {
    const action_raw = @atomicRmw(i32, &ws.split_action_request, .Xchg, 0, .seq_cst);
    if (action_raw == 0) return;
    const action: Action = @enumFromInt(@as(u8, @intCast(action_raw)));
    const layout = ctx.tab_mgr.activeLayout();
    const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - ws.g_grid_top_offset - ws.g_grid_bottom_offset));

    switch (action) {
        .split_vertical, .split_horizontal => {
            const dir: split_layout_mod.Direction = if (action == .split_vertical) .vertical else .horizontal;
            const new_pane = ctx.allocator.create(Pane) catch return;
            new_pane.* = Pane.spawn(ctx.allocator, pty_rows, ctx.grid_cols, null, null, ctx.applied_scrollback_lines) catch {
                ctx.allocator.destroy(new_pane);
                return;
            };
            ctx.tab_mgr.assignIpcId(new_pane);
            new_pane.engine.state.theme_colors = publish.themeToEngineColors(ctx.theme);
            layout.splitPaneWith(dir, new_pane) catch {
                new_pane.deinit();
                ctx.allocator.destroy(new_pane);
                return;
            };
            layout.layout(pty_rows, ctx.grid_cols);
            event_loop.switchActiveTab(ctx);
        },
        .pane_close => {
            if (layout.pane_count <= 1) {
                if (ctx.tab_mgr.count <= 1) {
                    c.attyx_request_quit();
                } else {
                    ctx.tab_mgr.closeTab(ctx.tab_mgr.active);
                    event_loop.updateGridOffsets(ctx);
                    event_loop.switchActiveTab(ctx);
                }
                return;
            }
            _ = layout.closePane(ctx.allocator);
            layout.layout(pty_rows, ctx.grid_cols);
            event_loop.switchActiveTab(ctx);
        },
        .pane_focus_up => { layout.navigate(.up); event_loop.switchActiveTab(ctx); },
        .pane_focus_down => { layout.navigate(.down); event_loop.switchActiveTab(ctx); },
        .pane_focus_left => { layout.navigate(.left); event_loop.switchActiveTab(ctx); },
        .pane_focus_right => { layout.navigate(.right); event_loop.switchActiveTab(ctx); },
        .pane_zoom_toggle => {
            layout.toggleZoom();
            layout.layout(pty_rows, ctx.grid_cols);
            event_loop.switchActiveTab(ctx);
        },
        .pane_rotate => {
            layout.rotatePanes();
            layout.layout(pty_rows, ctx.grid_cols);
            event_loop.switchActiveTab(ctx);
        },
        .pane_resize_left, .pane_resize_right => {
            if (layout.findResizeTarget(.vertical)) |target| {
                const step = cellsToRatio(ctx.split_resize_step, ctx.grid_cols);
                const delta: f32 = if (action == .pane_resize_left) -step else step;
                if (layout.resizeNode(target, delta, pty_rows, ctx.grid_cols)) {
                    notifyLocalPaneSizes(layout);
                    event_loop.switchActiveTab(ctx);
                }
            }
        },
        .pane_resize_up, .pane_resize_down => {
            if (layout.findResizeTarget(.horizontal)) |target| {
                const step = cellsToRatio(ctx.split_resize_step, pty_rows);
                const delta: f32 = if (action == .pane_resize_up) -step else step;
                if (layout.resizeNode(target, delta, pty_rows, ctx.grid_cols)) {
                    notifyLocalPaneSizes(layout);
                    event_loop.switchActiveTab(ctx);
                }
            }
        },
        .pane_resize_grow, .pane_resize_shrink => {
            if (layout.findSmartResizeTarget()) |target| {
                const total = if (target.direction == .vertical) ctx.grid_cols else pty_rows;
                const step = cellsToRatio(ctx.split_resize_step, total);
                const sign: f32 = if (target.is_first_child) 1.0 else -1.0;
                const grow_sign: f32 = if (action == .pane_resize_grow) sign else -sign;
                if (layout.resizeNode(target.branch, step * grow_sign, pty_rows, ctx.grid_cols)) {
                    notifyLocalPaneSizes(layout);
                    event_loop.switchActiveTab(ctx);
                }
            }
        },
        else => {},
    }
}

// ── Split click-to-focus ──

pub fn processSplitClick(ctx: *WinCtx) void {
    if (@atomicRmw(i32, &ws.split_click_pending, .Xchg, 0, .seq_cst) == 0) return;
    const layout = ctx.tab_mgr.activeLayout();
    if (layout.pane_count <= 1) return;
    const click_col: u16 = @intCast(@max(0, @atomicLoad(i32, &ws.split_click_col, .seq_cst)));
    const click_row: u16 = @intCast(@max(0, @atomicLoad(i32, &ws.split_click_row, .seq_cst) - ws.g_grid_top_offset));
    if (layout.paneAt(click_row, click_col)) |target_idx| {
        if (target_idx != layout.focused) {
            layout.focused = target_idx;
            event_loop.switchActiveTab(ctx);
        }
    }
}

// ── Split drag ──

pub fn processSplitDrag(ctx: *WinCtx) void {
    const layout = ctx.tab_mgr.activeLayout();
    const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - ws.g_grid_top_offset - ws.g_grid_bottom_offset));

    // Drag start: find branch at separator position
    if (@atomicRmw(i32, &ws.split_drag_start_pending, .Xchg, 0, .seq_cst) != 0) {
        const col: u16 = @intCast(@max(0, @atomicLoad(i32, &ws.split_drag_start_col, .seq_cst)));
        const row: u16 = @intCast(@max(0, @atomicLoad(i32, &ws.split_drag_start_row, .seq_cst) - ws.g_grid_top_offset));
        if (layout.separatorAt(row, col)) |branch_idx| {
            ws.split_drag_branch = branch_idx;
            @atomicStore(i32, &ws.g_split_drag_active, 1, .seq_cst);
            @atomicStore(i32, &ws.g_split_drag_direction, if (layout.pool[branch_idx].direction == .vertical) @as(i32, 0) else @as(i32, 1), .seq_cst);
        }
    }

    // Drag update: compute new ratio from mouse position
    if (@atomicRmw(i32, &ws.split_drag_cur_pending, .Xchg, 0, .seq_cst) != 0) {
        const branch_idx = ws.split_drag_branch;
        if (branch_idx != 0xFF and layout.pool[branch_idx].tag == .branch) {
            const col: u16 = @intCast(@max(0, @atomicLoad(i32, &ws.split_drag_cur_col, .seq_cst)));
            const row: u16 = @intCast(@max(0, @atomicLoad(i32, &ws.split_drag_cur_row, .seq_cst) - ws.g_grid_top_offset));
            const rect = layout.pool[branch_idx].rect;

            const new_ratio: f32 = switch (layout.pool[branch_idx].direction) {
                .vertical => blk: {
                    const available = rect.cols -| layout.gap_h;
                    if (available == 0) break :blk 0.5;
                    const offset: f32 = @floatFromInt(@as(i32, col) - @as(i32, rect.col));
                    break :blk @max(0.05, @min(0.95, offset / @as(f32, @floatFromInt(available))));
                },
                .horizontal => blk: {
                    const available = rect.rows -| layout.gap_v;
                    if (available == 0) break :blk 0.5;
                    const offset: f32 = @floatFromInt(@as(i32, row) - @as(i32, rect.row));
                    break :blk @max(0.05, @min(0.95, offset / @as(f32, @floatFromInt(available))));
                },
            };

            layout.pool[branch_idx].ratio = new_ratio;
            layout.layout(pty_rows, ctx.grid_cols);
        }
    }

    // Drag end: notify pane sizes and reset
    if (@atomicRmw(i32, &ws.split_drag_end_pending, .Xchg, 0, .seq_cst) != 0) {
        notifyLocalPaneSizes(layout);
        ws.split_drag_branch = 0xFF;
        @atomicStore(i32, &ws.g_split_drag_active, 0, .seq_cst);
    }
}

// ── Helpers ──

fn cellsToRatio(cells: u16, total: u16) f32 {
    if (total == 0) return 0.05;
    return @as(f32, @floatFromInt(cells)) / @as(f32, @floatFromInt(total));
}

fn notifyLocalPaneSizes(layout: *SplitLayout) void {
    var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
    const lc = layout.collectLeaves(&leaves);
    for (leaves[0..lc]) |leaf| {
        leaf.pane.forceNotifySize();
    }
}
