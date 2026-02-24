/// Compile-time embedded built-in themes.
/// Theme TOML files live in themes/ at the project root and are exposed via the
/// `builtin_themes` module (see build.zig). Add an entry to both themes/themes.zig
/// and this file when adding a new built-in theme.

const themes_data = @import("builtin_themes");

pub const BuiltinTheme = struct {
    name: []const u8,
    content: []const u8,
};

pub const builtins: []const BuiltinTheme = &.{
    .{ .name = "default",          .content = themes_data.default          },
    .{ .name = "catppuccin-mocha", .content = themes_data.catppuccin_mocha },
};
