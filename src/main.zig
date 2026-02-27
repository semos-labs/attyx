const std = @import("std");
const cli = @import("config/cli.zig");
const config_mod = @import("config/config.zig");
const ui2 = @import("app/ui2.zig");
const logging = @import("logging/log.zig");
const cli_binary = @import("cli_binary");

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

    installCli(allocator);

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

// ---------------------------------------------------------------------------
// Embedded CLI auto-install
// ---------------------------------------------------------------------------

fn installCli(allocator: std.mem.Allocator) void {
    installCliInner(allocator) catch |err| {
        logging.warn("cli", "failed to install CLI binary: {}", .{err});
    };
}

fn installCliInner(allocator: std.mem.Allocator) !void {
    const home = std.posix.getenv("HOME") orelse return;
    const bin_dir = try std.fmt.allocPrint(allocator, "{s}/.attyx/bin", .{home});
    defer allocator.free(bin_dir);
    const hash_path = try std.fmt.allocPrint(allocator, "{s}/.cli-hash", .{bin_dir});
    defer allocator.free(hash_path);
    const bin_path = try std.fmt.allocPrint(allocator, "{s}/attyx", .{bin_dir});
    defer allocator.free(bin_path);

    // Compute hash of embedded binary at runtime (one-time, fast)
    var hash_buf: [16]u8 = undefined;
    const h = std.hash.Fnv1a_64.hash(cli_binary.data);
    _ = std.fmt.bufPrint(&hash_buf, "{x:0>16}", .{h}) catch unreachable;

    // Check if the currently installed binary is already up-to-date
    if (hashMatches(hash_path, &hash_buf)) return;

    // Ensure directory exists
    std.fs.cwd().makePath(bin_dir) catch {};

    // Write the binary
    const file = try std.fs.cwd().createFile(bin_path, .{ .mode = 0o755 });
    defer file.close();
    try file.writeAll(cli_binary.data);

    // Write the hash file
    const hf = try std.fs.cwd().createFile(hash_path, .{});
    defer hf.close();
    try hf.writeAll(&hash_buf);

    logging.info("cli", "installed attyx CLI to {s}", .{bin_path});
}

fn hashMatches(hash_path: []const u8, expected: *const [16]u8) bool {
    const file = std.fs.cwd().openFile(hash_path, .{}) catch return false;
    defer file.close();
    var buf: [16]u8 = undefined;
    const n = file.readAll(&buf) catch return false;
    if (n != 16) return false;
    return std.mem.eql(u8, &buf, expected);
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
