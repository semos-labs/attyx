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

pub const PopupConfigEntry = struct {
    hotkey: []const u8, // "ctrl+shift+g"
    command: []const u8, // "lazygit"
    width: []const u8, // "80%"
    height: []const u8, // "80%"
    border: []const u8, // "single", "double", "rounded", "heavy", "none"
    border_color: []const u8, // "#RRGGBB" hex string
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
    cursor_trail: bool = false,

    // [background]
    background_opacity: f32 = 1.0,
    background_blur: u16 = 30,

    // [window]
    window_decorations: bool = true,
    window_padding_left: u16 = 0,
    window_padding_right: u16 = 0,
    window_padding_top: u16 = 0,
    window_padding_bottom: u16 = 0,

    // [program]
    program: ?[]const u8 = null,
    program_args: ?[]const []const u8 = null,

    // [logging]
    log_level: ?[]const u8 = null,
    log_file: ?[]const u8 = null,

    // [[popup]]
    popup_configs: ?[]PopupConfigEntry = null,
    _owned_popup_configs: ?[]PopupConfigEntry = null,

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
    _owned_log_level: ?[]const u8 = null,
    _owned_log_file: ?[]const u8 = null,

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
        if (self._owned_log_level) |s| alloc.free(s);
        if (self._owned_log_file)  |s| alloc.free(s);
        if (self._owned_popup_configs) |entries| {
            for (entries) |e| {
                alloc.free(e.hotkey);
                alloc.free(e.command);
                alloc.free(e.width);
                alloc.free(e.height);
                alloc.free(e.border);
                alloc.free(e.border_color);
            }
            alloc.free(entries);
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

/// Returns the path to the user's custom themes directory (e.g. ~/.config/attyx/themes).
/// Caller is responsible for freeing the returned string.
pub fn getThemesDir(allocator: std.mem.Allocator) ![]const u8 {
    var paths = try platform.getConfigPaths(allocator);
    defer paths.deinit();
    return std.fmt.allocPrint(allocator, "{s}/themes", .{paths.config_dir});
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
    if (Lookup.get(root, "cursor", "trail")) |v| {
        if (v == .bool) {
            config.cursor_trail = v.bool;
        } else {
            std.debug.print("error: {s}: cursor.trail must be a boolean\n", .{path});
            return error.ConfigValidationError;
        }
    }

    // [background]
    if (Lookup.get(root, "background", "opacity")) |v| {
        const raw: f64 = if (v == .float) v.float
            else if (v == .int) @floatFromInt(v.int)
            else {
                std.debug.print("error: {s}: background.opacity must be a number\n", .{path});
                return error.ConfigValidationError;
            };
        if (raw < 0.0 or raw > 1.0) {
            std.debug.print("error: {s}: background.opacity must be between 0.0 and 1.0\n", .{path});
            return error.ConfigValidationError;
        }
        config.background_opacity = @floatCast(raw);
    }
    if (Lookup.get(root, "background", "blur")) |v| {
        if (v == .int) {
            if (v.int < 0) {
                std.debug.print("error: {s}: background.blur must be >= 0\n", .{path});
                return error.ConfigValidationError;
            }
            config.background_blur = @intCast(v.int);
        } else {
            std.debug.print("error: {s}: background.blur must be an integer\n", .{path});
            return error.ConfigValidationError;
        }
    }

    // [window]
    if (Lookup.get(root, "window", "decorations")) |v| {
        if (v == .bool) {
            config.window_decorations = v.bool;
        } else {
            std.debug.print("error: {s}: window.decorations must be a boolean\n", .{path});
            return error.ConfigValidationError;
        }
    }
    // Padding shorthand: apply in increasing-specificity order so more-specific
    // keys override less-specific ones regardless of file ordering.
    if (Lookup.get(root, "window", "padding")) |v| {
        if (v == .int) {
            if (v.int < 0) {
                std.debug.print("error: {s}: window.padding must be >= 0\n", .{path});
                return error.ConfigValidationError;
            }
            const p: u16 = @intCast(v.int);
            config.window_padding_left   = p;
            config.window_padding_right  = p;
            config.window_padding_top    = p;
            config.window_padding_bottom = p;
        } else {
            std.debug.print("error: {s}: window.padding must be an integer\n", .{path});
            return error.ConfigValidationError;
        }
    }
    if (Lookup.get(root, "window", "padding_x")) |v| {
        if (v == .int) {
            if (v.int < 0) {
                std.debug.print("error: {s}: window.padding_x must be >= 0\n", .{path});
                return error.ConfigValidationError;
            }
            const p: u16 = @intCast(v.int);
            config.window_padding_left  = p;
            config.window_padding_right = p;
        } else {
            std.debug.print("error: {s}: window.padding_x must be an integer\n", .{path});
            return error.ConfigValidationError;
        }
    }
    if (Lookup.get(root, "window", "padding_y")) |v| {
        if (v == .int) {
            if (v.int < 0) {
                std.debug.print("error: {s}: window.padding_y must be >= 0\n", .{path});
                return error.ConfigValidationError;
            }
            const p: u16 = @intCast(v.int);
            config.window_padding_top    = p;
            config.window_padding_bottom = p;
        } else {
            std.debug.print("error: {s}: window.padding_y must be an integer\n", .{path});
            return error.ConfigValidationError;
        }
    }
    inline for (.{
        .{ "padding_left",   &config.window_padding_left   },
        .{ "padding_right",  &config.window_padding_right  },
        .{ "padding_top",    &config.window_padding_top    },
        .{ "padding_bottom", &config.window_padding_bottom },
    }) |kv| {
        if (Lookup.get(root, "window", kv[0])) |v| {
            if (v == .int) {
                if (v.int < 0) {
                    std.debug.print("error: {s}: window.{s} must be >= 0\n", .{ path, kv[0] });
                    return error.ConfigValidationError;
                }
                kv[1].* = @intCast(v.int);
            } else {
                std.debug.print("error: {s}: window.{s} must be an integer\n", .{ path, kv[0] });
                return error.ConfigValidationError;
            }
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

    // [logging]
    if (Lookup.get(root, "logging", "level")) |v| {
        if (v == .string) {
            const dupe = try allocator.dupe(u8, v.string);
            if (config._owned_log_level) |old| allocator.free(old);
            config.log_level = dupe;
            config._owned_log_level = dupe;
        } else {
            std.debug.print("error: {s}: logging.level must be a string\n", .{path});
            return error.ConfigValidationError;
        }
    }
    if (Lookup.get(root, "logging", "file")) |v| {
        if (v == .string) {
            const dupe = try allocator.dupe(u8, v.string);
            if (config._owned_log_file) |old| allocator.free(old);
            config.log_file = dupe;
            config._owned_log_file = dupe;
        } else {
            std.debug.print("error: {s}: logging.file must be a string\n", .{path});
            return error.ConfigValidationError;
        }
    }

    // [[popup]]
    if (root.get("popup")) |popup_val| {
        if (popup_val == .array) {
            const arr = popup_val.array.items;
            const count = @min(arr.len, @as(usize, 32)); // max 32 popups
            if (count > 0) {
                const entries = try allocator.alloc(PopupConfigEntry, count);
                var valid: usize = 0;
                for (arr[0..count]) |item| {
                    if (item != .table) continue;
                    const hotkey_v = item.table.get("hotkey") orelse continue;
                    const cmd_v = item.table.get("command") orelse continue;
                    if (hotkey_v != .string or cmd_v != .string) continue;
                    const width_v = item.table.get("width");
                    const height_v = item.table.get("height");
                    const border_v = item.table.get("border");
                    const border_color_v = item.table.get("border_color");
                    entries[valid] = .{
                        .hotkey = try allocator.dupe(u8, hotkey_v.string),
                        .command = try allocator.dupe(u8, cmd_v.string),
                        .width = if (width_v != null and width_v.? == .string) try allocator.dupe(u8, width_v.?.string) else try allocator.dupe(u8, "80%"),
                        .height = if (height_v != null and height_v.? == .string) try allocator.dupe(u8, height_v.?.string) else try allocator.dupe(u8, "80%"),
                        .border = if (border_v != null and border_v.? == .string) try allocator.dupe(u8, border_v.?.string) else try allocator.dupe(u8, "single"),
                        .border_color = if (border_color_v != null and border_color_v.? == .string) try allocator.dupe(u8, border_color_v.?.string) else try allocator.dupe(u8, "#78829a"),
                    };
                    valid += 1;
                }
                if (valid > 0) {
                    if (config._owned_popup_configs) |old| {
                        for (old) |e| {
                            allocator.free(e.hotkey);
                            allocator.free(e.command);
                            allocator.free(e.width);
                            allocator.free(e.height);
                            allocator.free(e.border);
                            allocator.free(e.border_color);
                        }
                        allocator.free(old);
                    }
                    config.popup_configs = entries[0..valid];
                    config._owned_popup_configs = entries;
                } else {
                    allocator.free(entries);
                }
            }
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

test "parse popup config" {
    const alloc = std.testing.allocator;
    var cfg = AppConfig{};
    defer cfg.deinit();

    const toml_str =
        \\[[popup]]
        \\hotkey = "ctrl+shift+g"
        \\command = "lazygit"
        \\width = "80%"
        \\height = "80%"
        \\
        \\[[popup]]
        \\hotkey = "ctrl+shift+t"
        \\command = "htop"
        \\width = "60%"
        \\height = "60%"
    ;

    try applyToml(alloc, toml_str, "<test>", &cfg);

    const entries = cfg.popup_configs orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("ctrl+shift+g", entries[0].hotkey);
    try std.testing.expectEqualStrings("lazygit", entries[0].command);
    try std.testing.expectEqualStrings("80%", entries[0].width);
    try std.testing.expectEqualStrings("single", entries[0].border);
    try std.testing.expectEqualStrings("#78829a", entries[0].border_color);
    try std.testing.expectEqualStrings("ctrl+shift+t", entries[1].hotkey);
    try std.testing.expectEqualStrings("htop", entries[1].command);
    try std.testing.expectEqualStrings("60%", entries[1].height);
    try std.testing.expectEqualStrings("single", entries[1].border);
    try std.testing.expectEqualStrings("#78829a", entries[1].border_color);
}
