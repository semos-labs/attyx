/// UI-side client for connecting to the session daemon over Unix socket.
/// Handles connect (with auto-start), message send/recv, and replay.
const std = @import("std");
const posix = std.posix;
const protocol = @import("daemon/protocol.zig");
const platform = @import("../platform/platform.zig");

extern "c" fn setsid() c_int;
extern "c" fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;
extern "c" fn readlink(path: [*:0]const u8, b: [*]u8, bufsiz: usize) isize;
extern "c" fn execvp(file: [*:0]const u8, argv: [*]const ?[*:0]const u8) c_int;

pub const max_list_entries = 32;

/// Cached session list entry (local copy, not referencing protocol buffer).
pub const ListEntry = struct {
    id: u32 = 0,
    name: [64]u8 = undefined,
    name_len: u8 = 0,
    alive: bool = false,

    pub fn getName(self: *const ListEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const SessionClient = struct {
    socket_fd: posix.fd_t = -1,
    read_buf: [65536]u8 = undefined,
    read_len: usize = 0,
    attached_session_id: ?u32 = null,
    allocator: std.mem.Allocator,

    /// Pending session list (populated when a session_list message arrives).
    pending_list: [max_list_entries]ListEntry = undefined,
    pending_list_count: u8 = 0,
    pending_list_ready: bool = false,

    /// Connect to daemon socket. Auto-starts daemon if not running.
    pub fn connect(allocator: std.mem.Allocator) !SessionClient {
        var client = SessionClient{ .allocator = allocator };
        client.socket_fd = try connectToSocket();
        setNonBlocking(client.socket_fd);
        return client;
    }

    fn connectToSocket() !posix.fd_t {
        var path_buf: [256]u8 = undefined;
        const socket_path = getSocketPath(&path_buf) orelse return error.NoHome;

        // First attempt
        if (tryConnect(socket_path)) |fd| return fd;

        // Auto-start daemon
        try startDaemon();

        // Retry with backoff: 50ms, 100ms, 200ms, 400ms (total ~750ms)
        var delay_ns: u64 = 50_000_000;
        for (0..4) |_| {
            posix.nanosleep(0, delay_ns);
            if (tryConnect(socket_path)) |fd| return fd;
            delay_ns *= 2;
        }

        return error.DaemonConnectFailed;
    }

    fn tryConnect(path: []const u8) ?posix.fd_t {
        const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return null;
        const addr = std.net.Address.initUnix(path) catch {
            posix.close(fd);
            return null;
        };
        posix.connect(fd, &addr.any, addr.getOsSockLen()) catch {
            posix.close(fd);
            return null;
        };
        return fd;
    }

    fn startDaemon() !void {
        // Double-fork to detach daemon from parent process group
        const pid = try posix.fork();
        if (pid == 0) {
            // First child — fork again and exit
            const pid2 = posix.fork() catch posix.abort();
            if (pid2 == 0) {
                // Grandchild — becomes daemon
                _ = setsid();

                // Re-exec ourselves as `attyx daemon`
                var exe_buf: [1024]u8 = undefined;
                const exe = getExePath(&exe_buf) orelse "/usr/local/bin/attyx";
                // Copy to a separate buffer to avoid aliasing (exe may point into exe_buf)
                var exe_z_buf: [1024]u8 = undefined;
                const exe_z = std.fmt.bufPrintZ(&exe_z_buf, "{s}", .{exe}) catch posix.abort();

                const daemon_str: [*:0]const u8 = "daemon";
                const argv = [_]?[*:0]const u8{ exe_z, daemon_str, null };
                _ = execvp(exe_z, &argv);
                posix.abort();
            }
            // First child exits immediately
            posix.abort();
        }
        // Parent — wait for first child to exit
        _ = posix.waitpid(pid, 0);
    }

    fn getExePath(buf: *[1024]u8) ?[]const u8 {
        if (comptime @import("builtin").os.tag == .macos) {
            var size: u32 = buf.len;
            if (_NSGetExecutablePath(buf, &size) == 0) {
                return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(buf)), 0);
            }
        } else {
            const n = readlink("/proc/self/exe", buf, buf.len);
            if (n > 0) return buf[0..@intCast(n)];
        }
        return null;
    }

    /// Create a new session on the daemon. Returns session ID.
    pub fn createSession(self: *SessionClient, name: []const u8, rows: u16, cols: u16) !u32 {
        var payload_buf: [128]u8 = undefined;
        const payload = try protocol.encodeCreate(&payload_buf, name, rows, cols);
        try self.sendMessage(.create, payload);

        // Wait for Created response (blocking with timeout)
        return self.waitForResponse(.created, 5000);
    }

    /// Attach to an existing session.
    pub fn attach(self: *SessionClient, session_id: u32, rows: u16, cols: u16) !void {
        var payload_buf: [8]u8 = undefined;
        const payload = try protocol.encodeAttach(&payload_buf, session_id, rows, cols);
        try self.sendMessage(.attach, payload);
        self.attached_session_id = session_id;
    }

    /// Detach from current session.
    pub fn detach(self: *SessionClient) !void {
        try self.sendMessage(.detach, &.{});
        self.attached_session_id = null;
    }

    /// Send input bytes to the attached session's PTY.
    pub fn sendInput(self: *SessionClient, bytes: []const u8) !void {
        try self.sendMessage(.input, bytes);
    }

    /// Send resize to the attached session.
    pub fn sendResize(self: *SessionClient, rows: u16, cols: u16) !void {
        var payload_buf: [4]u8 = undefined;
        const payload = try protocol.encodeResize(&payload_buf, rows, cols);
        try self.sendMessage(.resize, payload);
    }

    /// Request session list from daemon (non-blocking).
    pub fn requestList(self: *SessionClient) !void {
        try self.sendMessage(.list, &.{});
    }

    /// Request session list and block until response arrives (for startup).
    pub fn requestListSync(self: *SessionClient, timeout_ms: u32) !void {
        try self.sendMessage(.list, &.{});
        self.pending_list_ready = false;
        var elapsed: u32 = 0;
        while (elapsed < timeout_ms) {
            var fds = [1]posix.pollfd{.{ .fd = self.socket_fd, .events = 0x0001, .revents = 0 }};
            _ = posix.poll(&fds, 100) catch return error.PollFailed;
            if (fds[0].revents & 0x0001 != 0) {
                if (!self.recvData()) return error.ConnectionClosed;
                // Check for session_list message in buffer
                while (self.read_len >= protocol.header_size) {
                    const header = protocol.decodeHeader(self.read_buf[0..protocol.header_size]) catch {
                        self.consumeBytes(1);
                        continue;
                    };
                    const total = protocol.header_size + header.payload_len;
                    if (self.read_len < total) break;
                    const payload = self.read_buf[protocol.header_size..total];
                    if (header.msg_type == .session_list) {
                        self.parseSessionList(payload);
                        self.consumeBytes(total);
                        return; // Got the list
                    }
                    self.consumeBytes(total);
                }
            }
            elapsed += 100;
        }
        return error.Timeout;
    }

    /// Kill a session on the daemon.
    pub fn killSession(self: *SessionClient, session_id: u32) !void {
        var payload_buf: [4]u8 = undefined;
        const payload = try protocol.encodeKill(&payload_buf, session_id);
        try self.sendMessage(.kill, payload);
    }

    /// Returns the socket fd for inclusion in a poll array.
    pub fn pollFd(self: *const SessionClient) posix.fd_t {
        return self.socket_fd;
    }

    /// Read available data from socket. Call after poll indicates POLLIN.
    /// Returns false if connection is dead.
    pub fn recvData(self: *SessionClient) bool {
        const space = self.read_buf[self.read_len..];
        if (space.len == 0) {
            self.read_len = 0;
            return true;
        }
        const n = posix.read(self.socket_fd, space) catch |err| switch (err) {
            error.WouldBlock => return true,
            else => return false,
        };
        if (n == 0) return false;
        self.read_len += n;
        return true;
    }

    /// Read and return the next Output message's payload bytes, or null.
    /// Also handles SessionDied and Error messages inline.
    pub fn readOutput(self: *SessionClient, died_session: *?u32) ?[]const u8 {
        while (self.read_len >= protocol.header_size) {
            const header = protocol.decodeHeader(self.read_buf[0..protocol.header_size]) catch {
                self.consumeBytes(1);
                continue;
            };
            const total = protocol.header_size + header.payload_len;
            if (self.read_len < total) return null;

            const payload = self.read_buf[protocol.header_size..total];

            switch (header.msg_type) {
                .output => {
                    // Copy payload before consuming (it'll be overwritten)
                    const result = payload;
                    // Don't consume yet — caller needs the data
                    // We return a slice into read_buf; caller must use it before next recvData
                    self.consumeBytes(total);
                    return result;
                },
                .session_died => {
                    if (protocol.decodeSessionDied(payload)) |msg| {
                        died_session.* = msg.session_id;
                        if (self.attached_session_id == msg.session_id) {
                            self.attached_session_id = null;
                        }
                    } else |_| {}
                    self.consumeBytes(total);
                    continue;
                },
                .session_list => {
                    self.parseSessionList(payload);
                    self.consumeBytes(total);
                    continue;
                },
                .attached => {
                    // Attached confirmation — continue reading for replay output
                    self.consumeBytes(total);
                    continue;
                },
                else => {
                    self.consumeBytes(total);
                    continue;
                },
            }
        }
        return null;
    }

    fn parseSessionList(self: *SessionClient, payload: []const u8) void {
        var decoded: [max_list_entries]protocol.DecodedListEntry = undefined;
        const count = protocol.decodeSessionList(payload, &decoded) catch return;
        self.pending_list_count = @intCast(@min(count, max_list_entries));
        for (0..self.pending_list_count) |i| {
            var entry = &self.pending_list[i];
            entry.id = decoded[i].id;
            entry.alive = decoded[i].alive;
            const nlen: u8 = @intCast(@min(decoded[i].name.len, 64));
            @memcpy(entry.name[0..nlen], decoded[i].name[0..nlen]);
            entry.name_len = nlen;
        }
        self.pending_list_ready = true;
    }

    fn consumeBytes(self: *SessionClient, n: usize) void {
        const remaining = self.read_len - n;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.read_buf[0..remaining], self.read_buf[n .. n + remaining]);
        }
        self.read_len = remaining;
    }

    fn sendMessage(self: *SessionClient, msg_type: protocol.MessageType, payload: []const u8) !void {
        var hdr: [protocol.header_size]u8 = undefined;
        protocol.encodeHeader(&hdr, msg_type, @intCast(payload.len));
        _ = try posix.write(self.socket_fd, &hdr);
        if (payload.len > 0) {
            _ = try posix.write(self.socket_fd, payload);
        }
    }

    fn waitForResponse(self: *SessionClient, expected: protocol.MessageType, timeout_ms: u32) !u32 {
        _ = expected;
        var elapsed: u32 = 0;
        while (elapsed < timeout_ms) {
            // Blocking read with short poll
            var fds = [1]posix.pollfd{.{ .fd = self.socket_fd, .events = 0x0001, .revents = 0 }};
            _ = posix.poll(&fds, 100) catch return error.PollFailed;
            if (fds[0].revents & 0x0001 != 0) {
                if (!self.recvData()) return error.ConnectionClosed;
                // Check for complete message
                if (self.read_len >= protocol.header_size) {
                    const header = protocol.decodeHeader(self.read_buf[0..protocol.header_size]) catch {
                        self.consumeBytes(1);
                        continue;
                    };
                    const total = protocol.header_size + header.payload_len;
                    if (self.read_len >= total) {
                        const payload = self.read_buf[protocol.header_size..total];
                        if (header.msg_type == .created) {
                            const id = protocol.decodeCreated(payload) catch return error.InvalidResponse;
                            self.consumeBytes(total);
                            return id;
                        }
                        if (header.msg_type == .err) {
                            self.consumeBytes(total);
                            return error.DaemonError;
                        }
                        self.consumeBytes(total);
                    }
                }
            }
            elapsed += 100;
        }
        return error.Timeout;
    }

    pub fn deinit(self: *SessionClient) void {
        if (self.socket_fd >= 0) {
            posix.close(self.socket_fd);
            self.socket_fd = -1;
        }
    }
};

fn getSocketPath(buf: *[256]u8) ?[]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/attyx/sessions.sock", .{home}) catch null;
}

fn setNonBlocking(fd: posix.fd_t) void {
    const F_GETFL: i32 = 3;
    const F_SETFL: i32 = 4;
    const flags = std.posix.fcntl(fd, F_GETFL, 0) catch return;
    _ = std.posix.fcntl(fd, F_SETFL, flags | platform.O_NONBLOCK) catch {};
}
