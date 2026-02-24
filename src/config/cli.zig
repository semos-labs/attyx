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
        } else if (std.mem.eql(u8, arg, "--background-opacity")) {
            const val = requireArg(args, &i, "--background-opacity");
            const raw = std.fmt.parseFloat(f32, val) catch fatal("invalid --background-opacity value");
            if (raw < 0.0 or raw > 1.0) fatal("--background-opacity must be between 0.0 and 1.0");
            result.config.background_opacity = raw;
        } else if (std.mem.eql(u8, arg, "--background-blur")) {
            const val = requireArg(args, &i, "--background-blur");
            result.config.background_blur = std.fmt.parseInt(u16, val, 10) catch
                fatal("invalid --background-blur value");
        } else if (std.mem.eql(u8, arg, "--decorations")) {
            result.config.window_decorations = true;
        } else if (std.mem.eql(u8, arg, "--no-decorations")) {
            result.config.window_decorations = false;
        } else if (std.mem.eql(u8, arg, "--padding")) {
            const val = requireArg(args, &i, "--padding");
            const p = std.fmt.parseInt(u16, val, 10) catch fatal("invalid --padding value");
            result.config.window_padding_left   = p;
            result.config.window_padding_right  = p;
            result.config.window_padding_top    = p;
            result.config.window_padding_bottom = p;
        } else if (std.mem.eql(u8, arg, "--padding-x")) {
            const val = requireArg(args, &i, "--padding-x");
            const p = std.fmt.parseInt(u16, val, 10) catch fatal("invalid --padding-x value");
            result.config.window_padding_left  = p;
            result.config.window_padding_right = p;
        } else if (std.mem.eql(u8, arg, "--padding-y")) {
            const val = requireArg(args, &i, "--padding-y");
            const p = std.fmt.parseInt(u16, val, 10) catch fatal("invalid --padding-y value");
            result.config.window_padding_top    = p;
            result.config.window_padding_bottom = p;
        } else if (std.mem.eql(u8, arg, "--padding-left")) {
            const val = requireArg(args, &i, "--padding-left");
            result.config.window_padding_left = std.fmt.parseInt(u16, val, 10) catch fatal("invalid --padding-left value");
        } else if (std.mem.eql(u8, arg, "--padding-right")) {
            const val = requireArg(args, &i, "--padding-right");
            result.config.window_padding_right = std.fmt.parseInt(u16, val, 10) catch fatal("invalid --padding-right value");
        } else if (std.mem.eql(u8, arg, "--padding-top")) {
            const val = requireArg(args, &i, "--padding-top");
            result.config.window_padding_top = std.fmt.parseInt(u16, val, 10) catch fatal("invalid --padding-top value");
        } else if (std.mem.eql(u8, arg, "--padding-bottom")) {
            const val = requireArg(args, &i, "--padding-bottom");
            result.config.window_padding_bottom = std.fmt.parseInt(u16, val, 10) catch fatal("invalid --padding-bottom value");
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            result.config.log_level = requireArg(args, &i, "--log-level");
        } else if (std.mem.eql(u8, arg, "--log-file")) {
            result.config.log_file = requireArg(args, &i, "--log-file");
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

/// Re-scan args to apply only explicitly provided CLI flags on top of file config.
pub fn applyCliOverrides(args: []const [:0]const u8, config: *config_mod.AppConfig) void {
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
        } else if (std.mem.eql(u8, arg, "--cell-width")) {
            i += 1;
            if (i < args.len)
                config.cell_width = config_mod.CellSize.fromString(args[i]) orelse continue;
        } else if (std.mem.eql(u8, arg, "--cell-height")) {
            i += 1;
            if (i < args.len)
                config.cell_height = config_mod.CellSize.fromString(args[i]) orelse continue;
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
        } else if (std.mem.eql(u8, arg, "--shell")) {
            i += 1;
            if (i < args.len) config.program = args[i];
        } else if (std.mem.eql(u8, arg, "--background-opacity")) {
            i += 1;
            if (i < args.len)
                config.background_opacity = std.fmt.parseFloat(f32, args[i]) catch continue;
        } else if (std.mem.eql(u8, arg, "--background-blur")) {
            i += 1;
            if (i < args.len)
                config.background_blur = std.fmt.parseInt(u16, args[i], 10) catch continue;
        } else if (std.mem.eql(u8, arg, "--decorations")) {
            config.window_decorations = true;
        } else if (std.mem.eql(u8, arg, "--no-decorations")) {
            config.window_decorations = false;
        } else if (std.mem.eql(u8, arg, "--padding")) {
            i += 1;
            if (i < args.len) {
                if (std.fmt.parseInt(u16, args[i], 10)) |p| {
                    config.window_padding_left   = p;
                    config.window_padding_right  = p;
                    config.window_padding_top    = p;
                    config.window_padding_bottom = p;
                } else |_| {}
            }
        } else if (std.mem.eql(u8, arg, "--padding-x")) {
            i += 1;
            if (i < args.len) {
                if (std.fmt.parseInt(u16, args[i], 10)) |p| {
                    config.window_padding_left  = p;
                    config.window_padding_right = p;
                } else |_| {}
            }
        } else if (std.mem.eql(u8, arg, "--padding-y")) {
            i += 1;
            if (i < args.len) {
                if (std.fmt.parseInt(u16, args[i], 10)) |p| {
                    config.window_padding_top    = p;
                    config.window_padding_bottom = p;
                } else |_| {}
            }
        } else if (std.mem.eql(u8, arg, "--padding-left")) {
            i += 1;
            if (i < args.len)
                config.window_padding_left = std.fmt.parseInt(u16, args[i], 10) catch continue;
        } else if (std.mem.eql(u8, arg, "--padding-right")) {
            i += 1;
            if (i < args.len)
                config.window_padding_right = std.fmt.parseInt(u16, args[i], 10) catch continue;
        } else if (std.mem.eql(u8, arg, "--padding-top")) {
            i += 1;
            if (i < args.len)
                config.window_padding_top = std.fmt.parseInt(u16, args[i], 10) catch continue;
        } else if (std.mem.eql(u8, arg, "--padding-bottom")) {
            i += 1;
            if (i < args.len)
                config.window_padding_bottom = std.fmt.parseInt(u16, args[i], 10) catch continue;
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            i += 1;
            if (i < args.len) config.log_level = args[i];
        } else if (std.mem.eql(u8, arg, "--log-file")) {
            i += 1;
            if (i < args.len) config.log_file = args[i];
        } else if (std.mem.eql(u8, arg, "--cmd")) {
            config.argv = @ptrCast(args[i + 1 ..]);
            break;
        } else if (std.mem.eql(u8, arg, "--config") or
            std.mem.eql(u8, arg, "--no-config") or
            std.mem.eql(u8, arg, "--print-config") or
            std.mem.eql(u8, arg, "--help") or
            std.mem.eql(u8, arg, "-h") or
            std.mem.eql(u8, arg, "--decorations") or
            std.mem.eql(u8, arg, "--no-decorations"))
        {
            if (std.mem.eql(u8, arg, "--config")) i += 1;
        }
    }
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
        \\  --background-opacity <f>   Background opacity 0.0-1.0 (default: 1.0)
        \\  --background-blur <int>    Background blur radius when opacity < 1 (default: 30)
        \\  --decorations / --no-decorations
        \\                             Show/hide window title bar (default: shown)
        \\  --padding <int>            Window padding on all sides (logical pixels)
        \\  --padding-x <int>         Left + right padding
        \\  --padding-y <int>         Top + bottom padding
        \\  --padding-left/right/top/bottom <int>
        \\                             Per-side padding
        \\  --log-level <level>        Log level: err, warn, info, debug, trace (default: info)
        \\  --log-file <path>          Append logs to file (default: stderr only)
        \\  --print-config             Print merged config and exit
        \\  --help, -h                 Show this help
        \\
    ;
    std.debug.print("{s}", .{usage});
}
