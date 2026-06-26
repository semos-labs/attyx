//! `attyx dashboard` entry point. Opens a cross-session `watch_agents` stream,
//! renders a live full-screen table, and lets you jump to an agent's session.
//! Connection: the daemon (all-sessions sentinel) when available, else the
//! attached window (its session only). Frames are protocol-agnostic length-
//! prefixed payloads; each payload is fed to the model, which ignores non-records.
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

// --- signal-safe terminal restore -----------------------------------------
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

const Source = enum { daemon, window };

/// Daemon all-sessions watch: payload [session:u32 = sentinel][pane_filter:u32].
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

/// Attached-window watch (its session only): payload [pane_filter:u32].
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
/// we should fall back to the window. Silence (a live daemon with no agents) is
/// fine — keep it.
fn daemonRejected(stream: *Stream, m: *model_mod.Model, gpa: std.mem.Allocator) bool {
    var pf = [_]posix.pollfd{.{ .fd = stream.fd, .events = POLLIN, .revents = 0 }};
    var rounds: usize = 0;
    while (rounds < 3) : (rounds += 1) {
        const ready = posix.poll(&pf, 250) catch return false;
        if (ready == 0) return false; // open but quiet → working daemon
        const alive = stream.pump(m, gpa);
        if (stream.records > 0) return false; // got data → daemon is fine
        if (!alive or stream.errored) return true; // closed/errored with no data
    }
    return false;
}

/// Accumulates stream bytes and feeds complete length-prefixed frames to the
/// model. Frame = [len:u32 LE][type:u8][payload:len]. Type is ignored — the
/// payload is an NDJSON agent record (or an error, which the model ignores).
const Stream = struct {
    fd: posix.fd_t,
    buf: [64 * 1024]u8 = undefined,
    len: usize = 0,
    records: usize = 0, // agent records applied (frames starting with '{')
    errored: bool = false, // saw a non-record frame (an error reply)

    /// Read available bytes and apply any complete frames. Returns false on
    /// EOF/error (stream dropped).
    fn pump(self: *Stream, m: *model_mod.Model, gpa: std.mem.Allocator) bool {
        const n = posix.read(self.fd, self.buf[self.len..]) catch return false;
        if (n == 0) return false; // EOF
        self.len += n;
        var off: usize = 0;
        while (self.len - off >= io.header_size) {
            const plen = std.mem.readInt(u32, self.buf[off..][0..4], .little);
            if (plen > self.buf.len) { // unparseable; resync by dropping buffer
                self.len = 0;
                return true;
            }
            if (self.len - off - io.header_size < plen) break; // incomplete
            const payload = self.buf[off + io.header_size ..][0..plen];
            if (plen > 0 and payload[0] == '{') {
                m.applyLine(gpa, payload);
                self.records += 1;
            } else if (plen > 0) {
                self.errored = true; // an error reply (e.g. old daemon, no sentinel)
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

/// Jump to the selected agent's session by asking the attached window to switch
/// to it (one-shot session_switch on the window socket). Pane-level focus within
/// the session is a follow-up. Best-effort; ignores failure.
fn jumpToSession(session_id: u32) void {
    var sock_buf: [256]u8 = undefined;
    const sock = client.discoverSocket(&sock_buf, null) orelse return;
    const fd = client.connectToSocket(sock) catch return;
    defer io.closeFd(fd);
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], session_id, .little);
    var frame_buf: [ipc_proto.header_size + 4]u8 = undefined;
    const frame = ipc_proto.encodeMessage(&frame_buf, .session_switch, &payload) catch return;
    io.writeAll(fd, frame) catch return;
    // Read and discard the ack so the window processes it before we exit.
    var hdr: [ipc_proto.header_size]u8 = undefined;
    io.readExact(fd, &hdr) catch {};
}

pub fn run(gpa: std.mem.Allocator, opts: Options) void {
    var sock_buf: [256]u8 = undefined;
    var m = model_mod.Model{};

    // Prefer the daemon (all sessions); fall back to the attached window (its
    // session) if there's no daemon, or if the daemon is too old to understand
    // the all-sessions sentinel (it rejects the request).
    var source: Source = .daemon;
    var stream: Stream = if (openDaemon(&sock_buf)) |fd| Stream{ .fd = fd } else blk: {
        source = .window;
        break :blk Stream{ .fd = openWindow(&sock_buf) orelse {
            stderrMsg("error: no running Attyx instance found\n");
            std.process.exit(1);
        } };
    };
    if (source == .daemon and daemonRejected(&stream, &m, gpa)) {
        io.closeFd(stream.fd);
        source = .window;
        m = .{};
        stream = Stream{ .fd = openWindow(&sock_buf) orelse {
            stderrMsg("error: no running Attyx instance found\n");
            std.process.exit(1);
        } };
    }
    defer io.closeFd(stream.fd);

    const tty = term_mod.isTty(posix.STDOUT_FILENO) and term_mod.isTty(posix.STDIN_FILENO);

    // --once or non-TTY: drain the snapshot (read until briefly idle), print a
    // plain table, and exit. No raw mode.
    if (opts.once or !tty) {
        var fds = [_]posix.pollfd{.{ .fd = stream.fd, .events = POLLIN, .revents = 0 }};
        while (true) {
            const ready = posix.poll(&fds, 200) catch break;
            if (ready == 0) break; // ~200ms idle → snapshot complete
            if (!stream.pump(&m, gpa)) break;
        }
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var out = std.ArrayList(u8){};
        render.snapshot(out.writer(arena.allocator()), arena.allocator(), &m) catch {};
        _ = posix.write(posix.STDOUT_FILENO, out.items) catch {};
        return;
    }

    runInteractive(gpa, &stream, &m) catch {};
}

fn runInteractive(gpa: std.mem.Allocator, stream: *Stream, m: *model_mod.Model) !void {
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

    var fds = [_]posix.pollfd{
        .{ .fd = stream.fd, .events = POLLIN, .revents = 0 },
        .{ .fd = posix.STDIN_FILENO, .events = POLLIN, .revents = 0 },
    };

    while (true) {
        if (dirty) {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            var buf = std.ArrayList(u8){};
            render.frame(&buf, arena.allocator(), m, size.rows, size.cols, connected) catch {};
            t.write(buf.items);
            dirty = false;
        }

        // Only poll the stream while connected; -1 makes poll ignore the slot so
        // a dropped stream doesn't busy-loop. The fd is owned/closed by run().
        fds[0].fd = if (connected) stream.fd else -1;
        _ = posix.poll(&fds, 1000) catch {};

        if (g_winch) {
            g_winch = false;
            size = t.size();
            dirty = true;
        }
        if (connected and fds[0].revents & POLLIN != 0) {
            if (!stream.pump(m, gpa)) {
                // Stream dropped — keep the last table visible with a banner; the
                // user quits with q. (Auto-reconnect is a follow-up.)
                connected = false;
            }
            dirty = true;
        }
        if (fds[1].revents & POLLIN != 0) {
            var ib: [256]u8 = undefined;
            const n = posix.read(posix.STDIN_FILENO, &ib) catch 0;
            if (n == 0) break;
            for (ib[0..n]) |b| {
                if (dec.feed(b)) |key| switch (key) {
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
                    .refresh => dirty = true,
                    .enter => {
                        if (m.selectedRow()) |r| {
                            t.restore(); // leave the TUI before switching the window
                            jumpToSession(r.session);
                            return;
                        }
                    },
                    .help, .none => {},
                };
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
