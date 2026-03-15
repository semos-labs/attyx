/// UI-side client for connecting to the session daemon.
/// Handles connect (with auto-start), message send/recv, and replay.
/// V2: supports pane-multiplexed protocol (one socket per session).
///
/// Cross-platform: POSIX uses Unix sockets, Windows uses named pipes.
const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const posix = if (!is_windows) std.posix else struct {};
const attyx = @import("attyx");
const protocol = @import("daemon/protocol.zig");
const conn = @import("session_connect.zig");

// Windows API imports (no-op on POSIX).
const win32 = if (is_windows) struct {
    const windows = std.os.windows;
    const HANDLE = windows.HANDLE;
    const DWORD = windows.DWORD;
    const BOOL = windows.BOOL;
    extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, n: DWORD, read: ?*DWORD, ovl: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, n: DWORD, written: ?*DWORD, ovl: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn PeekNamedPipe(h: HANDLE, buf: ?[*]u8, sz: DWORD, read: ?*DWORD, avail: ?*DWORD, left: ?*DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
} else struct {};

/// Socket/handle type — fd_t on POSIX, HANDLE on Windows.
const SocketFd = if (is_windows) std.os.windows.HANDLE else std.posix.fd_t;
const invalid_fd: SocketFd = if (is_windows) std.os.windows.INVALID_HANDLE_VALUE else -1;

pub const max_list_entries = 32;

/// Cached session list entry (local copy, not referencing protocol buffer).
pub const ListEntry = struct {
    id: u32 = 0,
    name: [64]u8 = undefined,
    name_len: u8 = 0,
    alive: bool = false,
    pane_count: u8 = 0,

    pub fn getName(self: *const ListEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Tagged union for V2 daemon messages.
pub const DaemonMessage = union(enum) {
    pane_output: struct { pane_id: u32, data: []const u8 },
    pane_created: u32,
    pane_died: struct { pane_id: u32, exit_code: u8, stdout: []const u8 = "" },
    pane_proc_name: struct { pane_id: u32, name: []const u8 },
    replay_end: u32,
    session_attached: struct { session_id: u32, layout: []const u8, pane_ids: [32]u32, pane_count: u8 },
    layout_sync: struct { session_id: u32, layout: []const u8, pane_ids: [32]u32, pane_count: u8 },
    session_list: void,
    session_created: u32,
    err: void,
    hello_ack: []const u8,
};

pub const SessionClient = struct {
    socket_fd: SocketFd = invalid_fd,
    read_buf: [65536]u8 = undefined,
    read_len: usize = 0,
    read_off: usize = 0,
    output_buf: [65536]u8 = undefined,
    layout_buf: [4096]u8 = undefined,
    layout_len: u16 = 0,
    attached_session_id: ?u32 = null,
    allocator: std.mem.Allocator,

    pending_list: [max_list_entries]ListEntry = undefined,
    pending_list_count: u8 = 0,
    pending_list_ready: bool = false,

    legacy_daemon: bool = false,
    daemon_version: [64]u8 = undefined,
    daemon_version_len: u8 = 0,

    // ── Connect ──

    pub fn connect(allocator: std.mem.Allocator) !SessionClient {
        var client = SessionClient{ .allocator = allocator };
        client.socket_fd = try conn.connectToSocket();
        conn.setNonBlocking(client.socket_fd);
        client.checkDaemonVersion();
        return client;
    }

    fn checkDaemonVersion(self: *SessionClient) void {
        var path_buf: [256]u8 = undefined;
        const vpath = getDaemonVersionPath(&path_buf) orelse {
            self.legacy_daemon = true;
            return;
        };
        var ver_buf: [64]u8 = undefined;
        const ver_len = readVersionFile(vpath, &ver_buf);
        if (ver_len == 0) { self.legacy_daemon = true; return; }

        const daemon_ver = ver_buf[0..ver_len];
        const vlen: u8 = @intCast(@min(daemon_ver.len, 64));
        @memcpy(self.daemon_version[0..vlen], daemon_ver[0..vlen]);
        self.daemon_version_len = vlen;

        if (std.mem.eql(u8, daemon_ver, attyx.version)) return;

        self.sendHello();
        self.closeSocket();

        var socket_buf: [256]u8 = undefined;
        const socket_path = conn.getSocketPath(&socket_buf) orelse return;
        for (0..150) |_| {
            sleepMs(100);
            if (is_windows) {
                if (conn.tryConnectWindows(socket_path)) |h| {
                    self.socket_fd = h;
                    return;
                }
            } else {
                if (conn.tryConnect(socket_path)) |fd| {
                    self.socket_fd = fd;
                    conn.setNonBlocking(fd);
                    return;
                }
            }
        }
        self.socket_fd = conn.connectToSocket() catch return;
        conn.setNonBlocking(self.socket_fd);
    }

    fn sendHello(self: *SessionClient) void {
        var payload_buf: [256]u8 = undefined;
        const payload = protocol.encodeHello(&payload_buf, attyx.version) catch return;
        var msg_buf: [protocol.header_size + 256]u8 = undefined;
        const msg = protocol.encodeMessage(&msg_buf, .hello, payload) catch return;
        socketWrite(self.socket_fd, msg) catch return;

        // Wait up to 200ms for hello_ack
        if (!pollForData(self.socket_fd, 200)) return;

        const space = self.read_buf[self.read_len..];
        const n = socketRead(self.socket_fd, space) catch return;
        if (n == 0) return;
        self.read_len += n;

        if (self.availableBytes() >= protocol.header_size) {
            const buf = self.read_buf[self.read_off..self.read_len];
            const header = protocol.decodeHeader(buf[0..protocol.header_size]) catch return;
            const total = protocol.header_size + header.payload_len;
            if (self.availableBytes() >= total and header.msg_type == .hello_ack) {
                self.consumeBytes(total);
            }
        }
    }

    fn getDaemonVersionPath(buf: *[256]u8) ?[]const u8 {
        return conn.statePath(buf, "daemon{s}.version");
    }

    fn readVersionFile(path: []const u8, buf: *[64]u8) usize {
        const file = std.fs.openFileAbsolute(path, .{}) catch return 0;
        defer file.close();
        return file.read(buf) catch 0;
    }

    // ── Session ops ──

    pub fn createSession(self: *SessionClient, name: []const u8, rows: u16, cols: u16, cwd: []const u8, shell: []const u8) !u32 {
        var payload_buf: [4484]u8 = undefined;
        const payload = try protocol.encodeCreate(&payload_buf, name, rows, cols, cwd, shell);
        try self.sendMessage(.create, payload);
        return self.waitForResponse(.created, 5000);
    }

    pub fn attach(self: *SessionClient, session_id: u32, rows: u16, cols: u16) !void {
        var payload_buf: [8]u8 = undefined;
        const payload = try protocol.encodeAttach(&payload_buf, session_id, rows, cols);
        try self.sendMessage(.attach, payload);
        self.attached_session_id = session_id;
    }

    pub fn detach(self: *SessionClient) !void {
        try self.sendMessage(.detach, &.{});
        self.attached_session_id = null;
    }

    // ── Pane ops ──

    pub fn sendCreatePane(self: *SessionClient, rows: u16, cols: u16, cwd: []const u8) !void {
        return self.sendCreatePaneWithCmd(rows, cols, cwd, "");
    }

    pub fn sendCreatePaneWithCmd(self: *SessionClient, rows: u16, cols: u16, cwd: []const u8, cmd: []const u8) !void {
        var payload_buf: [8205]u8 = undefined;
        const payload = try protocol.encodeCreatePaneWithCmdFlags(&payload_buf, rows, cols, cwd, cmd, 0);
        try self.sendMessage(.create_pane, payload);
    }

    pub fn sendCreatePaneWithCmdWait(self: *SessionClient, rows: u16, cols: u16, cwd: []const u8, cmd: []const u8) !void {
        var payload_buf: [8205]u8 = undefined;
        const payload = try protocol.encodeCreatePaneWithCmdFlags(&payload_buf, rows, cols, cwd, cmd, 0x01);
        try self.sendMessage(.create_pane, payload);
    }

    pub fn sendClosePane(self: *SessionClient, pane_id: u32) !void {
        var payload_buf: [4]u8 = undefined;
        const payload = try protocol.encodeClosePane(&payload_buf, pane_id);
        try self.sendMessage(.close_pane, payload);
    }

    pub fn sendFocusPanes(self: *SessionClient, pane_ids: []const u32) !void {
        var payload_buf: [129]u8 = undefined;
        const payload = try protocol.encodeFocusPanes(&payload_buf, pane_ids);
        try self.sendMessage(.focus_panes, payload);
    }

    pub fn sendThemeColors(self: *SessionClient, fg: [3]u8, bg: [3]u8, cursor_set: bool, cursor: [3]u8) !void {
        var payload_buf: [16]u8 = undefined;
        const payload = try protocol.encodeThemeColors(&payload_buf, fg, bg, cursor_set, cursor);
        try self.sendMessage(.set_theme_colors, payload);
    }

    pub fn sendPaneInput(self: *SessionClient, pane_id: u32, bytes: []const u8) !void {
        if (bytes.len <= 508) {
            var payload_buf: [512]u8 = undefined;
            const payload = try protocol.encodePaneInput(&payload_buf, pane_id, bytes);
            try self.sendMessage(.pane_input, payload);
            return;
        }
        const chunk_max: usize = 508;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const end = @min(offset + chunk_max, bytes.len);
            var payload_buf: [512]u8 = undefined;
            const payload = try protocol.encodePaneInput(&payload_buf, pane_id, bytes[offset..end]);
            try self.sendMessage(.pane_input, payload);
            offset = end;
        }
    }

    pub fn sendPaneResize(self: *SessionClient, pane_id: u32, rows: u16, cols: u16) !void {
        var payload_buf: [8]u8 = undefined;
        const payload = try protocol.encodePaneResize(&payload_buf, pane_id, rows, cols);
        try self.sendMessage(.pane_resize, payload);
    }

    pub fn sendSaveLayout(self: *SessionClient, layout_data: []const u8) !void {
        try self.sendMessage(.save_layout, layout_data);
    }

    // ── Session list ──

    pub fn requestList(self: *SessionClient) !void {
        try self.sendMessage(.list, &.{});
    }

    pub fn requestListSync(self: *SessionClient, timeout_ms: u32) !void {
        try self.sendMessage(.list, &.{});
        self.pending_list_ready = false;
        var elapsed: u32 = 0;
        while (elapsed < timeout_ms) {
            while (self.availableBytes() >= protocol.header_size) {
                const buf = self.read_buf[self.read_off..self.read_len];
                const header = protocol.decodeHeader(buf[0..protocol.header_size]) catch {
                    self.consumeBytes(1);
                    continue;
                };
                const total = protocol.header_size + header.payload_len;
                if (self.availableBytes() < total) break;
                const payload = buf[protocol.header_size..total];
                if (header.msg_type == .session_list) {
                    self.parseSessionList(payload);
                    self.consumeBytes(total);
                    return;
                }
                self.consumeBytes(total);
            }
            if (!self.pollAndRecv(100)) return error.ConnectionClosed;
            elapsed += 100;
        }
        return error.Timeout;
    }

    pub fn waitForAttach(self: *SessionClient, timeout_ms: u32) !struct { session_id: u32, pane_ids: [32]u32, pane_count: u8 } {
        var elapsed: u32 = 0;
        while (elapsed < timeout_ms) {
            while (self.availableBytes() >= protocol.header_size) {
                const buf = self.read_buf[self.read_off..self.read_len];
                const header = protocol.decodeHeader(buf[0..protocol.header_size]) catch {
                    self.consumeBytes(1);
                    continue;
                };
                const total = protocol.header_size + header.payload_len;
                if (self.availableBytes() < total) break;
                const payload = buf[protocol.header_size..total];
                if (header.msg_type == .attached) {
                    const v2 = protocol.decodeAttachedV2(payload) catch {
                        self.consumeBytes(total);
                        return error.InvalidResponse;
                    };
                    self.attached_session_id = v2.session_id;
                    const llen: u16 = @intCast(@min(v2.layout.len, self.layout_buf.len));
                    @memcpy(self.layout_buf[0..llen], v2.layout[0..llen]);
                    self.layout_len = llen;
                    self.consumeBytes(total);
                    return .{ .session_id = v2.session_id, .pane_ids = v2.pane_ids, .pane_count = v2.pane_count };
                }
                if (header.msg_type == .err) {
                    self.consumeBytes(total);
                    return error.DaemonError;
                }
                self.consumeBytes(total);
            }
            if (!self.pollAndRecv(100)) return error.ConnectionClosed;
            elapsed += 100;
        }
        return error.Timeout;
    }

    pub fn waitForPaneCreated(self: *SessionClient, timeout_ms: u32) !u32 {
        var elapsed: u32 = 0;
        while (elapsed < timeout_ms) {
            while (self.availableBytes() >= protocol.header_size) {
                const buf = self.read_buf[self.read_off..self.read_len];
                const header = protocol.decodeHeader(buf[0..protocol.header_size]) catch {
                    self.consumeBytes(1);
                    continue;
                };
                const total = protocol.header_size + header.payload_len;
                if (self.availableBytes() < total) break;
                const payload = buf[protocol.header_size..total];
                if (header.msg_type == .pane_created) {
                    const pane_id = protocol.decodePaneCreated(payload) catch return error.InvalidResponse;
                    self.consumeBytes(total);
                    return pane_id;
                }
                if (header.msg_type == .err) {
                    self.consumeBytes(total);
                    return error.DaemonError;
                }
                self.consumeBytes(total);
            }
            if (!self.pollAndRecv(100)) return error.ConnectionClosed;
            elapsed += 100;
        }
        return error.Timeout;
    }

    pub fn killSession(self: *SessionClient, session_id: u32) !void {
        var payload_buf: [4]u8 = undefined;
        const payload = try protocol.encodeKill(&payload_buf, session_id);
        try self.sendMessage(.kill, payload);
    }

    pub fn renameSession(self: *SessionClient, session_id: u32, new_name: []const u8) !void {
        var payload_buf: [70]u8 = undefined;
        const payload = try protocol.encodeRename(&payload_buf, session_id, new_name);
        try self.sendMessage(.rename, payload);
    }

    pub fn pollFd(self: *const SessionClient) SocketFd {
        return self.socket_fd;
    }

    // ── Message reading ──

    pub fn recvData(self: *SessionClient) bool {
        if (self.read_len >= self.read_buf.len - 4096) self.compactReadBuf();
        if (is_windows) {
            // On Windows, named pipes are blocking. Read only what's available.
            var avail: win32.DWORD = 0;
            if (win32.PeekNamedPipe(self.socket_fd, null, 0, null, &avail, null) == 0) return false;
            if (avail == 0) return true;
            const space = self.read_buf[self.read_len..];
            if (space.len == 0) return true;
            const to_read: win32.DWORD = @intCast(@min(avail, space.len));
            var bytes_read: win32.DWORD = 0;
            if (win32.ReadFile(self.socket_fd, space.ptr, to_read, &bytes_read, null) == 0) return false;
            if (bytes_read == 0) return false;
            self.read_len += bytes_read;
            return true;
        } else {
            while (true) {
                const space = self.read_buf[self.read_len..];
                if (space.len == 0) return true;
                const n = posix.read(self.socket_fd, space) catch |err| switch (err) {
                    error.WouldBlock => return true,
                    else => return false,
                };
                if (n == 0) return false;
                self.read_len += n;
            }
        }
    }

    pub fn readMessage(self: *SessionClient) ?DaemonMessage {
        return readMessageImpl(self);
    }

    // ── Cleanup ──

    pub fn deinit(self: *SessionClient) void {
        self.closeSocket();
    }

    // ── Internals ──

    fn closeSocket(self: *SessionClient) void {
        if (is_windows) {
            if (self.socket_fd != std.os.windows.INVALID_HANDLE_VALUE) {
                _ = win32.CloseHandle(self.socket_fd);
                self.socket_fd = std.os.windows.INVALID_HANDLE_VALUE;
            }
        } else {
            if (self.socket_fd >= 0) {
                posix.close(self.socket_fd);
                self.socket_fd = -1;
            }
        }
    }

    /// Poll for data on the socket, then recv. Returns false on disconnect.
    fn pollAndRecv(self: *SessionClient, timeout_ms: u32) bool {
        if (is_windows) {
            // PeekNamedPipe polling loop
            var elapsed: u32 = 0;
            while (elapsed < timeout_ms) {
                var avail: win32.DWORD = 0;
                if (win32.PeekNamedPipe(self.socket_fd, null, 0, null, &avail, null) == 0) return false;
                if (avail > 0) return self.recvData();
                win32.Sleep(10);
                elapsed += 10;
            }
            return true; // timeout, not error
        } else {
            var fds = [1]posix.pollfd{.{ .fd = self.socket_fd, .events = 0x0001, .revents = 0 }};
            _ = posix.poll(&fds, @intCast(timeout_ms)) catch return false;
            if (fds[0].revents & 0x0001 != 0) return self.recvData();
            return true;
        }
    }

    fn sendMessage(self: *SessionClient, msg_type: protocol.MessageType, payload: []const u8) !void {
        var msg_buf: [protocol.header_size + 512]u8 = undefined;
        if (payload.len <= 512) {
            const msg = protocol.encodeMessage(&msg_buf, msg_type, payload) catch
                return error.EncodeFailed;
            try socketWrite(self.socket_fd, msg);
        } else {
            var hdr: [protocol.header_size]u8 = undefined;
            protocol.encodeHeader(&hdr, msg_type, @intCast(payload.len));
            try socketWrite(self.socket_fd, &hdr);
            try socketWrite(self.socket_fd, payload);
        }
    }

    fn waitForResponse(self: *SessionClient, expected: protocol.MessageType, timeout_ms: u32) !u32 {
        _ = expected;
        var elapsed: u32 = 0;
        while (elapsed < timeout_ms) {
            while (self.availableBytes() >= protocol.header_size) {
                const buf = self.read_buf[self.read_off..self.read_len];
                const header = protocol.decodeHeader(buf[0..protocol.header_size]) catch {
                    self.consumeBytes(1);
                    continue;
                };
                const total = protocol.header_size + header.payload_len;
                if (self.availableBytes() < total) break;
                const payload = buf[protocol.header_size..total];
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
            if (!self.pollAndRecv(100)) return error.ConnectionClosed;
            elapsed += 100;
        }
        return error.Timeout;
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
        self.read_off += n;
    }

    fn availableBytes(self: *const SessionClient) usize {
        return self.read_len - self.read_off;
    }

    fn compactReadBuf(self: *SessionClient) void {
        const remaining = self.read_len - self.read_off;
        if (self.read_off == 0) return;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.read_buf[0..remaining], self.read_buf[self.read_off..self.read_len]);
        }
        self.read_len = remaining;
        self.read_off = 0;
    }
};

// ── Cross-platform I/O helpers ──

fn socketRead(fd: SocketFd, buf: []u8) !usize {
    if (is_windows) {
        var bytes_read: win32.DWORD = 0;
        if (win32.ReadFile(fd, buf.ptr, @intCast(buf.len), &bytes_read, null) == 0) return error.ReadFailed;
        return bytes_read;
    } else {
        return posix.read(fd, buf);
    }
}

fn socketWrite(fd: SocketFd, data: []const u8) !void {
    var offset: usize = 0;
    var retries: u32 = 0;
    while (offset < data.len) {
        if (is_windows) {
            var written: win32.DWORD = 0;
            if (win32.WriteFile(fd, data[offset..].ptr, @intCast(data.len - offset), &written, null) == 0) {
                retries += 1;
                if (retries >= 200) return error.WriteFailed;
                win32.Sleep(1);
                continue;
            }
            offset += written;
            retries = 0;
        } else {
            const n = posix.write(fd, data[offset..]) catch |err| {
                if (err == error.WouldBlock) {
                    retries += 1;
                    if (retries >= 200) return error.WouldBlock;
                    posix.nanosleep(0, 1_000_000);
                    continue;
                }
                return err;
            };
            offset += n;
            retries = 0;
        }
    }
}

fn pollForData(fd: SocketFd, timeout_ms: u32) bool {
    if (is_windows) {
        var elapsed: u32 = 0;
        while (elapsed < timeout_ms) {
            var avail: win32.DWORD = 0;
            if (win32.PeekNamedPipe(fd, null, 0, null, &avail, null) == 0) return false;
            if (avail > 0) return true;
            win32.Sleep(10);
            elapsed += 10;
        }
        return false;
    } else {
        var fds = [1]posix.pollfd{.{ .fd = fd, .events = 0x0001, .revents = 0 }};
        _ = posix.poll(&fds, @intCast(timeout_ms)) catch return false;
        return (fds[0].revents & 0x0001) != 0;
    }
}

fn sleepMs(ms: u32) void {
    if (is_windows) {
        win32.Sleep(ms);
    } else {
        posix.nanosleep(0, @as(u64, ms) * 1_000_000);
    }
}

// ── Message dispatch (extracted to stay under line limit) ──

fn readMessageImpl(self: *SessionClient) ?DaemonMessage {
    while (self.availableBytes() >= protocol.header_size) {
        const buf = self.read_buf[self.read_off..self.read_len];
        const header = protocol.decodeHeader(buf[0..protocol.header_size]) catch {
            self.read_off += 1;
            continue;
        };
        const total = protocol.header_size + header.payload_len;
        if (self.availableBytes() < total) return null;
        const payload = buf[protocol.header_size..total];

        switch (header.msg_type) {
            .pane_output => {
                if (payload.len < 4) { self.consumeBytes(total); continue; }
                const pane_id = std.mem.readInt(u32, payload[0..4], .little);
                const data = payload[4..];
                @memcpy(self.output_buf[0..data.len], data);
                self.consumeBytes(total);
                return .{ .pane_output = .{ .pane_id = pane_id, .data = self.output_buf[0..data.len] } };
            },
            .pane_created => {
                const pane_id = protocol.decodePaneCreated(payload) catch { self.consumeBytes(total); continue; };
                self.consumeBytes(total);
                return .{ .pane_created = pane_id };
            },
            .pane_died => {
                const msg = protocol.decodePaneDied(payload) catch { self.consumeBytes(total); continue; };
                const slen = @min(msg.stdout.len, self.output_buf.len);
                if (slen > 0) @memcpy(self.output_buf[0..slen], msg.stdout[0..slen]);
                self.consumeBytes(total);
                return .{ .pane_died = .{ .pane_id = msg.pane_id, .exit_code = msg.exit_code, .stdout = self.output_buf[0..slen] } };
            },
            .pane_proc_name => {
                const msg = protocol.decodePaneProcName(payload) catch { self.consumeBytes(total); continue; };
                @memcpy(self.output_buf[0..msg.name.len], msg.name);
                self.consumeBytes(total);
                return .{ .pane_proc_name = .{ .pane_id = msg.pane_id, .name = self.output_buf[0..msg.name.len] } };
            },
            .replay_end => {
                if (payload.len < 4) { self.consumeBytes(total); continue; }
                const pane_id = std.mem.readInt(u32, payload[0..4], .little);
                self.consumeBytes(total);
                return .{ .replay_end = pane_id };
            },
            .session_list => {
                self.parseSessionList(payload);
                self.consumeBytes(total);
                return .{ .session_list = {} };
            },
            .created => {
                const id = protocol.decodeCreated(payload) catch { self.consumeBytes(total); continue; };
                self.consumeBytes(total);
                return .{ .session_created = id };
            },
            .attached => {
                if (protocol.decodeAttachedV2(payload)) |v2| {
                    const llen: u16 = @intCast(@min(v2.layout.len, self.layout_buf.len));
                    @memcpy(self.layout_buf[0..llen], v2.layout[0..llen]);
                    self.layout_len = llen;
                    self.attached_session_id = v2.session_id;
                    self.consumeBytes(total);
                    return .{ .session_attached = .{ .session_id = v2.session_id, .layout = self.layout_buf[0..llen], .pane_ids = v2.pane_ids, .pane_count = v2.pane_count } };
                } else |_| {}
                self.consumeBytes(total);
                continue;
            },
            .layout_sync => {
                if (protocol.decodeAttachedV2(payload)) |v2| {
                    const llen: u16 = @intCast(@min(v2.layout.len, self.layout_buf.len));
                    @memcpy(self.layout_buf[0..llen], v2.layout[0..llen]);
                    self.layout_len = llen;
                    self.consumeBytes(total);
                    return .{ .layout_sync = .{ .session_id = v2.session_id, .layout = self.layout_buf[0..llen], .pane_ids = v2.pane_ids, .pane_count = v2.pane_count } };
                } else |_| {}
                self.consumeBytes(total);
                continue;
            },
            .hello_ack => {
                if (protocol.decodeHello(payload)) |ver| {
                    const vlen = @min(ver.len, self.output_buf.len);
                    @memcpy(self.output_buf[0..vlen], ver[0..vlen]);
                    self.consumeBytes(total);
                    return .{ .hello_ack = self.output_buf[0..vlen] };
                } else |_| {}
                self.consumeBytes(total);
                continue;
            },
            else => { self.consumeBytes(total); continue; },
        }
    }
    return null;
}
