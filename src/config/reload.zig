const std = @import("std");
const config_mod = @import("config.zig");
const cli_mod = @import("cli.zig");

pub const AppConfig = config_mod.AppConfig;

/// Load config using the same resolution as startup, but returns error instead of exit(1).
pub fn loadReloadedConfig(
    allocator: std.mem.Allocator,
    no_config: bool,
    config_path: ?[]const u8,
    args: []const [:0]const u8,
) !AppConfig {
    var cfg = AppConfig{};
    if (!no_config) {
        if (config_path) |path| {
            try config_mod.loadFromFile(allocator, path, &cfg);
        } else {
            try config_mod.loadFromDefaultPath(allocator, &cfg);
        }
    }
    cli_mod.applyCliOverrides(args, &cfg);
    return cfg;
}

// ===========================================================================
// Tests
// ===========================================================================

test "no_config returns default AppConfig" {
    const cfg = try loadReloadedConfig(std.testing.allocator, true, null, &.{});
    try std.testing.expectEqual(@as(u16, 14), cfg.font_size);
    try std.testing.expectEqualStrings("JetBrains Mono", cfg.font_family);
    try std.testing.expectEqual(@as(u32, 20_000), cfg.scrollback_lines);
    try std.testing.expect(cfg.reflow_enabled);
    try std.testing.expect(cfg.cursor_blink);
}

test "default AppConfig key fields match expectations" {
    const cfg = AppConfig{};
    try std.testing.expectEqual(@as(f32, 1.0), cfg.background_opacity);
    try std.testing.expectEqual(@as(u16, 30), cfg.background_blur);
    try std.testing.expect(cfg.window_decorations);
    try std.testing.expect(cfg.check_updates);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.program);
}
