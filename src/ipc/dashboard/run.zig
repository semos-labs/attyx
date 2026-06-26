//! `attyx dashboard` entry point. Opens a cross-session `watch_agents` stream,
//! renders a live full-screen table, and lets you navigate/jump/zoom/close
//! agents. Connection: the daemon (all-sessions sentinel) when available, else
//! the attached window (its session only); reconnects with backoff if dropped.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const term_mod = @import("term.zig");
const model_mod = @import("model.zig");
const render = @import("render.zig");
const input = @import("input.zig");
const client = @import("../client.zig");
const io = @import("../protocol.zig"); // writeAll/readExact/closeFd + header
const ipc_proto = @import("../protocol.zig");
const dproto = @import("../../app/daemon/protocol.zig");
const session_connect = @import("../../app/session_connect.zig");
const agent_watch = @import("../../app/daemon/agent_watch.zig");

const POLLIN: i16 = 0x0001;

pub const Options = struct {
    once: bool = false,
};

var g_term: ?*term_mod.Term = null;
var g_winch: bool = false;

fn onTermSignal(_: i32) callconv(.c) void {
    if (g_term) |t| t.restore();
    std.c._exit(130);
}
fn onWinch(_: i32) callconv(.c) void {
    g_winch = true;
}
fn stderrMsg(s: []const u8) void {
    _ = posix.write(posix.STDERR_FILENO, s) catch {};
}
fn nowMs() i64 {
    return std.time.milliTimestamp();
}

const Source = enum { daemon, window };

fn openDaemon(sock_buf: *[256]u8) ?posix.fd_t {
    const sock = session_connect.getSocketPath(sock_buf) orelse return null;
    const fd = client.connectToSocket(sock) catch return null;
    var payload: [8]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], agent_watch.all_sessions, .little);
    std.mem.writeInt(u32, payload[4..8], 0, .little);
    var frame_buf: [dproto.header_size + 8]u8 = undefined;
    const frame = dproto.encodeMessage(&frame_buf, .watch_agents, &payload) catch {
        io.closeFd(fd);
        return null;
    };
    io.writeAll(fd, frame) catch {
        io.closeFd(fd);
        return null;
    };
    return fd;
}

fn openWindow(sock_buf: *[256]u8) ?posix.fd_t {
    const sock = client.discoverSocket(sock_buf, null) orelse return null;
    const fd = client.connectToSocket(sock) catch return null;
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], 0, .little);
    var frame_buf: [ipc_proto.header_size + 4]u8 = undefined;
    const frame = ipc_proto.encodeMessage(&frame_buf, .watch_agents, &payload) catch {
        io.closeFd(fd);
        return null;
    };
    io.writeAll(fd, frame) catch {
        io.closeFd(fd);
        return null;
    };
    return fd;
}

/// Briefly read the daemon stream; if it errors or closes before any record (an
/// older daemon that doesn't understand the all-sessions sentinel), report that
/// we should fall back to the window. Silence (a live daemon, no agents) is fine.
fn daemonRejected(stream: *Stream, m: *model_mod.Model, gpa: std.mem.Allocator) bool {
    var pf = [_]posix.pollfd{.{ .fd = stream.fd, .events = POLLIN, .revents = 0 }};
    var rounds: usize = 0;
    while (rounds < 3) : (rounds += 1) {
        const ready = posix.poll(&pf, 250) catch return false;
        if (ready == 0) return false;
        const alive = stream.pump(m, gpa, nowMs());
        if (stream.records > 0) return false;
        if (!alive or stream.errored) return true;
    }
    return false;
}

/// Connect: daemon (all sessions) if it accepts the sentinel, else the window.
/// Returns null if no instance is reachable.
fn connect(sock_buf: *[256]u8, m: *model_mod.Model, gpa: std.mem.Allocator) ?Stream {
    if (openDaemon(sock_buf)) |fd| {
        var s = Stream{ .fd = fd };
        if (!daemonRejected(&s, m, gpa)) return s;
        io.closeFd(s.fd);
        m.* = .{};
    }
    if (openWindow(sock_buf)) |fd| return Stream{ .fd = fd };
    return null;
}

const Stream = struct {
    fd: posix.fd_t,
    buf: [64 * 1024]u8 = undefined,
    len: usize = 0,
    records: usize = 0,
    errored: bool = false,

    /// Read available bytes and apply complete frames. Returns false on EOF/error.
    fn pump(self: *Stream, m: *model_mod.Model, gpa: std.mem.Allocator, now_ms: i64) bool {
        const n = posix.read(self.fd, self.buf[self.len..]) catch return false;
        if (n == 0) return false;
        self.len += n;
        var off: usize = 0;
        while (self.len - off >= io.header_size) {
            const plen = std.mem.readInt(u32, self.buf[off..][0..4], .little);
            if (plen > self.buf.len) {
                self.len = 0;
                return true;
            }
            if (self.len - off - io.header_size < plen) break;
            const payload = self.buf[off + io.header_size ..][0..plen];
            if (plen > 0 and payload[0] == '{') {
                m.applyLine(gpa, payload, now_ms);
                self.records += 1;
            } else if (plen > 0) {
                self.errored = true;
            }
            off += io.header_size + plen;
        }
        if (off > 0) {
            std.mem.copyForwards(u8, self.buf[0 .. self.len - off], self.buf[off..self.len]);
            self.len -= off;
        }
        return true;
    }
};

/// Switch the attached window to `session`, then send a pane-targeted op
/// (`.pane_focus_targeted` / `.pane_zoom_targeted` / `.pane_close_targeted`) for
/// `pane_id`. Best-effort; ignores failure. Switching first means the op lands on
/// the right session's tab manager even when it isn't the attached one.
fn switchAndPane(session: u32, pane_id: u32, op: ipc_proto.MessageType) void {
    var sock_buf: [256]u8 = undefined;
    const sock = client.discoverSocket(&sock_buf, null) orelse return;
    const fd = client.connectToSocket(sock) catch return;
    defer io.closeFd(fd);
    var hdr: [ipc_proto.header_size]u8 = undefined;

    var p1: [4]u8 = undefined;
    std.mem.writeInt(u32, &p1, session, .little);
    var fb1: [ipc_proto.header_size + 4]u8 = undefined;
    const f1 = ipc_proto.encodeMessage(&fb1, .session_switch, &p1) catch return;
    io.writeAll(fd, f1) catch return;
    io.readExact(fd, &hdr) catch return; // ack — ensure the switch applied first

    var p2: [4]u8 = undefined;
    std.mem.writeInt(u32, &p2, pane_id, .little);
    var fb2: [ipc_proto.header_size + 4]u8 = undefined;
    const f2 = ipc_proto.encodeMessage(&fb2, op, &p2) catch return;
    io.writeAll(fd, f2) catch return;
    io.readExact(fd, &hdr) catch {};
}

/// Populate `names` from the window's `session_list` (TSV: `id\tname\t...`).
fn resolveNames(names: *render.NameCache) void {
    var sock_buf: [256]u8 = undefined;
    const sock = client.discoverSocket(&sock_buf, null) orelse return;
    const fd = client.connectToSocket(sock) catch return;
    defer io.closeFd(fd);
    var fb: [ipc_proto.header_size]u8 = undefined;
    const frame = ipc_proto.encodeMessage(&fb, .session_list, "") catch return;
    io.writeAll(fd, frame) catch return;
    var hdr: [ipc_proto.header_size]u8 = undefined;
    io.readExact(fd, &hdr) catch return;
    const h = ipc_proto.decodeHeader(&hdr) catch return;
    if (h.payload_len == 0 or h.payload_len > 8192) return;
    var pbuf: [8192]u8 = undefined;
    io.readExact(fd, pbuf[0..h.payload_len]) catch return;
    var lines = std.mem.splitScalar(u8, pbuf[0..h.payload_len], '\n');
    while (lines.next()) |ln| {
        if (ln.len == 0) continue;
        var fields = std.mem.splitScalar(u8, ln, '\t');
        const id_s = fields.next() orelse continue;
        const name = fields.next() orelse continue;
        const id = std.fmt.parseInt(u32, std.mem.trim(u8, id_s, " "), 10) catch continue;
        if (name.len > 0) names.set(id, name);
    }
}

pub fn run(gpa: std.mem.Allocator, opts: Options) void {
    var sock_buf: [256]u8 = undefined;
    var m = model_mod.Model{};
    var stream = connect(&sock_buf, &m, gpa) orelse {
        stderrMsg("error: no running Attyx instance found\n");
        std.process.exit(1);
    };
    defer io.closeFd(stream.fd);

    var names = render.NameCache{};
    resolveNames(&names);

    const tty = term_mod.isTty(posix.STDOUT_FILENO) and term_mod.isTty(posix.STDIN_FILENO);
    if (opts.once or !tty) {
        var fds = [_]posix.pollfd{.{ .fd = stream.fd, .events = POLLIN, .revents = 0 }};
        while (true) {
            const ready = posix.poll(&fds, 200) catch break;
            if (ready == 0) break;
            if (!stream.pump(&m, gpa, nowMs())) break;
        }
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var out = std.ArrayList(u8){};
        render.snapshot(out.writer(arena.allocator()), arena.allocator(), &m, .{ .now_ms = nowMs(), .names = &names }) catch {};
        _ = posix.write(posix.STDOUT_FILENO, out.items) catch {};
        return;
    }

    runInteractive(gpa, &stream, &m, &names) catch {};
}

const Mode = enum { normal, search, confirm };

fn runInteractive(gpa: std.mem.Allocator, stream: *Stream, m: *model_mod.Model, names: *render.NameCache) !void {
    var t = try term_mod.Term.init();
    g_term = &t;
    installSignals();
    try t.enterRaw();
    t.enterAlt();
    defer t.restore();

    var size = t.size();
    var dec = input.Decoder{};
    var dirty = true;
    var connected = true;
    var mode: Mode = .normal;
    var detail = false;
    var next_retry: i64 = 0;
    var backoff: i64 = 500;
    var last_names = nowMs();

    var fds = [_]posix.pollfd{
        .{ .fd = stream.fd, .events = POLLIN, .revents = 0 },
        .{ .fd = posix.STDIN_FILENO, .events = POLLIN, .revents = 0 },
    };

    while (true) {
        if (dirty) {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            var buf = std.ArrayList(u8){};
            render.frame(&buf, arena.allocator(), m, size.rows, size.cols, .{
                .now_ms = nowMs(),
                .names = names,
                .connected = connected,
                .detail = detail,
                .confirm_close = mode == .confirm,
            }) catch {};
            t.write(buf.items);
            dirty = false;
        }

        fds[0].fd = if (connected) stream.fd else -1;
        _ = posix.poll(&fds, 1000) catch {};

        if (g_winch) {
            g_winch = false;
            size = t.size();
            dirty = true;
        }
        // Refresh elapsed/age (and re-resolve names) on a steady tick.
        const now = nowMs();
        if (now - last_names >= 5000) {
            resolveNames(names);
            last_names = now;
            dirty = true;
        }
        dirty = true; // 1 Hz idle redraw so the age/elapsed column ticks

        if (connected and fds[0].revents & POLLIN != 0) {
            if (!stream.pump(m, gpa, now)) {
                connected = false;
                next_retry = now + backoff;
            }
            dirty = true;
        }

        // Reconnect with backoff while disconnected.
        if (!connected and now >= next_retry) {
            var sb: [256]u8 = undefined;
            const saved_sort = m.sort_mode;
            const saved_filter = m.filter_mode;
            if (connect(&sb, m, gpa)) |ns| {
                io.closeFd(stream.fd);
                stream.* = ns;
                m.sort_mode = saved_sort;
                m.filter_mode = saved_filter;
                m.refresh(now);
                connected = true;
                backoff = 500;
            } else {
                backoff = @min(backoff * 2, 5000);
                next_retry = now + backoff;
            }
            dirty = true;
        }

        if (fds[1].revents & POLLIN != 0) {
            var ib: [256]u8 = undefined;
            const n = posix.read(posix.STDIN_FILENO, &ib) catch 0;
            if (n == 0) break;
            for (ib[0..n]) |b| {
                switch (mode) {
                    .search => {
                        switch (b) {
                            0x1b => {
                                m.searchClear();
                                mode = .normal;
                            },
                            '\r', '\n' => mode = .normal, // keep the query
                            0x7f, 0x08 => m.searchBackspace(),
                            else => if (b >= 0x20 and b < 0x7f) m.searchAppend(b),
                        }
                        dirty = true;
                    },
                    .confirm => {
                        if (b == 'y' or b == 'Y') {
                            if (m.selectedRow()) |r| switchAndPane(r.session, r.pane_id, .pane_close_targeted);
                        }
                        mode = .normal;
                        dirty = true;
                    },
                    .normal => if (dec.feed(b)) |key| switch (key) {
                        .quit => return,
                        .up => {
                            m.moveUp();
                            dirty = true;
                        },
                        .down => {
                            m.moveDown();
                            dirty = true;
                        },
                        .top => {
                            m.moveTop();
                            dirty = true;
                        },
                        .bottom => {
                            m.moveBottom();
                            dirty = true;
                        },
                        .sort => {
                            m.cycleSort();
                            dirty = true;
                        },
                        .filter => {
                            m.cycleFilter();
                            dirty = true;
                        },
                        .search => {
                            m.searchClear();
                            mode = .search;
                            dirty = true;
                        },
                        .detail => {
                            detail = !detail;
                            dirty = true;
                        },
                        .zoom => {
                            if (m.selectedRow()) |r| switchAndPane(r.session, r.pane_id, .pane_zoom_targeted);
                        },
                        .close => {
                            if (m.selectedRow()) |_| {
                                mode = .confirm;
                                dirty = true;
                            }
                        },
                        .refresh => dirty = true,
                        .enter => {
                            if (m.selectedRow()) |r| {
                                t.restore(); // leave the TUI before switching the window
                                switchAndPane(r.session, r.pane_id, .pane_focus_targeted);
                                return;
                            }
                        },
                        .help, .none => {},
                    },
                }
            }
        }
    }
}

fn installSignals() void {
    const sa = posix.Sigaction{ .handler = .{ .handler = onTermSignal }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(posix.SIG.INT, &sa, null);
    posix.sigaction(posix.SIG.TERM, &sa, null);
    posix.sigaction(posix.SIG.HUP, &sa, null);
    const saw = posix.Sigaction{ .handler = .{ .handler = onWinch }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(posix.SIG.WINCH, &saw, null);
}
