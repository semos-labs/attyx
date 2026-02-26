const std = @import("std");
const attyx = @import("attyx");
const color_mod = attyx.render_color;

const TerminalState = attyx.TerminalState;
const Style = attyx.Style;
const Color = attyx.Color;
const Rgb = color_mod.Rgb;

const c = @cImport({
    @cInclude("bridge.h");
});

// Stubs: ui2.zig normally provides these. UI-0 demo has no PTY.
export fn attyx_send_input(_: [*]const u8, _: c_int) void {}
export fn attyx_handle_key(_: u16, _: u8, _: u8, _: u32) void {}
export fn attyx_get_link_uri(_: u32, _: [*]u8, _: c_int) c_int { return 0; }
export var g_needs_reload_config: i32 = 0;
export var g_kitty_kbd_flags: i32 = 0;
export var g_needs_font_rebuild: i32 = 0;
export fn attyx_trigger_config_reload() void {}
export fn attyx_log(_: c_int, _: [*:0]const u8, _: [*:0]const u8) void {}
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
var _icon_stub: u8 = 0;
export var g_icon_png: [*]const u8 = @ptrCast(&_icon_stub);
export var g_icon_png_len: c_int = 0;
export var g_toggle_debug_overlay: i32 = 0;
export fn attyx_toggle_debug_overlay() void {}
export var g_toggle_anchor_demo: i32 = 0;
export fn attyx_toggle_anchor_demo() void {}
export var g_overlay_has_actions: i32 = 0;
export fn attyx_overlay_esc() void {}
export fn attyx_overlay_tab() void {}
export fn attyx_overlay_enter() void {}

// Popup terminal stubs (ui2.zig provides the real implementations)
export var g_popup_active: i32 = 0;
export var g_popup_trail_active: i32 = 0;
export fn attyx_popup_toggle(_: c_int) void {}
export fn attyx_popup_send_input(_: [*]const u8, _: c_int) void {}
export fn attyx_popup_handle_key(_: u16, _: u8, _: u8, _: u32) void {}

// Keybind stubs (keybinds.zig provides real implementations)
export fn attyx_keybind_match(_: u16, _: u8, _: u32) u8 { return 0; }
var _seq_stub: u8 = 0;
export var g_keybind_matched_seq: [*]const u8 = @ptrCast(&_seq_stub);
export var g_keybind_matched_seq_len: c_int = 0;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var state = try TerminalState.init(allocator, 24, 80);
    defer state.deinit();

    populateDemo(&state);

    const total = state.grid.rows * state.grid.cols;
    const render_cells = try allocator.alloc(c.AttyxCell, total);
    defer allocator.free(render_cells);

    for (0..total) |i| {
        const cell = state.grid.cells[i];
        const fg = color_mod.resolve(cell.style.fg, false);
        const bg = color_mod.resolve(cell.style.bg, true);
        render_cells[i] = .{
            .character = cell.char,
            .combining = .{ cell.combining[0], cell.combining[1] },
            .fg_r = fg.r,
            .fg_g = fg.g,
            .fg_b = fg.b,
            .bg_r = bg.r,
            .bg_g = bg.g,
            .bg_b = bg.b,
            .flags = @as(u8, if (cell.style.bold) 1 else 0) |
                @as(u8, if (cell.style.underline) 2 else 0),
            .link_id = cell.link_id,
        };
    }

    c.attyx_run(
        render_cells.ptr,
        @intCast(state.grid.cols),
        @intCast(state.grid.rows),
    );
}

// ---------------------------------------------------------------------------
// Demo content — exercises every color path
// ---------------------------------------------------------------------------

fn populateDemo(st: *TerminalState) void {
    // Title bar
    writeStr(st, 0, 2, " Attyx UI-0 ", .{
        .fg = .{ .rgb = .{ .r = 15, .g = 15, .b = 20 } },
        .bg = .{ .rgb = .{ .r = 100, .g = 180, .b = 255 } },
        .bold = true,
    });
    writeStr(st, 0, 16, " Rendering Spike ", .{
        .fg = .{ .rgb = .{ .r = 200, .g = 200, .b = 200 } },
        .bg = .{ .rgb = .{ .r = 55, .g = 60, .b = 70 } },
    });

    // ANSI foreground
    writeStr(st, 2, 0, "ANSI fg:", .{});
    const names = [8][]const u8{ "BLK", "RED", "GRN", "YEL", "BLU", "MAG", "CYN", "WHT" };
    for (0..8) |i| {
        writeStr(st, 2, 9 + i * 5, names[i], .{ .fg = .{ .ansi = @intCast(i) } });
    }

    // Bright ANSI foreground
    writeStr(st, 3, 0, "Bright: ", .{});
    for (0..8) |i| {
        writeStr(st, 3, 9 + i * 5, names[i], .{
            .fg = .{ .ansi = @intCast(i + 8) },
            .bold = true,
        });
    }

    // ANSI background blocks
    writeStr(st, 5, 0, "ANSI bg:", .{});
    for (0..8) |i| {
        fillBlock(st, 5, 9 + i * 5, 4, .{ .bg = .{ .ansi = @intCast(i) } });
    }
    writeStr(st, 6, 0, "Bright: ", .{});
    for (0..8) |i| {
        fillBlock(st, 6, 9 + i * 5, 4, .{ .bg = .{ .ansi = @intCast(i + 8) } });
    }

    // 256-color palette
    writeStr(st, 8, 0, "256-color palette:", .{});
    for (0..72) |i| {
        const idx: u8 = @intCast(16 + i);
        st.grid.setCell(9, i, .{
            .char = ' ',
            .style = .{ .bg = .{ .palette = idx } },
        });
    }
    for (0..72) |i| {
        const idx: u8 = @intCast(88 + i);
        st.grid.setCell(10, i, .{
            .char = ' ',
            .style = .{ .bg = .{ .palette = idx } },
        });
    }

    // RGB gradient
    writeStr(st, 12, 0, "RGB gradient:", .{});
    for (0..80) |i| {
        const t: u8 = @intCast(i * 255 / 79);
        st.grid.setCell(13, i, .{
            .char = ' ',
            .style = .{ .bg = .{ .rgb = .{ .r = t, .g = 50, .b = 255 -| t } } },
        });
    }
    for (0..80) |i| {
        const t: u8 = @intCast(i * 255 / 79);
        st.grid.setCell(14, i, .{
            .char = ' ',
            .style = .{ .bg = .{ .rgb = .{ .r = 20, .g = t, .b = 120 } } },
        });
    }

    // Styles
    writeStr(st, 16, 0, "Styles: ", .{});
    writeStr(st, 16, 8, "normal ", .{});
    writeStr(st, 16, 15, "bold ", .{ .bold = true });
    writeStr(st, 16, 20, "underline ", .{ .underline = true });
    writeStr(st, 16, 30, "both", .{ .bold = true, .underline = true });

    // Rainbow text
    writeStr(st, 18, 0, "RGB text: ", .{});
    const rainbow = "The quick brown fox jumps over the lazy dog";
    for (rainbow, 0..) |ch, i| {
        if (10 + i >= 80) break;
        const hue: u8 = @intCast(i * 255 / (rainbow.len - 1));
        const rgb = hueToRgb(hue);
        st.grid.setCell(18, 10 + i, .{
            .char = ch,
            .style = .{ .fg = .{ .rgb = rgb } },
        });
    }

    // Box
    writeStr(st, 20, 0, "+----------+", .{ .fg = Color.cyan });
    writeStr(st, 21, 0, "|  Attyx   |", .{ .fg = Color.cyan });
    writeStr(st, 22, 0, "+----------+", .{ .fg = Color.cyan });
    writeStr(st, 21, 3, "Attyx", .{
        .fg = .{ .rgb = .{ .r = 100, .g = 200, .b = 255 } },
        .bold = true,
    });

    // Status bar
    for (0..80) |i| {
        st.grid.setCell(23, i, .{
            .char = ' ',
            .style = .{ .bg = .{ .rgb = .{ .r = 40, .g = 44, .b = 52 } } },
        });
    }
    writeStr(st, 23, 1, "Attyx UI-0 | 80x24 | Metal | macOS", .{
        .fg = .{ .rgb = .{ .r = 150, .g = 160, .b = 180 } },
        .bg = .{ .rgb = .{ .r = 40, .g = 44, .b = 52 } },
    });
}

fn writeStr(st: *TerminalState, row: usize, col: usize, text: []const u8, style: Style) void {
    for (text, 0..) |ch, i| {
        if (col + i >= st.grid.cols) break;
        st.grid.setCell(row, col + i, .{
            .char = ch,
            .style = style,
        });
    }
}

fn fillBlock(st: *TerminalState, row: usize, col: usize, width: usize, style: Style) void {
    for (0..width) |i| {
        if (col + i >= st.grid.cols) break;
        st.grid.setCell(row, col + i, .{
            .char = ' ',
            .style = style,
        });
    }
}

fn hueToRgb(hue: u8) Color.Rgb {
    const h = @as(u16, hue) * 6;
    const sector = h / 256;
    const frac: u8 = @intCast(h % 256);
    const inv: u8 = 255 - frac;

    return switch (sector) {
        0 => .{ .r = 255, .g = frac, .b = 0 },
        1 => .{ .r = inv, .g = 255, .b = 0 },
        2 => .{ .r = 0, .g = 255, .b = frac },
        3 => .{ .r = 0, .g = inv, .b = 255 },
        4 => .{ .r = frac, .g = 0, .b = 255 },
        else => .{ .r = 255, .g = 0, .b = inv },
    };
}
