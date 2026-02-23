const std = @import("std");
const cli = @import("config/cli.zig");
const config_mod = @import("config/config.zig");
const ui2 = @import("app/ui2.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const result = cli.parse(args);

    switch (result.action) {
        .show_help => {
            cli.printUsage();
            return;
        },
        .print_config => {
            var merged = try loadMergedConfig(allocator, result.no_config, result.config_path, args);
            defer merged.deinit();
            const output = merged.formatConfig(allocator) catch {
                fatal("failed to format config");
            };
            defer allocator.free(output);
            std.fs.File.stdout().writeAll(output) catch {};
            return;
        },
        .run => {},
    }

    var merged = try loadMergedConfig(allocator, result.no_config, result.config_path, args);
    defer merged.deinit();

    try ui2.run(merged);
}

/// Load config with correct precedence: Defaults < ConfigFile < CLI.
fn loadMergedConfig(
    allocator: std.mem.Allocator,
    no_config: bool,
    config_path: ?[]const u8,
    args: []const [:0]const u8,
) !config_mod.AppConfig {
    var file_config = config_mod.AppConfig{};
    if (!no_config) {
        if (config_path) |path| {
            config_mod.loadFromFile(allocator, path, &file_config) catch |err| {
                if (err == error.ConfigParseError or err == error.ConfigValidationError)
                    std.process.exit(1);
                return err;
            };
        } else {
            config_mod.loadFromDefaultPath(allocator, &file_config) catch |err| {
                if (err == error.ConfigParseError or err == error.ConfigValidationError)
                    std.process.exit(1);
                return err;
            };
        }
    }
    applyCliOverrides(args, &file_config);
    return file_config;
}

/// Re-scan args to apply only explicitly provided CLI flags on top of file config.
fn applyCliOverrides(args: []const [:0]const u8, config: *config_mod.AppConfig) void {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--rows")) {
            i += 1;
            if (i < args.len)
                config.rows = std.fmt.parseInt(u16, args[i], 10) catch continue;
        } else if (std.mem.eql(u8, arg, "--cols")) {
            i += 1;
            if (i < args.len)
                config.cols = std.fmt.parseInt(u16, args[i], 10) catch continue;
        } else if (std.mem.eql(u8, arg, "--font-family")) {
            i += 1;
            if (i < args.len) config.font_family = args[i];
        } else if (std.mem.eql(u8, arg, "--font-size")) {
            i += 1;
            if (i < args.len)
                config.font_size = std.fmt.parseInt(u16, args[i], 10) catch continue;
        } else if (std.mem.eql(u8, arg, "--theme")) {
            i += 1;
            if (i < args.len) config.theme_name = args[i];
        } else if (std.mem.eql(u8, arg, "--scrollback-lines")) {
            i += 1;
            if (i < args.len)
                config.scrollback_lines = std.fmt.parseInt(u32, args[i], 10) catch continue;
        } else if (std.mem.eql(u8, arg, "--reflow")) {
            config.reflow_enabled = true;
        } else if (std.mem.eql(u8, arg, "--no-reflow")) {
            config.reflow_enabled = false;
        } else if (std.mem.eql(u8, arg, "--cursor-shape")) {
            i += 1;
            if (i < args.len) {
                if (config_mod.CursorShapeConfig.fromString(args[i])) |shape|
                    config.cursor_shape = shape;
            }
        } else if (std.mem.eql(u8, arg, "--cursor-blink")) {
            config.cursor_blink = true;
        } else if (std.mem.eql(u8, arg, "--no-cursor-blink")) {
            config.cursor_blink = false;
        } else if (std.mem.eql(u8, arg, "--cmd")) {
            config.argv = @ptrCast(args[i + 1 ..]);
            break;
        } else if (std.mem.eql(u8, arg, "--config") or
            std.mem.eql(u8, arg, "--no-config") or
            std.mem.eql(u8, arg, "--print-config") or
            std.mem.eql(u8, arg, "--help") or
            std.mem.eql(u8, arg, "-h"))
        {
            if (std.mem.eql(u8, arg, "--config")) i += 1;
        }
    }
}

fn fatal(msg: []const u8) noreturn {
    std.debug.print("error: {s}\n", .{msg});
    std.process.exit(1);
}

test {
    _ = ui2;
    _ = @import("config/config.zig");
}

test "AttyxCell struct layout matches C" {
    const c = @cImport(@cInclude("bridge.h"));
    try @import("std").testing.expectEqual(@as(usize, 16), @sizeOf(c.AttyxCell));
    try @import("std").testing.expectEqual(@as(usize, 12), @offsetOf(c.AttyxCell, "link_id"));
}
