// Built-in theme TOML content embedded at compile time.
// Add a new pub const here and a matching .toml file for each new built-in theme.

pub const default: []const u8 = @embedFile("default.toml");
pub const catppuccin_mocha: []const u8 = @embedFile("catppuccin-mocha.toml");
pub const catppuccin_latte: []const u8 = @embedFile("catppuccin-latte.toml");
pub const dracula: []const u8 = @embedFile("dracula.toml");
pub const everforest_dark: []const u8 = @embedFile("everforest-dark.toml");
pub const github_dark: []const u8 = @embedFile("github-dark.toml");
pub const gruvbox_dark: []const u8 = @embedFile("gruvbox-dark.toml");
pub const gruvbox_light: []const u8 = @embedFile("gruvbox-light.toml");
pub const iceberg: []const u8 = @embedFile("iceberg.toml");
pub const kanagawa: []const u8 = @embedFile("kanagawa.toml");
pub const material: []const u8 = @embedFile("material.toml");
pub const monokai: []const u8 = @embedFile("monokai.toml");
pub const nord: []const u8 = @embedFile("nord.toml");
pub const one_dark: []const u8 = @embedFile("one-dark.toml");
pub const palenight: []const u8 = @embedFile("palenight.toml");
pub const rose_pine: []const u8 = @embedFile("rose-pine.toml");
pub const rose_pine_moon: []const u8 = @embedFile("rose-pine-moon.toml");
pub const snazzy: []const u8 = @embedFile("snazzy.toml");
pub const solarized_dark: []const u8 = @embedFile("solarized-dark.toml");
pub const solarized_light: []const u8 = @embedFile("solarized-light.toml");
pub const tokyo_night: []const u8 = @embedFile("tokyo-night.toml");
pub const tokyo_night_storm: []const u8 = @embedFile("tokyo-night-storm.toml");
