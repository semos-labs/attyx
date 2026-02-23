const std = @import("std");
const config_mod = @import("config.zig");

pub const AppConfig = config_mod.AppConfig;
pub const CursorShapeConfig = config_mod.CursorShapeConfig;
pub const CellSize = config_mod.CellSize;

pub const CliResult = struct {
    config: AppConfig,
    action: Action,
    config_path: ?[]const u8 = null,
    no_config: bool = false,
};

pub const Action = enum {
    run,
    print_config,
    show_help,
};

fn fatal(msg: []const u8) noreturn {
    std.debug.print("error: {s}\n", .{msg});
    std.process.exit(1);
}

fn requireArg(args: []const [:0]const u8, i: *usize, flag: []const u8) [:0]const u8 {
    i.* += 1;
    if (i.* >= args.len) {
        std.debug.print("error: {s} requires a value\n", .{flag});
        std.process.exit(1);
    }
    return args[i.*];
}

pub fn parse(args: []const [:0]const u8) CliResult {
    var result = CliResult{
        .config = AppConfig{},
        .action = .run,
    };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            result.action = .show_help;
            return result;
        } else if (std.mem.eql(u8, arg, "--print-config")) {
            result.action = .print_config;
        } else if (std.mem.eql(u8, arg, "--config")) {
            result.config_path = requireArg(args, &i, "--config");
        } else if (std.mem.eql(u8, arg, "--no-config")) {
            result.no_config = true;
        } else if (std.mem.eql(u8, arg, "--rows")) {
            const val = requireArg(args, &i, "--rows");
            result.config.rows = std.fmt.parseInt(u16, val, 10) catch
                fatal("invalid --rows value");
        } else if (std.mem.eql(u8, arg, "--cols")) {
            const val = requireArg(args, &i, "--cols");
            result.config.cols = std.fmt.parseInt(u16, val, 10) catch
                fatal("invalid --cols value");
        } else if (std.mem.eql(u8, arg, "--font-family")) {
            result.config.font_family = requireArg(args, &i, "--font-family");
        } else if (std.mem.eql(u8, arg, "--font-size")) {
            const val = requireArg(args, &i, "--font-size");
            const size = std.fmt.parseInt(u16, val, 10) catch
                fatal("invalid --font-size value");
            if (size == 0) fatal("--font-size must be > 0");
            result.config.font_size = size;
        } else if (std.mem.eql(u8, arg, "--cell-width")) {
            const val = requireArg(args, &i, "--cell-width");
            result.config.cell_width = CellSize.fromString(val) orelse
                fatal("invalid --cell-width value (integer or \"N%\")");
        } else if (std.mem.eql(u8, arg, "--cell-height")) {
            const val = requireArg(args, &i, "--cell-height");
            result.config.cell_height = CellSize.fromString(val) orelse
                fatal("invalid --cell-height value (integer or \"N%\")");
        } else if (std.mem.eql(u8, arg, "--theme")) {
            result.config.theme_name = requireArg(args, &i, "--theme");
        } else if (std.mem.eql(u8, arg, "--scrollback-lines")) {
            const val = requireArg(args, &i, "--scrollback-lines");
            result.config.scrollback_lines = std.fmt.parseInt(u32, val, 10) catch
                fatal("invalid --scrollback-lines value");
        } else if (std.mem.eql(u8, arg, "--reflow")) {
            result.config.reflow_enabled = true;
        } else if (std.mem.eql(u8, arg, "--no-reflow")) {
            result.config.reflow_enabled = false;
        } else if (std.mem.eql(u8, arg, "--cursor-shape")) {
            const val = requireArg(args, &i, "--cursor-shape");
            result.config.cursor_shape = CursorShapeConfig.fromString(val) orelse {
                std.debug.print("error: --cursor-shape must be \"block\", \"beam\", or \"underline\"\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--cursor-blink")) {
            result.config.cursor_blink = true;
        } else if (std.mem.eql(u8, arg, "--no-cursor-blink")) {
            result.config.cursor_blink = false;
        } else if (std.mem.eql(u8, arg, "--shell")) {
            result.config.program = requireArg(args, &i, "--shell");
        } else if (std.mem.eql(u8, arg, "--cmd")) {
            result.config.argv = @ptrCast(args[i + 1 ..]);
            break;
        } else {
            std.debug.print("unknown option: {s}\n", .{arg});
            fatal("use --help for usage");
        }
    }
    return result;
}

pub fn printUsage() void {
    const usage =
        \\Attyx — GPU-accelerated VT-compatible terminal emulator
        \\
        \\Usage:
        \\  attyx [options]            Launch terminal (GPU-accelerated)
        \\
        \\Options:
        \\  --rows N                   Terminal rows (default: 24)
        \\  --cols N                   Terminal cols (default: 80)
        \\  --cmd <command...>         Override shell command
        \\  --config <path>            Load config from a specific file
        \\  --no-config                Skip reading config from disk
        \\  --font-family <string>     Font family (default: "JetBrains Mono")
        \\  --font-size <int>          Font size in points (default: 14)
        \\  --cell-width <value>       Cell width: points (e.g. 10) or percent (e.g. "110%")
        \\  --cell-height <value>      Cell height: points (e.g. 20) or percent (e.g. "115%")
        \\  --theme <string>           Theme name (default: "default")
        \\  --scrollback-lines <int>   Scrollback buffer lines (default: 20000)
        \\  --reflow / --no-reflow     Enable/disable reflow on resize
        \\  --cursor-shape <shape>     Cursor shape: block, beam, underline
        \\  --cursor-blink / --no-cursor-blink
        \\                             Enable/disable cursor blinking
        \\  --shell <path>             Shell program (default: $SHELL or /bin/sh)
        \\  --print-config             Print merged config and exit
        \\  --help, -h                 Show this help
        \\
    ;
    std.debug.print("{s}", .{usage});
}
