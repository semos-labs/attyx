/// Windows action dispatch — routes keybind actions to the appropriate
/// subsystem (tabs, splits, overlays, search, popup, etc.).
/// Extracted from windows_stubs.zig to stay under the 600-line limit.
const std = @import("std");
const attyx = @import("attyx");
const keybinds = @import("../config/keybinds.zig");
const Action = keybinds.Action;
const key_encode = attyx.key_encode;

const c = @cImport({
    @cInclude("bridge.h");
});

// Functions exported from windows_stubs.zig and other Windows modules.
extern fn attyx_popup_toggle(index: c_int) void;
extern fn attyx_tab_action(action: c_int) void;
extern fn attyx_split_action(action: c_int) void;
extern fn attyx_search_cmd(cmd: c_int) void;
extern fn attyx_toggle_session_switcher() void;
extern fn attyx_create_session_direct() void;
extern fn attyx_toggle_command_palette() void;
extern fn attyx_toggle_theme_picker() void;
extern fn attyx_toggle_debug_overlay() void;
extern fn attyx_toggle_anchor_demo() void;
extern fn attyx_toggle_ai_demo() void;
extern fn attyx_trigger_config_reload() void;
extern fn attyx_popup_send_input(bytes: [*]const u8, len: c_int) void;
extern fn attyx_send_input(bytes: [*]const u8, len: c_int) void;
extern fn attyx_copy_mode_enter() void;
extern fn attyx_platform_close_window() void;
extern fn attyx_clear_screen() void;
extern fn attyx_platform_copy() void;
extern fn attyx_platform_paste() void;

// ---------------------------------------------------------------------------
// Action dispatch
// ---------------------------------------------------------------------------

export fn attyx_dispatch_action(action_raw: u8) u8 {
    const action: Action = @enumFromInt(action_raw);

    if (c.g_sel_active != 0 and c.g_copy_mode == 0) {
        switch (action) {
            .copy, .scroll_page_up, .scroll_page_down, .scroll_to_top, .scroll_to_bottom => {},
            else => { c.g_sel_active = 0; c.attyx_mark_all_dirty(); },
        }
    }

    if (action.popupIndex()) |idx| {
        attyx_popup_toggle(@intCast(idx));
        return 1;
    }

    if (c.g_popup_active != 0) {
        switch (action) {
            .send_sequence, .session_create, .session_kill => {},
            else => return 1,
        }
    }

    switch (action) {
        .tab_new, .tab_close, .tab_next, .tab_prev,
        .tab_move_left, .tab_move_right,
        .tab_select_1, .tab_select_2, .tab_select_3,
        .tab_select_4, .tab_select_5, .tab_select_6,
        .tab_select_7, .tab_select_8, .tab_select_9,
        => { attyx_tab_action(action_raw); return 1; },
        else => {},
    }

    switch (action) {
        .split_vertical, .split_horizontal, .pane_close => {
            attyx_split_action(action_raw);
            return 1;
        },
        .pane_focus_up, .pane_focus_down, .pane_focus_left, .pane_focus_right,
        .pane_resize_up, .pane_resize_down, .pane_resize_left, .pane_resize_right,
        .pane_resize_grow, .pane_resize_shrink, .pane_rotate, .pane_zoom_toggle,
        => {
            if (c.g_split_active != 0) { attyx_split_action(action_raw); return 1; }
            return 0;
        },
        else => {},
    }

    switch (action) {
        .search_toggle => {
            if (c.g_search_active != 0) {
                attyx_search_cmd(7);
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
        .config_reload => { attyx_trigger_config_reload(); return 1; },
        .debug_toggle => { attyx_toggle_debug_overlay(); return 1; },
        .anchor_demo_toggle => { attyx_toggle_anchor_demo(); return 1; },
        .ai_demo_toggle => { attyx_toggle_ai_demo(); return 1; },
        .session_switcher_toggle => {
            std.log.info("dispatch: session_switcher_toggle", .{});
            attyx_toggle_session_switcher();
            return 1;
        },
        .command_palette_toggle => { attyx_toggle_command_palette(); return 1; },
        .theme_picker_toggle => { attyx_toggle_theme_picker(); return 1; },
        .session_create => {
            if (c.g_popup_active != 0) {
                const b = [_]u8{0x0e};
                attyx_popup_send_input(&b, 1);
            } else {
                attyx_create_session_direct();
            }
            return 1;
        },
        .session_kill => {
            if (c.g_popup_active != 0) {
                const b = [_]u8{0x04};
                attyx_popup_send_input(&b, 1);
                return 1;
            }
            return 0;
        },
        .new_window => { c.attyx_spawn_new_window(); return 1; },
        .close_window => { attyx_platform_close_window(); return 1; },
        .clear_screen => { attyx_clear_screen(); return 1; },
        .open_config => { openConfigWindows(); return 1; },
        .copy => {
            // Only copy when selection is active; otherwise fall through
            // so ctrl+c sends ^C to the shell.
            if (c.g_sel_active == 0 and c.g_copy_mode == 0) return 0;
            attyx_platform_copy();
            return 1;
        },
        .paste => { attyx_platform_paste(); return 1; },
        .copy_mode_enter => { attyx_copy_mode_enter(); return 1; },
        .font_size_increase => {
            if (c.g_font_size < 72) { c.g_font_size += 2; c.g_needs_font_rebuild = 1; }
            return 1;
        },
        .font_size_decrease => {
            if (c.g_font_size > 6) { c.g_font_size -= 2; c.g_needs_font_rebuild = 1; }
            return 1;
        },
        .font_size_reset => {
            c.g_font_size = c.g_default_font_size;
            c.g_needs_font_rebuild = 1;
            return 1;
        },
        .send_sequence => {
            if (c.g_keybind_matched_seq_len > 0) {
                if (c.g_popup_active != 0)
                    attyx_popup_send_input(c.g_keybind_matched_seq, c.g_keybind_matched_seq_len)
                else
                    attyx_send_input(c.g_keybind_matched_seq, c.g_keybind_matched_seq_len);
            }
            return 1;
        },
        else => return 0,
    }
}

// ---------------------------------------------------------------------------
// Open config file (Windows)
// ---------------------------------------------------------------------------

extern "shell32" fn ShellExecuteA(
    hwnd: ?*anyopaque,
    lpOperation: [*:0]const u8,
    lpFile: [*:0]const u8,
    lpParameters: ?[*:0]const u8,
    lpDirectory: ?[*:0]const u8,
    nShowCmd: c_int,
) callconv(.winapi) ?*anyopaque;

fn openConfigWindows() void {
    var buf: [512]u8 = undefined;
    const appdata = std.process.getEnvVarOwned(std.heap.page_allocator, "APPDATA") catch return;
    defer std.heap.page_allocator.free(appdata);
    const path = std.fmt.bufPrintZ(&buf, "{s}\\attyx\\attyx.toml", .{appdata}) catch return;

    // Ensure config dir + file exist
    var dir_buf: [512]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "{s}\\attyx", .{appdata}) catch return;
    std.fs.makeDirAbsolute(dir_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return,
    };
    if (std.fs.accessAbsolute(path, .{})) {} else |_| {
        const f = std.fs.createFileAbsolute(path, .{ .exclusive = true }) catch null;
        if (f) |file| file.close();
    }

    _ = ShellExecuteA(null, "open", path, null, null, 5); // SW_SHOW = 5
}

// ---------------------------------------------------------------------------
// Context menu — atomic action signals
// ---------------------------------------------------------------------------

var ctx_action_id: i32 = 0;
var ctx_action_col: i32 = -1;
var ctx_action_row: i32 = -1;
var ctx_action_pending: i32 = 0;

export fn attyx_context_menu_action(action_id: u8, col: c_int, row: c_int) void {
    @atomicStore(i32, &ctx_action_col, col, .seq_cst);
    @atomicStore(i32, &ctx_action_row, row, .seq_cst);
    @atomicStore(i32, &ctx_action_id, @as(i32, action_id), .seq_cst);
    @atomicStore(i32, &ctx_action_pending, 1, .seq_cst);
}
