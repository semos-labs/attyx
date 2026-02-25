const grid_mod = @import("grid.zig");
const actions_mod = @import("actions.zig");

const Color = grid_mod.Color;
const Style = grid_mod.Style;

/// Apply SGR (Select Graphic Rendition) parameters to a pen style.
/// Handles basic colors (30-37, 40-47), bright colors (90-97, 100-107),
/// 256-color (38;5;n, 48;5;n), truecolor (38;2;r;g;b, 48;2;r;g;b),
/// bold, underline, and reset codes.
pub fn applySgr(pen: *Style, sgr: actions_mod.Sgr) void {
    const params = sgr.params[0..sgr.len];
    var i: usize = 0;
    while (i < params.len) {
        const p = params[i];
        switch (p) {
            0 => {
                pen.* = .{};
                i += 1;
            },
            1 => {
                pen.bold = true;
                i += 1;
            },
            2 => {
                pen.dim = true;
                i += 1;
            },
            3 => {
                pen.italic = true;
                i += 1;
            },
            4 => {
                pen.underline = true;
                i += 1;
            },
            7 => {
                pen.reverse = true;
                i += 1;
            },
            9 => {
                pen.strikethrough = true;
                i += 1;
            },
            22 => {
                pen.bold = false;
                pen.dim = false;
                i += 1;
            },
            23 => {
                pen.italic = false;
                i += 1;
            },
            24 => {
                pen.underline = false;
                i += 1;
            },
            27 => {
                pen.reverse = false;
                i += 1;
            },
            29 => {
                pen.strikethrough = false;
                i += 1;
            },
            30...37 => {
                pen.fg = .{ .ansi = p - 30 };
                i += 1;
            },
            38 => {
                i = parseExtendedColor(pen, params, i, true);
            },
            39 => {
                pen.fg = .default;
                i += 1;
            },
            40...47 => {
                pen.bg = .{ .ansi = p - 40 };
                i += 1;
            },
            48 => {
                i = parseExtendedColor(pen, params, i, false);
            },
            49 => {
                pen.bg = .default;
                i += 1;
            },
            90...97 => {
                pen.fg = .{ .ansi = p - 82 };
                i += 1;
            },
            100...107 => {
                pen.bg = .{ .ansi = p - 92 };
                i += 1;
            },
            else => {
                i += 1;
            },
        }
    }
}

fn parseExtendedColor(pen: *Style, params: []const u8, start: usize, is_fg: bool) usize {
    var i = start + 1;
    if (i >= params.len) return i;

    if (params[i] == 5) {
        i += 1;
        if (i < params.len) {
            const color = Color{ .palette = params[i] };
            if (is_fg) {
                pen.fg = color;
            } else {
                pen.bg = color;
            }
            i += 1;
        }
    } else if (params[i] == 2) {
        i += 1;
        if (i + 2 < params.len) {
            const color = Color{ .rgb = .{
                .r = params[i],
                .g = params[i + 1],
                .b = params[i + 2],
            } };
            if (is_fg) {
                pen.fg = color;
            } else {
                pen.bg = color;
            }
            i += 3;
        }
    } else {
        i += 1;
    }

    return i;
}
