// Attyx — Declarative overlay UI types
// Element tree primitives for building overlay content declaratively.

const std = @import("std");

pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const StyledCell = struct {
    char: u21 = ' ',
    combining: [2]u21 = .{ 0, 0 },
    fg: Rgb = .{ .r = 220, .g = 220, .b = 220 },
    bg: Rgb = .{ .r = 30, .g = 30, .b = 40 },
    bg_alpha: u8 = 230,
    flags: u8 = 0, // bit 0=bold, 1=underline, 3=dim, 4=italic, 5=strikethrough
};

// ---------------------------------------------------------------------------
// Size values (cells or percent of available space)
// ---------------------------------------------------------------------------

pub const SizeValue = union(enum) {
    cells: u16,
    percent: u8, // 0–100, resolved against parent's available space

    pub fn resolve(self: SizeValue, available: u16) u16 {
        return switch (self) {
            .cells => |c| @min(c, available),
            .percent => |p| @intCast(@min(@as(u32, available) * p / 100, available)),
        };
    }
};

// ---------------------------------------------------------------------------
// Text flags (packed, matches StyledCell.flags bit layout)
// ---------------------------------------------------------------------------

pub const TextFlags = packed struct(u8) {
    bold: bool = false, // bit 0
    underline: bool = false, // bit 1
    _pad0: bool = false, // bit 2 (reserved)
    dim: bool = false, // bit 3
    italic: bool = false, // bit 4
    strikethrough: bool = false, // bit 5
    _pad1: u2 = 0, // bits 6-7

    pub fn toU8(self: TextFlags) u8 {
        return @bitCast(self);
    }

    pub fn fromU8(v: u8) TextFlags {
        return @bitCast(v);
    }
};

// ---------------------------------------------------------------------------
// Style (nullable fields inherit from parent)
// ---------------------------------------------------------------------------

pub const Style = struct {
    fg: ?Rgb = null,
    bg: ?Rgb = null,
    bg_alpha: ?u8 = null,
    text_flags: TextFlags = .{},
};

// ---------------------------------------------------------------------------
// Resolved style (all fields concrete, no nulls)
// ---------------------------------------------------------------------------

pub const ResolvedStyle = struct {
    fg: Rgb,
    bg: Rgb,
    bg_alpha: u8,
    text_flags: TextFlags,

    /// Merge child Style onto parent — null fields inherit from parent.
    pub fn merge(self: ResolvedStyle, child: Style) ResolvedStyle {
        return .{
            .fg = child.fg orelse self.fg,
            .bg = child.bg orelse self.bg,
            .bg_alpha = child.bg_alpha orelse self.bg_alpha,
            .text_flags = .{
                .bold = child.text_flags.bold or self.text_flags.bold,
                .underline = child.text_flags.underline or self.text_flags.underline,
                .dim = child.text_flags.dim or self.text_flags.dim,
                .italic = child.text_flags.italic or self.text_flags.italic,
                .strikethrough = child.text_flags.strikethrough or self.text_flags.strikethrough,
            },
        };
    }
};

// ---------------------------------------------------------------------------
// Padding
// ---------------------------------------------------------------------------

pub const Padding = struct {
    top: u16 = 0,
    bottom: u16 = 0,
    left: u16 = 0,
    right: u16 = 0,

    pub fn uniform(n: u16) Padding {
        return .{ .top = n, .bottom = n, .left = n, .right = n };
    }

    pub fn symmetric(v: u16, h: u16) Padding {
        return .{ .top = v, .bottom = v, .left = h, .right = h };
    }
};

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

pub const Direction = enum { vertical, horizontal };
pub const Align = enum { left, center, right };
pub const BorderStyle = enum { none, single, rounded };

// ---------------------------------------------------------------------------
// Element (tagged union — the core UI tree node)
// ---------------------------------------------------------------------------

pub const Element = union(enum) {
    box: Box,
    text: Text,
    input: Input,
    list: List,
    menu: Menu,
    hint: Hint,

    pub const Box = struct {
        children: []const Element = &.{},
        direction: Direction = .vertical,
        padding: Padding = .{},
        border: BorderStyle = .none,
        style: Style = .{},
        width: ?SizeValue = null,
        min_width: ?SizeValue = null,
        max_width: ?SizeValue = null,
        height: ?SizeValue = null,
        min_height: ?SizeValue = null,
        max_height: ?SizeValue = null,
        fill_width: bool = false,
    };

    pub const Text = struct {
        content: []const u8,
        style: Style = .{},
        wrap: bool = true,
        alignment: Align = .left,
    };

    pub const Input = struct {
        value: []const u8 = "",
        cursor_pos: u16 = 0,
        placeholder: []const u8 = "",
        style: Style = .{},
        cursor_style: CursorStyle = .{},
        width: ?SizeValue = null,

        pub const CursorStyle = struct {
            fg: ?Rgb = null,
            bg: ?Rgb = null,
        };
    };

    pub const List = struct {
        items: []const Element = &.{},
        scroll_offset: u16 = 0,
        visible_count: ?u16 = null,
        style: Style = .{},
    };

    pub const Menu = struct {
        items: []const MenuItem = &.{},
        selected: u16 = 0,
        scroll_offset: u16 = 0,
        visible_count: ?u16 = null,
        style: Style = .{},
        selected_style: Style = .{},
    };

    pub const MenuItem = struct {
        label: []const u8,
        hint_text: []const u8 = "",
        enabled: bool = true,
    };

    pub const Hint = struct {
        content: []const u8,
        style: Style = .{ .text_flags = .{ .dim = true } },
        alignment: Align = .left,
    };
};

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------

pub const OverlayTheme = struct {
    fg: Rgb = .{ .r = 220, .g = 220, .b = 220 },
    bg: Rgb = .{ .r = 30, .g = 30, .b = 40 },
    bg_alpha: u8 = 230,
    border_color: Rgb = .{ .r = 80, .g = 80, .b = 120 },
    cursor_fg: Rgb = .{ .r = 0, .g = 0, .b = 0 },
    cursor_bg: Rgb = .{ .r = 220, .g = 220, .b = 220 },
    selected_bg: Rgb = .{ .r = 60, .g = 60, .b = 100 },
    selected_fg: Rgb = .{ .r = 255, .g = 255, .b = 255 },
    hint_fg: Rgb = .{ .r = 120, .g = 120, .b = 140 },

    pub fn rootStyle(self: OverlayTheme) ResolvedStyle {
        return .{
            .fg = self.fg,
            .bg = self.bg,
            .bg_alpha = self.bg_alpha,
            .text_flags = .{},
        };
    }
};

// ---------------------------------------------------------------------------
// Size (measurement result)
// ---------------------------------------------------------------------------

pub const Size = struct {
    width: u16,
    height: u16,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "SizeValue.resolve cells" {
    const sv = SizeValue{ .cells = 20 };
    try std.testing.expectEqual(@as(u16, 20), sv.resolve(80));
    // Clamped to available
    try std.testing.expectEqual(@as(u16, 10), sv.resolve(10));
}

test "SizeValue.resolve percent" {
    const sv = SizeValue{ .percent = 50 };
    try std.testing.expectEqual(@as(u16, 40), sv.resolve(80));
    try std.testing.expectEqual(@as(u16, 0), sv.resolve(0));
    const full = SizeValue{ .percent = 100 };
    try std.testing.expectEqual(@as(u16, 80), full.resolve(80));
}

test "ResolvedStyle.merge inherits nulls" {
    const parent = ResolvedStyle{
        .fg = .{ .r = 100, .g = 100, .b = 100 },
        .bg = .{ .r = 10, .g = 10, .b = 10 },
        .bg_alpha = 200,
        .text_flags = .{ .bold = true },
    };
    const child = Style{ .fg = .{ .r = 255, .g = 0, .b = 0 } };
    const merged = parent.merge(child);
    // fg overridden
    try std.testing.expectEqual(@as(u8, 255), merged.fg.r);
    // bg inherited
    try std.testing.expectEqual(@as(u8, 10), merged.bg.r);
    // bold inherited
    try std.testing.expect(merged.text_flags.bold);
}

test "Padding.uniform" {
    const p = Padding.uniform(3);
    try std.testing.expectEqual(@as(u16, 3), p.top);
    try std.testing.expectEqual(@as(u16, 3), p.left);
    try std.testing.expectEqual(@as(u16, 3), p.bottom);
    try std.testing.expectEqual(@as(u16, 3), p.right);
}

test "Padding.symmetric" {
    const p = Padding.symmetric(2, 4);
    try std.testing.expectEqual(@as(u16, 2), p.top);
    try std.testing.expectEqual(@as(u16, 2), p.bottom);
    try std.testing.expectEqual(@as(u16, 4), p.left);
    try std.testing.expectEqual(@as(u16, 4), p.right);
}

test "TextFlags bit layout" {
    const f = TextFlags{ .bold = true, .underline = true, .dim = true };
    try std.testing.expectEqual(@as(u8, 0x0B), f.toU8());
    const f2 = TextFlags.fromU8(0x20);
    try std.testing.expect(f2.strikethrough);
    try std.testing.expect(!f2.bold);
}
