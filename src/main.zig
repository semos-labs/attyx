const std = @import("std");
const attyx = @import("attyx");
const cli = @import("config/cli.zig");
const config_mod = @import("config/config.zig");
const terminal = @import("app/terminal.zig");
const logging = @import("logging/log.zig");
const cli_commands = @import("cli_commands");
const daemon = @import("app/daemon/daemon.zig");
const session_connect = @import("app/session_connect.zig");
const ipc_client = @import("ipc/client.zig");

const base_url: []const u8 = if (std.mem.eql(u8, attyx.env, "production"))
    "https://app.semos.sh"
else
    "http://localhost:8085";

pub const std_options: std.Options = .{
    .logFn = logging.stdLogFn,
};

pub fn main() !void {
    // Migrate runtime files from config dir to state dir (one-time, idempotent).
    session_connect.migrateToStateDir();

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
        .login => {
            cli_commands.doLogin(allocator, base_url) catch |err| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "error: login failed: {s}\n", .{@errorName(err)}) catch "error: login failed\n";
                std.fs.File.stderr().writeAll(msg) catch {};
                std.process.exit(1);
            };
            return;
        },
        .device => {
            cli_commands.doDevice(allocator, base_url) catch |err| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "error: {s}\n", .{@errorName(err)}) catch "error: failed to get device info\n";
                std.fs.File.stderr().writeAll(msg) catch {};
                std.process.exit(1);
            };
            return;
        },
        .uninstall => {
            cli_commands.doUninstall();
            return;
        },
        .skill => {
            cli_commands.doSkill(args);
            return;
        },
        .daemon => {
            daemon.run(allocator, null) catch |err| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "error: daemon failed: {s}\n", .{@errorName(err)}) catch "error: daemon failed\n";
                std.fs.File.stderr().writeAll(msg) catch {};
                std.process.exit(1);
            };
            return;
        },
        .daemon_restore => {
            // Extract restore path from args: attyx daemon --restore <path>
            const restore_path: ?[]const u8 = if (args.len > 3) args[3] else null;
            daemon.run(allocator, restore_path) catch |err| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "error: daemon restore failed: {s}\n", .{@errorName(err)}) catch "error: daemon restore failed\n";
                std.fs.File.stderr().writeAll(msg) catch {};
                std.process.exit(1);
            };
            return;
        },
        .kill_daemon => {
            cli_commands.doKillDaemon();
            return;
        },
        .ipc_command => {
            ipc_client.run(args);
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

    // Silently update installed skills (e.g. Claude Code /attyx) to match this build
    cli_commands.autoUpdateSkills();

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

    try terminal.run(merged, result.no_config, result.config_path, args);
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
    _ = terminal;
    _ = @import("config/config.zig");
    _ = @import("app/daemon/session_test.zig");
}

test "AttyxCell struct layout matches C" {
    const c = @cImport(@cInclude("bridge.h"));
    try @import("std").testing.expectEqual(@as(usize, 24), @sizeOf(c.AttyxCell));
    try @import("std").testing.expectEqual(@as(usize, 20), @offsetOf(c.AttyxCell, "link_id"));
}
