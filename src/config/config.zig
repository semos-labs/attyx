const std = @import("std");
const platform = @import("../platform/platform.zig");
const theme_mod = @import("../theme/theme.zig");
pub const Rgb = theme_mod.Rgb;
const config_parse = @import("config_parse.zig");
pub const statusbar_config = @import("statusbar_config.zig");
pub const StatusbarConfig = statusbar_config.StatusbarConfig;

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

/// Tab appearance: built-in overlay bar (default) or macOS native window tabs.
pub const TabAppearance = enum {
    builtin,
    native,

    pub fn fromString(s: []const u8) ?TabAppearance {
        if (std.mem.eql(u8, s, "builtin")) return .builtin;
        if (std.mem.eql(u8, s, "native")) return .native;
        return null;
    }
};

const keybinds = @import("keybinds.zig");
pub const KeybindOverride = keybinds.KeybindOverride;
pub const SequenceEntry = keybinds.SequenceEntry;

pub const PopupConfigEntry = struct {
    hotkey: []const u8, // "ctrl+shift+g"
    command: []const u8, // "lazygit"
    width: []const u8, // "80%"
    height: []const u8, // "80%"
    border: []const u8, // "single", "double", "rounded", "heavy", "none"
    border_color: []const u8, // "#RRGGBB" hex string
    on_return_cmd: ?[]const u8 = null, // command to run with popup output on exit 0
    inject_alt: bool = false, // inject on_return_cmd even when alt screen is active
    background_opacity: ?f32 = null, // 0.0 (transparent) – 1.0 (opaque)
    background: []const u8 = "", // "#RRGGBB" hex color override; empty = use theme
    padding: ?u16 = null,
    padding_x: ?u16 = null,
    padding_y: ?u16 = null,
    padding_top: ?u16 = null,
    padding_bottom: ?u16 = null,
    padding_left: ?u16 = null,
    padding_right: ?u16 = null,
};

/// Merged application configuration. Precedence: Defaults < ConfigFile < CLI flags.
pub const AppConfig = struct {
    // [font]
    font_family: []const u8 = "JetBrains Mono",
    font_size: u16 = 14,
    cell_width: CellSize = .auto,
    cell_height: CellSize = .auto,
    font_fallback: ?[]const []const u8 = null,
    font_ligatures: bool = true,

    // [theme]
    theme_name: []const u8 = "default",
    theme_background: ?Rgb = null,

    // [scrollback]
    scrollback_lines: u32 = 5_000,

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
    working_directory: ?[]const u8 = null,

    // [logging]
    log_level: ?[]const u8 = null,
    log_file: ?[]const u8 = null,

    // [[popup]]
    popup_configs: ?[]PopupConfigEntry = null,
    _owned_popup_configs: ?[]PopupConfigEntry = null,

    // [keybindings]
    keybind_overrides: ?[]KeybindOverride = null,
    _owned_keybind_overrides: ?[]KeybindOverride = null,

    // [sequences]
    sequence_entries: ?[]SequenceEntry = null,
    _owned_sequence_entries: ?[]SequenceEntry = null,

    // [statusbar]
    statusbar: ?StatusbarConfig = null,
    _owned_statusbar: bool = false,

    // [splits]
    split_resize_step: u16 = 4,

    // [tabs]
    tab_appearance: TabAppearance = .builtin,
    tab_always_show: bool = false,
    tab_dim_unfocused: bool = false,

    // [sessions]
    sessions_enabled: bool = false,
    session_finder_root: []const u8 = "~",
    session_finder_depth: u8 = 4,
    session_finder_show_hidden: bool = false,
    _owned_session_finder_root: ?[]const u8 = null,
    session_icon_filter: []const u8 = ">",
    session_icon_session: []const u8 = "",
    session_icon_new: []const u8 = "+",
    session_icon_active: []const u8 = "\xe2\x97\x8f",
    session_icon_recent: []const u8 = "\xe2\x97\x8b",
    session_icon_folder: []const u8 = "\xe2\x96\xb8",
    _owned_session_icon_folder: ?[]const u8 = null,
    _owned_session_icon_filter: ?[]const u8 = null,
    _owned_session_icon_session: ?[]const u8 = null,
    _owned_session_icon_new: ?[]const u8 = null,
    _owned_session_icon_active: ?[]const u8 = null,
    _owned_session_icon_recent: ?[]const u8 = null,

    // [updates]
    check_updates: bool = true,

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
    _owned_working_directory: ?[]const u8 = null,
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
        if (self._owned_working_directory) |s| alloc.free(s);
        if (self._owned_session_finder_root) |s| alloc.free(s);
        if (self._owned_session_icon_folder) |s| alloc.free(s);
        if (self._owned_session_icon_filter) |s| alloc.free(s);
        if (self._owned_session_icon_session) |s| alloc.free(s);
        if (self._owned_session_icon_new) |s| alloc.free(s);
        if (self._owned_session_icon_active) |s| alloc.free(s);
        if (self._owned_session_icon_recent) |s| alloc.free(s);
        if (self._owned_statusbar) {
            if (self.statusbar) |*sb| statusbar_config.deinitStatusbar(alloc, sb);
        }
        if (self._owned_popup_configs) |entries| {
            for (entries) |e| {
                alloc.free(e.hotkey);
                alloc.free(e.command);
                alloc.free(e.width);
                alloc.free(e.height);
                alloc.free(e.border);
                alloc.free(e.border_color);
                alloc.free(e.background);
                if (e.on_return_cmd) |cmd| alloc.free(cmd);
            }
            alloc.free(entries);
        }
        if (self._owned_keybind_overrides) |entries| {
            for (entries) |e| {
                alloc.free(e.action_name);
                alloc.free(e.key_combo);
            }
            alloc.free(entries);
        }
        if (self._owned_sequence_entries) |entries| {
            for (entries) |e| {
                alloc.free(e.key_combo);
                alloc.free(e.data);
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
            self.program orelse if (comptime @import("builtin").os.tag == .windows) "cmd.exe" else (std.posix.getenv("SHELL") orelse "/bin/sh"),
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

    // Strip UTF-8 BOM if present (Windows editors like Notepad add this).
    const after_bom = if (file_content.len >= 3 and
        file_content[0] == 0xEF and file_content[1] == 0xBB and file_content[2] == 0xBF)
        file_content[3..]
    else
        file_content;

    // Strip \r (the TOML parser doesn't treat \r as whitespace, so \r\n
    // line endings from Windows editors cause parse failures).
    const content = stripCr(allocator, after_bom) catch after_bom;
    defer if (content.ptr != after_bom.ptr) allocator.free(content);

    return config_parse.applyToml(allocator, content, path, config);
}

/// Remove all \r bytes from file content so the TOML parser (which doesn't
/// treat \r as whitespace) can handle Windows \r\n line endings.
fn stripCr(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    // Fast path: no \r present.
    if (std.mem.indexOfScalar(u8, input, '\r') == null) return input;

    // Count output length first to allocate exactly.
    var count: usize = 0;
    for (input) |ch| {
        if (ch != '\r') count += 1;
    }
    var out = try allocator.alloc(u8, count);
    var j: usize = 0;
    for (input) |ch| {
        if (ch != '\r') {
            out[j] = ch;
            j += 1;
        }
    }
    return out;
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

test "default config has expected values" {
    const cfg = AppConfig{};
    try std.testing.expectEqual(@as(u16, 14), cfg.font_size);
    try std.testing.expectEqual(@as(u32, 5_000), cfg.scrollback_lines);
    try std.testing.expect(cfg.reflow_enabled);
    try std.testing.expect(cfg.cursor_blink);
    try std.testing.expectEqual(CursorShapeConfig.block, cfg.cursor_shape);
}
