// Attyx — Unified action dispatch
//
// Consolidates the C dispatchAction() functions from macos_input_keyboard.m
// and linux_input.c into a single Zig export. Platform-specific operations
// call back into C via attyx_platform_* functions.

const std = @import("std");
const builtin = @import("builtin");
const keybinds = @import("../../config/keybinds.zig");
const Action = keybinds.Action;

const terminal = @import("../terminal.zig");
const c = terminal.c;
const copy_mode = @import("copy_mode.zig");

// ---------------------------------------------------------------------------
// Platform callbacks (implemented in platform C files)
// ---------------------------------------------------------------------------

extern fn attyx_platform_close_window() void;
extern fn attyx_platform_copy() void;
extern fn attyx_platform_paste() void;

// ---------------------------------------------------------------------------
// Dispatch — exported for C callers
// ---------------------------------------------------------------------------

/// Dispatch a keybind action. Returns 1 if consumed, 0 if key should pass through.
pub export fn attyx_dispatch_action(action_raw: u8) u8 {
    const action: Action = @enumFromInt(action_raw);

    // Popup toggle range
    if (action.popupIndex()) |idx| {
        c.attyx_popup_toggle(@intCast(idx));
        return 1;
    }

    // Tab actions
    switch (action) {
        .tab_new, .tab_close, .tab_next, .tab_prev,
        .tab_move_left, .tab_move_right,
        .tab_select_1, .tab_select_2, .tab_select_3,
        .tab_select_4, .tab_select_5, .tab_select_6,
        .tab_select_7, .tab_select_8, .tab_select_9,
        => {
            c.attyx_tab_action(action_raw);
            return 1;
        },
        else => {},
    }

    // Split/pane actions
    switch (action) {
        .split_vertical, .split_horizontal, .pane_close => {
            c.attyx_split_action(action_raw);
            return 1;
        },
        .pane_focus_up, .pane_focus_down, .pane_focus_left, .pane_focus_right,
        .pane_resize_up, .pane_resize_down, .pane_resize_left, .pane_resize_right,
        .pane_rotate, .pane_zoom_toggle,
        => {
            if (c.g_split_active != 0) {
                c.attyx_split_action(action_raw);
                return 1;
            }
            return 0; // pass through when no splits
        },
        else => {},
    }

    // Individual actions
    switch (action) {
        .search_toggle => {
            if (c.g_search_active != 0) {
                c.attyx_search_cmd(7); // dismiss
            } else {
                c.g_search_active = 1;
                c.g_search_query_len = 0;
                c.g_search_gen +%= 1;
                c.attyx_mark_all_dirty();
            }
            return 1;
        },
        .search_next => {
            if (c.g_search_active != 0) {
                _ = @atomicRmw(c_int, @as(*c_int, @ptrCast(@volatileCast(&c.g_search_nav_delta))), .Add, 1, .seq_cst);
                c.attyx_mark_all_dirty();
            }
            return 1;
        },
        .search_prev => {
            if (c.g_search_active != 0) {
                _ = @atomicRmw(c_int, @as(*c_int, @ptrCast(@volatileCast(&c.g_search_nav_delta))), .Add, -1, .seq_cst);
                c.attyx_mark_all_dirty();
            }
            return 1;
        },
        .scroll_page_up => {
            if (c.g_mouse_tracking != 0 or c.g_alt_screen != 0) return 0;
            c.attyx_scroll_viewport(c.g_rows);
            return 1;
        },
        .scroll_page_down => {
            if (c.g_mouse_tracking != 0 or c.g_alt_screen != 0) return 0;
            c.attyx_scroll_viewport(-c.g_rows);
            return 1;
        },
        .scroll_to_top => {
            if (c.g_mouse_tracking != 0 or c.g_alt_screen != 0) return 0;
            c.g_viewport_offset = c.g_scrollback_count;
            c.attyx_mark_all_dirty();
            return 1;
        },
        .scroll_to_bottom => {
            if (c.g_mouse_tracking != 0 or c.g_alt_screen != 0) return 0;
            c.g_viewport_offset = 0;
            c.attyx_mark_all_dirty();
            return 1;
        },
        .config_reload => {
            c.attyx_trigger_config_reload();
            return 1;
        },
        .debug_toggle => {
            c.attyx_toggle_debug_overlay();
            return 1;
        },
        .anchor_demo_toggle => {
            c.attyx_toggle_anchor_demo();
            return 1;
        },
        .ai_demo_toggle => {
            c.attyx_toggle_ai_demo();
            return 1;
        },
        .session_switcher_toggle => {
            c.attyx_toggle_session_switcher();
            return 1;
        },
        .command_palette_toggle => {
            c.attyx_toggle_command_palette();
            return 1;
        },
        .session_create => {
            if (c.g_popup_active != 0) {
                const b = [_]u8{0x0e}; // Ctrl-N byte
                c.attyx_popup_send_input(&b, 1);
                return 1;
            }
            c.attyx_create_session_direct();
            return 1;
        },
        .session_kill => {
            if (c.g_popup_active != 0) {
                const b = [_]u8{0x04}; // Ctrl-D byte
                c.attyx_popup_send_input(&b, 1);
                return 1;
            }
            return 0;
        },
        .copy => {
            if (comptime builtin.os.tag == .linux) {
                attyx_platform_copy();
            }
            return 1;
        },
        .paste => {
            if (comptime builtin.os.tag == .linux) {
                attyx_platform_paste();
            }
            return 1;
        },
        .new_window => {
            c.attyx_spawn_new_window();
            return 1;
        },
        .close_window => {
            attyx_platform_close_window();
            return 1;
        },
        .clear_screen => {
            c.attyx_clear_screen();
            return 1;
        },
        .copy_mode_enter => {
            copy_mode.attyx_copy_mode_enter();
            return 1;
        },
        .send_sequence => {
            if (c.g_keybind_matched_seq_len > 0) {
                const seq = c.g_keybind_matched_seq;
                const len = c.g_keybind_matched_seq_len;
                if (c.g_popup_active != 0) {
                    c.attyx_popup_send_input(seq, len);
                } else {
                    c.attyx_send_input(seq, len);
                }
            }
            return 1;
        },
        else => return 0,
    }
}
