const std = @import("std");
const builtin = @import("builtin");
const attyx = @import("attyx");
const cli = @import("config/cli.zig");
const config_mod = @import("config/config.zig");
const logging = @import("logging/log.zig");
const cli_commands = @import("cli_commands");
const session_connect = @import("app/session_connect.zig");

const is_windows = builtin.os.tag == .windows;

fn debugToFile(msg: []const u8) void {
    var path_buf: [256]u8 = undefined;
    const path = session_connect.statePath(&path_buf, "daemon-debug{s}.log") orelse return;
    const file = std.fs.createFileAbsolute(path, .{ .truncate = false }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch {};
    file.writeAll(msg) catch {};
    file.writeAll("\n") catch {};
}

// These modules are deeply POSIX (Unix sockets, signals, poll, fork/exec).
// On Windows they'll need complete rewrites (Phase 1+), so avoid importing
// them at all to prevent type-checking failures on POSIX-only types.
const terminal = if (!is_windows) @import("app/terminal.zig") else @import("app/terminal_windows.zig");
// On Windows, terminal.zig is not imported (deeply POSIX), so bridge
// symbols it normally exports are missing. Pull them from stubs instead.
comptime {
    if (is_windows) _ = @import("app/windows_stubs.zig");
}
const daemon = if (!is_windows) @import("app/daemon/daemon.zig") else @import("app/daemon/daemon_windows.zig");
const ipc_client = @import("ipc/client.zig");

const base_url: []const u8 = if (std.mem.eql(u8, attyx.env, "production"))
    "https://app.semos.sh"
else
    "http://localhost:8085";

pub const std_options: std.Options = .{
    .logFn = logging.stdLogFn,
};

// Daemon panic handler — routes panics to the debug log file since the
// daemon process has no console (DETACHED_PROCESS).
var g_daemon_panic_handler_installed: bool = false;

fn installDaemonPanicHandler() void {
    g_daemon_panic_handler_installed = true;
}

/// Custom panic: on Windows daemon, log to file; otherwise use default.
pub const panic = std.debug.FullPanic(panicImpl);

fn panicImpl(msg: []const u8, ret_addr: ?usize) noreturn {
    if (is_windows) {
        // Static buffer — must not use stack (might be blown).
        const S = struct {
            var buf: [512]u8 = undefined;
            var path_buf: [256]u8 = undefined;
        };
        const text = if (ret_addr) |addr|
            std.fmt.bufPrint(&S.buf, "PANIC at 0x{x}: {s}", .{ addr, msg }) catch msg
        else
            std.fmt.bufPrint(&S.buf, "PANIC: {s}", .{msg}) catch msg;
        // Write directly — debugToFile also has stack locals
        const path = session_connect.statePath(&S.path_buf, "daemon-debug{s}.log") orelse {
            std.process.exit(3);
        };
        const file = std.fs.createFileAbsolute(path, .{ .truncate = false }) catch {
            std.process.exit(3);
        };
        file.seekFromEnd(0) catch {};
        file.writeAll(text) catch {};
        file.writeAll("\n") catch {};
        file.close();
        std.process.exit(3);
    }
    std.debug.defaultPanic(msg, ret_addr);
}

// Windows API imports for console management and error dialogs.
const win32 = if (is_windows) struct {
    const ATTACH_PARENT_PROCESS: u32 = 0xFFFFFFFF;
    extern "kernel32" fn AttachConsole(dwProcessId: u32) callconv(.c) i32;
    extern "kernel32" fn AllocConsole() callconv(.c) i32;
    extern "kernel32" fn FreeConsole() callconv(.c) i32;
    extern "user32" fn MessageBoxA(
        hWnd: ?*anyopaque,
        lpText: [*:0]const u8,
        lpCaption: [*:0]const u8,
        uType: u32,
    ) callconv(.c) i32;
} else struct {};

/// Show a Windows MessageBox for fatal errors (GUI path has no console).
fn winFatal(msg: []const u8) noreturn {
    if (is_windows) {
        var buf: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{s}\x00", .{msg}) catch "Fatal error\x00";
        _ = win32.MessageBoxA(null, text[0 .. text.len - 1 :0], "Attyx Error", 0x10);
    }
    std.process.exit(1);
}

pub fn main() !void {
    // On Windows (subsystem=Windows), attach to parent console for CLI paths.
    // This gives subcommands (login, device, etc.) stdout/stderr when run from
    // a terminal. GUI and daemon paths don't need a console.
    // Skip for daemon: if AttachConsole succeeds, the daemon gets
    // CTRL_CLOSE_EVENT when the console owner exits → kills the daemon.
    if (is_windows) {
        _ = win32.AttachConsole(win32.ATTACH_PARENT_PROCESS);
    }

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
            // Daemon must not be attached to any console — if main()
            // attached to the parent's console above, detach now.
            // Otherwise CTRL_CLOSE_EVENT kills the daemon when the
            // console owner exits.
            if (is_windows) _ = win32.FreeConsole();
            if (is_windows) installDaemonPanicHandler();
            daemon.run(allocator, null) catch |err| {
                var ebuf: [256]u8 = undefined;
                const emsg = std.fmt.bufPrint(&ebuf, "daemon failed: {s}", .{@errorName(err)}) catch "daemon failed";
                debugToFile(emsg);
                std.process.exit(1);
            };
            return;
        },
        .daemon_restore => {
            if (is_windows) _ = win32.FreeConsole();
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

    // GUI path — detach from any inherited console (we don't need it).
    if (is_windows) {
        _ = win32.FreeConsole();
    }

    // Silently update installed skills (e.g. Claude Code /attyx) to match this build
    cli_commands.autoUpdateSkills();

    var merged = loadMergedConfig(allocator, result.no_config, result.config_path, args) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Failed to load config: {s}", .{@errorName(err)}) catch "Failed to load config";
        winFatal(msg);
    };
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

    terminal.run(merged, result.no_config, result.config_path, args, result.headless) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Terminal failed: {s}", .{@errorName(err)}) catch "Terminal failed";
        winFatal(msg);
    };
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
    if (!is_windows) {
        _ = @import("app/terminal.zig");
    }
    if (is_windows) {
        _ = @import("app/pty_windows.zig");
    }
    _ = @import("config/config.zig");
    if (!is_windows) {
        _ = @import("app/daemon/session_test.zig");
    }
}

test "AttyxCell struct layout matches C" {
    // bridge.h requires the platform C layer — skip on Windows where it doesn't exist yet.
    if (comptime is_windows) return;
    const c = @cImport(@cInclude("bridge.h"));
    try @import("std").testing.expectEqual(@as(usize, 24), @sizeOf(c.AttyxCell));
    try @import("std").testing.expectEqual(@as(usize, 20), @offsetOf(c.AttyxCell, "link_id"));
}
