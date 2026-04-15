//! Test harness for daemon ↔ client integration tests.
//! Provides TestDaemon (runs in background thread) and TestClient
//! (raw socket with send/recv/expect helpers).
const std = @import("std");
const posix = std.posix;
const testing = std.testing;
const protocol = @import("protocol.zig");
const DaemonSession = @import("session.zig").DaemonSession;
const DaemonClient = @import("client.zig").DaemonClient;
const handler = @import("handler.zig");
const upgrade = @import("upgrade.zig");

const max_sessions: usize = 32;
const max_clients: usize = 16;

/// A minimal daemon that runs in a background thread.
/// Accepts connections, dispatches messages via handler.zig.
pub const TestDaemon = struct {
    listen_fd: posix.fd_t,
    sessions: [max_sessions]?DaemonSession = .{null} ** max_sessions,
    session_count: usize = 0,
    next_session_id: u32 = 1,
    next_pane_id: u32 = 1,
    clients: [max_clients]?DaemonClient = .{null} ** max_clients,
    client_count: usize = 0,
    running: bool = true,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, listen_fd: posix.fd_t) TestDaemon {
        return .{ .listen_fd = listen_fd, .allocator = allocator };
    }

    /// Single iteration of the event loop: accept, read PTY, read clients.
    pub fn tick(self: *TestDaemon) void {
        const max_panes_total = max_sessions * @import("session.zig").max_panes_per_session;
        const max_fds = 1 + max_panes_total + max_clients;
        var fds: [max_fds]posix.pollfd = undefined;
        var nfds: usize = 0;

        fds[0] = .{ .fd = self.listen_fd, .events = 0x0001, .revents = 0 };
        nfds = 1;

        const PaneFdEntry = struct { session_idx: usize, pane_idx: usize };
        var pty_fd_map: [max_panes_total]PaneFdEntry = undefined;
        var pty_fd_count: usize = 0;
        for (&self.sessions, 0..) |*slot, si| {
            if (slot.*) |*s| {
                for (&s.panes, 0..) |*pslot, pi| {
                    if (pslot.*) |*p| {
                        if (p.alive) {
                            fds[nfds] = .{ .fd = p.pty.master, .events = 0x0001, .revents = 0 };
                            pty_fd_map[pty_fd_count] = .{ .session_idx = si, .pane_idx = pi };
                            pty_fd_count += 1;
                            nfds += 1;
                        }
                    }
                }
            }
        }

        const client_fd_start = nfds;
        var client_fd_map: [max_clients]usize = undefined;
        var client_fd_count: usize = 0;
        for (&self.clients, 0..) |*slot, ci| {
            if (slot.*) |*cl| {
                fds[nfds] = .{ .fd = cl.socket_fd, .events = 0x0001, .revents = 0 };
                client_fd_map[client_fd_count] = ci;
                client_fd_count += 1;
                nfds += 1;
            }
        }

        _ = posix.poll(fds[0..nfds], 10) catch return;

        if (fds[0].revents & 0x0001 != 0) self.acceptClient();

        // Read PTY data and forward to attached clients
        var pty_buf: [8192]u8 = undefined;
        for (0..pty_fd_count) |pi| {
            const poll_idx = 1 + pi;
            const entry = pty_fd_map[pi];
            if (fds[poll_idx].revents & 0x0001 != 0) {
                if (self.sessions[entry.session_idx]) |*s| {
                    if (s.panes[entry.pane_idx]) |*pane| {
                        const n = pane.readPty(&pty_buf) catch 0;
                        if (n > 0) {
                            for (&self.clients) |*cslot| {
                                if (cslot.*) |*cl| {
                                    if (cl.attached_session == s.id and cl.isPaneActive(pane.id)) {
                                        cl.sendPaneOutput(pane.id, pty_buf[0..n]);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if (fds[poll_idx].revents & 0x0010 != 0) {
                if (self.sessions[entry.session_idx]) |*s| {
                    if (s.panes[entry.pane_idx]) |*pane| {
                        if (pane.checkExit()) |exit_code| {
                            var any_alive = false;
                            for (s.panes) |slot| {
                                if (slot) |p| if (p.alive) {
                                    any_alive = true;
                                    break;
                                };
                            }
                            if (!any_alive) s.alive = false;
                            for (&self.clients) |*cslot| {
                                if (cslot.*) |*cl| {
                                    if (cl.attached_session == s.id) {
                                        cl.sendPaneDied(pane.id, exit_code);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Read client messages
        for (0..client_fd_count) |ci| {
            const poll_idx = client_fd_start + ci;
            const slot_idx = client_fd_map[ci];
            if (fds[poll_idx].revents & (0x0001 | 0x0010) != 0) {
                if (self.clients[slot_idx]) |*cl| {
                    if (!cl.recvData()) {
                        cl.deinit();
                        self.clients[slot_idx] = null;
                        self.client_count -= 1;
                        continue;
                    }
                    var upgrade_requested: bool = false;
                    while (cl.nextMessage()) |msg| {
                        handler.handleMessage(
                            cl, msg, &self.sessions, &self.session_count,
                            &self.next_session_id, &self.next_pane_id,
                            self.allocator, &self.clients, &upgrade_requested,
                        );
                    }
                    if (cl.dead) {
                        cl.deinit();
                        self.clients[slot_idx] = null;
                        self.client_count -= 1;
                    }
                }
            }
        }
    }

    fn acceptClient(self: *TestDaemon) void {
        const fd = posix.accept(self.listen_fd, null, null, 0) catch return;
        if (self.client_count >= max_clients) {
            posix.close(fd);
            return;
        }
        setNonBlocking(fd);
        for (&self.clients) |*slot| {
            if (slot.* == null) {
                slot.* = DaemonClient.init(fd);
                self.client_count += 1;
                return;
            }
        }
        posix.close(fd);
    }

    pub fn deinit(self: *TestDaemon) void {
        for (&self.sessions) |*slot| {
            if (slot.*) |*s| {
                s.deinit();
                slot.* = null;
            }
        }
        for (&self.clients) |*slot| {
            if (slot.*) |*cl| {
                cl.deinit();
                slot.* = null;
            }
        }
        posix.close(self.listen_fd);
    }
};

fn daemonThread(d: *TestDaemon) void {
    while (d.running) d.tick();
}

/// Raw test client — socket fd with send/recv/expect helpers.
pub const TestClient = struct {
    fd: posix.fd_t,
    read_buf: [65536]u8 = undefined,
    read_len: usize = 0,

    pub fn connect(path: []const u8) !TestClient {
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);
        const addr = try std.net.Address.initUnix(path);
        try posix.connect(fd, &addr.any, addr.getOsSockLen());
        setNonBlocking(fd);
        return .{ .fd = fd };
    }

    pub fn send(self: *TestClient, msg_type: protocol.MessageType, payload: []const u8) !void {
        var hdr: [protocol.header_size]u8 = undefined;
        protocol.encodeHeader(&hdr, msg_type, @intCast(payload.len));
        try writeAllBlocking(self.fd, &hdr);
        if (payload.len > 0) try writeAllBlocking(self.fd, payload);
    }

    /// Wait for a specific message type, with timeout. Returns payload.
    pub fn expect(self: *TestClient, expected: protocol.MessageType, timeout_ms: u32) ![]const u8 {
        var elapsed: u32 = 0;
        while (elapsed < timeout_ms) {
            if (self.tryParse(expected)) |payload| return payload;
            var fds = [1]posix.pollfd{.{ .fd = self.fd, .events = 0x0001, .revents = 0 }};
            _ = posix.poll(&fds, 50) catch return error.PollFailed;
            if (fds[0].revents & 0x0001 != 0) {
                const space = self.read_buf[self.read_len..];
                if (space.len == 0) return error.BufferFull;
                const n = posix.read(self.fd, space) catch |err| switch (err) {
                    error.WouldBlock => { elapsed += 50; continue; },
                    else => return error.ReadFailed,
                };
                if (n == 0) return error.ConnectionClosed;
                self.read_len += n;
            } else {
                elapsed += 50;
            }
        }
        return error.Timeout;
    }

    /// Drain messages until we find the expected type or exhaust buffer.
    pub fn tryParse(self: *TestClient, expected: protocol.MessageType) ?[]const u8 {
        while (self.read_len >= protocol.header_size) {
            const hdr = protocol.decodeHeader(self.read_buf[0..protocol.header_size]) catch {
                self.consume(1);
                continue;
            };
            const total = protocol.header_size + hdr.payload_len;
            if (self.read_len < total) return null;
            const payload_start = protocol.header_size;
            if (hdr.msg_type == expected) {
                const plen = hdr.payload_len;
                const dest_start = self.read_buf.len - plen;
                if (plen > 0) {
                    var tmp: [4096]u8 = undefined;
                    const copy_len = @min(plen, tmp.len);
                    @memcpy(tmp[0..copy_len], self.read_buf[payload_start..][0..copy_len]);
                    self.consume(total);
                    @memcpy(self.read_buf[dest_start..][0..copy_len], tmp[0..copy_len]);
                    return self.read_buf[dest_start..][0..copy_len];
                }
                self.consume(total);
                return self.read_buf[0..0];
            }
            self.consume(total);
        }
        return null;
    }

    fn consume(self: *TestClient, n: usize) void {
        const remaining = self.read_len - n;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.read_buf[0..remaining], self.read_buf[n..self.read_len]);
        }
        self.read_len = remaining;
    }

    pub fn deinit(self: *TestClient) void {
        posix.close(self.fd);
    }
};

pub fn writeAllBlocking(fd: posix.fd_t, data: []const u8) !void {
    var offset: usize = 0;
    var retries: u32 = 0;
    while (offset < data.len) {
        const n = posix.write(fd, data[offset..]) catch |err| {
            if (err == error.WouldBlock) {
                retries += 1;
                if (retries >= 100) return error.WouldBlock;
                posix.nanosleep(0, 1_000_000);
                continue;
            }
            return err;
        };
        offset += n;
        retries = 0;
    }
}

pub fn setNonBlocking(fd: posix.fd_t) void {
    const F_GETFL: i32 = 3;
    const F_SETFL: i32 = 4;
    const O_NONBLOCK: i32 = if (@import("builtin").os.tag == .linux) 0o4000 else 0x0004;
    const flags = std.posix.fcntl(fd, F_GETFL, 0) catch return;
    _ = std.posix.fcntl(fd, F_SETFL, flags | O_NONBLOCK) catch {};
}

// ── Setup / teardown ──

pub const TestEnv = struct {
    daemon: *TestDaemon,
    thread: ?std.Thread,
    socket_path: [128]u8,
    path_len: usize,
    allocator: std.mem.Allocator,

    pub fn path(self: *const TestEnv) []const u8 {
        return self.socket_path[0..self.path_len];
    }

    /// Start the daemon thread (for delayed-start tests).
    pub fn startDaemon(self: *TestEnv) !void {
        if (self.thread != null) return error.AlreadyRunning;
        self.thread = try std.Thread.spawn(.{}, daemonThread, .{self.daemon});
        posix.nanosleep(0, 10_000_000);
    }

    /// Simulate hot-upgrade migration: serialize state, wipe daemon, deserialize into fresh daemon.
    /// Unlike restartDaemon(), this preserves session state through the transition.
    pub fn migrateDaemon(self: *TestEnv) !void {
        // Stop daemon thread
        self.daemon.running = false;
        if (self.thread) |t| t.join();
        self.thread = null;

        // Serialize current state
        var list: std.ArrayList(u8) = .{};
        defer list.deinit(self.allocator);
        try upgrade.serialize(
            list.writer(self.allocator),
            &self.daemon.sessions,
            self.daemon.next_session_id,
            self.daemon.next_pane_id,
        );

        // Wipe old sessions/clients (don't deinit panes — PTY fds transfer)
        // We need to deinit ring buffers but NOT close PTY fds.
        // Since fromRestored allocates new ring buffers, free the old ones.
        for (&self.daemon.sessions) |*slot| {
            if (slot.*) |*s| {
                for (&s.panes) |*pslot| {
                    if (pslot.*) |*p| {
                        p.freeTransferableState();
                        pslot.* = null;
                    }
                }
                slot.* = null;
            }
        }
        for (&self.daemon.clients) |*slot| {
            if (slot.*) |*cl| { cl.deinit(); slot.* = null; }
        }
        self.daemon.sessions = .{null} ** max_sessions;
        self.daemon.session_count = 0;
        self.daemon.client_count = 0;
        self.daemon.next_session_id = 1;
        self.daemon.next_pane_id = 1;

        // Deserialize into fresh state
        const restored = try upgrade.deserialize(
            list.items,
            &self.daemon.sessions,
            &self.daemon.next_session_id,
            &self.daemon.next_pane_id,
            self.allocator,
        );
        // Update session_count to match restored slots
        self.daemon.session_count = restored;

        // Set PTY fds non-blocking for restored panes
        for (&self.daemon.sessions) |*slot| {
            if (slot.*) |*s| {
                for (&s.panes) |*pslot| {
                    if (pslot.*) |*p| {
                        if (p.alive) setNonBlocking(p.pty.master);
                    }
                }
            }
        }

        // Restart daemon thread
        self.daemon.running = true;
        self.thread = try std.Thread.spawn(.{}, daemonThread, .{self.daemon});
        posix.nanosleep(0, 10_000_000);
    }

    /// Stop the current daemon and start a fresh one on the same socket.
    /// Sessions from the old daemon are lost — simulates daemon restart.
    pub fn restartDaemon(self: *TestEnv) !void {
        // Stop old daemon
        self.daemon.running = false;
        if (self.thread) |t| t.join();
        self.thread = null;

        // Close old sessions/clients but keep the listen_fd
        for (&self.daemon.sessions) |*slot| {
            if (slot.*) |*s| { s.deinit(); slot.* = null; }
        }
        for (&self.daemon.clients) |*slot| {
            if (slot.*) |*cl| { cl.deinit(); slot.* = null; }
        }
        self.daemon.session_count = 0;
        self.daemon.client_count = 0;
        self.daemon.next_session_id = 1;
        self.daemon.next_pane_id = 1;
        self.daemon.running = true;

        self.thread = try std.Thread.spawn(.{}, daemonThread, .{self.daemon});
        posix.nanosleep(0, 10_000_000);
    }
};

pub fn setup() !TestEnv {
    var env = try setupDelayed();
    try env.startDaemon();
    return env;
}

/// Create socket and daemon but don't start the thread yet.
/// Call env.startDaemon() when ready. Simulates launch delay.
pub fn setupDelayed() !TestEnv {
    const allocator = testing.allocator;

    var path_buf: [128]u8 = undefined;
    const pid = std.c.getpid();
    const ts = std.time.milliTimestamp();
    const path_len = (std.fmt.bufPrint(&path_buf, "/tmp/attyx-test-{d}-{d}.sock", .{ pid, ts }) catch
        return error.PathTooLong).len;
    const socket_path = path_buf[0..path_len];

    const listen_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    errdefer posix.close(listen_fd);
    var addr = try std.net.Address.initUnix(socket_path);
    try posix.bind(listen_fd, &addr.any, addr.getOsSockLen());
    posix.listen(listen_fd, 5) catch return error.ListenFailed;
    setNonBlocking(listen_fd);

    const daemon = try allocator.create(TestDaemon);
    daemon.* = TestDaemon.init(allocator, listen_fd);

    return .{
        .daemon = daemon,
        .thread = null,
        .socket_path = path_buf,
        .path_len = path_len,
        .allocator = allocator,
    };
}

pub fn teardown(env: *TestEnv) void {
    env.daemon.running = false;
    if (env.thread) |t| t.join();
    env.daemon.deinit();
    env.allocator.destroy(env.daemon);
    std.fs.deleteFileAbsolute(env.path()) catch {};
}
