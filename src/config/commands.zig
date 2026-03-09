// Attyx — Command Registry
//
// Single source of truth for all commands, their hotkeys, descriptions,
// and scopes. Used by keybinds.zig for default keybind generation and
// by the command palette for display/search.

const std = @import("std");
const builtin = @import("builtin");
const kb = @import("keybinds.zig");
const Action = kb.Action;
const Keybind = kb.Keybind;
const KeyCombo = kb.KeyCombo;
const parseKeyCombo = kb.parseKeyCombo;

// ---------------------------------------------------------------------------
// Scope — when a command is available
// ---------------------------------------------------------------------------

pub const Scope = enum {
    global,
    search,
    ai_prompt,
    overlay,
};

// ---------------------------------------------------------------------------
// CommandDef — one entry in the registry
// ---------------------------------------------------------------------------

pub const CommandDef = struct {
    action: Action,
    name: []const u8,
    description: []const u8,
    scope: Scope,
    mac_hotkey: ?[]const u8,
    linux_hotkey: ?[]const u8,
    hidden: bool = false, // hide from command palette (for alias keybinds)
};

// ---------------------------------------------------------------------------
// Registry — all commands
// ---------------------------------------------------------------------------

pub const registry = [_]CommandDef{
    // --- Global commands ---
    .{ .action = .copy, .name = "copy", .description = "Copy selection to clipboard", .scope = .global, .mac_hotkey = null, .linux_hotkey = "ctrl+shift+c" },
    .{ .action = .paste, .name = "paste", .description = "Paste from clipboard", .scope = .global, .mac_hotkey = null, .linux_hotkey = "ctrl+shift+v" },
    .{ .action = .search_toggle, .name = "search_toggle", .description = "Toggle search bar", .scope = .global, .mac_hotkey = "cmd+f", .linux_hotkey = "ctrl+f" },
    .{ .action = .search_next, .name = "search_next", .description = "Find next match", .scope = .global, .mac_hotkey = "cmd+g", .linux_hotkey = "ctrl+g" },
    .{ .action = .search_prev, .name = "search_prev", .description = "Find previous match", .scope = .global, .mac_hotkey = "cmd+shift+g", .linux_hotkey = "ctrl+shift+g" },
    .{ .action = .scroll_page_up, .name = "scroll_page_up", .description = "Scroll page up", .scope = .global, .mac_hotkey = "shift+page_up", .linux_hotkey = "shift+page_up" },
    .{ .action = .scroll_page_down, .name = "scroll_page_down", .description = "Scroll page down", .scope = .global, .mac_hotkey = "shift+page_down", .linux_hotkey = "shift+page_down" },
    .{ .action = .scroll_to_top, .name = "scroll_to_top", .description = "Scroll to top", .scope = .global, .mac_hotkey = "shift+home", .linux_hotkey = "shift+home" },
    .{ .action = .scroll_to_bottom, .name = "scroll_to_bottom", .description = "Scroll to bottom", .scope = .global, .mac_hotkey = "shift+end", .linux_hotkey = "shift+end" },
    .{ .action = .config_reload, .name = "config_reload", .description = "Reload configuration", .scope = .global, .mac_hotkey = "ctrl+shift+r", .linux_hotkey = "ctrl+shift+r" },
    .{ .action = .debug_toggle, .name = "debug_toggle", .description = "Toggle debug overlay", .scope = .global, .mac_hotkey = "ctrl+shift+d", .linux_hotkey = "ctrl+shift+d" },
    .{ .action = .anchor_demo_toggle, .name = "anchor_demo_toggle", .description = "Toggle anchor demo", .scope = .global, .mac_hotkey = "ctrl+shift+a", .linux_hotkey = "ctrl+shift+a" },
    .{ .action = .new_window, .name = "new_window", .description = "Open new window", .scope = .global, .mac_hotkey = null, .linux_hotkey = null },
    .{ .action = .close_window, .name = "close_window", .description = "Close window", .scope = .global, .mac_hotkey = "ctrl+shift+w", .linux_hotkey = "ctrl+shift+w" },
    .{ .action = .ai_demo_toggle, .name = "ai_demo_toggle", .description = "Toggle AI edit prompt", .scope = .global, .mac_hotkey = "ctrl+shift+i", .linux_hotkey = "ctrl+shift+i" },
    .{ .action = .tab_new, .name = "tab_new", .description = "Open new tab", .scope = .global, .mac_hotkey = "cmd+t", .linux_hotkey = "ctrl+shift+t" },
    .{ .action = .tab_close, .name = "tab_close", .description = "Close tab", .scope = .global, .mac_hotkey = "cmd+w", .linux_hotkey = "ctrl+shift+w" },
    .{ .action = .tab_next, .name = "tab_next", .description = "Next tab", .scope = .global, .mac_hotkey = "ctrl+tab", .linux_hotkey = "ctrl+tab" },
    .{ .action = .tab_prev, .name = "tab_prev", .description = "Previous tab", .scope = .global, .mac_hotkey = "ctrl+shift+tab", .linux_hotkey = "ctrl+shift+tab" },
    .{ .action = .split_vertical, .name = "split_vertical", .description = "Split pane vertically", .scope = .global, .mac_hotkey = "cmd+d", .linux_hotkey = "ctrl+shift+d" },
    .{ .action = .split_horizontal, .name = "split_horizontal", .description = "Split pane horizontally", .scope = .global, .mac_hotkey = "cmd+shift+d", .linux_hotkey = "ctrl+shift+e" },
    .{ .action = .pane_close, .name = "pane_close", .description = "Close pane", .scope = .global, .mac_hotkey = "cmd+shift+w", .linux_hotkey = "ctrl+shift+q" },
    .{ .action = .pane_focus_up, .name = "pane_focus_up", .description = "Focus pane above", .scope = .global, .mac_hotkey = "ctrl+k", .linux_hotkey = "ctrl+k" },
    .{ .action = .pane_focus_down, .name = "pane_focus_down", .description = "Focus pane below", .scope = .global, .mac_hotkey = "ctrl+j", .linux_hotkey = "ctrl+j" },
    .{ .action = .pane_focus_left, .name = "pane_focus_left", .description = "Focus pane left", .scope = .global, .mac_hotkey = "ctrl+h", .linux_hotkey = "ctrl+h" },
    .{ .action = .pane_focus_right, .name = "pane_focus_right", .description = "Focus pane right", .scope = .global, .mac_hotkey = "ctrl+l", .linux_hotkey = "ctrl+l" },
    .{ .action = .pane_resize_up, .name = "pane_resize_up", .description = "Resize pane up", .scope = .global, .mac_hotkey = "cmd+ctrl+k", .linux_hotkey = "ctrl+alt+k" },
    .{ .action = .pane_resize_down, .name = "pane_resize_down", .description = "Resize pane down", .scope = .global, .mac_hotkey = "cmd+ctrl+j", .linux_hotkey = "ctrl+alt+j" },
    .{ .action = .pane_resize_left, .name = "pane_resize_left", .description = "Resize pane left", .scope = .global, .mac_hotkey = "cmd+ctrl+h", .linux_hotkey = "ctrl+alt+h" },
    .{ .action = .pane_resize_right, .name = "pane_resize_right", .description = "Resize pane right", .scope = .global, .mac_hotkey = "cmd+ctrl+l", .linux_hotkey = "ctrl+alt+l" },
    .{ .action = .pane_resize_grow, .name = "pane_resize_grow", .description = "Grow focused pane", .scope = .global, .mac_hotkey = "cmd+ctrl+=", .linux_hotkey = "ctrl+alt+=" },
    .{ .action = .pane_resize_shrink, .name = "pane_resize_shrink", .description = "Shrink focused pane", .scope = .global, .mac_hotkey = "cmd+ctrl+-", .linux_hotkey = "ctrl+alt+-" },
    .{ .action = .clear_screen, .name = "clear_screen", .description = "Clear screen and scrollback", .scope = .global, .mac_hotkey = "cmd+k", .linux_hotkey = "ctrl+shift+k" },
    .{ .action = .session_switcher_toggle, .name = "session_switcher_toggle", .description = "Toggle session switcher", .scope = .global, .mac_hotkey = "cmd+shift+s", .linux_hotkey = "ctrl+shift+s" },
    .{ .action = .session_create, .name = "session_create", .description = "Create new session", .scope = .global, .mac_hotkey = "ctrl+shift+n", .linux_hotkey = "ctrl+shift+n" },
    .{ .action = .session_kill, .name = "session_kill", .description = "Kill current session", .scope = .global, .mac_hotkey = "ctrl+d", .linux_hotkey = "ctrl+d" },
    .{ .action = .command_palette_toggle, .name = "command_palette_toggle", .description = "Toggle command palette", .scope = .global, .mac_hotkey = "cmd+shift+p", .linux_hotkey = "ctrl+shift+p" },
    .{ .action = .pane_rotate, .name = "pane_rotate", .description = "Rotate pane contents", .scope = .global, .mac_hotkey = "ctrl+shift+o", .linux_hotkey = "ctrl+shift+o" },
    .{ .action = .pane_zoom_toggle, .name = "pane_zoom_toggle", .description = "Toggle zoom on focused pane", .scope = .global, .mac_hotkey = "cmd+shift+z", .linux_hotkey = "ctrl+shift+z" },
    .{ .action = .copy_mode_enter, .name = "copy_mode", .description = "Enter copy/visual mode", .scope = .global, .mac_hotkey = "ctrl+shift+space", .linux_hotkey = "ctrl+shift+space" },
    .{ .action = .theme_picker_toggle, .name = "theme_picker", .description = "Pick theme", .scope = .global, .mac_hotkey = null, .linux_hotkey = null },
    .{ .action = .open_config, .name = "open_config", .description = "Open config in editor", .scope = .global, .mac_hotkey = "cmd+,", .linux_hotkey = "ctrl+," },
    // Tab select by number
    .{ .action = .tab_select_1, .name = "tab_select_1", .description = "Switch to tab 1", .scope = .global, .mac_hotkey = "cmd+1", .linux_hotkey = "alt+1" },
    .{ .action = .tab_select_2, .name = "tab_select_2", .description = "Switch to tab 2", .scope = .global, .mac_hotkey = "cmd+2", .linux_hotkey = "alt+2" },
    .{ .action = .tab_select_3, .name = "tab_select_3", .description = "Switch to tab 3", .scope = .global, .mac_hotkey = "cmd+3", .linux_hotkey = "alt+3" },
    .{ .action = .tab_select_4, .name = "tab_select_4", .description = "Switch to tab 4", .scope = .global, .mac_hotkey = "cmd+4", .linux_hotkey = "alt+4" },
    .{ .action = .tab_select_5, .name = "tab_select_5", .description = "Switch to tab 5", .scope = .global, .mac_hotkey = "cmd+5", .linux_hotkey = "alt+5" },
    .{ .action = .tab_select_6, .name = "tab_select_6", .description = "Switch to tab 6", .scope = .global, .mac_hotkey = "cmd+6", .linux_hotkey = "alt+6" },
    .{ .action = .tab_select_7, .name = "tab_select_7", .description = "Switch to tab 7", .scope = .global, .mac_hotkey = "cmd+7", .linux_hotkey = "alt+7" },
    .{ .action = .tab_select_8, .name = "tab_select_8", .description = "Switch to tab 8", .scope = .global, .mac_hotkey = "cmd+8", .linux_hotkey = "alt+8" },
    .{ .action = .tab_select_9, .name = "tab_select_9", .description = "Switch to tab 9", .scope = .global, .mac_hotkey = "cmd+9", .linux_hotkey = "alt+9" },
    // macOS-only additional keybinds (arrow-based tab switching)
    .{ .action = .tab_prev, .name = "tab_prev_arrows", .description = "Previous tab (arrows)", .scope = .global, .mac_hotkey = "cmd+shift+left", .linux_hotkey = "ctrl+alt+left" },
    .{ .action = .tab_next, .name = "tab_next_arrows", .description = "Next tab (arrows)", .scope = .global, .mac_hotkey = "cmd+shift+right", .linux_hotkey = "ctrl+alt+right" },
    // Tab reordering
    .{ .action = .tab_move_left, .name = "tab_move_left", .description = "Move tab left", .scope = .global, .mac_hotkey = "cmd+ctrl+shift+left", .linux_hotkey = "ctrl+alt+shift+left" },
    .{ .action = .tab_move_right, .name = "tab_move_right", .description = "Move tab right", .scope = .global, .mac_hotkey = "cmd+ctrl+shift+right", .linux_hotkey = "ctrl+alt+shift+right" },
    // Font size
    .{ .action = .font_size_increase, .name = "font_size_increase", .description = "Increase font size", .scope = .global, .mac_hotkey = "cmd+=", .linux_hotkey = "ctrl+=" },
    .{ .action = .font_size_increase, .name = "font_size_increase_shift", .description = "Increase font size", .scope = .global, .mac_hotkey = "cmd+shift+=", .linux_hotkey = "ctrl+shift+=", .hidden = true },
    .{ .action = .font_size_decrease, .name = "font_size_decrease", .description = "Decrease font size", .scope = .global, .mac_hotkey = "cmd+-", .linux_hotkey = "ctrl+-" },
    .{ .action = .font_size_reset, .name = "font_size_reset", .description = "Reset font size", .scope = .global, .mac_hotkey = "cmd+0", .linux_hotkey = "ctrl+0" },
};

// ---------------------------------------------------------------------------
// Lookup helpers
// ---------------------------------------------------------------------------

/// Look up an Action by its string name. Replaces keybinds.actionFromString.
pub fn actionFromName(name: []const u8) ?Action {
    inline for (registry) |cmd| {
        if (std.mem.eql(u8, name, cmd.name)) return cmd.action;
    }
    return null;
}

/// Find the first CommandDef for a given action.
pub fn commandForAction(action: Action) ?*const CommandDef {
    inline for (&registry) |*cmd| {
        if (cmd.action == action) return cmd;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Default keybinds — built from registry at comptime
// ---------------------------------------------------------------------------

pub fn defaultKeybinds() []const Keybind {
    const is_macos = comptime builtin.os.tag == .macos;
    const keybinds = comptime blk: {
        @setEvalBranchQuota(10_000);
        var list: []const Keybind = &.{};
        for (registry) |cmd| {
            const hotkey_str = if (is_macos) cmd.mac_hotkey else cmd.linux_hotkey;
            if (hotkey_str) |hk| {
                if (parseKeyCombo(hk)) |combo| {
                    list = list ++ &[_]Keybind{
                        .{ .combo = combo, .action = cmd.action },
                    };
                }
            }
        }
        break :blk list;
    };
    return keybinds;
}

// Tests are in commands_test.zig
test {
    _ = @import("commands_test.zig");
}
