const std = @import("std");
const cli = @import("config/cli.zig");
const config_mod = @import("config/config.zig");
const ui2 = @import("app/ui2.zig");
const logging = @import("logging/log.zig");

pub const std_options: std.Options = .{
    .logFn = logging.stdLogFn,
};

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

    const log_level = if (merged.log_level) |s|
        logging.Level.fromString(s) orelse blk: {
            std.debug.print("warning: unknown log level '{s}', using 'info'\n", .{s});
            break :blk logging.Level.info;
        }
    else
        logging.Level.info;
    logging.init(log_level, merged.log_file);
    defer logging.deinit();

    try ui2.run(merged, result.no_config, result.config_path, args);
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
    cli.applyCliOverrides(args, &file_config);
    return file_config;
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
    try @import("std").testing.expectEqual(@as(usize, 24), @sizeOf(c.AttyxCell));
    try @import("std").testing.expectEqual(@as(usize, 20), @offsetOf(c.AttyxCell, "link_id"));
}
