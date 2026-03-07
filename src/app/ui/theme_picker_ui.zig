/// Theme picker UI integration — wires the overlay-based theme picker
/// state machine to the overlay manager, live preview, and config persistence.
const std = @import("std");

const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const c = terminal.c;
const publish = @import("publish.zig");
const input = @import("input.zig");
const actions = @import("actions.zig");
const command_palette_ui = @import("command_palette_ui.zig");
const session_picker_ui = @import("session_picker_ui.zig");
const platform = @import("../../platform/platform.zig");

const attyx = @import("attyx");
const picker_state_mod = attyx.overlay_theme_picker;
const ThemePickerState = picker_state_mod.ThemePickerState;
const ThemeEntry = picker_state_mod.ThemeEntry;
const picker_panel = attyx.overlay_theme_picker_panel;
const overlay_mod = attyx.overlay_mod;
const Theme = @import("../../theme/registry.zig").Theme;

var g_picker_state: ?ThemePickerState = null;
pub var g_original_theme: ?Theme = null;
/// Heap-duped name slices for entries (freed on close).
var g_name_slices: [picker_state_mod.max_themes]?[]const u8 = .{null} ** picker_state_mod.max_themes;
var g_name_count: u8 = 0;

pub fn openThemePicker(ctx: *PtyThreadCtx) void {
    // Close other modals
    if (terminal.g_command_palette_active != 0) command_palette_ui.closeCommandPalette(ctx);
    if (terminal.g_session_picker_active != 0) session_picker_ui.closeSessionPicker(ctx);

    // Save original theme for cancel/revert
    g_original_theme = ctx.active_theme;

    const panel_h = @as(u16, @intCast(@max(3, ctx.grid_rows))) / 2;
    const visible = if (panel_h > 4) @as(u8, @intCast(panel_h - 4)) else 3;

    var state = ThemePickerState{};
    state.visible_rows = visible;

    // Populate entries from theme registry
    const registry = ctx.theme_registry;
    var it = registry.themes.iterator();
    var entry_idx: u8 = 0;
    // Free any leftover name slices
    freeNameSlices(ctx.allocator);

    while (it.next()) |kv| {
        if (entry_idx >= picker_state_mod.max_themes) break;
        const name = kv.key_ptr.*;
        const nlen: u8 = @intCast(@min(name.len, 64));
        var entry = ThemeEntry{};
        @memcpy(entry.name[0..nlen], name[0..nlen]);
        entry.name_len = nlen;
        state.entries[entry_idx] = entry;

        // Keep a reference to the registry key for config writing
        g_name_slices[entry_idx] = ctx.allocator.dupe(u8, name) catch null;
        entry_idx += 1;
    }
    state.entry_count = entry_idx;
    g_name_count = entry_idx;

    // Sort entries alphabetically for a nice presentation
    sortEntries(&state);
    state.applyFilter();

    g_picker_state = state;
    @atomicStore(i32, &terminal.g_theme_picker_active, 1, .seq_cst);

    renderAndPublish(ctx);
}

fn sortEntries(state: *ThemePickerState) void {
    const n = state.entry_count;
    if (n <= 1) return;
    // Simple insertion sort — at most 64 entries
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

/// Drain picker input rings and process actions. Returns true if any input consumed.
pub fn consumePickerInput(ctx: *PtyThreadCtx) bool {
    var state = &(g_picker_state orelse return false);
    var consumed = false;

    // Drain char ring (shared with command palette / session picker)
    while (true) {
        const r = @atomicLoad(u32, &input.g_picker_char_read, .seq_cst);
        const w = @atomicLoad(u32, &input.g_picker_char_write, .seq_cst);
        if (r == w) break;
        const cp = input.g_picker_char_ring[r % 32];
        @atomicStore(u32, &input.g_picker_char_read, r +% 1, .seq_cst);
        consumed = true;

        const action = state.handleChar(cp);
        if (processAction(ctx, state, action)) return true;
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
        if (processAction(ctx, state, action)) return true;
    }

    if (consumed) renderAndPublish(ctx);
    return consumed;
}

fn processAction(ctx: *PtyThreadCtx, state: *const ThemePickerState, action: picker_state_mod.PickerAction) bool {
    switch (action) {
        .none => return false,
        .close => {
            // Revert to original theme
            if (g_original_theme) |orig| {
                ctx.active_theme = orig;
                publish.publishTheme(&ctx.active_theme);
                publish.publishThemeToEngines(ctx);
                actions.g_force_full_redraw = true;
                publish.generateStatusbar(ctx);
                publish.generateTabBar(ctx);
            }
            closeThemePicker(ctx);
            return true;
        },
        .preview => |idx| {
            applyThemePreview(ctx, state, idx);
            return false; // don't close — keep picking
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

fn applyThemePreview(ctx: *PtyThreadCtx, state: *const ThemePickerState, idx: u8) void {
    if (idx >= state.entry_count) return;
    const name = if (g_name_slices[idx]) |s| s else state.entries[idx].getName();
    if (ctx.theme_registry.get(name)) |theme| {
        ctx.active_theme = theme;
        publish.publishTheme(&ctx.active_theme);
        publish.publishThemeToEngines(ctx);
        // Force full redraw so all cells re-resolve with new theme colors
        actions.g_force_full_redraw = true;
        // Regenerate statusbar/tab bar with new theme colors
        publish.generateStatusbar(ctx);
        publish.generateTabBar(ctx);
    }
}

pub fn closeThemePicker(ctx: *PtyThreadCtx) void {
    g_picker_state = null;
    g_original_theme = null;
    freeNameSlices(ctx.allocator);
    @atomicStore(i32, &terminal.g_theme_picker_active, 0, .seq_cst);
    if (ctx.overlay_mgr) |mgr| mgr.hide(.theme_picker);
    publish.publishOverlays(ctx);
}

fn freeNameSlices(allocator: std.mem.Allocator) void {
    for (0..g_name_count) |i| {
        if (g_name_slices[i]) |s| allocator.free(s);
        g_name_slices[i] = null;
    }
    g_name_count = 0;
}

/// Write `[theme] / name = "value"` to the user's config file.
/// Preserves the existing file structure: replaces in-place if found, appends if not.
fn writeThemeToConfig(allocator: std.mem.Allocator, name: []const u8) void {
    var paths = platform.getConfigPaths(allocator) catch return;
    defer paths.deinit();

    const config_path = std.fmt.allocPrint(allocator, "{s}/attyx.toml", .{paths.config_dir}) catch return;
    defer allocator.free(config_path);

    // Ensure config dir exists
    std.fs.makeDirAbsolute(paths.config_dir) catch |err| {
        if (err != error.PathAlreadyExists) return;
    };

    // Read existing config (or start empty)
    const existing = std.fs.cwd().readFileAlloc(allocator, config_path, 256 * 1024) catch
        allocator.alloc(u8, 0) catch return;
    defer allocator.free(existing);

    const new_val = std.fmt.allocPrint(allocator, "name = \"{s}\"", .{name}) catch return;
    defer allocator.free(new_val);

    const result = setTomlSectionKey(allocator, existing, "theme", "name", new_val) catch return;
    defer allocator.free(result);

    var file = std.fs.cwd().createFile(config_path, .{}) catch return;
    defer file.close();
    file.writeAll(result) catch {};
}

/// Set a key within a TOML section, preserving file structure.
/// If `[section]` exists and contains `key = ...`, replace that line.
/// If `[section]` exists but has no `key`, insert the line after the section header.
/// If `[section]` doesn't exist, append `[section]\nnew_line\n`.
fn setTomlSectionKey(allocator: std.mem.Allocator, content: []const u8, section: []const u8, key: []const u8, new_line: []const u8) ![]u8 {
    // Parse line boundaries
    var section_header_end: ?usize = null; // byte offset after [section] header line (including \n)
    var key_line_start: ?usize = null;
    var key_line_end: usize = 0;
    var in_section = false;

    var start: usize = 0;
    while (start < content.len) {
        const rest = content[start..];
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const end = if (nl) |n| start + n else content.len;
        const line = content[start..end];
        const trimmed = std.mem.trimLeft(u8, line, " \t");

        // Check for section header [xxx]
        if (trimmed.len > 0 and trimmed[0] == '[') {
            const close = std.mem.indexOfScalar(u8, trimmed, ']');
            if (close) |ci| {
                const sec_name = std.mem.trim(u8, trimmed[1..ci], " \t");
                if (std.mem.eql(u8, sec_name, section)) {
                    in_section = true;
                    section_header_end = if (nl != null) end + 1 else end;
                } else {
                    in_section = false;
                }
            }
        } else if (in_section and key_line_start == null) {
            // Look for key = ... within the target section
            if (std.mem.startsWith(u8, trimmed, key)) {
                const after_key = trimmed[key.len..];
                const after_trim = std.mem.trimLeft(u8, after_key, " \t");
                if (after_trim.len > 0 and after_trim[0] == '=') {
                    key_line_start = start;
                    key_line_end = end;
                }
            }
        }
        start = if (nl != null) end + 1 else content.len;
    }

    if (key_line_start) |ks| {
        // Replace existing key line in-place
        const before = content[0..ks];
        const after = if (key_line_end < content.len) content[key_line_end..] else "";
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ before, new_line, after });
    } else if (section_header_end) |she| {
        // Section exists but no key — insert after header
        const before = content[0..she];
        const after = content[she..];
        return std.fmt.allocPrint(allocator, "{s}{s}\n{s}", .{ before, new_line, after });
    } else {
        // No section — append
        if (content.len > 0 and content[content.len - 1] != '\n') {
            return std.fmt.allocPrint(allocator, "{s}\n\n[{s}]\n{s}\n", .{ content, section, new_line });
        }
        return std.fmt.allocPrint(allocator, "{s}\n[{s}]\n{s}\n", .{ content, section, new_line });
    }
}

/// Re-render the theme picker at the current grid size without publishing.
pub fn relayout(ctx: *PtyThreadCtx) void {
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
        publish.overlayThemeFromTheme(&ctx.active_theme),
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

fn renderAndPublish(ctx: *PtyThreadCtx) void {
    const state = &(g_picker_state orelse return);
    const mgr = ctx.overlay_mgr orelse return;

    const result = picker_panel.renderThemePicker(
        ctx.allocator,
        state,
        ctx.grid_cols,
        ctx.grid_rows,
        publish.overlayThemeFromTheme(&ctx.active_theme),
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

    publish.publishOverlays(ctx);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "setTomlSectionKey: replace existing key" {
    const alloc = std.testing.allocator;
    const toml_input = "[font]\nsize = 14\n\n[theme]\nname = \"default\"\n\n[cursor]\nshape = \"block\"\n";
    const result = try setTomlSectionKey(alloc, toml_input, "theme", "name", "name = \"dracula\"");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("[font]\nsize = 14\n\n[theme]\nname = \"dracula\"\n\n[cursor]\nshape = \"block\"\n", result);
}

test "setTomlSectionKey: section exists, key missing" {
    const alloc = std.testing.allocator;
    const toml_input = "[theme]\nbackground = \"#000\"\n";
    const result = try setTomlSectionKey(alloc, toml_input, "theme", "name", "name = \"nord\"");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("[theme]\nname = \"nord\"\nbackground = \"#000\"\n", result);
}

test "setTomlSectionKey: no section at all" {
    const alloc = std.testing.allocator;
    const toml_input = "[font]\nsize = 14\n";
    const result = try setTomlSectionKey(alloc, toml_input, "theme", "name", "name = \"gruvbox\"");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("[font]\nsize = 14\n\n[theme]\nname = \"gruvbox\"\n", result);
}

test "setTomlSectionKey: empty file" {
    const alloc = std.testing.allocator;
    const result = try setTomlSectionKey(alloc, "", "theme", "name", "name = \"monokai\"");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("\n[theme]\nname = \"monokai\"\n", result);
}

test "setTomlSectionKey: preserves other sections untouched" {
    const alloc = std.testing.allocator;
    const toml_input = "# my config\n\n[font]\nfamily = \"JetBrains Mono\"\nsize = 13\n\n[theme]\nname = \"old\"\nbackground = \"#112233\"\n\n[cursor]\nblink = true\n";
    const result = try setTomlSectionKey(alloc, toml_input, "theme", "name", "name = \"new\"");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("# my config\n\n[font]\nfamily = \"JetBrains Mono\"\nsize = 13\n\n[theme]\nname = \"new\"\nbackground = \"#112233\"\n\n[cursor]\nblink = true\n", result);
}
