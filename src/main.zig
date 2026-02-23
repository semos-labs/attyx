const std = @import("std");
const builtin = @import("builtin");
const ui2 = @import("app/ui2.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len >= 2) {
        const cmd = args[1];
        if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
            printUsage();
            return;
        }
    }

    var config = ui2.Config{};
    var i: usize = 1;
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
        } else if (std.mem.eql(u8, arg, "--cmd")) {
            config.argv = @ptrCast(args[i + 1 ..]);
            break;
        } else {
            std.debug.print("unknown option: {s}\n", .{arg});
            fatal("use --help for usage");
        }
    }
    try ui2.run(config);
}

fn printUsage() void {
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
        \\  --help, -h                 Show this help
        \\
    ;
    std.debug.print("{s}", .{usage});
}

fn fatal(msg: []const u8) noreturn {
    std.debug.print("error: {s}\n", .{msg});
    std.process.exit(1);
}

test {
    _ = ui2;
}
