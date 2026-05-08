const std = @import("std");
const attyx = @import("attyx");
const Engine = attyx.Engine;
const color_mod = attyx.render_color;
const overlay_mod = attyx.overlay_mod;
const overlay_layout = attyx.overlay_layout;
const overlay_anchor = attyx.overlay_anchor;
const OverlayManager = overlay_mod.OverlayManager;
const tab_bar_mod = @import("../tab_bar.zig");
const agent_status_mod = @import("../agent_status.zig");
const statusbar_mod = @import("../statusbar.zig");
const split_render = @import("../split_render.zig");
const logging = @import("../../logging/log.zig");
const platform = @import("../../platform/platform.zig");
const Pty = @import("../pty.zig").Pty;
const AppConfig = @import("../../config/config.zig").AppConfig;
const CursorShapeConfig = @import("../../config/config.zig").CursorShapeConfig;

const builtin = @import("builtin");
const terminal = if (builtin.os.tag != .windows) @import("../terminal.zig") else struct {};
const PtyThreadCtx = if (builtin.os.tag != .windows) terminal.PtyThreadCtx else void;
pub const Theme = @import("../../theme/registry.zig").Theme;
pub const c = @cImport({
    @cInclude("bridge.h");
});

const overlay_ui = attyx.overlay_ui;

// Shared anchor demo mode counter (persists across calls).
pub var g_anchor_mode_counter: u8 = 0;

// Last hash of statusbar cells — skip overlay update when unchanged.
var last_statusbar_hash: u64 = 0;

fn hashStatusbarCells(cells: []const overlay_mod.StyledCell) u64 {
    const bytes = std.mem.sliceAsBytes(cells);
    return std.hash.Wyhash.hash(0, bytes);
}

/// Derive overlay panel theme from the active terminal theme.
pub fn overlayThemeFromTheme(theme: *const Theme) overlay_ui.OverlayTheme {
    const bg = theme.background;
    const fg = theme.foreground;
    // Border: blend fg toward bg
    const bdr = @as(u8, @intCast((@as(u16, bg.r) * 2 + @as(u16, fg.r)) / 3));
    const bdg = @as(u8, @intCast((@as(u16, bg.g) * 2 + @as(u16, fg.g)) / 3));
    const bdb = @as(u8, @intCast((@as(u16, bg.b) * 2 + @as(u16, fg.b)) / 3));
    // Selection: blend fg toward bg more
    const sr = @as(u8, @intCast((@as(u16, bg.r) + @as(u16, fg.r)) / 2));
    const sg = @as(u8, @intCast((@as(u16, bg.g) + @as(u16, fg.g)) / 2));
    const sb_c = @as(u8, @intCast((@as(u16, bg.b) + @as(u16, fg.b)) / 2));
    // Hint: dimmed fg
    const hr = @as(u8, @intCast((@as(u16, bg.r) + @as(u16, fg.r)) / 2));
    const hg = @as(u8, @intCast((@as(u16, bg.g) + @as(u16, fg.g)) / 2));
    const hb = @as(u8, @intCast((@as(u16, bg.b) + @as(u16, fg.b)) / 2));
    return .{
        .fg = .{ .r = fg.r, .g = fg.g, .b = fg.b },
        .bg = .{ .r = bg.r, .g = bg.g, .b = bg.b },
        .bg_alpha = 230,
        .border_color = .{ .r = bdr, .g = bdg, .b = bdb },
        .cursor_fg = .{ .r = bg.r, .g = bg.g, .b = bg.b },
        .cursor_bg = .{ .r = fg.r, .g = fg.g, .b = fg.b },
        .selected_bg = .{ .r = sr, .g = sg, .b = sb_c },
        .selected_fg = .{ .r = fg.r, .g = fg.g, .b = fg.b },
        .hint_fg = .{ .r = hr, .g = hg, .b = hb },
    };
}

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
    c.g_default_font_size = @intCast(config.font_size);
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

/// Scan the screen for the first U+10EEEE placeholder cell whose fg color encodes the given image_id.
fn findPlaceholderPosition(ring: anytype, image_id: u32) ?struct { row: i32, col: i32 } {
    const rows: usize = ring.screen_rows;
    const cols: usize = ring.cols;
    for (0..rows) |r| {
        const row_cells = ring.getScreenRow(r);
        for (0..cols) |co| {
            const cell = row_cells[co];
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
    const visible = store.visiblePlacements(state.ring.screen_rows, &buf);

    var out_count: c_int = 0;
    for (visible) |p| {
        if (out_count >= c.ATTYX_MAX_IMAGE_PLACEMENTS) break;

        const img = store.getImage(p.image_id) orelse continue;
        const idx: usize = @intCast(out_count);

        // For virtual placements, derive position from grid placeholder cells.
        var row = p.row;
        var col = p.col;
        if (p.virtual) {
            if (findPlaceholderPosition(&state.ring, p.image_id)) |pos| {
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
                .combining = .{ cells[ci].combining[0], cells[ci].combining[1] },
                .fg_r = cells[ci].fg.r,
                .fg_g = cells[ci].fg.g,
                .fg_b = cells[ci].fg.b,
                .bg_r = cells[ci].bg.r,
                .bg_g = cells[ci].bg.g,
                .bg_b = cells[ci].bg.b,
                .bg_alpha = cells[ci].bg_alpha,
                .flags = cells[ci].flags,
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
            .backdrop_alpha = @intCast(layer.backdrop_alpha),
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
    const cols: u16 = @intCast(eng.state.ring.cols);
    const rows: u16 = @intCast(eng.state.ring.screen_rows);

    // Format debug info lines
    var grid_buf: [32]u8 = undefined;
    var vp_buf: [32]u8 = undefined;
    var sb_buf: [32]u8 = undefined;
    var cur_buf: [32]u8 = undefined;
    var alt_buf: [32]u8 = undefined;

    const grid_line = std.fmt.bufPrint(&grid_buf, "Grid: {d}x{d}", .{ cols, rows }) catch "Grid: ?";
    const vp_line = std.fmt.bufPrint(&vp_buf, "Viewport: {d}", .{eng.state.viewport_offset}) catch "Viewport: ?";
    const sb_line = std.fmt.bufPrint(&sb_buf, "Scrollback: {d}", .{eng.state.ring.scrollbackCount()}) catch "Scrollback: ?";
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

    // Pane offset converts pane-relative placement to window-absolute coords.
    const layout = ctx.tab_mgr.activeLayout();
    const in_split = layout.pane_count > 1 and !layout.isZoomed();
    const pane_row: u16 = if (in_split) @intCast(layout.pool[layout.focused].rect.row) else 0;
    const pane_col: u16 = if (in_split) @intCast(layout.pool[layout.focused].rect.col) else 0;
    const top_offset: u16 = @intCast(terminal.g_grid_top_offset);
    const left_offset: u16 = @intCast(terminal.g_grid_left_offset);

    return .{
        .grid_cols = @intCast(eng.state.ring.cols),
        .grid_rows = @intCast(eng.state.ring.screen_rows),
        .cursor_row = @intCast(eng.state.cursor.row),
        .cursor_col = @intCast(eng.state.cursor.col),
        .sel_active = sel_active_raw != 0,
        .sel_end_row = if (sel_end_row_raw >= 0) @intCast(@as(u32, @bitCast(sel_end_row_raw))) else 0,
        .sel_end_col = if (sel_end_col_raw >= 0) @intCast(@as(u32, @bitCast(sel_end_col_raw))) else 0,
        .alt_active = eng.state.alt_active,
        .offset_row = pane_row + top_offset,
        .offset_col = pane_col + left_offset,
    };
}

/// Build a ViewportInfo anchored to a specific pane within the active tab.
/// Returns null if the pane is not present in the active tab's layout — the
/// caller should hide any overlay keyed to that pane.
pub fn viewportInfoForPane(ctx: *PtyThreadCtx, pane_id: u32) ?overlay_anchor.ViewportInfo {
    if (pane_id == 0) return null;
    const layout = ctx.tab_mgr.activeLayout();
    const split_layout_mod = @import("../split_layout.zig");
    var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
    const n = layout.collectLeaves(&leaves);
    var pool_idx: ?u8 = null;
    var pane_ptr: ?*@import("../pane.zig").Pane = null;
    for (leaves[0..n]) |leaf| {
        if (leaf.pane.ipc_id == pane_id) {
            pool_idx = leaf.index;
            pane_ptr = leaf.pane;
            break;
        }
    }
    const idx = pool_idx orelse return null;
    const pane = pane_ptr orelse return null;

    const in_split = layout.pane_count > 1 and !layout.isZoomed();
    const pane_row: u16 = if (in_split) @intCast(layout.pool[idx].rect.row) else 0;
    const pane_col: u16 = if (in_split) @intCast(layout.pool[idx].rect.col) else 0;
    const top_offset: u16 = @intCast(terminal.g_grid_top_offset);
    const left_offset: u16 = @intCast(terminal.g_grid_left_offset);

    const st = &pane.engine.state;
    return .{
        .grid_cols = @intCast(st.ring.cols),
        .grid_rows = @intCast(st.ring.screen_rows),
        .cursor_row = @intCast(st.cursor.row),
        .cursor_col = @intCast(st.cursor.col),
        .sel_active = false,
        .sel_end_row = 0,
        .sel_end_col = 0,
        .alt_active = st.alt_active,
        .offset_row = pane_row + top_offset,
        .offset_col = pane_col + left_offset,
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
    c.g_scrollback_count = @intCast(ctxEngine(ctx).state.ring.scrollbackCount());
    c.g_alt_screen = @intFromBool(ctxEngine(ctx).state.alt_active);

    c.g_cursor_shape = @intFromEnum(ctxEngine(ctx).state.cursor_shape);
    c.g_cursor_visible = @intFromBool(ctxEngine(ctx).state.cursor_visible);
    terminal.g_kitty_kbd_flags = @intCast(ctxEngine(ctx).state.kittyFlags());

    // Window title: prefer OSC 0/2 title from the shell; fall back to the
    // foreground process name (e.g. "zsh", "vim") so the title bar is useful
    // even when the shell doesn't send title sequences.
    const win_title: ?[]const u8 = ctxEngine(ctx).state.title orelse blk: {
        var name_buf: [256]u8 = undefined;
        const pane = ctx.tab_mgr.activePane();
        if (platform.getForegroundProcessName(ctxPty(ctx).master, &name_buf)) |name|
            break :blk name;
        break :blk pane.getDaemonProcName();
    };
    if (win_title) |title| {
        const len: usize = @min(title.len, c.ATTYX_TITLE_MAX - 1);
        const cur_len: usize = @intCast(c.g_title_len);
        const same = (len == cur_len) and std.mem.eql(u8, c.g_title_buf[0..cur_len], title[0..len]);
        if (!same) {
            @memcpy(c.g_title_buf[0..len], title[0..len]);
            c.g_title_buf[len] = 0;
            c.g_title_len = @intCast(len);
            c.g_title_changed = 1;
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
    c.g_theme_bg_r = @intCast(theme.background.r);
    c.g_theme_bg_g = @intCast(theme.background.g);
    c.g_theme_bg_b = @intCast(theme.background.b);
}

/// Convert a Theme to ThemeColors for OSC 10/11/12/4 query responses.
pub fn themeToEngineColors(theme: *const Theme) attyx.ThemeColors {
    var tc: attyx.ThemeColors = .{
        .fg = .{ .r = theme.foreground.r, .g = theme.foreground.g, .b = theme.foreground.b },
        .bg = .{ .r = theme.background.r, .g = theme.background.g, .b = theme.background.b },
    };
    if (theme.cursor) |cur| {
        tc.cursor = .{ .r = cur.r, .g = cur.g, .b = cur.b };
    }
    for (theme.palette, 0..) |opt, i| {
        if (opt) |p| {
            tc.palette[i] = .{ .r = p.r, .g = p.g, .b = p.b };
        }
    }
    return tc;
}

/// Push theme colors to the daemon so it can respond to OSC 10/11/12 queries directly.
pub fn publishThemeToDaemon(ctx: *PtyThreadCtx) void {
    const sc = ctx.session_client orelse return;
    if (sc.legacy_daemon) return;
    const theme = &ctx.active_theme;
    const cursor_set = theme.cursor != null;
    const cursor_rgb = if (theme.cursor) |cur| [3]u8{ cur.r, cur.g, cur.b } else [3]u8{ 0, 0, 0 };
    sc.sendThemeColors(
        .{ theme.foreground.r, theme.foreground.g, theme.foreground.b },
        .{ theme.background.r, theme.background.g, theme.background.b },
        cursor_set,
        cursor_rgb,
    ) catch {};
}

/// Push theme colors to all pane engines across all tabs (+ popup).
pub fn publishThemeToEngines(ctx: *PtyThreadCtx) void {
    const tc = themeToEngineColors(&ctx.active_theme);
    const tab_mgr = ctx.tab_mgr;
    for (&tab_mgr.tabs) |*slot| {
        if (slot.*) |*layout| {
            for (&layout.pool) |*node| {
                if (node.tag == .leaf) {
                    if (node.pane) |pane| {
                        pane.engine.state.theme_colors = tc;
                    }
                }
            }
        }
    }
    if (ctx.popup_state) |ps| {
        ps.pane.engine.state.theme_colors = tc;
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
        .palette => |n| {
            // SGR 38;5;N for indices 0-15 should also use theme palette.
            // Many TUI frameworks (crossterm/ratatui) emit 38;5;N even for
            // basic ANSI colors, producing .palette instead of .ansi.
            if (n < 16) {
                if (theme.palette[n]) |p| return .{ .r = p.r, .g = p.g, .b = p.b };
            }
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

const DirtyRows = attyx.DirtyRows;

pub fn fillCells(cells: []c.AttyxCell, eng: *Engine, _: usize, theme: *const Theme, dirty: ?*const DirtyRows) void {
    fillCellsStride(cells, eng, theme, @intCast(eng.state.ring.cols), dirty);
}

/// Write the engine's visible viewport into `cells` using `stride` as the
/// row stride.  Callers that compose into the live render buffer must pass
/// `g_cols` (== ctx.grid_cols) so the renderer's row indexing matches.
/// Cells past `eng.cols` in each row are left untouched — the caller is
/// responsible for pre-clearing them to the desired background.
pub fn fillCellsStride(
    cells: []c.AttyxCell,
    eng: *Engine,
    theme: *const Theme,
    stride: u16,
    dirty: ?*const DirtyRows,
) void {
    fillCellsStrideAt(cells, eng, theme, stride, 0, dirty);
}

/// Like `fillCellsStride`, but writes engine cells starting at column
/// `col_offset` within each buffer row. Used when vertical side tabs
/// reserve the leftmost N columns of the displayed grid.
pub fn fillCellsStrideAt(
    cells: []c.AttyxCell,
    eng: *Engine,
    theme: *const Theme,
    stride: u16,
    col_offset: u16,
    dirty: ?*const DirtyRows,
) void {
    const vp = eng.state.viewport_offset;
    const cols = eng.state.ring.cols;
    const wrapped: *volatile [c.ATTYX_MAX_ROWS]u8 = @ptrCast(&c.g_row_wrapped);
    const stride_usize: usize = stride;
    const off: usize = col_offset;
    const remaining: usize = if (off >= stride_usize) 0 else stride_usize - off;
    const cols_to_copy = @min(@as(usize, cols), remaining);
    const max_rows = if (stride_usize > 0) cells.len / stride_usize else 0;
    const rows = @min(eng.state.ring.screen_rows, max_rows);

    for (0..rows) |row| {
        const row_cells = eng.state.ring.viewportRow(vp, row);
        wrapped[row] = @intFromBool(eng.state.ring.viewportRowWrapped(vp, row));
        if (dirty) |d| {
            if (!d.isDirty(row)) continue;
        }
        const base = row * stride_usize + off;
        for (0..cols_to_copy) |col| {
            cells[base + col] = cellToAttyxCell(row_cells[col], theme);
        }
    }
}

pub fn bgCell(theme: *const Theme) c.AttyxCell {
    const bg = theme.background;
    return .{
        .character = ' ',
        .combining = .{ 0, 0 },
        .fg_r = bg.r,
        .fg_g = bg.g,
        .fg_b = bg.b,
        .bg_r = bg.r,
        .bg_g = bg.g,
        .bg_b = bg.b,
        .flags = 4,
        .link_id = 0,
    };
}

/// Check if statusbar is active and enabled.
pub fn statusbarActive(ctx: *PtyThreadCtx) bool {
    const sb = ctx.statusbar orelse return false;
    return sb.config.enabled;
}

/// Centralized offset calculation for tab bar, search bar, and statusbar.
/// Resizes panes when the total consumed rows or columns change.
pub fn updateGridOffsets(ctx: *PtyThreadCtx) void {
    const old_top = terminal.g_grid_top_offset;
    const old_bottom = terminal.g_grid_bottom_offset;
    const old_left = terminal.g_grid_left_offset;
    const old_right = terminal.g_grid_right_offset;
    var top: i32 = 0;
    var bottom: i32 = 0;
    var left: i32 = 0;
    var right: i32 = 0;
    const sb_active = statusbarActive(ctx);
    const native_tabs = (terminal.g_native_tabs_enabled != 0);
    const always_show = (terminal.g_tab_always_show != 0);
    const search_active = (@as(i32, @bitCast(c.g_search_active)) != 0);
    const tab_side = terminal.g_tab_side; // 0=top, 1=left, 2=right
    const side_active = !native_tabs and tab_side != 0;

    // Side tab bar: reserves left/right columns whenever configured.
    // Persistent reservation (no flicker) — user opted in by setting tabs.side.
    if (side_active and ctx.grid_cols > 0) {
        const req: u16 = @intCast(@max(0, terminal.g_tab_side_width));
        const w: i32 = @intCast(tab_bar_mod.sideBarWidthRequested(ctx.grid_cols, req));
        if (tab_side == 1) left = w else right = w;
    }

    // Bottom row: statusbar at bottom (unaffected by search)
    if (sb_active) {
        if (ctx.statusbar.?.config.position == .top) {
            terminal.g_statusbar_position = 0;
        } else {
            terminal.g_statusbar_position = 1;
            bottom += 1;
        }
        terminal.g_statusbar_visible = 1;
        terminal.g_tab_bar_visible = 0;
    } else {
        terminal.g_statusbar_visible = 0;
    }

    // Top row: search > statusbar-top > horizontal tab bar (mutually exclusive).
    // When side tabs are active, the top horizontal tab bar is suppressed.
    if (search_active) {
        top += 1;
        terminal.g_tab_bar_visible = 0;
    } else if (sb_active and ctx.statusbar.?.config.position == .top) {
        top += 1;
        // tab_bar_visible already 0 from above
    } else if (!sb_active and !native_tabs and !side_active) {
        const show_builtin = (ctx.tab_mgr.count > 1) or always_show;
        if (show_builtin) top += 1;
        terminal.g_tab_bar_visible = if (show_builtin) @as(i32, 1) else @as(i32, 0);
    } else {
        terminal.g_tab_bar_visible = 0;
    }
    terminal.g_grid_top_offset = top;
    terminal.g_grid_bottom_offset = bottom;
    terminal.g_grid_left_offset = left;
    terminal.g_grid_right_offset = right;
    @atomicStore(i32, &terminal.g_tab_count, @as(i32, ctx.tab_mgr.count), .seq_cst);

    const changed = (top != old_top) or (bottom != old_bottom) or
        (left != old_left) or (right != old_right);
    if (changed and ctx.grid_rows > 0 and ctx.grid_cols > 0) {
        const pty_rows = @as(u16, @intCast(@max(1, @as(i32, ctx.grid_rows) - top - bottom)));
        const pty_cols = @as(u16, @intCast(@max(1, @as(i32, ctx.grid_cols) - left - right)));
        ctx.tab_mgr.resizeAll(pty_rows, pty_cols);
        // Layout changed — force a full-buffer recompose so the gutter
        // columns get refilled with bg cells before the side tab overlay
        // paints on top.
        @import("actions.zig").g_force_full_redraw = true;
    }
}
pub const updateGridTopOffset = updateGridOffsets;

/// Resolve a display title for each tab: prefer an explicit tab title, then
/// fall back to the focused pane's OSC title / process name chain.
fn resolveTabTitlesInternal(
    ctx: *PtyThreadCtx,
    titles: *tab_bar_mod.TabTitles,
    statuses: ?*tab_bar_mod.AgentStatuses,
    name_bufs: *[tab_bar_mod.max_tabs][256]u8,
) void {
    titles.* = .{null} ** tab_bar_mod.max_tabs;
    if (statuses) |status_buf| status_buf.* = .{.none} ** tab_bar_mod.max_tabs;
    for (0..ctx.tab_mgr.count) |i| {
        const layout = &(ctx.tab_mgr.tabs[i] orelse continue);
        const pane = layout.focusedPane();
        const daemon_name = pane.getDaemonProcName();
        var proc_name: ?[]const u8 = null;
        if (layout.getTitle()) |title| {
            titles[i] = title;
        } else if (pane.engine.state.title) |t| {
            titles[i] = t;
        } else if (daemon_name) |name| {
            titles[i] = name;
        } else if (platform.getForegroundProcessName(pane.pty.master, &name_bufs[i])) |name| {
            titles[i] = name;
            proc_name = name;
        } else {
            titles[i] = layout.getHintTitle();
        }

        if (statuses != null and proc_name == null and agent_status_mod.shouldQueryProcessName(titles[i], pane.engine.state.title, daemon_name)) {
            proc_name = platform.getForegroundProcessName(pane.pty.master, &name_bufs[i]);
        }
        if (statuses) |status_buf| {
            status_buf[i] = agent_status_mod.detectPaneStatus(pane, titles[i], proc_name);
        }
    }
}

pub fn resolveTabTitles(
    ctx: *PtyThreadCtx,
    titles: *tab_bar_mod.TabTitles,
    statuses: *tab_bar_mod.AgentStatuses,
    name_bufs: *[tab_bar_mod.max_tabs][256]u8,
) void {
    resolveTabTitlesInternal(ctx, titles, statuses, name_bufs);
}

pub fn resolveTabTitlesOnly(
    ctx: *PtyThreadCtx,
    titles: *tab_bar_mod.TabTitles,
    name_bufs: *[tab_bar_mod.max_tabs][256]u8,
) void {
    resolveTabTitlesInternal(ctx, titles, null, name_bufs);
}

/// Compute a bitmask of which tabs are currently zoomed.
fn computeZoomedTabs(ctx: *PtyThreadCtx) u16 {
    var mask: u16 = 0;
    for (0..ctx.tab_mgr.count) |i| {
        const layout = &(ctx.tab_mgr.tabs[i] orelse continue);
        if (layout.isZoomed()) mask |= @as(u16, 1) << @intCast(i);
    }
    return mask;
}

/// Generate the tab bar overlay (horizontal on top by default, vertical on
/// the side when `tabs.side` is configured).
pub fn generateTabBar(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;

    // Native tabs: overlay tab bar is never shown
    if (terminal.g_native_tabs_enabled != 0) {
        if (mgr.isVisible(.tab_bar)) mgr.hide(.tab_bar);
        return;
    }

    const tab_side = terminal.g_tab_side; // 0=top, 1=left, 2=right
    const side_active = (tab_side != 0);

    // Horizontal tab bar yields to statusbar / search; the vertical side
    // tab bar coexists with both — it lives outside the top/bottom area.
    if (!side_active) {
        if (statusbarActive(ctx)) {
            if (mgr.isVisible(.tab_bar)) mgr.hide(.tab_bar);
            return;
        }
        if (@as(i32, @bitCast(c.g_search_active)) != 0) {
            if (mgr.isVisible(.tab_bar)) mgr.hide(.tab_bar);
            return;
        }
    }

    const always_show = (terminal.g_tab_always_show != 0);
    if (!side_active and ctx.tab_mgr.count <= 1 and !always_show) {
        if (mgr.isVisible(.tab_bar)) {
            mgr.hide(.tab_bar);
        }
        return;
    }

    var titles: tab_bar_mod.TabTitles = undefined;
    var statuses: tab_bar_mod.AgentStatuses = undefined;
    var name_bufs: [tab_bar_mod.max_tabs][256]u8 = undefined;
    resolveTabTitles(ctx, &titles, &statuses, &name_bufs);

    const zoomed_tabs = computeZoomedTabs(ctx);
    const tbg = ctx.active_theme.background;
    const tfg = ctx.active_theme.foreground;
    // Mix helpers: blend bg toward fg for subtle contrast
    const mix20 = struct {
        fn m(bg_c: u8, fg_c: u8) u8 {
            return @intCast((@as(u16, bg_c) * 4 + @as(u16, fg_c)) / 5);
        }
    }.m;
    const mix35 = struct {
        fn m(bg_c: u8, fg_c: u8) u8 {
            return @intCast((@as(u16, bg_c) * 13 + @as(u16, fg_c) * 7) / 20);
        }
    }.m;
    // Dim border for the side bar separator: blend bg ~85% toward fg for a
    // subtle line that's visible but not distracting.
    const mix_border = struct {
        fn m(bg_c: u8, fg_c: u8) u8 {
            return @intCast((@as(u16, bg_c) * 17 + @as(u16, fg_c) * 3) / 20);
        }
    }.m;
    const tab_style = tab_bar_mod.Style{
        .tab_bg = .{ .r = mix20(tbg.r, tfg.r), .g = mix20(tbg.g, tfg.g), .b = mix20(tbg.b, tfg.b) },
        .active_tab_bg = .{ .r = mix35(tbg.r, tfg.r), .g = mix35(tbg.g, tfg.g), .b = mix35(tbg.b, tfg.b) },
        .fg = .{ .r = tfg.r, .g = tfg.g, .b = tfg.b },
        .active_fg = .{ .r = tfg.r, .g = tfg.g, .b = tfg.b },
        .num_highlight_bg = .{ .r = tfg.r / 2, .g = tfg.g / 2, .b = tfg.b / 2 },
        .num_highlight_fg = .{ .r = tfg.r, .g = tfg.g, .b = tfg.b },
        .border_fg = .{ .r = mix_border(tbg.r, tfg.r), .g = mix_border(tbg.g, tfg.g), .b = mix_border(tbg.b, tfg.b) },
        // Side tabs sit on the reserved gutter and should be fully opaque so
        // nothing bleeds through; the horizontal bar keeps the historical 230.
        .bg_alpha = if (side_active) @as(u8, 255) else @as(u8, 230),
    };

    if (side_active) {
        const req_w: u16 = @intCast(@max(0, terminal.g_tab_side_width));
        const width: u16 = tab_bar_mod.sideBarWidthRequested(ctx.grid_cols, req_w);
        if (width == 0 or ctx.grid_rows == 0) {
            if (mgr.isVisible(.tab_bar)) mgr.hide(.tab_bar);
            return;
        }
        // Side bar spans the full window height. The statusbar and search
        // bar yield their sidebar columns so the bar runs uninterrupted from
        // the very top to the very bottom.
        const max_cells: usize = @intCast(c.ATTYX_OVERLAY_MAX_CELLS);
        var v_cells: [c.ATTYX_OVERLAY_MAX_CELLS]overlay_mod.StyledCell = undefined;
        const max_h_for_buf: u16 = @intCast(max_cells / @as(usize, width));
        const height: u16 = @min(ctx.grid_rows, max_h_for_buf);
        const left_side = (tab_side == 1);
        const result = tab_bar_mod.generateVertical(
            v_cells[0 .. @as(usize, width) * @as(usize, height)],
            ctx.tab_mgr.count,
            ctx.tab_mgr.active,
            width,
            height,
            tab_style,
            &titles,
            zoomed_tabs,
            &statuses,
            left_side, // border on right edge for left-side bars
        ) orelse return;
        const place_col: u16 = if (left_side) 0 else ctx.grid_cols -| width;
        mgr.setContent(.tab_bar, place_col, 0, result.width, result.height, result.cells) catch return;
        if (!mgr.isVisible(.tab_bar)) mgr.show(.tab_bar);
        return;
    }

    var tab_cells: [512]overlay_mod.StyledCell = undefined;
    const result = tab_bar_mod.generate(
        &tab_cells,
        ctx.tab_mgr.count,
        ctx.tab_mgr.active,
        ctx.grid_cols,
        tab_style,
        &titles,
        zoomed_tabs,
        &statuses,
    ) orelse return;

    mgr.setContent(.tab_bar, 0, 0, result.width, result.height, result.cells) catch return;
    if (!mgr.isVisible(.tab_bar)) {
        mgr.show(.tab_bar);
    }
}

/// Publish per-tab titles to the native tab bridge globals.
/// Called when native tabs are enabled after tab switches and data updates.
pub fn publishNativeTabTitles(ctx: *PtyThreadCtx) void {
    if (terminal.g_native_tabs_enabled == 0) return;

    var titles: tab_bar_mod.TabTitles = undefined;
    var statuses: tab_bar_mod.AgentStatuses = undefined;
    var name_bufs: [tab_bar_mod.max_tabs][256]u8 = undefined;
    resolveTabTitles(ctx, &titles, &statuses, &name_bufs);

    const max_native = 16;
    const count = @min(ctx.tab_mgr.count, max_native);
    for (0..count) |i| {
        const title = titles[i] orelse "shell";
        const len = @min(title.len, c.ATTYX_NATIVE_TAB_TITLE_MAX - 1);
        const dst: [*]u8 = @ptrCast(@volatileCast(&c.g_native_tab_titles[i]));
        @memcpy(dst[0..len], title[0..len]);
        dst[len] = 0;
    }
    @atomicStore(i32, &terminal.g_native_tab_count, @as(i32, ctx.tab_mgr.count), .seq_cst);
    @atomicStore(i32, &terminal.g_native_tab_active, @as(i32, ctx.tab_mgr.active), .seq_cst);
    @atomicStore(i32, &terminal.g_native_tab_titles_changed, 1, .seq_cst);
}

/// Generate the statusbar overlay.
pub fn generateStatusbar(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    const sb = ctx.statusbar orelse return;
    if (!sb.config.enabled) {
        if (mgr.isVisible(.statusbar)) mgr.hide(.statusbar);
        return;
    }
    // Search takes priority for the top row — yield while it's active
    if (@as(i32, @bitCast(c.g_search_active)) != 0 and sb.config.position == .top) {
        if (mgr.isVisible(.statusbar)) mgr.hide(.statusbar);
        return;
    }
    var titles: tab_bar_mod.TabTitles = undefined;
    var statuses: tab_bar_mod.AgentStatuses = undefined;
    var name_bufs: [tab_bar_mod.max_tabs][256]u8 = undefined;
    resolveTabTitles(ctx, &titles, &statuses, &name_bufs);

    var sb_cells: [512]overlay_mod.StyledCell = undefined;
    const theme_bg = ctx.active_theme.background;
    const theme_fg = ctx.active_theme.foreground;
    const sb_bg = if (ctx.active_theme.statusbar_background) |bg|
        overlay_mod.Rgb{ .r = bg.r, .g = bg.g, .b = bg.b }
    else
        overlay_mod.Rgb{ .r = theme_bg.r, .g = theme_bg.g, .b = theme_bg.b };
    // Tab bg: 20% toward foreground from statusbar bg (slightly lighter)
    // Active tab number: 35% toward foreground (noticeably lighter)
    const mix20 = struct {
        fn m(bg_c: u8, fg_c: u8) u8 {
            return @intCast((@as(u16, bg_c) * 4 + @as(u16, fg_c)) / 5);
        }
    }.m;
    const mix35 = struct {
        fn m(bg_c: u8, fg_c: u8) u8 {
            return @intCast((@as(u16, bg_c) * 13 + @as(u16, fg_c) * 7) / 20);
        }
    }.m;
    const sb_style = statusbar_mod.Style{
        .bg = sb_bg,
        .fg = .{ .r = theme_fg.r, .g = theme_fg.g, .b = theme_fg.b },
        .tab_bg = .{ .r = mix20(sb_bg.r, theme_fg.r), .g = mix20(sb_bg.g, theme_fg.g), .b = mix20(sb_bg.b, theme_fg.b) },
        .active_tab_bg = .{ .r = mix35(sb_bg.r, theme_fg.r), .g = mix35(sb_bg.g, theme_fg.g), .b = mix35(sb_bg.b, theme_fg.b) },
        .active_tab_fg = .{ .r = theme_fg.r, .g = theme_fg.g, .b = theme_fg.b },
        .bg_alpha = sb.config.background_opacity,
    };
    // When native tabs are active, hide the tab section in the statusbar.
    // When a side tab bar is active, the side bar runs full-height through
    // the statusbar's row, so the statusbar yields the sidebar columns and
    // only spans the remaining (PTY) columns.
    const side_active = (terminal.g_tab_side != 0);
    const sb_tab_count: u8 = if (terminal.g_native_tabs_enabled != 0 or side_active) 0 else ctx.tab_mgr.count;
    const zoomed_tabs = computeZoomedTabs(ctx);
    const left_off: u16 = @intCast(@max(0, terminal.g_grid_left_offset));
    const right_off: u16 = @intCast(@max(0, terminal.g_grid_right_offset));
    const sb_width: u16 = ctx.grid_cols -| left_off -| right_off;
    if (sb_width == 0) {
        if (mgr.isVisible(.statusbar)) mgr.hide(.statusbar);
        return;
    }
    const result = statusbar_mod.generate(&sb_cells, sb, sb_tab_count, ctx.tab_mgr.active, sb_width, sb_style, &titles, zoomed_tabs, &statuses) orelse return;

    // Skip overlay update if statusbar content hasn't changed.
    const cell_count = @as(usize, result.width) * @as(usize, result.height);
    const hash = hashStatusbarCells(result.cells[0..cell_count]);
    if (hash == last_statusbar_hash) return;
    last_statusbar_hash = hash;

    const row: u16 = if (sb.config.position == .top) 0 else ctx.grid_rows -| 1;
    mgr.setContent(.statusbar, left_off, row, result.width, result.height, result.cells) catch return;
    if (!mgr.isVisible(.statusbar)) mgr.show(.statusbar);
}
