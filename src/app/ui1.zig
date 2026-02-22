const std = @import("std");
const posix = std.posix;
const attyx = @import("attyx");

const Engine = attyx.Engine;
const snapshot = attyx.snapshot;
const state_hash = attyx.hash;
const Pty = @import("pty.zig").Pty;
const SessionLog = @import("session_log.zig").SessionLog;

const Termios = std.posix.termios;

extern "c" fn tcgetattr(fd: c_int, termios: *Termios) c_int;
extern "c" fn tcsetattr(fd: c_int, action: c_int, termios: *const Termios) c_int;

const TCSAFLUSH: c_int = switch (@import("builtin").os.tag) {
    .macos => 2,
    .linux => 2,
    else => @compileError("unsupported OS"),
};

pub const Config = struct {
    rows: u16 = 24,
    cols: u16 = 80,
    argv: ?[]const [:0]const u8 = null,
    no_snapshot: bool = false,
    separator: bool = false,
};

pub fn run(config: Config) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try Engine.init(allocator, config.rows, config.cols);
    defer engine.deinit();

    var pty = try Pty.spawn(.{
        .rows = config.rows,
        .cols = config.cols,
        .argv = config.argv,
    });
    defer pty.deinit();

    var session = try SessionLog.init(allocator);
    defer session.deinit();

    // Put stdin in raw mode
    var orig_termios: Termios = undefined;
    const stdin_fd: c_int = 0;
    const have_termios = tcgetattr(stdin_fd, &orig_termios) == 0;

    if (have_termios) {
        var raw = orig_termios;
        makeRaw(&raw);
        _ = tcsetattr(stdin_fd, TCSAFLUSH, &raw);
    }
    defer {
        if (have_termios) _ = tcsetattr(stdin_fd, TCSAFLUSH, &orig_termios);
    }

    const stdout_fd: posix.fd_t = posix.STDOUT_FILENO;
    var prev_hash: u64 = state_hash.hash(&engine.state);
    var pty_buf: [65536]u8 = undefined;
    var stdin_buf: [4096]u8 = undefined;

    // Minimum interval between snapshots (~30 fps)
    const frame_ns: u64 = 33 * std.time.ns_per_ms;
    var last_snap: i128 = 0;

    const POLLIN: i16 = 0x0001;
    const POLLHUP: i16 = 0x0010;
    var stdin_open = true;

    while (true) {
        var fds = [_]posix.pollfd{
            .{ .fd = pty.master, .events = POLLIN, .revents = 0 },
            .{ .fd = @as(posix.fd_t, stdin_fd), .events = if (stdin_open) POLLIN else 0, .revents = 0 },
        };

        _ = posix.poll(&fds, 16) catch break;

        if (fds[0].revents & POLLIN != 0) {
            const n = pty.read(&pty_buf) catch break;
            if (n > 0) {
                const chunk = pty_buf[0..n];
                session.appendOutput(chunk);
                engine.feed(chunk);
                const h = state_hash.hash(&engine.state);
                session.appendFrame(h, engine.state.alt_active);
            }
        }

        if (stdin_open and fds[1].revents & POLLIN != 0) {
            const n = posix.read(@as(posix.fd_t, stdin_fd), &stdin_buf) catch {
                stdin_open = false;
                continue;
            };
            if (n == 0) {
                stdin_open = false;
                continue;
            }
            const input_chunk = stdin_buf[0..n];
            session.appendInput(input_chunk);
            _ = pty.writeToPty(input_chunk) catch {
                stdin_open = false;
                continue;
            };
        }

        // Snapshot on change (throttled)
        if (!config.no_snapshot) {
            const h = state_hash.hash(&engine.state);
            if (h != prev_hash) {
                const now = std.time.nanoTimestamp();
                if (now - last_snap >= @as(i128, frame_ns)) {
                    prev_hash = h;
                    last_snap = now;

                    const snap = snapshot.dumpToString(allocator, &engine.state.grid) catch continue;
                    defer allocator.free(snap);

                    if (config.separator) _ = posix.write(stdout_fd, "\n---\n") catch {};
                    _ = posix.write(stdout_fd, "\x1b[H") catch {};
                    _ = posix.write(stdout_fd, snap) catch {};
                }
            }
        }

        // Exit after processing + snapshot, so we don't miss final output
        if (fds[0].revents & POLLHUP != 0 or pty.childExited()) break;
    }

    // Final snapshot flush — catch any last-frame changes
    if (!config.no_snapshot) {
        const final_h = state_hash.hash(&engine.state);
        if (final_h != prev_hash) {
            if (snapshot.dumpToString(allocator, &engine.state.grid)) |snap| {
                defer allocator.free(snap);
                _ = posix.write(stdout_fd, "\x1b[H") catch {};
                _ = posix.write(stdout_fd, snap) catch {};
            } else |_| {}
        }
    }

    if (have_termios) {
        _ = posix.write(stdout_fd, "\x1b[2J\x1b[H") catch {};
    }
}

fn makeRaw(t: *Termios) void {
    t.lflag.ECHO = false;
    t.lflag.ICANON = false;
    t.lflag.ISIG = false;
    t.lflag.IEXTEN = false;
}
