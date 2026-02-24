// Built-in theme TOML content embedded at compile time.
// Add a new pub const here and a matching .toml file for each new built-in theme.

pub const default: []const u8 = @embedFile("default.toml");
pub const catppuccin_mocha: []const u8 = @embedFile("catppuccin-mocha.toml");
