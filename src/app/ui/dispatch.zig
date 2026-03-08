// Attyx — Unified action dispatch
//
// Consolidates the C dispatchAction() functions from macos_input_keyboard.m
// and linux_input.c into a single Zig export. Platform-specific operations
// call back into C via attyx_platform_* functions.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const keybinds = @import("../../config/keybinds.zig");
const Action = keybinds.Action;
const platform = @import("../../platform/platform.zig");

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

    // Clear mouse selection on any action except copy and scroll
    if (c.g_sel_active != 0 and c.g_copy_mode == 0) {
        switch (action) {
            .copy, .scroll_page_up, .scroll_page_down, .scroll_to_top, .scroll_to_bottom => {},
            else => {
                c.g_sel_active = 0;
                c.attyx_mark_all_dirty();
            },
        }
    }

    // Popup toggle range
    if (action.popupIndex()) |idx| {
        c.attyx_popup_toggle(@intCast(idx));
        return 1;
    }

    // When a popup is active, block all non-popup actions so the
    // underlying UI doesn't react to keybinds (e.g. tab switching).
    // Popup-specific actions (toggle, send_sequence, session_create/kill)
    // are handled above or below; everything else is consumed silently.
    if (c.g_popup_active != 0) {
        switch (action) {
            .send_sequence, .session_create, .session_kill => {},
            else => return 1,
        }
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
        .pane_resize_grow, .pane_resize_shrink,
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
        .theme_picker_toggle => {
            c.attyx_toggle_theme_picker();
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
        .font_size_increase => {
            const size = c.g_font_size;
            if (size < 72) {
                c.g_font_size = size + 2;
                c.g_needs_font_rebuild = 1;
            }
            return 1;
        },
        .font_size_decrease => {
            const size = c.g_font_size;
            if (size > 6) {
                c.g_font_size = size - 2;
                c.g_needs_font_rebuild = 1;
            }
            return 1;
        },
        .font_size_reset => {
            c.g_font_size = c.g_default_font_size;
            c.g_needs_font_rebuild = 1;
            return 1;
        },
        .open_config => {
            openConfigInEditor();
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

// ---------------------------------------------------------------------------
// Open config file in $EDITOR
// ---------------------------------------------------------------------------

extern fn execvp(file: [*:0]const u8, argv: [*]const ?[*:0]const u8) c_int;
extern fn _exit(status: c_int) noreturn;

fn openConfigInEditor() void {
    // Build config file path
    const home = std.posix.getenv("HOME") orelse return;
    const xdg = std.posix.getenv("XDG_CONFIG_HOME") orelse "";
    var path_buf: [512]u8 = undefined;
    const config_path = if (xdg.len > 0)
        std.fmt.bufPrintZ(&path_buf, "{s}/attyx/attyx.toml", .{xdg}) catch return
    else
        std.fmt.bufPrintZ(&path_buf, "{s}/.config/attyx/attyx.toml", .{home}) catch return;

    // Ensure the config file exists (create empty if missing)
    if (std.fs.accessAbsolute(config_path, .{})) {} else |_| {
        if (std.mem.lastIndexOfScalar(u8, config_path, '/')) |i| {
            std.fs.makeDirAbsolute(config_path[0..i]) catch {};
        }
        const f = std.fs.createFileAbsolute(config_path, .{ .exclusive = true }) catch null;
        if (f) |file| file.close();
    }

    // Use the platform's default file opener (open on macOS, xdg-open on Linux).
    // This lets the OS pick the right editor and avoids issues with terminal
    // editors needing a TTY that a GUI app doesn't have.
    const opener = if (comptime @import("builtin").os.tag == .macos) "open" else "xdg-open";

    // Double-fork to avoid zombie
    const pid = posix.fork() catch return;
    if (pid == 0) {
        const pid2 = posix.fork() catch posix.abort();
        if (pid2 == 0) {
            const argv = [_]?[*:0]const u8{ opener, config_path, null };
            _ = execvp(opener, &argv);
            posix.abort();
        }
        _exit(0);
    }
    _ = posix.waitpid(pid, 0);
}
