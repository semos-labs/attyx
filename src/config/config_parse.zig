const std = @import("std");
const toml = @import("toml");
const config_mod = @import("config.zig");
const AppConfig = config_mod.AppConfig;
const CursorShapeConfig = config_mod.CursorShapeConfig;
const CellSize = config_mod.CellSize;
const TabAppearance = config_mod.TabAppearance;
const PopupConfigEntry = config_mod.PopupConfigEntry;
const KeybindOverride = config_mod.KeybindOverride;
const SequenceEntry = config_mod.SequenceEntry;
const statusbar_config = @import("statusbar_config.zig");

pub fn parseCellSize(v: toml.TomlValue, path: []const u8, field: []const u8) ?CellSize {
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

pub fn tomlOptU16(v: ?toml.TomlValue) ?u16 {
    const val = v orelse return null;
    if (val != .int) return null;
    if (val.int < 0) return null;
    return @intCast(@min(val.int, std.math.maxInt(u16)));
}

pub fn applyToml(allocator: std.mem.Allocator, content: []const u8, path: []const u8, config: *AppConfig) !void {
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
    if (Lookup.get(root, "theme", "background")) |v| {
        if (v == .string) {
            config.theme_background = config_mod.Rgb.fromHex(v.string) orelse {
                std.debug.print("error: {s}: theme.background is not a valid hex color\n", .{path});
                return error.ConfigValidationError;
            };
        } else {
            std.debug.print("error: {s}: theme.background must be a string\n", .{path});
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

    // [tabs]
    if (Lookup.get(root, "tabs", "appearance")) |v| {
        if (v == .string) {
            if (TabAppearance.fromString(v.string)) |appearance| {
                config.tab_appearance = appearance;
            } else {
                std.debug.print("error: {s}: tabs.appearance must be \"builtin\" or \"native\"\n", .{path});
                return error.ConfigValidationError;
            }
        } else {
            std.debug.print("error: {s}: tabs.appearance must be a string\n", .{path});
            return error.ConfigValidationError;
        }
    }
    if (Lookup.get(root, "tabs", "always_show")) |v| {
        if (v == .bool) {
            config.tab_always_show = v.bool;
        } else {
            std.debug.print("error: {s}: tabs.always_show must be a boolean\n", .{path});
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
                    const on_return_v = item.table.get("on_return_cmd");
                    const inject_alt_v = item.table.get("inject_alt");
                    const bg_opacity_v = item.table.get("background_opacity");
                    const bg_color_v = item.table.get("background");
                    entries[valid] = .{
                        .hotkey = try allocator.dupe(u8, hotkey_v.string),
                        .command = try allocator.dupe(u8, cmd_v.string),
                        .width = if (width_v != null and width_v.? == .string) try allocator.dupe(u8, width_v.?.string) else try allocator.dupe(u8, "80%"),
                        .height = if (height_v != null and height_v.? == .string) try allocator.dupe(u8, height_v.?.string) else try allocator.dupe(u8, "80%"),
                        .border = if (border_v != null and border_v.? == .string) try allocator.dupe(u8, border_v.?.string) else try allocator.dupe(u8, "single"),
                        .border_color = if (border_color_v != null and border_color_v.? == .string) try allocator.dupe(u8, border_color_v.?.string) else try allocator.dupe(u8, "#78829a"),
                        .on_return_cmd = if (on_return_v != null and on_return_v.? == .string) try allocator.dupe(u8, on_return_v.?.string) else null,
                        .inject_alt = if (inject_alt_v != null and inject_alt_v.? == .bool) inject_alt_v.?.bool else false,
                        .background_opacity = if (bg_opacity_v) |bv| blk: {
                            const raw: f64 = if (bv == .float) bv.float else if (bv == .int) @floatFromInt(bv.int) else break :blk null;
                            break :blk if (raw >= 0.0 and raw <= 1.0) @as(f32, @floatCast(raw)) else null;
                        } else null,
                        .background = if (bg_color_v != null and bg_color_v.? == .string) try allocator.dupe(u8, bg_color_v.?.string) else try allocator.dupe(u8, ""),
                        .padding = tomlOptU16(item.table.get("padding")),
                        .padding_x = tomlOptU16(item.table.get("padding_x")),
                        .padding_y = tomlOptU16(item.table.get("padding_y")),
                        .padding_top = tomlOptU16(item.table.get("padding_top")),
                        .padding_bottom = tomlOptU16(item.table.get("padding_bottom")),
                        .padding_left = tomlOptU16(item.table.get("padding_left")),
                        .padding_right = tomlOptU16(item.table.get("padding_right")),
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
                            allocator.free(e.background);
                            if (e.on_return_cmd) |cmd| allocator.free(cmd);
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

    // [keybindings] — table of action_name = "key+combo" pairs
    if (root.get("keybindings")) |kb_val| {
        if (kb_val == .table) {
            var it = kb_val.table.table.iterator();
            var kb_count: usize = 0;
            // First pass: count valid entries
            while (it.next()) |entry| {
                if (entry.value_ptr.* == .string) kb_count += 1;
            }
            if (kb_count > 0) {
                const entries = try allocator.alloc(KeybindOverride, kb_count);
                var idx: usize = 0;
                var it2 = kb_val.table.table.iterator();
                while (it2.next()) |entry| {
                    if (entry.value_ptr.* != .string) continue;
                    entries[idx] = .{
                        .action_name = try allocator.dupe(u8, entry.key_ptr.*),
                        .key_combo = try allocator.dupe(u8, entry.value_ptr.string),
                    };
                    idx += 1;
                }
                if (config._owned_keybind_overrides) |old| {
                    for (old) |e| { allocator.free(e.action_name); allocator.free(e.key_combo); }
                    allocator.free(old);
                }
                config.keybind_overrides = entries[0..idx];
                config._owned_keybind_overrides = entries;
            }
        }
    }

    // [sequences] — table of "key+combo" = "escape sequence bytes" pairs
    if (root.get("sequences")) |seq_val| {
        if (seq_val == .table) {
            var it = seq_val.table.table.iterator();
            var seq_count: usize = 0;
            while (it.next()) |entry| {
                if (entry.value_ptr.* == .string) seq_count += 1;
            }
            if (seq_count > 0) {
                const entries = try allocator.alloc(SequenceEntry, seq_count);
                var idx: usize = 0;
                var it2 = seq_val.table.table.iterator();
                while (it2.next()) |entry| {
                    if (entry.value_ptr.* != .string) continue;
                    entries[idx] = .{
                        .key_combo = try allocator.dupe(u8, entry.key_ptr.*),
                        .data = try allocator.dupe(u8, entry.value_ptr.string),
                    };
                    idx += 1;
                }
                if (config._owned_sequence_entries) |old| {
                    for (old) |e| { allocator.free(e.key_combo); allocator.free(e.data); }
                    allocator.free(old);
                }
                config.sequence_entries = entries[0..idx];
                config._owned_sequence_entries = entries;
            }
        }
    }

    // [sessions]
    if (Lookup.get(root, "sessions", "enabled")) |v| {
        if (v == .bool) {
            config.sessions_enabled = v.bool;
        } else {
            std.debug.print("error: {s}: sessions.enabled must be a boolean\n", .{path});
            return error.ConfigValidationError;
        }
    }
    inline for (.{
        .{ "icon_filter", &config.session_icon_filter, &config._owned_session_icon_filter },
        .{ "icon_session", &config.session_icon_session, &config._owned_session_icon_session },
        .{ "icon_new", &config.session_icon_new, &config._owned_session_icon_new },
        .{ "icon_active", &config.session_icon_active, &config._owned_session_icon_active },
    }) |kv| {
        if (Lookup.get(root, "sessions", kv[0])) |v| {
            if (v == .string) {
                const dupe = try allocator.dupe(u8, v.string);
                if (kv[2].*) |old| allocator.free(old);
                kv[1].* = dupe;
                kv[2].* = dupe;
            } else {
                std.debug.print("error: {s}: sessions.{s} must be a string\n", .{ path, kv[0] });
                return error.ConfigValidationError;
            }
        }
    }

    // [updates]
    if (Lookup.get(root, "updates", "check_updates")) |v| {
        if (v == .bool) {
            config.check_updates = v.bool;
        } else {
            std.debug.print("error: {s}: updates.check_updates must be a boolean\n", .{path});
            return error.ConfigValidationError;
        }
    }

    // [statusbar]
    if (try statusbar_config.parseStatusbar(allocator, root, path)) |sb| {
        if (config._owned_statusbar) {
            if (config.statusbar) |*old_sb| statusbar_config.deinitStatusbar(allocator, old_sb);
        }
        config.statusbar = sb;
        config._owned_statusbar = true;
    }

    config._allocator = allocator;
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

test "parse tabs config" {
    const alloc = std.testing.allocator;
    var cfg = AppConfig{};
    defer cfg.deinit();

    const toml_str =
        \\[tabs]
        \\appearance = "native"
        \\always_show = true
    ;

    try applyToml(alloc, toml_str, "<test>", &cfg);

    try std.testing.expectEqual(TabAppearance.native, cfg.tab_appearance);
    try std.testing.expect(cfg.tab_always_show);
}

test "invalid tabs.appearance rejects" {
    const alloc = std.testing.allocator;
    var cfg = AppConfig{};

    const toml_str =
        \\[tabs]
        \\appearance = "fancy"
    ;

    try std.testing.expectError(error.ConfigValidationError, applyToml(alloc, toml_str, "<test>", &cfg));
}
