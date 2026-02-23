const std = @import("std");
const toml = @import("toml");
const platform = @import("../platform/platform.zig");

/// Abstract cursor shape (config-level). Maps to CursorShape enum with blink.
pub const CursorShapeConfig = enum {
    block,
    beam,
    underline,

    pub fn fromString(s: []const u8) ?CursorShapeConfig {
        if (std.mem.eql(u8, s, "block")) return .block;
        if (std.mem.eql(u8, s, "beam")) return .beam;
        if (std.mem.eql(u8, s, "underline")) return .underline;
        return null;
    }

    pub fn toString(self: CursorShapeConfig) []const u8 {
        return switch (self) {
            .block => "block",
            .beam => "beam",
            .underline => "underline",
        };
    }
};

/// Cell size: auto (from font metrics), absolute points, or percentage of font-derived base.
///
/// Encoding passed to the C bridge (g_cell_width / g_cell_height):
///   0        → auto: renderer derives from font metrics
///   > 0      → fixed: exact point value (renderer multiplies by DPI scale)
///   < 0      → percent: renderer applies abs(value)% to its font-derived dimension
///              e.g. -115 means "font-derived × 115 / 100"
pub const CellSize = union(enum) {
    auto,
    pixels: u16,
    percent: u16,

    /// Parse from a string: "10" → pixels, "110%" → percent.
    pub fn fromString(s: []const u8) ?CellSize {
        if (s.len > 0 and s[s.len - 1] == '%') {
            const num = std.fmt.parseInt(u16, s[0 .. s.len - 1], 10) catch return null;
            if (num == 0) return null;
            return .{ .percent = num };
        }
        const num = std.fmt.parseInt(u16, s, 10) catch return null;
        if (num == 0) return null;
        return .{ .pixels = num };
    }

    /// Encode for the C bridge.
    ///   auto    → 0
    ///   pixels  → +N (fixed points)
    ///   percent → -N (renderer applies N% to its font-derived base)
    pub fn encode(self: CellSize) i32 {
        return switch (self) {
            .auto => 0,
            .pixels => |v| @intCast(v),
            .percent => |pct| -@as(i32, pct),
        };
    }
};

/// Merged application configuration. Precedence: Defaults < ConfigFile < CLI flags.
pub const AppConfig = struct {
    // [font]
    font_family: []const u8 = "JetBrains Mono",
    font_size: u16 = 14,
    cell_width: CellSize = .auto,
    cell_height: CellSize = .auto,
    font_fallback: ?[]const []const u8 = null,

    // [theme]
    theme_name: []const u8 = "default",

    // [scrollback]
    scrollback_lines: u32 = 20_000,

    // [reflow]
    reflow_enabled: bool = true,

    // [cursor]
    cursor_shape: CursorShapeConfig = .block,
    cursor_blink: bool = true,

    // [program]
    program: ?[]const u8 = null,
    program_args: ?[]const []const u8 = null,

    // Runtime (CLI-only, not from config file)
    rows: u16 = 24,
    cols: u16 = 80,
    argv: ?[]const [:0]const u8 = null,

    // Allocated strings that we own (for cleanup)
    _allocator: ?std.mem.Allocator = null,
    _owned_font_family: ?[]const u8 = null,
    _owned_theme_name: ?[]const u8 = null,
    _owned_fallback_items: ?[]const []const u8 = null,
    _owned_program: ?[]const u8 = null,
    _owned_program_args: ?[]const []const u8 = null,

    pub fn deinit(self: *AppConfig) void {
        const alloc = self._allocator orelse return;
        if (self._owned_font_family) |s| alloc.free(s);
        if (self._owned_theme_name) |s| alloc.free(s);
        if (self._owned_fallback_items) |items| {
            for (items) |item| alloc.free(item);
            alloc.free(items);
        }
        if (self._owned_program) |s| alloc.free(s);
        if (self._owned_program_args) |items| {
            for (items) |item| alloc.free(item);
            alloc.free(items);
        }
    }

    fn formatCellSize(cs: CellSize, buf: *[32]u8) []const u8 {
        return switch (cs) {
            .auto => "0",
            .pixels => |v| std.fmt.bufPrint(buf, "{d}", .{v}) catch "0",
            .percent => |v| std.fmt.bufPrint(buf, "\"{d}%\"", .{v}) catch "\"100%\"",
        };
    }

    pub fn formatConfig(self: *const AppConfig, allocator: std.mem.Allocator) ![]const u8 {
        const fallback_str = if (self.font_fallback) |fallback| blk: {
            var fb_buf = std.ArrayList(u8).initCapacity(allocator, 128) catch
                break :blk @as([]const u8, "");
            const w = fb_buf.writer(allocator);
            w.writeAll("fallback = [") catch break :blk @as([]const u8, "");
            for (fallback, 0..) |item, i| {
                if (i > 0) w.writeAll(", ") catch {};
                w.print("\"{s}\"", .{item}) catch {};
            }
            w.writeAll("]\n") catch {};
            break :blk fb_buf.toOwnedSlice(allocator) catch @as([]const u8, "");
        } else @as([]const u8, "");
        defer if (self.font_fallback != null) allocator.free(fallback_str);

        var cw_buf: [32]u8 = undefined;
        var ch_buf: [32]u8 = undefined;
        const cw_str = formatCellSize(self.cell_width, &cw_buf);
        const ch_str = formatCellSize(self.cell_height, &ch_buf);

        return std.fmt.allocPrint(allocator,
            \\[font]
            \\family = "{s}"
            \\size = {d}
            \\cell_width = {s}
            \\cell_height = {s}
            \\{s}
            \\[theme]
            \\name = "{s}"
            \\
            \\[scrollback]
            \\lines = {d}
            \\
            \\[reflow]
            \\enabled = {s}
            \\
            \\[cursor]
            \\shape = "{s}"
            \\blink = {s}
            \\
            \\[program]
            \\shell = "{s}"
            \\
        , .{
            self.font_family,
            self.font_size,
            cw_str,
            ch_str,
            fallback_str,
            self.theme_name,
            self.scrollback_lines,
            if (self.reflow_enabled) "true" else "false",
            self.cursor_shape.toString(),
            if (self.cursor_blink) "true" else "false",
            self.program orelse std.posix.getenv("SHELL") orelse "/bin/sh",
        });
    }
};

/// Load and merge config from TOML file into an existing AppConfig.
/// File errors (not found) are silently ignored; parse/validation errors are fatal.
pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8, config: *AppConfig) !void {
    const file_content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            std.debug.print("error: cannot read config file: {s}\n", .{path});
            return err;
        },
    };
    defer allocator.free(file_content);

    return applyToml(allocator, file_content, path, config);
}

/// Load config from the default XDG location.
pub fn loadFromDefaultPath(allocator: std.mem.Allocator, config: *AppConfig) !void {
    var paths = platform.getConfigPaths(allocator) catch return;
    defer paths.deinit();

    const config_file = std.fmt.allocPrint(allocator, "{s}/attyx.toml", .{paths.config_dir}) catch return;
    defer allocator.free(config_file);

    return loadFromFile(allocator, config_file, config);
}

fn parseCellSize(v: toml.TomlValue, path: []const u8, field: []const u8) ?CellSize {
    if (v == .int) {
        if (v.int == 0) return .auto;
        if (v.int < 0) {
            std.debug.print("error: {s}: {s} must be >= 0\n", .{ path, field });
            return null;
        }
        return .{ .pixels = @intCast(v.int) };
    }
    if (v == .string) {
        if (CellSize.fromString(v.string)) |cs| return cs;
        std.debug.print("error: {s}: {s} must be an integer or a percentage string (e.g. \"110%\")\n", .{ path, field });
        return null;
    }
    std.debug.print("error: {s}: {s} must be an integer or a percentage string\n", .{ path, field });
    return null;
}

fn applyToml(allocator: std.mem.Allocator, content: []const u8, path: []const u8, config: *AppConfig) !void {
    const parser = toml.Parser.init(allocator) catch {
        std.debug.print("error: failed to initialize TOML parser\n", .{});
        return error.ConfigParseError;
    };
    defer parser.deinit();

    const doc = parser.parse_string(content) catch {
        if (parser.get_error_context()) |ctx| {
            std.debug.print("error: {s}: TOML parse error at line {d}\n", .{ path, ctx.line_number });
        } else {
            std.debug.print("error: {s}: TOML parse error\n", .{path});
        }
        return error.ConfigParseError;
    };
    defer doc.deinit();

    const root = doc.get_table();

    // Helper: look up a key inside a section table. Returns null if the
    // section doesn't exist or the key doesn't exist in that section.
    const Lookup = struct {
        fn get(table: *const toml.TomlTable, section: []const u8, key: []const u8) ?toml.TomlValue {
            const sec_val = table.get(section) orelse return null;
            if (sec_val != .table) return null;
            return sec_val.table.get(key);
        }
    };

    // [font]
    if (Lookup.get(root, "font", "family")) |v| {
        if (v == .string) {
            const dupe = try allocator.dupe(u8, v.string);
            if (config._owned_font_family) |old| allocator.free(old);
            config.font_family = dupe;
            config._owned_font_family = dupe;
        } else {
            std.debug.print("error: {s}: font.family must be a string\n", .{path});
            return error.ConfigValidationError;
        }
    }
    if (Lookup.get(root, "font", "size")) |v| {
        if (v == .int) {
            if (v.int <= 0) {
                std.debug.print("error: {s}: font.size must be > 0\n", .{path});
                return error.ConfigValidationError;
            }
            config.font_size = @intCast(v.int);
        } else {
            std.debug.print("error: {s}: font.size must be an integer\n", .{path});
            return error.ConfigValidationError;
        }
    }
    if (Lookup.get(root, "font", "cell_width")) |v| {
        config.cell_width = parseCellSize(v, path, "font.cell_width") orelse
            return error.ConfigValidationError;
    }
    if (Lookup.get(root, "font", "cell_height")) |v| {
        config.cell_height = parseCellSize(v, path, "font.cell_height") orelse
            return error.ConfigValidationError;
    }
    if (Lookup.get(root, "font", "fallback")) |v| {
        if (v == .array) {
            const items = try allocator.alloc([]const u8, v.array.items.len);
            for (v.array.items, 0..) |item, idx| {
                if (item == .string) {
                    items[idx] = try allocator.dupe(u8, item.string);
                } else {
                    for (items[0..idx]) |prev| allocator.free(prev);
                    allocator.free(items);
                    std.debug.print("error: {s}: font.fallback entries must be strings\n", .{path});
                    return error.ConfigValidationError;
                }
            }
            if (config._owned_fallback_items) |old_items| {
                for (old_items) |old| allocator.free(old);
                allocator.free(old_items);
            }
            config.font_fallback = items;
            config._owned_fallback_items = items;
        } else {
            std.debug.print("error: {s}: font.fallback must be an array of strings\n", .{path});
            return error.ConfigValidationError;
        }
    }

    // [theme]
    if (Lookup.get(root, "theme", "name")) |v| {
        if (v == .string) {
            const dupe = try allocator.dupe(u8, v.string);
            if (config._owned_theme_name) |old| allocator.free(old);
            config.theme_name = dupe;
            config._owned_theme_name = dupe;
        } else {
            std.debug.print("error: {s}: theme.name must be a string\n", .{path});
            return error.ConfigValidationError;
        }
    }

    // [scrollback]
    if (Lookup.get(root, "scrollback", "lines")) |v| {
        if (v == .int) {
            if (v.int < 0) {
                std.debug.print("error: {s}: scrollback.lines must be >= 0\n", .{path});
                return error.ConfigValidationError;
            }
            config.scrollback_lines = @intCast(v.int);
        } else {
            std.debug.print("error: {s}: scrollback.lines must be an integer\n", .{path});
            return error.ConfigValidationError;
        }
    }

    // [reflow]
    if (Lookup.get(root, "reflow", "enabled")) |v| {
        if (v == .bool) {
            config.reflow_enabled = v.bool;
        } else {
            std.debug.print("error: {s}: reflow.enabled must be a boolean\n", .{path});
            return error.ConfigValidationError;
        }
    }

    // [cursor]
    if (Lookup.get(root, "cursor", "shape")) |v| {
        if (v == .string) {
            if (CursorShapeConfig.fromString(v.string)) |shape| {
                config.cursor_shape = shape;
            } else {
                std.debug.print("error: {s}: cursor.shape must be \"block\", \"beam\", or \"underline\"\n", .{path});
                return error.ConfigValidationError;
            }
        } else {
            std.debug.print("error: {s}: cursor.shape must be a string\n", .{path});
            return error.ConfigValidationError;
        }
    }
    if (Lookup.get(root, "cursor", "blink")) |v| {
        if (v == .bool) {
            config.cursor_blink = v.bool;
        } else {
            std.debug.print("error: {s}: cursor.blink must be a boolean\n", .{path});
            return error.ConfigValidationError;
        }
    }

    // [program]
    if (Lookup.get(root, "program", "shell")) |v| {
        if (v == .string) {
            const dupe = try allocator.dupe(u8, v.string);
            if (config._owned_program) |old| allocator.free(old);
            config.program = dupe;
            config._owned_program = dupe;
        } else {
            std.debug.print("error: {s}: program.shell must be a string\n", .{path});
            return error.ConfigValidationError;
        }
    }
    if (Lookup.get(root, "program", "args")) |v| {
        if (v == .array) {
            const items = try allocator.alloc([]const u8, v.array.items.len);
            for (v.array.items, 0..) |item, idx| {
                if (item == .string) {
                    items[idx] = try allocator.dupe(u8, item.string);
                } else {
                    for (items[0..idx]) |prev| allocator.free(prev);
                    allocator.free(items);
                    std.debug.print("error: {s}: program.args entries must be strings\n", .{path});
                    return error.ConfigValidationError;
                }
            }
            if (config._owned_program_args) |old_items| {
                for (old_items) |old| allocator.free(old);
                allocator.free(old_items);
            }
            config.program_args = items;
            config._owned_program_args = items;
        } else {
            std.debug.print("error: {s}: program.args must be an array of strings\n", .{path});
            return error.ConfigValidationError;
        }
    }

    config._allocator = allocator;
}

test "default config has expected values" {
    const cfg = AppConfig{};
    try std.testing.expectEqual(@as(u16, 14), cfg.font_size);
    try std.testing.expectEqual(@as(u32, 20_000), cfg.scrollback_lines);
    try std.testing.expect(cfg.reflow_enabled);
    try std.testing.expect(cfg.cursor_blink);
    try std.testing.expectEqual(CursorShapeConfig.block, cfg.cursor_shape);
}

test "parse minimal toml config" {
    const alloc = std.testing.allocator;
    var cfg = AppConfig{};
    defer cfg.deinit();

    const toml_str =
        \\[font]
        \\family = "Fira Code"
        \\size = 16
        \\
        \\[scrollback]
        \\lines = 5000
        \\
        \\[cursor]
        \\shape = "beam"
        \\blink = false
    ;

    try applyToml(alloc, toml_str, "<test>", &cfg);

    try std.testing.expectEqualStrings("Fira Code", cfg.font_family);
    try std.testing.expectEqual(@as(u16, 16), cfg.font_size);
    try std.testing.expectEqual(@as(u32, 5000), cfg.scrollback_lines);
    try std.testing.expectEqual(CursorShapeConfig.beam, cfg.cursor_shape);
    try std.testing.expect(!cfg.cursor_blink);
}

test "invalid font.size rejects" {
    const alloc = std.testing.allocator;
    var cfg = AppConfig{};

    const toml_str =
        \\[font]
        \\size = 0
    ;

    try std.testing.expectError(error.ConfigValidationError, applyToml(alloc, toml_str, "<test>", &cfg));
}

test "invalid cursor.shape rejects" {
    const alloc = std.testing.allocator;
    var cfg = AppConfig{};

    const toml_str =
        \\[cursor]
        \\shape = "triangle"
    ;

    try std.testing.expectError(error.ConfigValidationError, applyToml(alloc, toml_str, "<test>", &cfg));
}
