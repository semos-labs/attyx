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
    .{ .name = "default",            .content = themes_data.default            },
    .{ .name = "catppuccin-latte",   .content = themes_data.catppuccin_latte   },
    .{ .name = "catppuccin-mocha",   .content = themes_data.catppuccin_mocha   },
    .{ .name = "dracula",            .content = themes_data.dracula            },
    .{ .name = "everforest-dark",    .content = themes_data.everforest_dark    },
    .{ .name = "github-dark",        .content = themes_data.github_dark        },
    .{ .name = "gruvbox-dark",       .content = themes_data.gruvbox_dark       },
    .{ .name = "gruvbox-light",      .content = themes_data.gruvbox_light      },
    .{ .name = "iceberg",            .content = themes_data.iceberg            },
    .{ .name = "kanagawa",           .content = themes_data.kanagawa           },
    .{ .name = "material",           .content = themes_data.material           },
    .{ .name = "monokai",            .content = themes_data.monokai            },
    .{ .name = "nord",               .content = themes_data.nord               },
    .{ .name = "one-dark",           .content = themes_data.one_dark           },
    .{ .name = "palenight",          .content = themes_data.palenight          },
    .{ .name = "rose-pine",          .content = themes_data.rose_pine          },
    .{ .name = "rose-pine-moon",     .content = themes_data.rose_pine_moon     },
    .{ .name = "snazzy",             .content = themes_data.snazzy             },
    .{ .name = "solarized-dark",     .content = themes_data.solarized_dark     },
    .{ .name = "solarized-light",    .content = themes_data.solarized_light    },
    .{ .name = "tokyo-night",        .content = themes_data.tokyo_night        },
    .{ .name = "tokyo-night-storm",  .content = themes_data.tokyo_night_storm  },
};
