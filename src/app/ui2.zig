const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const attyx = @import("attyx");

const Engine = attyx.Engine;
const state_hash = attyx.hash;
const color_mod = attyx.render_color;
const Pty = @import("pty.zig").Pty;
const SessionLog = @import("session_log.zig").SessionLog;

const c = @cImport({
    @cInclude("bridge.h");
});

pub const Config = struct {
    rows: u16 = 24,
    cols: u16 = 80,
    argv: ?[]const [:0]const u8 = null,
};

const PtyThreadCtx = struct {
    engine: *Engine,
    pty: *Pty,
    cells: [*]c.AttyxCell,
    total: usize,
    session: *SessionLog,
};

// Global PTY fd for attyx_send_input (set before attyx_run, read by main thread)
var g_pty_master: posix.fd_t = -1;

export fn attyx_send_input(bytes: [*]const u8, len: c_int) void {
    if (g_pty_master < 0 or len <= 0) return;
    _ = posix.write(g_pty_master, bytes[0..@intCast(@as(c_uint, @bitCast(len)))]) catch {};
}

pub fn run(config: Config) !void {
    if (builtin.os.tag != .macos) {
        std.debug.print("ui2 requires macOS (Metal renderer). Use ui1 on other platforms.\n", .{});
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try Engine.init(allocator, config.rows, config.cols);
    defer engine.deinit();

    const total: usize = @as(usize, config.rows) * @as(usize, config.cols);
    const render_cells = try allocator.alloc(c.AttyxCell, total);
    defer allocator.free(render_cells);

    fillCells(render_cells, &engine, total);
    c.attyx_set_cursor(@intCast(engine.state.cursor.row), @intCast(engine.state.cursor.col));

    var pty = try Pty.spawn(.{
        .rows = config.rows,
        .cols = config.cols,
        .argv = config.argv,
    });
    defer pty.deinit();

    g_pty_master = pty.master;
    defer {
        g_pty_master = -1;
    }

    var session = try SessionLog.init(allocator);
    defer session.deinit();

    var ctx = PtyThreadCtx{
        .engine = &engine,
        .pty = &pty,
        .cells = render_cells.ptr,
        .total = total,
        .session = &session,
    };

    const thread = try std.Thread.spawn(.{}, ptyReaderThread, .{&ctx});
    defer thread.join();

    c.attyx_run(render_cells.ptr, @intCast(config.cols), @intCast(config.rows));
}

fn ptyReaderThread(ctx: *PtyThreadCtx) void {
    const POLLIN: i16 = 0x0001;
    const POLLHUP: i16 = 0x0010;
    var buf: [65536]u8 = undefined;

    while (c.attyx_should_quit() == 0) {
        var fds = [_]posix.pollfd{
            .{ .fd = ctx.pty.master, .events = POLLIN, .revents = 0 },
        };

        _ = posix.poll(&fds, 16) catch break;

        if (fds[0].revents & POLLIN != 0) {
            const n = ctx.pty.read(&buf) catch break;
            if (n > 0) {
                const chunk = buf[0..n];
                ctx.session.appendOutput(chunk);
                ctx.engine.feed(chunk);
                fillCells(ctx.cells[0..ctx.total], ctx.engine, ctx.total);
                c.attyx_set_cursor(
                    @intCast(ctx.engine.state.cursor.row),
                    @intCast(ctx.engine.state.cursor.col),
                );
                c.attyx_set_mode_flags(
                    @intFromBool(ctx.engine.state.bracketed_paste),
                    @intFromBool(ctx.engine.state.cursor_keys_app),
                );
                const h = state_hash.hash(&ctx.engine.state);
                ctx.session.appendFrame(h, ctx.engine.state.alt_active);
            }
        }

        if (fds[0].revents & POLLHUP != 0 or ctx.pty.childExited()) {
            c.attyx_request_quit();
            break;
        }
    }
}

fn fillCells(cells: []c.AttyxCell, eng: *Engine, total: usize) void {
    for (0..total) |i| {
        const cell = eng.state.grid.cells[i];
        const fg = color_mod.resolve(cell.style.fg, false);
        const bg = color_mod.resolve(cell.style.bg, true);
        cells[i] = .{
            .character = cell.char,
            .fg_r = fg.r,
            .fg_g = fg.g,
            .fg_b = fg.b,
            .bg_r = bg.r,
            .bg_g = bg.g,
            .bg_b = bg.b,
            .flags = @as(u8, if (cell.style.bold) 1 else 0) |
                @as(u8, if (cell.style.underline) 2 else 0),
        };
    }
}
