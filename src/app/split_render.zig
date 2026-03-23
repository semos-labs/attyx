// Attyx — Split pane rendering
//
// Fills the flat g_cells buffer from multiple pane engines, drawing
// box-drawing separator characters between split regions.

const std = @import("std");
const builtin = @import("builtin");
const attyx = @import("attyx");
const is_windows = builtin.os.tag == .windows;
const term_globals = if (is_windows) @import("windows_stubs.zig") else @import("terminal.zig");
const Engine = attyx.Engine;
const color_mod = attyx.render_color;
const SplitLayout = @import("split_layout.zig").SplitLayout;
const LeafEntry = @import("split_layout.zig").LeafEntry;
const max_panes = @import("split_layout.zig").max_panes;
const Rect = @import("split_layout.zig").Rect;
const theme_registry_mod = @import("../theme/registry.zig");
pub const Theme = theme_registry_mod.Theme;

// Zig-native mirror of AttyxCell (matches the C struct layout in bridge.h).
// Defined here to avoid @cImport type conflicts between compilation units.
pub const Cell = extern struct {
    character: u32,
    combining: [2]u32,
    fg_r: u8,
    fg_g: u8,
    fg_b: u8,
    bg_r: u8,
    bg_g: u8,
    bg_b: u8,
    flags: u8,
    link_id: u32,
};

/// Fill the cell buffer from a multi-pane split layout.
/// Draws separators and composites each pane's engine into its region.
pub fn fillCellsSplit(
    cells: [*]Cell,
    layout_ptr: *SplitLayout,
    grid_rows: u16,
    grid_cols: u16,
    theme: *const Theme,
) void {
    // 1. Clear entire buffer to dark background
    const total: usize = @as(usize, grid_rows) * @as(usize, grid_cols);
    const bg = theme.background;
    for (0..total) |i| {
        cells[i] = .{
            .character = ' ',
            .combining = .{ 0, 0 },
            .fg_r = bg.r,
            .fg_g = bg.g,
            .fg_b = bg.b,
            .bg_r = bg.r,
            .bg_g = bg.g,
            .bg_b = bg.b,
            .flags = 4, // default bg flag
            .link_id = 0,
        };
    }

    // If zoomed, render only the zoomed pane at full grid size
    if (layout_ptr.isZoomed()) {
        const zoomed_pane = layout_ptr.pool[layout_ptr.zoomed_leaf].pane orelse return;
        const full_rect = Rect{ .row = 0, .col = 0, .rows = grid_rows, .cols = grid_cols };
        fillRegion(cells, &zoomed_pane.engine, full_rect, grid_cols, theme);
        return;
    }

    // 2. Draw separator characters on branch nodes
    drawSeparators(cells, layout_ptr, grid_rows, grid_cols, theme);

    // 3. Fill each leaf's region from its engine
    var leaves: [max_panes]LeafEntry = undefined;
    const leaf_count = layout_ptr.collectLeaves(&leaves);
    const dim = (term_globals.g_tab_dim_unfocused != 0);
    for (leaves[0..leaf_count]) |leaf| {
        fillRegion(cells, &leaf.pane.engine, leaf.rect, grid_cols, theme);
        if (dim and leaf.index != layout_ptr.focused) {
            dimRegion(cells, leaf.rect, grid_cols);
        }
    }
}

/// Fill a rectangular sub-region of the cell buffer from an engine's grid.
fn fillRegion(
    cells: [*]Cell,
    eng: *Engine,
    rect: Rect,
    grid_cols: u16,
    theme: *const Theme,
) void {
    const vp = eng.state.viewport_offset;
    const eng_cols = eng.state.ring.cols;
    const eng_rows = eng.state.ring.screen_rows;

    const copy_rows = @min(rect.rows, eng_rows);
    const copy_cols = @min(rect.cols, eng_cols);

    for (0..copy_rows) |row| {
        const dst_offset = @as(usize, rect.row + @as(u16, @intCast(row))) * @as(usize, grid_cols) + rect.col;
        const row_cells = eng.state.ring.viewportRow(vp, row);
        for (0..copy_cols) |col| {
            cells[dst_offset + col] = cellToRenderCell(row_cells[col], theme);
        }
    }
}

/// Dim foreground text in a rectangular region (unfocused pane).
fn dimRegion(cells: [*]Cell, rect: Rect, grid_cols: u16) void {
    for (0..rect.rows) |row| {
        const offset = @as(usize, rect.row + @as(u16, @intCast(row))) * @as(usize, grid_cols) + rect.col;
        for (0..rect.cols) |col| {
            const c = &cells[offset + col];
            c.fg_r = @intCast(@as(u16, c.fg_r) / 2);
            c.fg_g = @intCast(@as(u16, c.fg_g) / 2);
            c.fg_b = @intCast(@as(u16, c.fg_b) / 2);
        }
    }
}

/// Walk branch nodes and draw box-drawing separator characters.
fn drawSeparators(
    cells: [*]Cell,
    layout_ptr: *SplitLayout,
    grid_rows: u16,
    grid_cols: u16,
    theme: *const Theme,
) void {
    // Dim the separator: blend foreground 1/3 toward background
    const fg = .{
        .r = @as(u8, @intCast((@as(u16, theme.foreground.r) + @as(u16, theme.background.r) * 2) / 3)),
        .g = @as(u8, @intCast((@as(u16, theme.foreground.g) + @as(u16, theme.background.g) * 2) / 3)),
        .b = @as(u8, @intCast((@as(u16, theme.foreground.b) + @as(u16, theme.background.b) * 2) / 3)),
    };
    const bg = theme.background;

    const gap_h = layout_ptr.gap_h;
    const gap_v = layout_ptr.gap_v;

    const sep_cell_template = Cell{
        .character = 0,
        .combining = .{ 0, 0 },
        .fg_r = fg.r,
        .fg_g = fg.g,
        .fg_b = fg.b,
        .bg_r = bg.r,
        .bg_g = bg.g,
        .bg_b = bg.b,
        .flags = 4,
        .link_id = 0,
    };

    // Pass 1: draw all separators as │ and ─
    for (&layout_ptr.pool) |*node| {
        if (node.tag != .branch) continue;
        const rect = node.rect;

        switch (node.direction) {
            .vertical => {
                const available = rect.cols -| gap_h;
                const left_cols = @as(u16, @intFromFloat(@as(f32, @floatFromInt(available)) * node.ratio));
                const padding = (gap_h -| 1) / 2;
                const sep_col = rect.col + left_cols + padding;
                if (sep_col >= grid_cols) continue;
                // Extend into parent gaps so vertical lines meet horizontal ones
                const row_start = rect.row -| gap_v;
                const row_end = @min(grid_rows, rect.row + rect.rows + gap_v);
                for (row_start..row_end) |r| {
                    const idx = r * @as(usize, grid_cols) + sep_col;
                    cells[idx] = sep_cell_template;
                    cells[idx].character = 0x2502; // │
                }
            },
            .horizontal => {
                const available = rect.rows -| gap_v;
                const top_rows = @as(u16, @intFromFloat(@as(f32, @floatFromInt(available)) * node.ratio));
                const padding = (gap_v -| 1) / 2;
                const sep_row = rect.row + top_rows + padding;
                if (sep_row >= grid_rows) continue;
                const row_offset = @as(usize, sep_row) * @as(usize, grid_cols);
                // Extend into parent gaps so horizontal lines meet vertical ones
                const col_start = rect.col -| gap_h;
                const col_end = @min(grid_cols, rect.col + rect.cols + gap_h);
                for (col_start..col_end) |cc| {
                    cells[row_offset + cc] = sep_cell_template;
                    cells[row_offset + cc].character = 0x2500; // ─
                }
            },
        }
    }

    // Pass 2: fix up intersections with proper junction characters
    const gcols: usize = grid_cols;
    for (0..grid_rows) |r| {
        for (0..gcols) |cc| {
            const idx = r * gcols + cc;
            const ch = cells[idx].character;
            if (ch != 0x2502 and ch != 0x2500) continue;

            // Check 4 neighbors for separator lines
            const has_up = r > 0 and isVerticalSep(cells[(r - 1) * gcols + cc].character);
            const has_down = r + 1 < grid_rows and isVerticalSep(cells[(r + 1) * gcols + cc].character);
            const has_left = cc > 0 and isHorizontalSep(cells[r * gcols + (cc - 1)].character);
            const has_right = cc + 1 < gcols and isHorizontalSep(cells[r * gcols + (cc + 1)].character);

            const junction = junctionChar(has_up, has_down, has_left, has_right);
            if (junction != 0) cells[idx].character = junction;
        }
    }
}

fn isVerticalSep(ch: u32) bool {
    return ch == 0x2502 or ch == 0x253C or ch == 0x251C or ch == 0x2524 or ch == 0x252C or ch == 0x2534;
}

fn isHorizontalSep(ch: u32) bool {
    return ch == 0x2500 or ch == 0x253C or ch == 0x251C or ch == 0x2524 or ch == 0x252C or ch == 0x2534;
}

fn junctionChar(up: bool, down: bool, left: bool, right: bool) u32 {
    // Only replace when lines from both axes meet
    const v = up or down;
    const h = left or right;
    if (!v or !h) return 0; // single-axis: no change

    if (up and down and left and right) return 0x253C; // ┼
    if (up and down and right) return 0x251C; // ├
    if (up and down and left) return 0x2524; // ┤
    if (left and right and down) return 0x252C; // ┬
    if (left and right and up) return 0x2534; // ┴
    if (down and right) return 0x250C; // ┌
    if (down and left) return 0x2510; // ┐
    if (up and right) return 0x2514; // └
    if (up and left) return 0x2518; // ┘
    return 0;
}

/// Convert a terminal Cell to a render Cell.
fn cellToRenderCell(cell: attyx.Cell, theme: *const Theme) Cell {
    if (cell.char == 0x10EEEE) {
        const eff_bg = if (cell.style.reverse) cell.style.fg else cell.style.bg;
        const bg = resolveWithTheme(eff_bg, !cell.style.reverse, theme);
        return .{
            .character = ' ',
            .combining = .{ 0, 0 },
            .fg_r = 0,
            .fg_g = 0,
            .fg_b = 0,
            .bg_r = bg.r,
            .bg_g = bg.g,
            .bg_b = bg.b,
            .flags = if (!cell.style.reverse and eff_bg == .default) @as(u8, 4) else @as(u8, 0),
            .link_id = 0,
        };
    }

    const eff_fg = if (cell.style.reverse) cell.style.bg else cell.style.fg;
    const eff_bg = if (cell.style.reverse) cell.style.fg else cell.style.bg;
    const fg = resolveWithTheme(eff_fg, cell.style.reverse, theme);
    const bg = resolveWithTheme(eff_bg, !cell.style.reverse, theme);
    const fg_r = if (cell.style.dim) fg.r / 2 else fg.r;
    const fg_g = if (cell.style.dim) fg.g / 2 else fg.g;
    const fg_b = if (cell.style.dim) fg.b / 2 else fg.b;
    return .{
        .character = cell.char,
        .combining = .{ cell.combining[0], cell.combining[1] },
        .fg_r = fg_r,
        .fg_g = fg_g,
        .fg_b = fg_b,
        .bg_r = bg.r,
        .bg_g = bg.g,
        .bg_b = bg.b,
        .flags = @as(u8, if (cell.style.bold) 1 else 0) |
            @as(u8, if (cell.style.underline) 2 else 0) |
            @as(u8, if (!cell.style.reverse and eff_bg == .default) @as(u8, 4) else @as(u8, 0)) |
            @as(u8, if (cell.style.dim) 8 else 0) |
            @as(u8, if (cell.style.italic) 16 else 0) |
            @as(u8, if (cell.style.strikethrough) 32 else 0),
        .link_id = cell.link_id,
    };
}

fn resolveWithTheme(color: anytype, is_bg: bool, theme: *const Theme) color_mod.Rgb {
    switch (color) {
        .default => {
            const src = if (is_bg) theme.background else theme.foreground;
            return .{ .r = src.r, .g = src.g, .b = src.b };
        },
        .ansi => |n| {
            if (theme.palette[n]) |p| return .{ .r = p.r, .g = p.g, .b = p.b };
            return color_mod.resolve(color, is_bg);
        },
        .palette => |n| {
            if (n < 16) {
                if (theme.palette[n]) |p| return .{ .r = p.r, .g = p.g, .b = p.b };
            }
            return color_mod.resolve(color, is_bg);
        },
        else => return color_mod.resolve(color, is_bg),
    }
}
