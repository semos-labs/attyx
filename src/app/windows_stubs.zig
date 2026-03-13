// Windows bridge stubs — provides Zig-exported symbols that terminal.zig
// normally exports on macOS/Linux. On Windows, terminal.zig is not imported
// because it depends deeply on POSIX (Unix sockets, signals, fork/exec).
// These stubs let the Windows C platform layer link without errors.
// Note: daemon/IPC now has real Windows implementations (daemon_windows.zig).
// These stubs cover the UI/rendering bridge only.

export fn attyx_send_input(_: [*]const u8, _: c_int) void {}
export fn attyx_clear_screen() void {}
export fn attyx_handle_key(_: u16, _: u8, _: u8, _: u32) void {}
export fn attyx_get_link_uri(_: u32, _: [*]u8, _: c_int) c_int { return 0; }
export fn attyx_trigger_config_reload() void {}
export fn attyx_cleanup() void {}
export fn attyx_log(_: c_int, _: [*:0]const u8, _: [*:0]const u8) void {}

// Overlay interaction
export var g_overlay_has_actions: i32 = 0;
export fn attyx_overlay_esc() void {}
export fn attyx_overlay_tab() void {}
export fn attyx_overlay_shift_tab() void {}
export fn attyx_overlay_enter() void {}
export fn attyx_overlay_click(_: c_int, _: c_int) c_int { return 0; }
export fn attyx_overlay_scroll(_: c_int, _: c_int, _: c_int) c_int { return 0; }

// Search
export fn attyx_search_insert_char(_: u32) void {}
export fn attyx_search_cmd(_: c_int) void {}

// AI edit prompt
export var g_ai_prompt_active: i32 = 0;
export fn attyx_ai_prompt_insert_char(_: u32) void {}
export fn attyx_ai_prompt_cmd(_: c_int) void {}

// Session picker
export var g_session_picker_active: i32 = 0;
export fn attyx_picker_insert_char(_: u32) void {}
export fn attyx_picker_cmd(_: c_int) void {}

// Tabs
export fn attyx_tab_action(_: c_int) void {}
export fn attyx_tab_bar_click(_: c_int, _: c_int) void {}
export fn attyx_statusbar_tab_click(_: c_int, _: c_int) void {}

// Splits
export fn attyx_split_action(_: c_int) void {}
export fn attyx_split_click(_: c_int, _: c_int) void {}
export fn attyx_split_drag_start(_: c_int, _: c_int) void {}
export fn attyx_split_drag_update(_: c_int, _: c_int) void {}
export fn attyx_split_drag_end() void {}

// Session switcher
export fn attyx_toggle_session_switcher() void {}
export fn attyx_create_session_direct() void {}

// Command palette
export fn attyx_toggle_command_palette() void {}

// Theme picker
export fn attyx_toggle_theme_picker() void {}

// Debug overlays
export fn attyx_toggle_debug_overlay() void {}
export fn attyx_toggle_anchor_demo() void {}
export fn attyx_toggle_ai_demo() void {}

// Popup terminal
export fn attyx_popup_toggle(_: c_int) void {}
export fn attyx_popup_send_input(_: [*]const u8, _: c_int) void {}
export fn attyx_popup_handle_key(_: u16, _: u8, _: u8, _: u32) void {}

// Copy mode
export fn attyx_copy_mode_enter() void {}
export fn attyx_copy_mode_key(_: u16, _: u8, _: u32) u8 { return 0; }
export fn attyx_copy_mode_exit(_: c_int) void {}
export fn attyx_copy_selection() void {}

// Keybinds (attyx_keybind_match, attyx_keybind_for_action, g_keybind_matched_seq*)
// are provided by keybinds.zig in the attyx module — no stubs needed.
export fn attyx_dispatch_action(_: u8) u8 { return 0; }
export fn attyx_context_menu_action(_: u8, _: c_int, _: c_int) void {}

// Zig-owned globals (normally exported by terminal.zig / copy_mode.zig)
export var g_needs_reload_config: i32 = 0;
export var g_kitty_kbd_flags: i32 = 0;
export var g_needs_font_rebuild: i32 = 0;
export var g_needs_window_update: i32 = 0;
export var g_background_opacity: f32 = 1.0;
export var g_background_blur: i32 = 30;
export var g_window_decorations: i32 = 1;
export var g_padding_left: i32 = 0;
export var g_padding_right: i32 = 0;
export var g_padding_top: i32 = 0;
export var g_padding_bottom: i32 = 0;
export var g_theme_cursor_r: i32 = -1;
export var g_theme_cursor_g: i32 = 0;
export var g_theme_cursor_b: i32 = 0;
export var g_theme_sel_bg_set: i32 = 0;
export var g_theme_sel_bg_r: i32 = 0;
export var g_theme_sel_bg_g: i32 = 0;
export var g_theme_sel_bg_b: i32 = 0;
export var g_theme_sel_fg_set: i32 = 0;
export var g_theme_sel_fg_r: i32 = 0;
export var g_theme_sel_fg_g: i32 = 0;
export var g_theme_sel_fg_b: i32 = 0;
export var g_theme_bg_r: i32 = 30;
export var g_theme_bg_g: i32 = 30;
export var g_theme_bg_b: i32 = 36;

var _icon_stub: u8 = 0;
export var g_icon_png: [*]const u8 = @ptrCast(&_icon_stub);
export var g_icon_png_len: c_int = 0;
var _ver_stub: u8 = 0;
export var g_app_version: [*]const u8 = @ptrCast(&_ver_stub);
export var g_app_version_len: c_int = 0;

export var g_grid_top_offset: i32 = 0;
export var g_grid_bottom_offset: i32 = 0;
export var g_statusbar_visible: i32 = 0;
export var g_statusbar_position: i32 = 0;
export var g_tab_bar_visible: i32 = 0;
export var g_toggle_debug_overlay_flag: i32 = 0;
export var g_toggle_anchor_demo_flag: i32 = 0;
export var g_toggle_ai_demo_flag: i32 = 0;

export var g_native_tabs_enabled: i32 = 0;
export var g_tab_always_show: i32 = 0;
export var g_native_tab_count: i32 = 1;
export var g_native_tab_active: i32 = 0;
export var g_native_tab_titles_changed: i32 = 0;
export var g_native_tab_click: i32 = -1;
export var g_native_tab_reorder: i32 = -1;
export var g_native_tab_titles: [16][128]u8 = .{.{0} ** 128} ** 16;
export var g_sessions_active: i32 = 0;
export var g_session_count: i32 = 0;
export var g_active_session_idx: i32 = -1;
export var g_session_ids: [32]u32 = .{0} ** 32;
export var g_session_names: [32][64]u8 = .{.{0} ** 64} ** 32;
export var g_session_list_changed: i32 = 0;
export var g_session_switch_id: i32 = -1;

export var g_split_active: i32 = 0;
export var g_split_drag_active: i32 = 0;
export var g_split_drag_direction: i32 = 0;
export var g_pane_rect_row: i32 = 0;
export var g_pane_rect_col: i32 = 0;
export var g_pane_rect_rows: i32 = 24;
export var g_pane_rect_cols: i32 = 80;

export var g_toggle_session_switcher: i32 = 0;
export var g_create_session_direct: i32 = 0;
export var g_command_palette_active: i32 = 0;
export var g_toggle_command_palette: i32 = 0;
export var g_theme_picker_active: i32 = 0;
export var g_toggle_theme_picker: i32 = 0;

export var g_popup_active: i32 = 0;
export var g_popup_trail_active: i32 = 0;
export var g_popup_mouse_tracking: i32 = 0;
export var g_popup_mouse_sgr: i32 = 0;

export var g_copy_mode: c_int = 0;
export var g_copy_cursor_row: c_int = 0;
export var g_copy_cursor_col: c_int = 0;
export var g_sel_block: c_int = 0;
export var g_copy_search_active: c_int = 0;
export var g_copy_search_dir: c_int = 1;
export var g_copy_search_buf: [128]u8 = .{0} ** 128;
export var g_copy_search_len: c_int = 0;
export var g_copy_search_dirty: c_int = 0;

// g_keybind_matched_seq* provided by keybinds.zig — no stubs needed.
