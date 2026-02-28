// Attyx — Split pane rendering
//
// Fills the flat g_cells buffer from multiple pane engines, drawing
// box-drawing separator characters between split regions.

const std = @import("std");
const attyx = @import("attyx");
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

    // 2. Draw separator characters on branch nodes
    drawSeparators(cells, layout_ptr, grid_rows, grid_cols, theme);

    // 3. Fill each leaf's region from its engine
    var leaves: [max_panes]LeafEntry = undefined;
    const leaf_count = layout_ptr.collectLeaves(&leaves);
    for (leaves[0..leaf_count]) |leaf| {
        fillRegion(cells, &leaf.pane.engine, leaf.rect, grid_cols, theme);
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
    const eng_cols = eng.state.grid.cols;
    const eng_rows = eng.state.grid.rows;
    const sb = &eng.state.scrollback;

    const copy_rows = @min(rect.rows, eng_rows);
    const copy_cols = @min(rect.cols, eng_cols);

    if (vp == 0) {
        for (0..copy_rows) |row| {
            const dst_offset = @as(usize, rect.row + @as(u16, @intCast(row))) * @as(usize, grid_cols) + rect.col;
            for (0..copy_cols) |col| {
                cells[dst_offset + col] = cellToRenderCell(
                    eng.state.grid.cells[row * eng_cols + col],
                    theme,
                );
            }
        }
    } else {
        const effective_vp = @min(vp, sb.count);
        for (0..copy_rows) |row| {
            const dst_offset = @as(usize, rect.row + @as(u16, @intCast(row))) * @as(usize, grid_cols) + rect.col;
            if (row < effective_vp) {
                const sb_line_idx = sb.count - effective_vp + row;
                const sb_cells = sb.getLine(sb_line_idx);
                for (0..copy_cols) |col| {
                    cells[dst_offset + col] = cellToRenderCell(sb_cells[col], theme);
                }
            } else {
                const grid_row = row - effective_vp;
                for (0..copy_cols) |col| {
                    cells[dst_offset + col] = cellToRenderCell(
                        eng.state.grid.cells[grid_row * eng_cols + col],
                        theme,
                    );
                }
            }
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
    const fg = theme.foreground;
    const bg = theme.background;

    const gap_h = layout_ptr.gap_h;
    const gap_v = layout_ptr.gap_v;

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
                for (0..rect.rows) |r| {
                    const row = rect.row + @as(u16, @intCast(r));
                    if (row >= grid_rows) break;
                    const idx = @as(usize, row) * @as(usize, grid_cols) + sep_col;
                    cells[idx] = .{
                        .character = 0x2502, // │
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
                }
            },
            .horizontal => {
                const available = rect.rows -| gap_v;
                const top_rows = @as(u16, @intFromFloat(@as(f32, @floatFromInt(available)) * node.ratio));
                const padding = (gap_v -| 1) / 2;
                const sep_row = rect.row + top_rows + padding;
                if (sep_row >= grid_rows) continue;
                const row_offset = @as(usize, sep_row) * @as(usize, grid_cols);
                for (0..rect.cols) |cc| {
                    const col = rect.col + @as(u16, @intCast(cc));
                    if (col >= grid_cols) break;
                    cells[row_offset + col] = .{
                        .character = 0x2500, // ─
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
                }
            },
        }
    }
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
        else => return color_mod.resolve(color, is_bg),
    }
}
