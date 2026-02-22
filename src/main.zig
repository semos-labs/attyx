const std = @import("std");
const ui1 = @import("app/ui1.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "ui1")) {
        var config = ui1.Config{};

        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--rows")) {
                i += 1;
                if (i >= args.len) fatal("--rows requires a value");
                config.rows = std.fmt.parseInt(u16, args[i], 10) catch
                    fatal("invalid --rows value");
            } else if (std.mem.eql(u8, arg, "--cols")) {
                i += 1;
                if (i >= args.len) fatal("--cols requires a value");
                config.cols = std.fmt.parseInt(u16, args[i], 10) catch
                    fatal("invalid --cols value");
            } else if (std.mem.eql(u8, arg, "--no-snapshot")) {
                config.no_snapshot = true;
            } else if (std.mem.eql(u8, arg, "--separator")) {
                config.separator = true;
            } else if (std.mem.eql(u8, arg, "--cmd")) {
                config.argv = @ptrCast(args[i + 1 ..]);
                break;
            } else {
                std.debug.print("unknown option: {s}\n", .{arg});
                fatal("use --help for usage");
            }
        }

        try ui1.run(config);
    } else if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        printUsage();
    } else {
        std.debug.print("unknown command: {s}\n", .{cmd});
        printUsage();
    }
}

fn printUsage() void {
    const usage =
        \\Attyx — deterministic VT-compatible terminal emulator
        \\
        \\Usage:
        \\  attyx ui1 [options]       Run PTY bridge (headless app loop)
        \\
        \\UI-1 options:
        \\  --rows N                  Terminal rows (default: 24)
        \\  --cols N                  Terminal cols (default: 80)
        \\  --cmd <command...>        Override shell command (default: /bin/bash --noprofile --norc)
        \\  --no-snapshot             Disable snapshot output
        \\  --separator               Print --- between snapshot frames
        \\  --help, -h                Show this help
        \\
    ;
    std.debug.print("{s}", .{usage});
}

fn fatal(msg: []const u8) noreturn {
    std.debug.print("error: {s}\n", .{msg});
    std.process.exit(1);
}
