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
