const std = @import("std");
const toml = @import("toml");

pub const StatusbarPosition = enum {
    top,
    bottom,

    pub fn fromString(s: []const u8) ?StatusbarPosition {
        if (std.mem.eql(u8, s, "top")) return .top;
        if (std.mem.eql(u8, s, "bottom")) return .bottom;
        return null;
    }
};

pub const WidgetSide = enum {
    left,
    right,

    pub fn fromString(s: []const u8) ?WidgetSide {
        if (std.mem.eql(u8, s, "left")) return .left;
        if (std.mem.eql(u8, s, "right")) return .right;
        return null;
    }
};

pub const WidgetParam = struct {
    key: []const u8,
    value: []const u8,
};

pub const max_widgets = 16;
pub const max_params = 16;

pub const StatusbarWidgetConfig = struct {
    name: []const u8 = "",
    side: WidgetSide = .left,
    interval_s: u16 = 5,
    params: [max_params]WidgetParam = undefined,
    param_count: u8 = 0,

    pub fn getParam(self: *const StatusbarWidgetConfig, key: []const u8) ?[]const u8 {
        for (self.params[0..self.param_count]) |p| {
            if (std.mem.eql(u8, p.key, key)) return p.value;
        }
        return null;
    }
};

pub const StatusbarConfig = struct {
    enabled: bool = false,
    position: StatusbarPosition = .bottom,
    background_opacity: u8 = 0,
    background_r: u8 = 30,
    background_g: u8 = 30,
    background_b: u8 = 40,
    widgets: [max_widgets]StatusbarWidgetConfig = undefined,
    widget_count: u8 = 0,
};

/// Parse the [statusbar] section from a TOML root table.
/// Sub-tables within [statusbar] are treated as widget definitions.
/// Top-level keys "enabled" and "position" are statusbar properties;
/// everything else is a widget name.
pub fn parseStatusbar(
    allocator: std.mem.Allocator,
    root: *const toml.TomlTable,
    path: []const u8,
) !?StatusbarConfig {
    const sb_val = root.get("statusbar") orelse return null;
    if (sb_val != .table) {
        std.debug.print("error: {s}: [statusbar] must be a table\n", .{path});
        return error.ConfigValidationError;
    }
    const sb_table = sb_val.table;

    var config = StatusbarConfig{};

    // Parse top-level keys
    if (sb_table.get("enabled")) |v| {
        if (v == .bool) {
            config.enabled = v.bool;
        } else {
            std.debug.print("error: {s}: statusbar.enabled must be a boolean\n", .{path});
            return error.ConfigValidationError;
        }
    }
    if (sb_table.get("position")) |v| {
        if (v == .string) {
            config.position = StatusbarPosition.fromString(v.string) orelse {
                std.debug.print("error: {s}: statusbar.position must be \"top\" or \"bottom\"\n", .{path});
                return error.ConfigValidationError;
            };
        } else {
            std.debug.print("error: {s}: statusbar.position must be a string\n", .{path});
            return error.ConfigValidationError;
        }
    }
    if (sb_table.get("background_opacity")) |v| {
        if (v == .int) {
            config.background_opacity = @intCast(@min(@max(v.int, 0), 255));
        }
    }
    if (sb_table.get("background")) |v| {
        if (v == .string) {
            if (parseHexRgb(v.string)) |rgb| {
                config.background_r = rgb[0];
                config.background_g = rgb[1];
                config.background_b = rgb[2];
            }
        }
    }

    // Iterate all keys — sub-tables are widgets
    var it = sb_table.table.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .table) continue;
        const name = entry.key_ptr.*;
        // Skip reserved top-level keys
        if (std.mem.eql(u8, name, "enabled") or std.mem.eql(u8, name, "position")) continue;

        if (config.widget_count >= max_widgets) break;
        const widget_table = entry.value_ptr.table;

        var widget = StatusbarWidgetConfig{};
        widget.name = try allocator.dupe(u8, name);

        // Parse reserved widget keys
        if (widget_table.get("side")) |v| {
            if (v == .string) {
                widget.side = WidgetSide.fromString(v.string) orelse .left;
            }
        }
        if (widget_table.get("interval")) |v| {
            if (v == .int and v.int > 0) {
                widget.interval_s = @intCast(@min(v.int, std.math.maxInt(u16)));
            }
        }

        // All other keys are params
        var int_buf: [32]u8 = undefined;
        var wit = widget_table.table.iterator();
        while (wit.next()) |wentry| {
            const wkey = wentry.key_ptr.*;
            if (std.mem.eql(u8, wkey, "side") or std.mem.eql(u8, wkey, "interval")) continue;
            if (widget.param_count >= max_params) break;
            const val_str: ?[]const u8 = switch (wentry.value_ptr.*) {
                .string => |s| s,
                .int => |v| std.fmt.bufPrint(&int_buf, "{d}", .{v}) catch null,
                .bool => |v| if (v) "true" else "false",
                else => null,
            };
            if (val_str) |vs| {
                widget.params[widget.param_count] = .{
                    .key = try allocator.dupe(u8, wkey),
                    .value = try allocator.dupe(u8, vs),
                };
                widget.param_count += 1;
            }
        }

        config.widgets[config.widget_count] = widget;
        config.widget_count += 1;
    }

    return config;
}

/// Free owned strings in a StatusbarConfig.
pub fn deinitStatusbar(allocator: std.mem.Allocator, config: *StatusbarConfig) void {
    for (config.widgets[0..config.widget_count]) |*w| {
        if (w.name.len > 0) allocator.free(w.name);
        for (w.params[0..w.param_count]) |p| {
            allocator.free(p.key);
            allocator.free(p.value);
        }
    }
}

/// Parse a "#rrggbb" or "rrggbb" hex string into [3]u8 {r, g, b}.
fn parseHexRgb(s: []const u8) ?[3]u8 {
    const hex = if (s.len > 0 and s[0] == '#') s[1..] else s;
    if (hex.len != 6) return null;
    const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null;
    const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null;
    const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null;
    return .{ r, g, b };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "parseStatusbar: returns null when no [statusbar] section" {
    const alloc = std.testing.allocator;
    const parser = toml.Parser.init(alloc) catch return;
    defer parser.deinit();

    const doc = parser.parse_string("[font]\nsize = 14") catch return;
    defer doc.deinit();

    const result = try parseStatusbar(alloc, doc.get_table(), "<test>");
    try std.testing.expect(result == null);
}

test "parseStatusbar: parses enabled and position" {
    const alloc = std.testing.allocator;
    const parser = toml.Parser.init(alloc) catch return;
    defer parser.deinit();

    const doc = parser.parse_string(
        \\[statusbar]
        \\enabled = true
        \\position = "top"
    ) catch return;
    defer doc.deinit();

    var config = (try parseStatusbar(alloc, doc.get_table(), "<test>")) orelse
        return error.TestUnexpectedResult;
    defer deinitStatusbar(alloc, &config);

    try std.testing.expect(config.enabled);
    try std.testing.expectEqual(StatusbarPosition.top, config.position);
    try std.testing.expectEqual(@as(u8, 0), config.widget_count);
}

test "parseStatusbar: parses widgets with params" {
    const alloc = std.testing.allocator;
    const parser = toml.Parser.init(alloc) catch return;
    defer parser.deinit();

    const doc = parser.parse_string(
        \\[statusbar]
        \\enabled = true
        \\
        \\[statusbar.time]
        \\side = "right"
        \\interval = 1
        \\format = "%H:%M"
        \\
        \\[statusbar.cwd]
        \\side = "left"
        \\interval = 5
    ) catch return;
    defer doc.deinit();

    var config = (try parseStatusbar(alloc, doc.get_table(), "<test>")) orelse
        return error.TestUnexpectedResult;
    defer deinitStatusbar(alloc, &config);

    try std.testing.expect(config.enabled);
    try std.testing.expectEqual(@as(u8, 2), config.widget_count);

    // Find the time widget
    var found_time = false;
    var found_cwd = false;
    for (config.widgets[0..config.widget_count]) |w| {
        if (std.mem.eql(u8, w.name, "time")) {
            found_time = true;
            try std.testing.expectEqual(WidgetSide.right, w.side);
            try std.testing.expectEqual(@as(u16, 1), w.interval_s);
            try std.testing.expectEqual(@as(u8, 1), w.param_count);
            try std.testing.expectEqualStrings("format", w.params[0].key);
            try std.testing.expectEqualStrings("%H:%M", w.params[0].value);
        }
        if (std.mem.eql(u8, w.name, "cwd")) {
            found_cwd = true;
            try std.testing.expectEqual(WidgetSide.left, w.side);
            try std.testing.expectEqual(@as(u16, 5), w.interval_s);
        }
    }
    try std.testing.expect(found_time);
    try std.testing.expect(found_cwd);
}

test "parseStatusbar: default position is bottom" {
    const alloc = std.testing.allocator;
    const parser = toml.Parser.init(alloc) catch return;
    defer parser.deinit();

    const doc = parser.parse_string(
        \\[statusbar]
        \\enabled = true
    ) catch return;
    defer doc.deinit();

    var config = (try parseStatusbar(alloc, doc.get_table(), "<test>")) orelse
        return error.TestUnexpectedResult;
    defer deinitStatusbar(alloc, &config);

    try std.testing.expectEqual(StatusbarPosition.bottom, config.position);
}

test "StatusbarWidgetConfig: getParam" {
    var w = StatusbarWidgetConfig{};
    w.params[0] = .{ .key = "format", .value = "%H:%M" };
    w.params[1] = .{ .key = "color", .value = "blue" };
    w.param_count = 2;

    try std.testing.expectEqualStrings("%H:%M", w.getParam("format").?);
    try std.testing.expectEqualStrings("blue", w.getParam("color").?);
    try std.testing.expect(w.getParam("missing") == null);
}
