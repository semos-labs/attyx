const std = @import("std");
const config_mod = @import("config.zig");
const cli_mod = @import("cli.zig");

pub const AppConfig = config_mod.AppConfig;

/// Which config fields changed between two snapshots.
pub const ConfigDiff = struct {
    cursor_changed: bool,
    scrollback_changed: bool,
    font_changed: bool, // requires restart
    reflow_changed: bool, // currently dormant
    theme_changed: bool, // currently dormant
};

pub fn diff(old: AppConfig, new: AppConfig) ConfigDiff {
    const font_changed = old.font_size != new.font_size or
        !std.mem.eql(u8, old.font_family, new.font_family) or
        old.cell_width != new.cell_width or
        old.cell_height != new.cell_height or
        !sameFallback(old, new);
    return .{
        .cursor_changed = old.cursor_shape != new.cursor_shape or
            old.cursor_blink != new.cursor_blink,
        .scrollback_changed = old.scrollback_lines != new.scrollback_lines,
        .font_changed = font_changed,
        .reflow_changed = old.reflow_enabled != new.reflow_enabled,
        .theme_changed = !std.mem.eql(u8, old.theme_name, new.theme_name),
    };
}

fn sameFallback(a: AppConfig, b: AppConfig) bool {
    const af = a.font_fallback orelse &[_][]const u8{};
    const bf = b.font_fallback orelse &[_][]const u8{};
    if (af.len != bf.len) return false;
    for (af, bf) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

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
