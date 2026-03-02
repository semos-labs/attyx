const std = @import("std");
const attyx = @import("attyx");
const Engine = attyx.Engine;
const color_mod = attyx.render_color;
const overlay_mod = attyx.overlay_mod;
const overlay_layout = attyx.overlay_layout;
const overlay_anchor = attyx.overlay_anchor;
const OverlayManager = overlay_mod.OverlayManager;
const tab_bar_mod = @import("../tab_bar.zig");
const statusbar_mod = @import("../statusbar.zig");
const split_render = @import("../split_render.zig");
const platform = @import("../../platform/platform.zig");
const Pty = @import("../pty.zig").Pty;
const AppConfig = @import("../../config/config.zig").AppConfig;
const CursorShapeConfig = @import("../../config/config.zig").CursorShapeConfig;

const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
pub const Theme = @import("../../theme/registry.zig").Theme;
const c = terminal.c;

// Shared anchor demo mode counter (persists across calls).
pub var g_anchor_mode_counter: u8 = 0;

/// Convenience: return the active tab's Engine from a PtyThreadCtx.
pub fn ctxEngine(ctx: *PtyThreadCtx) *Engine {
    return &ctx.tab_mgr.activePane().engine;
}

/// Convenience: return the active tab's Pty from a PtyThreadCtx.
pub fn ctxPty(ctx: *PtyThreadCtx) *Pty {
    return &ctx.tab_mgr.activePane().pty;
}

pub fn cursorShapeFromConfig(shape: CursorShapeConfig, blink: bool) attyx.actions.CursorShape {
    return switch (shape) {
        .block => if (blink) .blinking_block else .steady_block,
        .underline => if (blink) .blinking_underline else .steady_underline,
        .beam => if (blink) .blinking_bar else @enumFromInt(5),
    };
}

pub fn publishFontConfig(config: *const AppConfig) void {
    const family = config.font_family;
    const len = @min(family.len, c.ATTYX_FONT_FAMILY_MAX - 1);
    @memcpy(c.g_font_family[0..len], family[0..len]);
    c.g_font_family[len] = 0;
    c.g_font_family_len = @intCast(len);
    c.g_font_size = @intCast(config.font_size);
    c.g_cell_width = config.cell_width.encode();
    c.g_cell_height = config.cell_height.encode();

    // Publish fallback font list.
    if (config.font_fallback) |fallback| {
        const count = @min(fallback.len, c.ATTYX_FONT_FALLBACK_MAX);
        for (0..count) |i| {
            const name = fallback[i];
            const flen = @min(name.len, c.ATTYX_FONT_FAMILY_MAX - 1);
            @memcpy(c.g_font_fallback[i][0..flen], name[0..flen]);
            c.g_font_fallback[i][flen] = 0;
        }
        c.g_font_fallback_count = @intCast(count);
    } else {
        c.g_font_fallback_count = 0;
    }
}

pub fn syncViewportFromC(state: *attyx.TerminalState) void {
    const c_vp: i32 = @bitCast(c.g_viewport_offset);
    if (c_vp >= 0) {
        state.viewport_offset = @intCast(@as(c_uint, @bitCast(c_vp)));
    }
}

/// Extract image_id from a cell's foreground color (Kitty Unicode placement protocol).
fn imageIdFromFg(fg: attyx.grid.Color) ?u32 {
    return switch (fg) {
        .palette => |v| @as(u32, v),
        .ansi => |v| @as(u32, v),
        .rgb => |rgb| (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | @as(u32, rgb.b),
        .default => null,
    };
}

/// Scan the grid for the first U+10EEEE placeholder cell whose fg color encodes the given image_id.
fn findPlaceholderPosition(grid: anytype, image_id: u32) ?struct { row: i32, col: i32 } {
    const rows: usize = @intCast(grid.rows);
    const cols: usize = @intCast(grid.cols);
    for (0..rows) |r| {
        for (0..cols) |co| {
            const cell = grid.cells[r * cols + co];
            if (cell.char == 0x10EEEE) {
                if (imageIdFromFg(cell.style.fg)) |id| {
                    if (id == image_id) {
                        return .{ .row = @intCast(r), .col = @intCast(co) };
                    }
                }
            }
        }
    }
    return null;
}

pub fn publishImagePlacements(ctx: *PtyThreadCtx) void {
    const state = &ctxEngine(ctx).state;
    const store = state.graphics_store orelse {
        c.g_image_placement_count = 0;
        return;
    };

    const gs = attyx.graphics_store;
    var buf: [c.ATTYX_MAX_IMAGE_PLACEMENTS]gs.Placement = undefined;
    const visible = store.visiblePlacements(state.grid.rows, &buf);

    var out_count: c_int = 0;
    for (visible) |p| {
        if (out_count >= c.ATTYX_MAX_IMAGE_PLACEMENTS) break;

        const img = store.getImage(p.image_id) orelse continue;
        const idx: usize = @intCast(out_count);

        // For virtual placements, derive position from grid placeholder cells.
        var row = p.row;
        var col = p.col;
        if (p.virtual) {
            if (findPlaceholderPosition(&state.grid, p.image_id)) |pos| {
                row = pos.row;
                col = pos.col;
            }
        }

        c.g_image_placements[idx] = .{
            .image_id = p.image_id,
            .row = row,
            .col = col,
            .img_width = img.width,
            .img_height = img.height,
            .src_x = p.src_x,
            .src_y = p.src_y,
            .src_w = p.src_width,
            .src_h = p.src_height,
            .display_cols = p.display_cols,
            .display_rows = p.display_rows,
            .z_index = p.z_index,
            .pixels = img.pixels.ptr,
        };
        out_count += 1;
    }

    c.g_image_placement_count = out_count;
    if (out_count > 0) {
        // Bump generation so renderer knows to check for texture changes.
        _ = @atomicRmw(u64, @as(*u64, @ptrCast(@volatileCast(&c.g_image_gen))), .Add, 1, .seq_cst);
    }
}

pub fn publishOverlays(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    var out_count: c_int = 0;

    for (mgr.layers[0..overlay_mod.max_layers], 0..) |layer, li| {
        if (!layer.visible) continue;
        const cells = layer.cells orelse continue;
        if (out_count >= c.ATTYX_OVERLAY_MAX_LAYERS) break;

        const idx: usize = @intCast(out_count);
        const cell_count = @min(cells.len, c.ATTYX_OVERLAY_MAX_CELLS);

        for (0..cell_count) |ci| {
            c.g_overlay_cells[idx][ci] = .{
                .character = cells[ci].char,
                .fg_r = cells[ci].fg.r,
                .fg_g = cells[ci].fg.g,
                .fg_b = cells[ci].fg.b,
                .bg_r = cells[ci].bg.r,
                .bg_g = cells[ci].bg.g,
                .bg_b = cells[ci].bg.b,
                .bg_alpha = cells[ci].bg_alpha,
            };
        }

        c.g_overlay_descs[idx] = .{
            .visible = 1,
            .col = @intCast(layer.col),
            .row = @intCast(layer.row),
            .width = @intCast(layer.width),
            .height = @intCast(layer.height),
            .cell_count = @intCast(cell_count),
            .z_order = @intCast(li),
        };

        out_count += 1;
    }

    c.g_overlay_count = out_count;

    // Update g_overlay_has_actions so input thread knows whether to intercept keys
    terminal.g_overlay_has_actions = if (mgr.hasActiveActions()) @as(i32, 1) else @as(i32, 0);

    _ = @atomicRmw(u32, @as(*u32, @ptrCast(@volatileCast(&c.g_overlay_gen))), .Add, 1, .seq_cst);
}

pub fn generateDebugCard(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    if (!mgr.isVisible(.debug_card)) return;

    const eng = ctxEngine(ctx);
    const cols: u16 = @intCast(eng.state.grid.cols);
    const rows: u16 = @intCast(eng.state.grid.rows);

    // Format debug info lines
    var grid_buf: [32]u8 = undefined;
    var vp_buf: [32]u8 = undefined;
    var sb_buf: [32]u8 = undefined;
    var cur_buf: [32]u8 = undefined;
    var alt_buf: [32]u8 = undefined;

    const grid_line = std.fmt.bufPrint(&grid_buf, "Grid: {d}x{d}", .{ cols, rows }) catch "Grid: ?";
    const vp_line = std.fmt.bufPrint(&vp_buf, "Viewport: {d}", .{eng.state.viewport_offset}) catch "Viewport: ?";
    const sb_line = std.fmt.bufPrint(&sb_buf, "Scrollback: {d}", .{eng.state.scrollback.count}) catch "Scrollback: ?";
    const cur_line = std.fmt.bufPrint(&cur_buf, "Cursor: {d},{d}", .{ eng.state.cursor.row, eng.state.cursor.col }) catch "Cursor: ?";
    const alt_line = std.fmt.bufPrint(&alt_buf, "Alt screen: {s}", .{if (eng.state.alt_active) "yes" else "no"}) catch "Alt screen: ?";

    const debug_lines = [_][]const u8{
        grid_line,
        vp_line,
        sb_line,
        cur_line,
        alt_line,
    };

    const action_mod = attyx.overlay_action;

    // Build action bar with [Dismiss] button
    var action_bar = action_mod.ActionBar{};
    action_bar.add(.dismiss, "Dismiss");
    // Preserve focus state from existing action_bar if present
    const layer = &mgr.layers[@intFromEnum(overlay_mod.OverlayId.debug_card)];
    if (layer.action_bar) |existing| {
        action_bar.focused = existing.focused;
    }

    const result = overlay_layout.layoutActionCard(
        mgr.allocator,
        "Attyx Debug",
        &debug_lines,
        layer.style,
        action_bar,
    ) catch return;

    // Position: top-right, 2 cells margin
    const card_col = if (cols > result.width + 2) cols - result.width - 2 else 0;
    const card_row: u16 = 2;

    mgr.setContent(.debug_card, card_col, card_row, result.width, result.height, result.cells) catch {
        mgr.allocator.free(result.cells);
        return;
    };
    // layoutActionCard allocated cells; setContent copies them, so free the original.
    mgr.allocator.free(result.cells);

    // Store action_bar on the layer for interaction
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.debug_card)].action_bar = action_bar;
}

pub fn viewportInfoFromCtx(ctx: *PtyThreadCtx) overlay_anchor.ViewportInfo {
    const eng = ctxEngine(ctx);
    const sel_active_raw: i32 = @bitCast(c.g_sel_active);
    const sel_end_row_raw: i32 = @bitCast(c.g_sel_end_row);
    const sel_end_col_raw: i32 = @bitCast(c.g_sel_end_col);
    return .{
        .grid_cols = @intCast(eng.state.grid.cols),
        .grid_rows = @intCast(eng.state.grid.rows),
        .cursor_row = @intCast(eng.state.cursor.row),
        .cursor_col = @intCast(eng.state.cursor.col),
        .sel_active = sel_active_raw != 0,
        .sel_end_row = if (sel_end_row_raw >= 0) @intCast(@as(u32, @bitCast(sel_end_row_raw))) else 0,
        .sel_end_col = if (sel_end_col_raw >= 0) @intCast(@as(u32, @bitCast(sel_end_col_raw))) else 0,
        .alt_active = eng.state.alt_active,
    };
}

pub fn generateAnchorDemo(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    if (!mgr.isVisible(.anchor_demo)) return;

    const kinds = [_]overlay_anchor.AnchorKind{
        .cursor_line,
        .selection_end,
        .after_command,
        .viewport_dock,
    };
    const kind_names = [_][]const u8{
        "cursor_line",
        "selection_end",
        "after_command",
        "viewport_dock",
    };

    const kind = kinds[g_anchor_mode_counter % 4];
    const kind_name = kind_names[g_anchor_mode_counter % 4];

    // Build card content
    var mode_buf: [32]u8 = undefined;
    const mode_line = std.fmt.bufPrint(&mode_buf, "Mode: {s}", .{kind_name}) catch "Mode: ?";

    const demo_lines = [_][]const u8{
        mode_line,
        "Ctrl+Shift+A: cycle",
    };

    const result = overlay_layout.layoutDebugCard(
        mgr.allocator,
        "Anchor Demo",
        &demo_lines,
        mgr.layers[@intFromEnum(overlay_mod.OverlayId.anchor_demo)].style,
    ) catch return;

    // Build anchor based on current mode
    const vp = viewportInfoFromCtx(ctx);
    const anchor = overlay_anchor.Anchor{
        .kind = kind,
        .command_row_hint = if (vp.cursor_row + 1 < vp.grid_rows) vp.cursor_row + 1 else null,
        .dock = .bottom_right,
    };

    const placement = overlay_anchor.placeOverlay(anchor, result.width, result.height, vp, .{});

    mgr.setContent(.anchor_demo, placement.col, placement.row, result.width, result.height, result.cells) catch {
        mgr.allocator.free(result.cells);
        return;
    };
    mgr.allocator.free(result.cells);

    // Store anchor on the layer for relayout
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.anchor_demo)].anchor = anchor;
}

pub fn publishState(ctx: *PtyThreadCtx) void {
    c.attyx_set_mode_flags(
        @intFromBool(ctxEngine(ctx).state.bracketed_paste),
        @intFromBool(ctxEngine(ctx).state.cursor_keys_app),
    );
    c.attyx_set_mouse_mode(
        @intFromEnum(ctxEngine(ctx).state.mouse_tracking),
        @intFromBool(ctxEngine(ctx).state.mouse_sgr),
    );
    c.g_scrollback_count = @intCast(ctxEngine(ctx).state.scrollback.count);
    c.g_alt_screen = @intFromBool(ctxEngine(ctx).state.alt_active);
    c.g_viewport_offset = @intCast(ctxEngine(ctx).state.viewport_offset);

    c.g_cursor_shape = @intFromEnum(ctxEngine(ctx).state.cursor_shape);
    c.g_cursor_visible = @intFromBool(ctxEngine(ctx).state.cursor_visible);
    terminal.g_kitty_kbd_flags = @intCast(ctxEngine(ctx).state.kittyFlags());

    // Window title: prefer OSC 0/2 title from the shell; fall back to the
    // foreground process name (e.g. "zsh", "vim") so the title bar is useful
    // even when the shell doesn't send title sequences.
    if (ctxEngine(ctx).state.title) |title| {
        const len: usize = @min(title.len, c.ATTYX_TITLE_MAX - 1);
        @memcpy(c.g_title_buf[0..len], title[0..len]);
        c.g_title_buf[len] = 0;
        c.g_title_len = @intCast(len);
        c.g_title_changed = 1;
    } else {
        var name_buf: [256]u8 = undefined;
        if (platform.getForegroundProcessName(ctxPty(ctx).master, &name_buf)) |name| {
            const len: usize = @min(name.len, c.ATTYX_TITLE_MAX - 1);
            // Only update if the name actually changed.
            const cur_len: usize = @intCast(c.g_title_len);
            const same = (len == cur_len) and std.mem.eql(u8, c.g_title_buf[0..cur_len], name[0..len]);
            if (!same) {
                @memcpy(c.g_title_buf[0..len], name[0..len]);
                c.g_title_buf[len] = 0;
                c.g_title_len = @intCast(len);
                c.g_title_changed = 1;
            }
        }
    }
}

/// Publish active theme colors to the C bridge globals.
pub fn publishTheme(theme: *const Theme) void {
    if (theme.cursor) |cur| {
        c.g_theme_cursor_r = @intCast(cur.r);
        c.g_theme_cursor_g = @intCast(cur.g);
        c.g_theme_cursor_b = @intCast(cur.b);
    } else {
        c.g_theme_cursor_r = -1;
    }
    if (theme.selection_background) |sel| {
        c.g_theme_sel_bg_set = 1;
        c.g_theme_sel_bg_r = @intCast(sel.r);
        c.g_theme_sel_bg_g = @intCast(sel.g);
        c.g_theme_sel_bg_b = @intCast(sel.b);
    } else {
        c.g_theme_sel_bg_set = 0;
    }
    if (theme.selection_foreground) |sel| {
        c.g_theme_sel_fg_set = 1;
        c.g_theme_sel_fg_r = @intCast(sel.r);
        c.g_theme_sel_fg_g = @intCast(sel.g);
        c.g_theme_sel_fg_b = @intCast(sel.b);
    } else {
        c.g_theme_sel_fg_set = 0;
    }
}

/// Resolve a cell color using the active theme for default fg/bg and ANSI palette.
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

pub fn cellToAttyxCell(cell: attyx.Cell, theme: *const Theme) c.AttyxCell {
    // Kitty Unicode placeholder: suppress all visual attributes.
    // The fg color encodes image_id and must not be rendered.
    if (cell.char == 0x10EEEE) {
        // Emit a space with the cell's actual bg (not fg!) and default-bg opacity flag.
        const eff_bg = if (cell.style.reverse) cell.style.fg else cell.style.bg;
        const bg = resolveWithTheme(eff_bg, !cell.style.reverse, theme);
        return .{
            .character = ' ',
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

    // Swap fg/bg when reverse video is active.
    // Also flip the is_bg hint so .default resolves to the opposite theme color.
    const eff_fg = if (cell.style.reverse) cell.style.bg else cell.style.fg;
    const eff_bg = if (cell.style.reverse) cell.style.fg else cell.style.bg;
    const fg = resolveWithTheme(eff_fg, cell.style.reverse, theme);
    const bg = resolveWithTheme(eff_bg, !cell.style.reverse, theme);
    // Dim: halve foreground brightness
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

pub fn fillCells(cells: []c.AttyxCell, eng: *Engine, _: usize, theme: *const Theme) void {
    const vp = eng.state.viewport_offset;
    const cols = eng.state.grid.cols;
    const rows = eng.state.grid.rows;
    const sb = &eng.state.scrollback;
    const wrapped: *volatile [c.ATTYX_MAX_ROWS]u8 = @ptrCast(&c.g_row_wrapped);

    if (vp == 0) {
        const total = rows * cols;
        for (0..total) |i| {
            cells[i] = cellToAttyxCell(eng.state.grid.cells[i], theme);
        }
        for (0..rows) |row| {
            wrapped[row] = @intFromBool(eng.state.grid.row_wrapped[row]);
        }
        return;
    }

    const effective_vp = @min(vp, sb.count);
    for (0..rows) |row| {
        if (row < effective_vp) {
            const sb_line_idx = sb.count - effective_vp + row;
            const sb_cells = sb.getLine(sb_line_idx);
            for (0..cols) |col| {
                cells[row * cols + col] = cellToAttyxCell(sb_cells[col], theme);
            }
            wrapped[row] = @intFromBool(sb.getLineWrapped(sb_line_idx));
        } else {
            const grid_row = row - effective_vp;
            for (0..cols) |col| {
                cells[row * cols + col] = cellToAttyxCell(eng.state.grid.cells[grid_row * cols + col], theme);
            }
            wrapped[row] = @intFromBool(eng.state.grid.row_wrapped[grid_row]);
        }
    }
}

/// Check if statusbar is active and enabled.
fn statusbarActive(ctx: *PtyThreadCtx) bool {
    const sb = ctx.statusbar orelse return false;
    return sb.config.enabled;
}

/// Centralized offset calculation for tab bar, search bar, and statusbar.
/// Resizes panes when the total consumed rows change.
pub fn updateGridOffsets(ctx: *PtyThreadCtx) void {
    const old_total = terminal.g_grid_top_offset + terminal.g_grid_bottom_offset;
    var top: i32 = 0;
    var bottom: i32 = 0;
    const sb_active = statusbarActive(ctx);
    if (sb_active) {
        if (ctx.statusbar.?.config.position == .top) {
            top += 1;
            terminal.g_statusbar_position = 0;
        } else {
            bottom += 1;
            terminal.g_statusbar_position = 1;
        }
        terminal.g_statusbar_visible = 1;
        terminal.g_tab_bar_visible = 0;
    } else {
        terminal.g_statusbar_visible = 0;
        if (ctx.tab_mgr.count > 1) top += 1;
        terminal.g_tab_bar_visible = if (ctx.tab_mgr.count > 1) @as(i32, 1) else @as(i32, 0);
    }
    if (@as(i32, @bitCast(c.g_search_active)) != 0) top += 1;
    terminal.g_grid_top_offset = top;
    terminal.g_grid_bottom_offset = bottom;
    @atomicStore(i32, &terminal.g_tab_count, @as(i32, ctx.tab_mgr.count), .seq_cst);
    const new_total = top + bottom;
    if (new_total != old_total and ctx.grid_rows > 0) {
        const pty_rows = @as(u16, @intCast(@max(1, @as(i32, ctx.grid_rows) - new_total)));
        ctx.tab_mgr.resizeAll(pty_rows, ctx.grid_cols);
    }
}
pub const updateGridTopOffset = updateGridOffsets;

/// Resolve a display title for each tab: prefer OSC title, fall back to
/// the foreground process name (e.g. "zsh", "vim").
pub fn resolveTabTitles(
    ctx: *PtyThreadCtx,
    titles: *tab_bar_mod.TabTitles,
    name_bufs: *[tab_bar_mod.max_tabs][256]u8,
) void {
    titles.* = .{null} ** tab_bar_mod.max_tabs;
    for (0..ctx.tab_mgr.count) |i| {
        const layout = &(ctx.tab_mgr.tabs[i] orelse continue);
        const pane = layout.focusedPane();
        if (pane.engine.state.title) |t| {
            titles[i] = t;
        } else {
            if (platform.getForegroundProcessName(pane.pty.master, &name_bufs[i])) |name| {
                titles[i] = name;
            }
        }
    }
}

/// Generate the tab bar overlay (only visible when count > 1 and statusbar is not active).
pub fn generateTabBar(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;

    // When statusbar is active, tabs are rendered inside the statusbar overlay
    if (statusbarActive(ctx)) {
        if (mgr.isVisible(.tab_bar)) mgr.hide(.tab_bar);
        return;
    }

    if (ctx.tab_mgr.count <= 1) {
        if (mgr.isVisible(.tab_bar)) {
            mgr.hide(.tab_bar);
        }
        return;
    }

    var titles: tab_bar_mod.TabTitles = undefined;
    var name_bufs: [tab_bar_mod.max_tabs][256]u8 = undefined;
    resolveTabTitles(ctx, &titles, &name_bufs);

    var tab_cells: [512]overlay_mod.OverlayCell = undefined;
    const result = tab_bar_mod.generate(
        &tab_cells,
        ctx.tab_mgr.count,
        ctx.tab_mgr.active,
        ctx.grid_cols,
        .{},
        &titles,
    ) orelse return;

    mgr.setContent(.tab_bar, 0, 0, result.width, result.height, result.cells) catch return;
    if (!mgr.isVisible(.tab_bar)) {
        mgr.show(.tab_bar);
    }
}

/// Generate the statusbar overlay.
pub fn generateStatusbar(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    const sb = ctx.statusbar orelse return;
    if (!sb.config.enabled) {
        if (mgr.isVisible(.statusbar)) mgr.hide(.statusbar);
        return;
    }
    var titles: tab_bar_mod.TabTitles = undefined;
    var name_bufs: [tab_bar_mod.max_tabs][256]u8 = undefined;
    resolveTabTitles(ctx, &titles, &name_bufs);

    var sb_cells: [512]overlay_mod.OverlayCell = undefined;
    const sb_style = statusbar_mod.Style{
        .bg = .{ .r = sb.config.background_r, .g = sb.config.background_g, .b = sb.config.background_b },
        .bg_alpha = sb.config.background_opacity,
    };
    const result = statusbar_mod.generate(&sb_cells, sb, ctx.tab_mgr.count, ctx.tab_mgr.active, ctx.grid_cols, sb_style, &titles) orelse return;
    const row: u16 = if (sb.config.position == .top) 0 else ctx.grid_rows -| 1;
    mgr.setContent(.statusbar, 0, row, result.width, result.height, result.cells) catch return;
    if (!mgr.isVisible(.statusbar)) mgr.show(.statusbar);
}
