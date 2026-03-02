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

// ===========================================================================
// Tests
// ===========================================================================

const std = @import("std");
const testing = std.testing;

fn makeSgr(params_slice: []const u8) actions_mod.Sgr {
    var sgr = actions_mod.Sgr{};
    for (params_slice, 0..) |p, i| {
        sgr.params[i] = p;
    }
    sgr.len = @intCast(params_slice.len);
    return sgr;
}

test "sgr: reset (code 0)" {
    var pen = Style{ .bold = true, .fg = .{ .ansi = 1 } };
    applySgr(&pen, makeSgr(&.{0}));
    try testing.expectEqual(Style{}, pen);
}

test "sgr: bold/dim enable and disable" {
    var pen = Style{};
    applySgr(&pen, makeSgr(&.{1}));
    try testing.expect(pen.bold);
    applySgr(&pen, makeSgr(&.{2}));
    try testing.expect(pen.dim);
    applySgr(&pen, makeSgr(&.{22}));
    try testing.expect(!pen.bold);
    try testing.expect(!pen.dim);
}

test "sgr: italic enable and disable" {
    var pen = Style{};
    applySgr(&pen, makeSgr(&.{3}));
    try testing.expect(pen.italic);
    applySgr(&pen, makeSgr(&.{23}));
    try testing.expect(!pen.italic);
}

test "sgr: underline enable and disable" {
    var pen = Style{};
    applySgr(&pen, makeSgr(&.{4}));
    try testing.expect(pen.underline);
    applySgr(&pen, makeSgr(&.{24}));
    try testing.expect(!pen.underline);
}

test "sgr: reverse enable and disable" {
    var pen = Style{};
    applySgr(&pen, makeSgr(&.{7}));
    try testing.expect(pen.reverse);
    applySgr(&pen, makeSgr(&.{27}));
    try testing.expect(!pen.reverse);
}

test "sgr: strikethrough enable and disable" {
    var pen = Style{};
    applySgr(&pen, makeSgr(&.{9}));
    try testing.expect(pen.strikethrough);
    applySgr(&pen, makeSgr(&.{29}));
    try testing.expect(!pen.strikethrough);
}

test "sgr: ANSI fg 30-37" {
    var pen = Style{};
    for (30..38) |code| {
        applySgr(&pen, makeSgr(&.{@intCast(code)}));
        try testing.expectEqual(Color{ .ansi = @intCast(code - 30) }, pen.fg);
    }
}

test "sgr: ANSI bg 40-47" {
    var pen = Style{};
    for (40..48) |code| {
        applySgr(&pen, makeSgr(&.{@intCast(code)}));
        try testing.expectEqual(Color{ .ansi = @intCast(code - 40) }, pen.bg);
    }
}

test "sgr: bright fg 90-97" {
    var pen = Style{};
    for (90..98) |code| {
        applySgr(&pen, makeSgr(&.{@intCast(code)}));
        try testing.expectEqual(Color{ .ansi = @intCast(code - 82) }, pen.fg);
    }
}

test "sgr: bright bg 100-107" {
    var pen = Style{};
    for (100..108) |code| {
        applySgr(&pen, makeSgr(&.{@intCast(code)}));
        try testing.expectEqual(Color{ .ansi = @intCast(code - 92) }, pen.bg);
    }
}

test "sgr: 256-color fg (38;5;N)" {
    var pen = Style{};
    applySgr(&pen, makeSgr(&.{ 38, 5, 196 }));
    try testing.expectEqual(Color{ .palette = 196 }, pen.fg);
}

test "sgr: 256-color bg (48;5;N)" {
    var pen = Style{};
    applySgr(&pen, makeSgr(&.{ 48, 5, 22 }));
    try testing.expectEqual(Color{ .palette = 22 }, pen.bg);
}

test "sgr: truecolor fg (38;2;R;G;B)" {
    var pen = Style{};
    applySgr(&pen, makeSgr(&.{ 38, 2, 255, 128, 0 }));
    try testing.expectEqual(Color{ .rgb = .{ .r = 255, .g = 128, .b = 0 } }, pen.fg);
}

test "sgr: truecolor bg (48;2;R;G;B)" {
    var pen = Style{};
    applySgr(&pen, makeSgr(&.{ 48, 2, 10, 20, 30 }));
    try testing.expectEqual(Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } }, pen.bg);
}

test "sgr: default reset 39/49" {
    var pen = Style{ .fg = .{ .ansi = 1 }, .bg = .{ .ansi = 2 } };
    applySgr(&pen, makeSgr(&.{39}));
    try testing.expectEqual(Color.default, pen.fg);
    try testing.expectEqual(Color{ .ansi = 2 }, pen.bg);
    applySgr(&pen, makeSgr(&.{49}));
    try testing.expectEqual(Color.default, pen.bg);
}

test "sgr: unknown codes ignored" {
    var pen = Style{};
    applySgr(&pen, makeSgr(&.{99}));
    try testing.expectEqual(Style{}, pen);
}

test "sgr: truncated extended color (38 alone)" {
    var pen = Style{};
    applySgr(&pen, makeSgr(&.{38}));
    try testing.expectEqual(Color.default, pen.fg);
}

test "sgr: truncated 256 color (38;5 without index)" {
    var pen = Style{};
    applySgr(&pen, makeSgr(&.{ 38, 5 }));
    try testing.expectEqual(Color.default, pen.fg);
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
