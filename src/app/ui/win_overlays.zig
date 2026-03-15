/// Windows overlay integration — command palette, theme picker, session picker.
///
/// Mirrors command_palette_ui.zig and theme_picker_ui.zig but uses WinCtx
/// and windows_stubs.zig globals instead of PtyThreadCtx/terminal.zig.
const std = @import("std");
const builtin = @import("builtin");

const attyx = @import("attyx");
const overlay_mod = attyx.overlay_mod;
const OverlayManager = overlay_mod.OverlayManager;

const ws = @import("../windows_stubs.zig");
const publish = @import("publish.zig");
const c = publish.c;
const win_search = @import("win_search.zig");
const WinCtx = @import("event_loop_windows.zig").WinCtx;
const Theme = @import("../../theme/registry.zig").Theme;
const commands = @import("../../config/commands.zig");
const keybinds = @import("../../config/keybinds.zig");
const platform = @import("../../platform/platform.zig");
const toml_edit = @import("../../config/toml_edit.zig");
const win_session_picker = @import("win_session_picker.zig");
// Note: can't import actions.zig (depends on terminal.zig/POSIX).
// Use c.attyx_mark_all_dirty() directly for force-redraw instead.

// ── Pure state machines + renderers (cross-platform) ─────────────────
const palette_state_mod = attyx.overlay_command_palette;
const CommandPaletteState = palette_state_mod.CommandPaletteState;
const CommandEntry = palette_state_mod.CommandEntry;
const palette_panel = attyx.overlay_command_palette_panel;

const picker_state_mod = attyx.overlay_theme_picker;
const ThemePickerState = picker_state_mod.ThemePickerState;
const ThemeEntry = picker_state_mod.ThemeEntry;
const picker_panel = attyx.overlay_theme_picker_panel;

// =====================================================================
// Command Palette
// =====================================================================

var g_palette_state: ?CommandPaletteState = null;

pub fn openCommandPalette(ctx: *WinCtx) void {
    const panel_h = @as(u16, @intCast(@max(3, ctx.grid_rows))) / 2;
    const visible = if (panel_h > 4) @as(u8, @intCast(panel_h - 4)) else 3;

    var state = CommandPaletteState{};
    state.visible_rows = visible;

    var entry_idx: usize = 0;
    for (commands.registry) |cmd| {
        if (cmd.hidden) continue;
        if (entry_idx >= palette_state_mod.max_commands) break;
        var entry = CommandEntry{};
        entry.action_id = @intFromEnum(cmd.action);
        const nlen: u8 = @intCast(@min(cmd.name.len, 64));
        @memcpy(entry.name[0..nlen], cmd.name[0..nlen]);
        entry.name_len = nlen;
        const dlen: u8 = @intCast(@min(cmd.description.len, 80));
        @memcpy(entry.desc[0..dlen], cmd.description[0..dlen]);
        entry.desc_len = dlen;
        // Show Windows keybinds (same as Linux slot)
        if (keybinds.findComboForAction(cmd.action)) |combo| {
            entry.linux_hotkey_len = keybinds.formatKeyCombo(combo, &entry.linux_hotkey);
        }
        state.entries[entry_idx] = entry;
        entry_idx += 1;
    }
    state.entry_count = @intCast(entry_idx);
    state.applyFilter();

    g_palette_state = state;
    @atomicStore(i32, &ws.g_command_palette_active, 1, .seq_cst);

    paletteRenderAndPublish(ctx);
}

pub fn consumePaletteInput(ctx: *WinCtx) bool {
    var state = &(g_palette_state orelse return false);
    var consumed = false;

    while (true) {
        const r = @atomicLoad(u32, &ws.picker_char_read, .seq_cst);
        const w = @atomicLoad(u32, &ws.picker_char_write, .seq_cst);
        if (r == w) break;
        const cp = ws.picker_char_ring[r % 32];
        @atomicStore(u32, &ws.picker_char_read, r +% 1, .seq_cst);
        consumed = true;
        const action = state.handleChar(cp);
        if (processPaletteAction(ctx, action)) return true;
    }

    while (true) {
        const r = @atomicLoad(u32, &ws.picker_cmd_read, .seq_cst);
        const w = @atomicLoad(u32, &ws.picker_cmd_write, .seq_cst);
        if (r == w) break;
        const cmd = ws.picker_cmd_ring[r % 16];
        @atomicStore(u32, &ws.picker_cmd_read, r +% 1, .seq_cst);
        consumed = true;
        const action = state.handleCmd(cmd);
        if (processPaletteAction(ctx, action)) return true;
    }

    if (consumed) paletteRenderAndPublish(ctx);
    return consumed;
}

fn processPaletteAction(ctx: *WinCtx, action: palette_state_mod.PaletteAction) bool {
    switch (action) {
        .none => return false,
        .close => {
            closeCommandPalette(ctx);
            return true;
        },
        .execute => |action_id| {
            closeCommandPalette(ctx);
            _ = c.attyx_dispatch_action(action_id);
            return true;
        },
    }
}

pub fn closeCommandPalette(ctx: *WinCtx) void {
    g_palette_state = null;
    @atomicStore(i32, &ws.g_command_palette_active, 0, .seq_cst);
    if (ctx.overlay_mgr) |mgr| mgr.hide(.command_palette);
    win_search.publishOverlays(ctx);
}

fn paletteRenderAndPublish(ctx: *WinCtx) void {
    const state = &(g_palette_state orelse return);
    const mgr = ctx.overlay_mgr orelse return;

    const result = palette_panel.renderCommandPalette(
        ctx.allocator,
        state,
        ctx.grid_cols,
        ctx.grid_rows,
        publish.overlayThemeFromTheme(ctx.theme),
    ) catch return;

    if (result.width == 0 or result.height == 0) return;

    mgr.setContent(
        .command_palette,
        result.col,
        result.row,
        result.width,
        result.height,
        result.cells,
    ) catch {};
    mgr.show(.command_palette);
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.command_palette)].backdrop_alpha = 100;
    ctx.allocator.free(result.cells);

    win_search.publishOverlays(ctx);
}

pub fn paletteRelayout(ctx: *WinCtx) void {
    const state = &(g_palette_state orelse return);
    const mgr = ctx.overlay_mgr orelse return;

    const panel_h = @as(u16, @intCast(@max(3, ctx.grid_rows))) / 2;
    state.visible_rows = if (panel_h > 4) @as(u8, @intCast(panel_h - 4)) else 3;
    state.adjustScroll();

    const result = palette_panel.renderCommandPalette(
        ctx.allocator,
        state,
        ctx.grid_cols,
        ctx.grid_rows,
        publish.overlayThemeFromTheme(ctx.theme),
    ) catch return;

    if (result.width == 0 or result.height == 0) return;

    mgr.setContent(
        .command_palette,
        result.col,
        result.row,
        result.width,
        result.height,
        result.cells,
    ) catch {};
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.command_palette)].backdrop_alpha = 100;
    ctx.allocator.free(result.cells);
}

// =====================================================================
// Theme Picker
// =====================================================================

var g_picker_state: ?ThemePickerState = null;
var g_original_theme: ?Theme = null;
var g_name_slices: [picker_state_mod.max_themes]?[]const u8 = .{null} ** picker_state_mod.max_themes;
var g_name_count: u8 = 0;

pub fn openThemePicker(ctx: *WinCtx) void {
    // Close command palette if open (mutually exclusive)
    if (ws.g_command_palette_active != 0) closeCommandPalette(ctx);

    g_original_theme = ctx.theme.*;

    const panel_h = @as(u16, @intCast(@max(3, ctx.grid_rows))) / 2;
    const visible = if (panel_h > 4) @as(u8, @intCast(panel_h - 4)) else 3;

    var state = ThemePickerState{};
    state.visible_rows = visible;

    const registry = ctx.theme_registry;
    var it = registry.themes.iterator();
    var entry_idx: u8 = 0;
    freeNameSlices(ctx.allocator);

    while (it.next()) |kv| {
        if (entry_idx >= picker_state_mod.max_themes) break;
        const name = kv.key_ptr.*;
        const nlen: u8 = @intCast(@min(name.len, 64));
        var entry = ThemeEntry{};
        @memcpy(entry.name[0..nlen], name[0..nlen]);
        entry.name_len = nlen;
        state.entries[entry_idx] = entry;
        g_name_slices[entry_idx] = ctx.allocator.dupe(u8, name) catch null;
        entry_idx += 1;
    }
    state.entry_count = entry_idx;
    g_name_count = entry_idx;

    sortEntries(&state);
    state.applyFilter();

    g_picker_state = state;
    @atomicStore(i32, &ws.g_theme_picker_active, 1, .seq_cst);

    pickerRenderAndPublish(ctx);
}

pub fn consumePickerInput(ctx: *WinCtx) bool {
    var state = &(g_picker_state orelse return false);
    var consumed = false;

    while (true) {
        const r = @atomicLoad(u32, &ws.picker_char_read, .seq_cst);
        const w = @atomicLoad(u32, &ws.picker_char_write, .seq_cst);
        if (r == w) break;
        const cp = ws.picker_char_ring[r % 32];
        @atomicStore(u32, &ws.picker_char_read, r +% 1, .seq_cst);
        consumed = true;
        const action = state.handleChar(cp);
        if (processPickerAction(ctx, state, action)) return true;
    }

    while (true) {
        const r = @atomicLoad(u32, &ws.picker_cmd_read, .seq_cst);
        const w = @atomicLoad(u32, &ws.picker_cmd_write, .seq_cst);
        if (r == w) break;
        const cmd = ws.picker_cmd_ring[r % 16];
        @atomicStore(u32, &ws.picker_cmd_read, r +% 1, .seq_cst);
        consumed = true;
        const action = state.handleCmd(cmd);
        if (processPickerAction(ctx, state, action)) return true;
    }

    if (consumed) pickerRenderAndPublish(ctx);
    return consumed;
}

fn processPickerAction(ctx: *WinCtx, state: *const ThemePickerState, action: picker_state_mod.PickerAction) bool {
    switch (action) {
        .none => return false,
        .close => {
            if (g_original_theme) |orig| {
                ctx.theme.* = orig;
                publish.publishTheme(ctx.theme);
                publishThemeToEngines(ctx);
                c.attyx_mark_all_dirty();
                generateStatusbar(ctx);
                generateTabBar(ctx);
            }
            closeThemePicker(ctx);
            return true;
        },
        .preview => |idx| {
            applyThemePreview(ctx, state, idx);
            return false;
        },
        .select => |idx| {
            applyThemePreview(ctx, state, idx);
            const name = if (g_name_slices[idx]) |s| s else state.entries[idx].getName();
            writeThemeToConfig(ctx.allocator, name);
            closeThemePicker(ctx);
            return true;
        },
    }
}

fn applyThemePreview(ctx: *WinCtx, state: *const ThemePickerState, idx: u8) void {
    if (idx >= state.entry_count) return;
    const name = if (g_name_slices[idx]) |s| s else state.entries[idx].getName();
    if (ctx.theme_registry.get(name)) |theme| {
        ctx.theme.* = theme;
        publish.publishTheme(ctx.theme);
        publishThemeToEngines(ctx);
        c.attyx_mark_all_dirty();
        generateStatusbar(ctx);
        generateTabBar(ctx);
    }
}

pub fn closeThemePicker(ctx: *WinCtx) void {
    g_picker_state = null;
    g_original_theme = null;
    freeNameSlices(ctx.allocator);
    @atomicStore(i32, &ws.g_theme_picker_active, 0, .seq_cst);
    if (ctx.overlay_mgr) |mgr| mgr.hide(.theme_picker);
    win_search.publishOverlays(ctx);
}

fn freeNameSlices(allocator: std.mem.Allocator) void {
    for (0..g_name_count) |i| {
        if (g_name_slices[i]) |s| allocator.free(s);
        g_name_slices[i] = null;
    }
    g_name_count = 0;
}

fn pickerRenderAndPublish(ctx: *WinCtx) void {
    const state = &(g_picker_state orelse return);
    const mgr = ctx.overlay_mgr orelse return;

    const result = picker_panel.renderThemePicker(
        ctx.allocator,
        state,
        ctx.grid_cols,
        ctx.grid_rows,
        publish.overlayThemeFromTheme(ctx.theme),
    ) catch return;

    if (result.width == 0 or result.height == 0) return;

    mgr.setContent(
        .theme_picker,
        result.col,
        result.row,
        result.width,
        result.height,
        result.cells,
    ) catch {};
    mgr.show(.theme_picker);
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.theme_picker)].backdrop_alpha = 100;
    ctx.allocator.free(result.cells);

    win_search.publishOverlays(ctx);
}

pub fn pickerRelayout(ctx: *WinCtx) void {
    const state = &(g_picker_state orelse return);
    const mgr = ctx.overlay_mgr orelse return;

    const panel_h = @as(u16, @intCast(@max(3, ctx.grid_rows))) / 2;
    state.visible_rows = if (panel_h > 4) @as(u8, @intCast(panel_h - 4)) else 3;
    state.adjustScroll();

    const result = picker_panel.renderThemePicker(
        ctx.allocator,
        state,
        ctx.grid_cols,
        ctx.grid_rows,
        publish.overlayThemeFromTheme(ctx.theme),
    ) catch return;

    if (result.width == 0 or result.height == 0) return;

    mgr.setContent(
        .theme_picker,
        result.col,
        result.row,
        result.width,
        result.height,
        result.cells,
    ) catch {};
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.theme_picker)].backdrop_alpha = 100;
    ctx.allocator.free(result.cells);
}

// =====================================================================
// Helpers
// =====================================================================

/// Publish theme colors to all pane engines (Windows equivalent of
/// publish.publishThemeToEngines for PtyThreadCtx).
fn publishThemeToEngines(ctx: *WinCtx) void {
    const split_layout_mod = @import("../split_layout.zig");
    const theme_colors = publish.themeToEngineColors(ctx.theme);
    for (ctx.tab_mgr.tabs[0..ctx.tab_mgr.count]) |*maybe_layout| {
        const lay = &(maybe_layout.* orelse continue);
        var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
        const lc = lay.collectLeaves(&leaves);
        for (leaves[0..lc]) |leaf| {
            leaf.pane.engine.state.theme_colors = theme_colors;
            // Mark all rows dirty so fillCells re-resolves colors with new theme
            leaf.pane.engine.state.dirty.markAll(leaf.pane.engine.state.ring.screen_rows);
        }
    }
}

/// Forward to event_loop_windows generateStatusbar.
fn generateStatusbar(ctx: *WinCtx) void {
    const el = @import("event_loop_windows.zig");
    el.generateStatusbar(ctx);
}

/// Forward to event_loop_windows generateTabBar.
fn generateTabBar(ctx: *WinCtx) void {
    const el = @import("event_loop_windows.zig");
    el.generateTabBar(ctx);
}

/// Write theme name to config file.
fn writeThemeToConfig(allocator: std.mem.Allocator, name: []const u8) void {
    var paths = platform.getConfigPaths(allocator) catch return;
    defer paths.deinit();

    const sep: []const u8 = if (comptime builtin.os.tag == .windows) "\\" else "/";
    const config_path = std.fmt.allocPrint(allocator, "{s}{s}attyx.toml", .{ paths.config_dir, sep }) catch return;
    defer allocator.free(config_path);

    std.fs.makeDirAbsolute(paths.config_dir) catch |err| {
        if (err != error.PathAlreadyExists) return;
    };

    const existing = std.fs.cwd().readFileAlloc(allocator, config_path, 256 * 1024) catch
        allocator.alloc(u8, 0) catch return;
    defer allocator.free(existing);

    const new_val = std.fmt.allocPrint(allocator, "name = \"{s}\"", .{name}) catch return;
    defer allocator.free(new_val);

    const result = toml_edit.setSectionKey(allocator, existing, "theme", "name", new_val) catch return;
    defer allocator.free(result);

    var file = std.fs.cwd().createFile(config_path, .{}) catch return;
    defer file.close();
    file.writeAll(result) catch {};
}

fn sortEntries(state: *ThemePickerState) void {
    const n = state.entry_count;
    if (n <= 1) return;
    var i: u8 = 1;
    while (i < n) : (i += 1) {
        const tmp_entry = state.entries[i];
        const tmp_name = g_name_slices[i];
        var j: u8 = i;
        while (j > 0 and lessThan(&state.entries[j - 1], &tmp_entry)) {
            state.entries[j] = state.entries[j - 1];
            g_name_slices[j] = g_name_slices[j - 1];
            j -= 1;
        }
        state.entries[j] = tmp_entry;
        g_name_slices[j] = tmp_name;
    }
}

fn lessThan(a: *const ThemeEntry, b: *const ThemeEntry) bool {
    const an = a.getName();
    const bn = b.getName();
    const min_len = @min(an.len, bn.len);
    for (0..min_len) |k| {
        const ac = toLower(an[k]);
        const bc = toLower(bn[k]);
        if (ac != bc) return ac > bc;
    }
    return an.len > bn.len;
}

fn toLower(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

// =====================================================================
// Overlay dismiss — extended to handle command palette and theme picker
// =====================================================================

/// Process overlay dismiss (Esc). Checks command palette and theme picker
/// in addition to search (handled by win_search.processOverlayDismiss).
pub fn processOverlayDismiss(ctx: *WinCtx) void {
    if (@atomicRmw(i32, &ws.overlay_dismiss, .Xchg, 0, .seq_cst) == 0) return;

    // Search takes priority
    if (@as(i32, @bitCast(c.g_search_active)) != 0) {
        win_search.dismissSearch();
        return;
    }

    // Command palette
    // Session picker
    if (ws.g_session_picker_active != 0) {
        win_session_picker.close(ctx);
        return;
    }

    if (ws.g_command_palette_active != 0) {
        closeCommandPalette(ctx);
        return;
    }

    // Theme picker — revert to original
    if (ws.g_theme_picker_active != 0) {
        if (g_original_theme) |orig| {
            ctx.theme.* = orig;
            publish.publishTheme(ctx.theme);
            publishThemeToEngines(ctx);
            c.attyx_mark_all_dirty();
            generateStatusbar(ctx);
            generateTabBar(ctx);
        }
        closeThemePicker(ctx);
        return;
    }

    // Generic overlay dismiss
    if (ctx.overlay_mgr) |mgr| {
        if (mgr.dismissActive()) {
            win_search.publishOverlays(ctx);
        }
    }
}

// =====================================================================
// Toggle detection — called from event loop
// =====================================================================

pub fn processToggles(ctx: *WinCtx) void {
    if (@atomicRmw(i32, &ws.g_toggle_command_palette, .Xchg, 0, .seq_cst) != 0) {
        if (ws.g_command_palette_active != 0) {
            closeCommandPalette(ctx);
        } else {
            // Close theme picker if open (mutually exclusive)
            if (ws.g_theme_picker_active != 0) closeThemePicker(ctx);
            openCommandPalette(ctx);
        }
    }

    if (@atomicRmw(i32, &ws.g_toggle_session_switcher, .Xchg, 0, .seq_cst) != 0) {
        if (ws.g_session_picker_active != 0) {
            win_session_picker.close(ctx);
        } else {
            if (ws.g_command_palette_active != 0) closeCommandPalette(ctx);
            if (ws.g_theme_picker_active != 0) closeThemePicker(ctx);
            win_session_picker.openSessionPicker(ctx);
        }
    }

    if (@atomicRmw(i32, &ws.g_toggle_theme_picker, .Xchg, 0, .seq_cst) != 0) {
        if (ws.g_theme_picker_active != 0) {
            // Revert on toggle-off
            if (g_original_theme) |orig| {
                ctx.theme.* = orig;
                publish.publishTheme(ctx.theme);
                publishThemeToEngines(ctx);
                c.attyx_mark_all_dirty();
                generateStatusbar(ctx);
                generateTabBar(ctx);
            }
            closeThemePicker(ctx);
        } else {
            if (ws.g_command_palette_active != 0) closeCommandPalette(ctx);
            openThemePicker(ctx);
        }
    }
}

/// Returns true if any overlay input was consumed this tick.
pub fn processInput(ctx: *WinCtx) bool {
    if (ws.g_session_picker_active != 0) {
        return win_session_picker.consumeInput(ctx);
    }
    if (ws.g_command_palette_active != 0) {
        return consumePaletteInput(ctx);
    }
    if (ws.g_theme_picker_active != 0) {
        return consumePickerInput(ctx);
    }
    return false;
}
