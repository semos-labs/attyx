const std = @import("std");
const toml = @import("toml");

/// 8-bit RGB color.
pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    /// Parse "#rrggbb" or "rrggbb". Returns null on invalid input.
    pub fn fromHex(hex: []const u8) ?Rgb {
        var s = hex;
        if (s.len > 0 and s[0] == '#') s = s[1..];
        if (s.len != 6) return null;
        const r = std.fmt.parseInt(u8, s[0..2], 16) catch return null;
        const g = std.fmt.parseInt(u8, s[2..4], 16) catch return null;
        const b = std.fmt.parseInt(u8, s[4..6], 16) catch return null;
        return .{ .r = r, .g = g, .b = b };
    }
};

/// A terminal color theme.
pub const Theme = struct {
    /// Default text (foreground) color.
    foreground: Rgb,
    /// Default background color.
    background: Rgb,
    /// Cursor color. null = use foreground color.
    cursor: ?Rgb = null,
    /// Text color drawn under the cursor. null = use background color.
    cursor_text: ?Rgb = null,
    /// Selection highlight background. null = renderer default.
    selection_background: ?Rgb = null,
    /// Selection highlight foreground. null = cell foreground.
    selection_foreground: ?Rgb = null,
    /// 16-color ANSI palette, indices 0–15. null entries = renderer built-in.
    palette: [16]?Rgb = [_]?Rgb{null} ** 16,

    /// The built-in default theme, matching the renderer's hard-coded colors.
    pub fn default() Theme {
        return .{
            .foreground = .{ .r = 220, .g = 220, .b = 220 },
            .background = .{ .r = 30, .g = 30, .b = 36 },
        };
    }
};

/// Parse a Theme from TOML content.
/// `source` is used only in diagnostic log messages (e.g., a file path or theme name).
pub fn parseTheme(allocator: std.mem.Allocator, content: []const u8, source: []const u8) !Theme {
    const parser = toml.Parser.init(allocator) catch return error.ThemeParseError;
    defer parser.deinit();

    const doc = parser.parse_string(content) catch {
        if (parser.get_error_context()) |ctx| {
            std.log.warn("theme '{s}': TOML parse error at line {d}", .{ source, ctx.line_number });
        } else {
            std.log.warn("theme '{s}': TOML parse error", .{source});
        }
        return error.ThemeParseError;
    };
    defer doc.deinit();

    const root = doc.get_table();
    var theme = Theme.default();

    // [colors]
    if (root.get("colors")) |cv| {
        if (cv != .table) {
            std.log.warn("theme '{s}': [colors] must be a table", .{source});
            return error.ThemeValidationError;
        }
        const ct = cv.table;
        inline for (.{
            "foreground",
            "background",
            "cursor",
            "cursor_text",
            "selection_background",
            "selection_foreground",
        }) |key| {
            if (ct.get(key)) |v| {
                if (v != .string) {
                    std.log.warn("theme '{s}': colors.{s} must be a string", .{ source, key });
                    return error.ThemeValidationError;
                }
                const rgb = Rgb.fromHex(v.string) orelse {
                    std.log.warn("theme '{s}': colors.{s} is not a valid hex color", .{ source, key });
                    return error.ThemeValidationError;
                };
                @field(theme, key) = rgb;
            }
        }
    }

    // [palette] — bare-key integers "0" through "15" are valid TOML
    if (root.get("palette")) |pv| {
        if (pv == .table) {
            const pt = pv.table;
            for (0..16) |i| {
                var kbuf: [3]u8 = undefined;
                const k = std.fmt.bufPrint(&kbuf, "{d}", .{i}) catch continue;
                if (pt.get(k)) |v| {
                    if (v != .string) {
                        std.log.warn("theme '{s}': palette.{d} must be a string", .{ source, i });
                        return error.ThemeValidationError;
                    }
                    theme.palette[i] = Rgb.fromHex(v.string) orelse {
                        std.log.warn("theme '{s}': palette.{d} is not a valid hex color", .{ source, i });
                        return error.ThemeValidationError;
                    };
                }
            }
        }
    }

    return theme;
}

test "Rgb.fromHex" {
    const t = std.testing;
    const c = Rgb.fromHex("#1e1e24").?;
    try t.expectEqual(@as(u8, 0x1e), c.r);
    try t.expectEqual(@as(u8, 0x1e), c.g);
    try t.expectEqual(@as(u8, 0x24), c.b);

    try t.expect(Rgb.fromHex("gggggg") == null);
    try t.expect(Rgb.fromHex("#12345") == null); // wrong length
    try t.expect(Rgb.fromHex("") == null);
}
