const std = @import("std");
const posix = std.posix;

const attyx = @import("attyx");
const protocol = @import("protocol.zig");
const grid_sync = @import("grid_sync.zig");

const SocketClient = struct {
    fd: posix.fd_t,
    buf: [128 * 1024]u8 = undefined,
    len: usize = 0,

    fn connect(path: []const u8) !SocketClient {
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);
        const addr = try std.net.Address.initUnix(path);
        try posix.connect(fd, &addr.any, addr.getOsSockLen());
        try setNonBlocking(fd);
        return .{ .fd = fd };
    }

    fn close(self: *SocketClient) void {
        if (self.fd < 0) return;
        posix.close(self.fd);
        self.fd = -1;
    }

    fn send(self: *SocketClient, msg_type: protocol.MessageType, payload: []const u8) !void {
        var hdr: [protocol.header_size]u8 = undefined;
        protocol.encodeHeader(&hdr, msg_type, @intCast(payload.len));
        try writeAll(self.fd, &hdr);
        if (payload.len > 0) try writeAll(self.fd, payload);
    }

    fn recv(self: *SocketClient, timeout_ms: u32) !bool {
        var fds = [1]posix.pollfd{.{ .fd = self.fd, .events = 0x0001, .revents = 0 }};
        _ = posix.poll(&fds, @intCast(timeout_ms)) catch return error.PollFailed;
        if (fds[0].revents & 0x0001 == 0) return false;
        while (true) {
            const space = self.buf[self.len..];
            if (space.len == 0) return error.BufferFull;
            const n = posix.read(self.fd, space) catch |err| switch (err) {
                error.WouldBlock => return true,
                else => return err,
            };
            if (n == 0) return error.ConnectionClosed;
            self.len += n;
        }
    }

    fn next(self: *SocketClient) ?struct { msg_type: protocol.MessageType, payload: []const u8, total: usize } {
        if (self.len < protocol.header_size) return null;
        const hdr = protocol.decodeHeader(self.buf[0..protocol.header_size]) catch {
            self.consume(1);
            return null;
        };
        const total = protocol.header_size + hdr.payload_len;
        if (self.len < total) return null;
        return .{ .msg_type = hdr.msg_type, .payload = self.buf[protocol.header_size..total], .total = total };
    }

    fn consume(self: *SocketClient, n: usize) void {
        const remaining = self.len - n;
        if (remaining > 0) std.mem.copyForwards(u8, self.buf[0..remaining], self.buf[n..self.len]);
        self.len = remaining;
    }

    fn expect(self: *SocketClient, msg_type: protocol.MessageType, timeout_ms: u32) ![]const u8 {
        var elapsed: u32 = 0;
        while (elapsed < timeout_ms) : (elapsed += 50) {
            while (self.next()) |m| {
                if (m.msg_type == msg_type) {
                    const payload_len = m.payload.len;
                    const dst = self.buf.len - payload_len;
                    if (payload_len > 0) std.mem.copyBackwards(u8, self.buf[dst..][0..payload_len], m.payload);
                    self.consume(m.total);
                    return self.buf[dst..][0..payload_len];
                }
                self.consume(m.total);
            }
            _ = try self.recv(50);
        }
        return error.Timeout;
    }
};

fn setNonBlocking(fd: posix.fd_t) !void {
    const F_GETFL: i32 = 3;
    const F_SETFL: i32 = 4;
    const O_NONBLOCK: i32 = if (@import("builtin").os.tag == .linux) 0o4000 else 0x0004;
    const flags = try posix.fcntl(fd, F_GETFL, 0);
    _ = try posix.fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = posix.write(fd, bytes[off..]) catch |err| switch (err) {
            error.WouldBlock => {
                posix.nanosleep(0, 1_000_000);
                continue;
            },
            else => return err,
        };
        off += n;
    }
}

fn connectWithRetry(path: []const u8) !SocketClient {
    var attempts: u32 = 0;
    while (attempts < 100) : (attempts += 1) {
        if (SocketClient.connect(path)) |client| return client else |_| {}
        posix.nanosleep(0, 50_000_000);
    }
    return error.DaemonDidNotStart;
}

fn hello(client: *SocketClient) !void {
    var buf: [256]u8 = undefined;
    const payload = try protocol.encodeHello(&buf, attyx.version, protocol.CAPABILITIES);
    try client.send(.hello, payload);
    _ = try client.expect(.hello_ack, 5000);
}

const SessionPane = struct { session_id: u32, pane_id: u32 };

fn sendMarker(client: *SocketClient, pane_id: u32, marker: []const u8) !void {
    var buf: [4200]u8 = undefined;
    var input_buf: [256]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&input_buf, "printf '{s}\\n'\n", .{marker});
    const ip = try protocol.encodePaneInput(&buf, pane_id, cmd);
    try client.send(.pane_input, ip);
}

fn focusPane(client: *SocketClient, pane_id: u32) !void {
    var buf: [4200]u8 = undefined;
    const fp = try protocol.encodeFocusPanes(&buf, &.{pane_id});
    try client.send(.focus_panes, fp);
}

fn createSession(client: *SocketClient, name: []const u8, marker: []const u8) !SessionPane {
    var buf: [4200]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, name, 6, 32, "/tmp", "/bin/sh");
    try client.send(.create, cp);
    const created = try client.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);

    const ap = try protocol.encodeAttach(&buf, sid, 6, 32);
    try client.send(.attach, ap);
    const attached = try client.expect(.attached, 5000);
    const v2 = try protocol.decodeAttachedV2(attached);
    const pane_id = v2.pane_ids[0];

    const rp = try protocol.encodePaneResize(&buf, pane_id, 6, 32);
    try client.send(.pane_resize, rp);
    try focusPane(client, pane_id);
    try sendMarker(client, pane_id, marker);
    try waitForSnapshotText(client, pane_id, marker, null, 5000);
    return .{ .session_id = sid, .pane_id = pane_id };
}

fn createPaneInAttachedSession(client: *SocketClient, marker: []const u8) !u32 {
    var buf: [4200]u8 = undefined;
    const cp = try protocol.encodeCreatePaneWithCmdFlagsShell(&buf, 6, 32, "/tmp", "", 0, "/bin/sh");
    try client.send(.create_pane, cp);
    const created = try client.expect(.pane_created, 5000);
    const pane_id = try protocol.decodePaneCreated(created);
    const rp = try protocol.encodePaneResize(&buf, pane_id, 6, 32);
    try client.send(.pane_resize, rp);
    try focusPane(client, pane_id);
    try sendMarker(client, pane_id, marker);
    try waitForSnapshotText(client, pane_id, marker, null, 5000);
    return pane_id;
}

fn attachAndFocus(client: *SocketClient, sp: SessionPane, marker: []const u8, forbidden: ?[]const u8) !void {
    var buf: [4200]u8 = undefined;
    const ap = try protocol.encodeAttach(&buf, sp.session_id, 6, 32);
    try client.send(.attach, ap);
    _ = try client.expect(.attached, 5000);
    try focusPane(client, sp.pane_id);
    try waitForSnapshotText(client, sp.pane_id, marker, forbidden, 5000);
}

fn waitForSnapshotText(client: *SocketClient, pane_id: u32, needle: []const u8, forbidden: ?[]const u8, timeout_ms: u32) !void {
    var elapsed: u32 = 0;
    while (elapsed < timeout_ms) : (elapsed += 50) {
        while (client.next()) |m| {
            if (m.msg_type == .grid_snapshot) {
                const info = grid_sync.decodeSnapshotHeader(m.payload) catch {
                    client.consume(m.total);
                    continue;
                };
                if (info.pane_id == pane_id) {
                    const text = snapshotText(m.payload) catch {
                        client.consume(m.total);
                        continue;
                    };
                    if (forbidden) |bad| {
                        if (std.mem.indexOf(u8, text, bad) != null) return error.StaleSnapshotText;
                    }
                    if (std.mem.indexOf(u8, text, needle) != null) {
                        client.consume(m.total);
                        return;
                    }
                }
            }
            client.consume(m.total);
        }
        _ = try client.recv(50);
    }
    return error.SnapshotTextMissing;
}

fn snapshotText(payload: []const u8) ![]const u8 {
    const S = struct {
        var text: [4096]u8 = undefined;
    };
    const info = try grid_sync.decodeSnapshotHeader(payload);
    const cell_bytes = try grid_sync.snapshotCellBytes(payload, info);
    var len: usize = 0;
    var idx: usize = 0;
    for (0..info.row_count) |_| {
        for (0..info.cols) |_| {
            const cell = grid_sync.unpackCell(grid_sync.readPackedCell(cell_bytes, idx));
            idx += 1;
            const ch: u21 = cell.char;
            S.text[len] = if (ch >= 32 and ch < 127) @intCast(ch) else ' ';
            len += 1;
            if (len >= S.text.len) break;
        }
        if (len < S.text.len) {
            S.text[len] = '\n';
            len += 1;
        }
    }
    return S.text[0..len];
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) return error.MissingAttyxPath;
    const attyx_exe = args[1];

    try std.fs.cwd().makePath(".zig-cache/attyx-real-daemon-state");
    const state_home = try std.fs.cwd().realpathAlloc(allocator, ".zig-cache/attyx-real-daemon-state");
    defer allocator.free(state_home);
    const suffix = try std.fmt.allocPrint(allocator, "-test-{d}", .{std.time.nanoTimestamp()});
    defer allocator.free(suffix);

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put("XDG_STATE_HOME", state_home);
    try env.put("ATTYX_STATE_SUFFIX", suffix);

    var child = std.process.Child.init(&.{ attyx_exe, "daemon" }, allocator);
    child.env_map = &env;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    defer {
        _ = child.kill() catch null;
    }

    const socket_path = try std.fmt.allocPrint(allocator, "{s}/attyx/sessions{s}.sock", .{ state_home, suffix });
    defer allocator.free(socket_path);

    var client = try connectWithRetry(socket_path);
    defer client.close();
    try hello(&client);

    const a = try createSession(&client, "smoke-a", "ATTYX_A_MARKER");
    const a_second_pane = try createPaneInAttachedSession(&client, "ATTYX_A_TAB2_MARKER");
    const b = try createSession(&client, "smoke-b", "ATTYX_B_MARKER");

    // Session switch A → B → A must hydrate the visible grid with the right content.
    try attachAndFocus(&client, b, "ATTYX_B_MARKER", "ATTYX_A_MARKER");
    try attachAndFocus(&client, a, "ATTYX_A_MARKER", "ATTYX_B_MARKER");

    // Tab switch within one session is a focus change between daemon panes.
    try focusPane(&client, a_second_pane);
    try waitForSnapshotText(&client, a_second_pane, "ATTYX_A_TAB2_MARKER", "ATTYX_A_MARKER", 5000);
    try focusPane(&client, a.pane_id);
    try waitForSnapshotText(&client, a.pane_id, "ATTYX_A_MARKER", "ATTYX_A_TAB2_MARKER", 5000);

    // Simulate app restart: new client, same isolated real daemon.
    client.close();
    var restarted = try connectWithRetry(socket_path);
    defer restarted.close();
    try hello(&restarted);
    try attachAndFocus(&restarted, a, "ATTYX_A_MARKER", "ATTYX_A_TAB2_MARKER");
}
