const std = @import("std");
const theme_mod = @import("theme.zig");
const builtin_mod = @import("builtin.zig");
const logging = @import("../logging/log.zig");

pub const Theme = theme_mod.Theme;
pub const Rgb = theme_mod.Rgb;

pub const ThemeRegistry = struct {
    allocator: std.mem.Allocator,
    themes: std.StringHashMap(Theme),

    pub fn init(allocator: std.mem.Allocator) ThemeRegistry {
        return .{
            .allocator = allocator,
            .themes = std.StringHashMap(Theme).init(allocator),
        };
    }

    pub fn deinit(self: *ThemeRegistry) void {
        var it = self.themes.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.themes.deinit();
    }

    /// Register a theme by name. Overwrites any existing entry with the same name.
    fn register(self: *ThemeRegistry, name: []const u8, theme: Theme) !void {
        const result = try self.themes.getOrPut(name);
        if (result.found_existing) {
            result.value_ptr.* = theme;
        } else {
            // Own a copy of the key — the source slice may be temporary.
            result.key_ptr.* = try self.allocator.dupe(u8, name);
            result.value_ptr.* = theme;
        }
    }

    /// Load all built-in themes embedded at compile time.
    pub fn loadBuiltins(self: *ThemeRegistry) !void {
        for (builtin_mod.builtins) |bt| {
            const theme = theme_mod.parseTheme(self.allocator, bt.content, bt.name) catch |err| {
                logging.warn("theme", "built-in theme '{s}' failed to load: {}", .{ bt.name, err });
                continue;
            };
            try self.register(bt.name, theme);
        }
    }

    /// Load all .toml files from `dir_path` as custom themes.
    /// Silently skips missing directories and unparseable files.
    pub fn loadDir(self: *ThemeRegistry, dir_path: []const u8) void {
        var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch return) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;

            const stem = entry.name[0 .. entry.name.len - ".toml".len];
            const content = dir.readFileAlloc(self.allocator, entry.name, 64 * 1024) catch continue;
            defer self.allocator.free(content);

            const theme = theme_mod.parseTheme(self.allocator, content, stem) catch continue;
            self.register(stem, theme) catch |err| {
                logging.warn("theme", "failed to register '{s}': {}", .{ stem, err });
            };
        }
    }

    /// Look up a theme by name. Returns null if not registered.
    pub fn get(self: *const ThemeRegistry, name: []const u8) ?Theme {
        return self.themes.get(name);
    }

    /// Look up a theme by name, falling back to Theme.default() if not found.
    pub fn resolve(self: *const ThemeRegistry, name: []const u8) Theme {
        if (self.themes.get(name)) |t| return t;
        if (!std.mem.eql(u8, name, "default")) {
            logging.warn("theme", "theme '{s}' not found, using default", .{name});
        }
        return Theme.default();
    }

    /// Number of registered themes.
    pub fn count(self: *const ThemeRegistry) usize {
        return self.themes.count();
    }
};
