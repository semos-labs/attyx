/// Command palette UI integration — wires the overlay-based command palette
/// state machine to the overlay manager and action dispatch.
const std = @import("std");

const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const c = terminal.c;
const publish = @import("publish.zig");
const input = @import("input.zig");
const actions = @import("actions.zig");
const session_picker_ui = @import("session_picker_ui.zig");
const commands = @import("../../config/commands.zig");
const keybinds = @import("../../config/keybinds.zig");

const attyx = @import("attyx");
const palette_state_mod = attyx.overlay_command_palette;
const CommandPaletteState = palette_state_mod.CommandPaletteState;
const CommandEntry = palette_state_mod.CommandEntry;
const palette_panel = attyx.overlay_command_palette_panel;
const overlay_mod = attyx.overlay_mod;

var g_palette_state: ?CommandPaletteState = null;

pub fn openCommandPalette(ctx: *PtyThreadCtx) void {
    // Close session picker if open (mutually exclusive modals)
    if (terminal.g_session_picker_active != 0) {
        session_picker_ui.closeSessionPicker(ctx);
    }

    // Compute visible rows from grid size
    const panel_h = @as(u16, @intCast(@max(3, ctx.grid_rows))) / 2;
    const visible = if (panel_h > 4) @as(u8, @intCast(panel_h - 4)) else 3;

    var state = CommandPaletteState{};
    state.visible_rows = visible;

    // Populate entries from command registry (skip hidden alias entries)
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
        // Use the runtime keybind table to show actual (possibly overridden) hotkeys.
        // Fall back to registry defaults if no runtime binding exists.
        const is_macos = comptime @import("builtin").os.tag == .macos;
        if (keybinds.findComboForAction(cmd.action)) |combo| {
            if (is_macos) {
                entry.mac_hotkey_len = keybinds.formatKeyCombo(combo, &entry.mac_hotkey);
            } else {
                entry.linux_hotkey_len = keybinds.formatKeyCombo(combo, &entry.linux_hotkey);
            }
        } else {
            // Action was unbound — show no hotkey (leave len = 0)
        }
        state.entries[entry_idx] = entry;
        entry_idx += 1;
    }
    state.entry_count = @intCast(entry_idx);
    state.applyFilter();

    g_palette_state = state;
    @atomicStore(i32, &terminal.g_command_palette_active, 1, .seq_cst);

    renderAndPublish(ctx);
}

/// Drain palette input rings and process actions. Returns true if any input consumed.
pub fn consumePaletteInput(ctx: *PtyThreadCtx) bool {
    var state = &(g_palette_state orelse return false);
    var consumed = false;

    // Drain char ring (shared with session picker)
    while (true) {
        const r = @atomicLoad(u32, &input.g_picker_char_read, .seq_cst);
        const w = @atomicLoad(u32, &input.g_picker_char_write, .seq_cst);
        if (r == w) break;
        const cp = input.g_picker_char_ring[r % 32];
        @atomicStore(u32, &input.g_picker_char_read, r +% 1, .seq_cst);
        consumed = true;

        const action = state.handleChar(cp);
        if (processAction(ctx, action)) return true;
    }

    // Drain cmd ring (shared with session picker)
    while (true) {
        const r = @atomicLoad(u32, &input.g_picker_cmd_read, .seq_cst);
        const w = @atomicLoad(u32, &input.g_picker_cmd_write, .seq_cst);
        if (r == w) break;
        const cmd = input.g_picker_cmd_ring[r % 16];
        @atomicStore(u32, &input.g_picker_cmd_read, r +% 1, .seq_cst);
        consumed = true;

        const action = state.handleCmd(cmd);
        if (processAction(ctx, action)) return true;
    }

    if (consumed) renderAndPublish(ctx);
    return consumed;
}

fn processAction(ctx: *PtyThreadCtx, action: palette_state_mod.PaletteAction) bool {
    switch (action) {
        .none => return false,
        .close => {
            closeCommandPalette(ctx);
            return true;
        },
        .execute => |action_id| {
            // Intercept tab_rename: switch palette to rename input mode
            if (action_id == @intFromEnum(keybinds.Action.tab_rename)) {
                if (g_palette_state) |*state| {
                    state.enterRenameMode();
                    renderAndPublish(ctx);
                }
                return true;
            }
            closeCommandPalette(ctx);
            _ = c.attyx_dispatch_action(action_id);
            return true;
        },
        .rename_tab => |name| {
            ctx.tab_mgr.activeLayout().setTitle(name);
            actions.saveSessionLayout(ctx);
            closeCommandPalette(ctx);
            return true;
        },
    }
}

pub fn closeCommandPalette(ctx: *PtyThreadCtx) void {
    g_palette_state = null;
    @atomicStore(i32, &terminal.g_command_palette_active, 0, .seq_cst);
    if (ctx.overlay_mgr) |mgr| mgr.hide(.command_palette);
    publish.publishOverlays(ctx);
}

/// Re-render the command palette at the current grid size without publishing.
/// Called from handleResize so the panel re-centers after window size changes.
pub fn relayout(ctx: *PtyThreadCtx) void {
    const state = &(g_palette_state orelse return);
    const mgr = ctx.overlay_mgr orelse return;

    // Recompute visible rows from new grid size
    const panel_h = @as(u16, @intCast(@max(3, ctx.grid_rows))) / 2;
    state.visible_rows = if (panel_h > 4) @as(u8, @intCast(panel_h - 4)) else 3;
    state.adjustScroll();

    const result = palette_panel.renderCommandPalette(
        ctx.allocator,
        state,
        ctx.grid_cols,
        ctx.grid_rows,
        publish.overlayThemeFromTheme(&ctx.active_theme),
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

fn renderAndPublish(ctx: *PtyThreadCtx) void {
    const state = &(g_palette_state orelse return);
    const mgr = ctx.overlay_mgr orelse return;

    const result = palette_panel.renderCommandPalette(
        ctx.allocator,
        state,
        ctx.grid_cols,
        ctx.grid_rows,
        publish.overlayThemeFromTheme(&ctx.active_theme),
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

    publish.publishOverlays(ctx);
}
