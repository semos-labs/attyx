const grid_mod = @import("../term/grid.zig");
const Color = grid_mod.Color;

pub const Rgb = struct { r: u8, g: u8, b: u8 };

const default_fg = Rgb{ .r = 220, .g = 220, .b = 220 };
const default_bg = Rgb{ .r = 30, .g = 30, .b = 36 };

pub fn resolve(color: Color, is_bg: bool) Rgb {
    return switch (color) {
        .default => if (is_bg) default_bg else default_fg,
        .ansi => |n| ansi16[n],
        .palette => |n| paletteRgb(n),
        .rgb => |c| .{ .r = c.r, .g = c.g, .b = c.b },
    };
}

const ansi16 = [16]Rgb{
    .{ .r = 0, .g = 0, .b = 0 }, // 0  black
    .{ .r = 170, .g = 0, .b = 0 }, // 1  red
    .{ .r = 0, .g = 170, .b = 0 }, // 2  green
    .{ .r = 170, .g = 85, .b = 0 }, // 3  yellow
    .{ .r = 0, .g = 0, .b = 170 }, // 4  blue
    .{ .r = 170, .g = 0, .b = 170 }, // 5  magenta
    .{ .r = 0, .g = 170, .b = 170 }, // 6  cyan
    .{ .r = 170, .g = 170, .b = 170 }, // 7  white
    .{ .r = 85, .g = 85, .b = 85 }, // 8  bright black
    .{ .r = 255, .g = 85, .b = 85 }, // 9  bright red
    .{ .r = 85, .g = 255, .b = 85 }, // 10 bright green
    .{ .r = 255, .g = 255, .b = 85 }, // 11 bright yellow
    .{ .r = 85, .g = 85, .b = 255 }, // 12 bright blue
    .{ .r = 255, .g = 85, .b = 255 }, // 13 bright magenta
    .{ .r = 85, .g = 255, .b = 255 }, // 14 bright cyan
    .{ .r = 255, .g = 255, .b = 255 }, // 15 bright white
};

fn cubeComponent(idx: u8) u8 {
    if (idx == 0) return 0;
    return @intCast(@as(u16, 55) + @as(u16, idx) * 40);
}

fn paletteRgb(n: u8) Rgb {
    if (n < 16) return ansi16[n];
    if (n < 232) {
        const idx = n - 16;
        return .{
            .r = cubeComponent(idx / 36),
            .g = cubeComponent((idx / 6) % 6),
            .b = cubeComponent(idx % 6),
        };
    }
    const g: u8 = @intCast(@as(u16, 8) + @as(u16, n - 232) * 10);
    return .{ .r = g, .g = g, .b = g };
}
