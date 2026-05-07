const std = @import("std");
const posix = std.posix;
const DaemonSession = @import("session.zig").DaemonSession;
const DaemonPane = @import("pane.zig").DaemonPane;
const DaemonClient = @import("client.zig").DaemonClient;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;
const session_connect = @import("../session_connect.zig");
const spawn = @import("../spawn.zig");
const protocol = @import("protocol.zig");

const magic = "ATUP";
const format_version: u8 = 3;
const max_sessions: usize = 32;
const max_panes_per_session = @import("session.zig").max_panes_per_session;

extern "c" fn kill(pid: std.c.pid_t, sig: c_int) c_int;

// ── Binary format helpers (write to ArrayList, read from slice) ──

const ListWriter = std.ArrayList(u8).Writer;

fn writeBytes(w: ListWriter, data: []const u8) !void {
    try w.writeAll(data);
}

fn writeByte(w: ListWriter, b: u8) !void {
    try w.writeByte(b);
}

fn writeU16(w: ListWriter, val: u16) !void {
    try w.writeInt(u16, val, .little);
}

fn writeU32(w: ListWriter, val: u32) !void {
    try w.writeInt(u32, val, .little);
}

fn writeI32(w: ListWriter, val: i32) !void {
    try w.writeInt(i32, val, .little);
}

const SliceReader = struct {
    data: []const u8,
    pos: usize = 0,

    fn readByte(self: *SliceReader) !u8 {
        if (self.pos >= self.data.len) return error.EndOfStream;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    fn readU16(self: *SliceReader) !u16 {
        if (self.pos + 2 > self.data.len) return error.EndOfStream;
        const val = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return val;
    }

    fn readU32(self: *SliceReader) !u32 {
        if (self.pos + 4 > self.data.len) return error.EndOfStream;
        const val = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return val;
    }

    fn readI32(self: *SliceReader) !i32 {
        if (self.pos + 4 > self.data.len) return error.EndOfStream;
        const val = std.mem.readInt(i32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return val;
    }

    fn readSlice(self: *SliceReader, len: usize) ![]const u8 {
        if (self.pos + len > self.data.len) return error.EndOfStream;
        const slice = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return slice;
    }

    fn readInto(self: *SliceReader, dest: []u8) !void {
        if (self.pos + dest.len > self.data.len) return error.EndOfStream;
        @memcpy(dest, self.data[self.pos .. self.pos + dest.len]);
        self.pos += dest.len;
    }
};

/// Serialize all session state. Pass `list.writer(allocator)`.
pub fn serialize(
    w: ListWriter,
    sessions: *[max_sessions]?DaemonSession,
    next_session_id: u32,
    next_pane_id: u32,
) !void {
    try writeBytes(w, magic);
    try writeByte(w, format_version);
    try writeU32(w, next_session_id);
    try writeU32(w, next_pane_id);

    var session_count: u8 = 0;
    for (sessions) |*slot| {
        if (slot.* != null) session_count += 1;
    }
    try writeByte(w, session_count);

    for (sessions) |*slot| {
        if (slot.*) |*s| {
            try serializeSession(w, s);
        }
    }
}

fn serializeSession(w: ListWriter, s: *DaemonSession) !void {
    try writeU32(w, s.id);
    try writeByte(w, s.name_len);
    try writeBytes(w, s.name[0..s.name_len]);
    try writeByte(w, if (s.alive) 1 else 0);
    try writeU16(w, s.rows);
    try writeU16(w, s.cols);
    try writeU16(w, s.cwd_len);
    try writeBytes(w, s.cwd[0..s.cwd_len]);
    try writeU16(w, s.shell_len);
    try writeBytes(w, s.shell[0..s.shell_len]);
    try writeU16(w, s.layout_len);
    try writeBytes(w, s.layout_data[0..s.layout_len]);

    var pane_count: u8 = 0;
    for (s.panes) |p| {
        if (p != null) pane_count += 1;
    }
    try writeByte(w, pane_count);

    for (&s.panes) |*pslot| {
        if (pslot.*) |*p| {
            try serializePane(w, p);
        }
    }
}

fn serializePane(w: ListWriter, p: *DaemonPane) !void {
    try writeU32(w, p.id);
    try writeI32(w, p.pty.master);
    try writeI32(w, p.pty.pid);
    try writeU16(w, p.rows);
    try writeU16(w, p.cols);
    try writeByte(w, if (p.alive) 1 else 0);
    try writeByte(w, p.exit_code orelse 0xFF);
    try writeByte(w, if (p.cursor_visible) 1 else 0);
    try writeByte(w, if (p.alt_screen) 1 else 0);
    try writeByte(w, p.proc_name_len);
    try writeBytes(w, p.proc_name[0..p.proc_name_len]);

    // OSC 7 CWD and OSC 7337 shell PATH
    try writeU16(w, p.osc7_cwd_len);
    try writeBytes(w, p.osc7_cwd[0..p.osc7_cwd_len]);
    try writeU16(w, p.osc7337_path_len);
    try writeBytes(w, p.osc7337_path[0..p.osc7337_path_len]);

    // Foreground process CWD
    try writeU16(w, p.fg_cwd_len);
    try writeBytes(w, p.fg_cwd[0..p.fg_cwd_len]);

    const slices = p.replay.readSlices();
    const ring_len: u32 = @intCast(slices.totalLen());
    try writeU32(w, ring_len);
    if (slices.first.len > 0) try writeBytes(w, slices.first);
    if (slices.second.len > 0) try writeBytes(w, slices.second);
}

/// Deserialize session state from a byte slice. Returns count of sessions restored.
pub fn deserialize(
    data: []const u8,
    sessions: *[max_sessions]?DaemonSession,
    next_session_id: *u32,
    next_pane_id: *u32,
    allocator: std.mem.Allocator,
) !u8 {
    var r = SliceReader{ .data = data };

    var magic_buf: [4]u8 = undefined;
    try r.readInto(&magic_buf);
    if (!std.mem.eql(u8, &magic_buf, magic)) return error.InvalidMagic;

    const ver = try r.readByte();
    if (ver != 1 and ver != 2 and ver != format_version) return error.UnsupportedVersion;

    next_session_id.* = try r.readU32();
    next_pane_id.* = try r.readU32();

    const session_count = try r.readByte();
    var restored: u8 = 0;

    for (0..session_count) |_| {
        const s = deserializeSession(&r, ver, allocator) catch continue;
        for (sessions) |*slot| {
            if (slot.* == null) {
                slot.* = s;
                restored += 1;
                break;
            }
        }
    }

    return restored;
}

fn deserializeSession(r: *SliceReader, ver: u8, allocator: std.mem.Allocator) !DaemonSession {
    var s = DaemonSession{
        .id = try r.readU32(),
        .rows = 24,
        .cols = 80,
    };
    // On error, free any ring buffers already allocated for restored panes.
    errdefer {
        for (&s.panes) |*pslot| {
            if (pslot.*) |*p| {
                p.freeTransferableState();
                pslot.* = null;
            }
        }
    }
    s.name_len = try r.readByte();
    try r.readInto(s.name[0..s.name_len]);
    s.alive = (try r.readByte()) != 0;
    s.rows = try r.readU16();
    s.cols = try r.readU16();
    s.cwd_len = try r.readU16();
    try r.readInto(s.cwd[0..s.cwd_len]);
    s.shell_len = try r.readU16();
    try r.readInto(s.shell[0..s.shell_len]);
    s.layout_len = try r.readU16();
    try r.readInto(s.layout_data[0..s.layout_len]);

    const pane_count = try r.readByte();
    for (0..pane_count) |_| {
        const pane = try deserializePane(r, ver, allocator);
        for (&s.panes) |*pslot| {
            if (pslot.* == null) {
                pslot.* = pane;
                s.pane_count += 1;
                break;
            }
        }
    }

    return s;
}

fn deserializePane(r: *SliceReader, ver: u8, allocator: std.mem.Allocator) !DaemonPane {
    const id = try r.readU32();
    const pty_fd = try r.readI32();
    const pty_pid = try r.readI32();
    const rows = try r.readU16();
    const cols = try r.readU16();
    const alive = (try r.readByte()) != 0;
    const exit_code_raw = try r.readByte();
    const exit_code: ?u8 = if (exit_code_raw == 0xFF) null else exit_code_raw;
    const cursor_visible = (try r.readByte()) != 0;
    const alt_screen = (try r.readByte()) != 0;
    const proc_name_len = try r.readByte();
    const proc_name_slice = try r.readSlice(proc_name_len);

    // OSC 7 CWD and OSC 7337 shell PATH (v2+)
    var osc7_cwd_slice: []const u8 = &.{};
    var osc7337_path_slice: []const u8 = &.{};
    if (ver >= 2) {
        const osc7_cwd_len = try r.readU16();
        osc7_cwd_slice = try r.readSlice(osc7_cwd_len);
        const osc7337_path_len = try r.readU16();
        osc7337_path_slice = try r.readSlice(osc7337_path_len);
    }

    var fg_cwd_slice: []const u8 = &.{};
    if (ver >= 3) {
        const fg_cwd_len = try r.readU16();
        fg_cwd_slice = try r.readSlice(fg_cwd_len);
    }

    const ring_len = try r.readU32();
    const ring_data = try r.readSlice(ring_len);

    var pane = try DaemonPane.fromRestored(
        allocator,
        id,
        pty_fd,
        pty_pid,
        rows,
        cols,
        alive,
        exit_code,
        cursor_visible,
        alt_screen,
        proc_name_slice,
        ring_data,
        RingBuffer.default_capacity,
    );

    // Restore tracked OSC state
    const cwd_len: u16 = @intCast(@min(osc7_cwd_slice.len, pane.osc7_cwd.len));
    @memcpy(pane.osc7_cwd[0..cwd_len], osc7_cwd_slice[0..cwd_len]);
    pane.osc7_cwd_len = cwd_len;
    const path_len: u16 = @intCast(@min(osc7337_path_slice.len, pane.osc7337_path.len));
    @memcpy(pane.osc7337_path[0..path_len], osc7337_path_slice[0..path_len]);
    pane.osc7337_path_len = path_len;

    const fg_len: u16 = @intCast(@min(fg_cwd_slice.len, pane.fg_cwd.len));
    @memcpy(pane.fg_cwd[0..fg_len], fg_cwd_slice[0..fg_len]);
    pane.fg_cwd_len = fg_len;

    return pane;
}

/// Get the upgrade state file path.
fn getUpgradePath(buf: *[256]u8) ?[]const u8 {
    return session_connect.statePath(buf, "upgrade{s}.bin");
}

/// Result of an upgrade attempt.
pub const UpgradeResult = enum {
    /// New daemon is running. Caller should exit immediately.
    success,
    /// Upgrade failed. Socket has been rebound. Caller continues.
    failed,
    /// Upgrade failed and socket could not be rebound. Caller should exit.
    fatal,
};

/// Perform the hot upgrade: serialize state, spawn new daemon, verify it started.
/// Uses posix_spawn instead of exec — allows recovery if the new daemon fails.
/// On failure, the socket is rebound so the old daemon can continue serving.
pub fn performUpgrade(
    sessions: *[max_sessions]?DaemonSession,
    clients: *[16]?DaemonClient,
    listen_fd: *posix.fd_t,
    socket_path: []const u8,
    next_session_id: u32,
    next_pane_id: u32,
    allocator: std.mem.Allocator,
) UpgradeResult {
    const stderr = std.fs.File.stderr();

    var path_buf: [256]u8 = undefined;
    const upgrade_path = getUpgradePath(&path_buf) orelse {
        stderr.writeAll("upgrade: cannot determine state file path\n") catch {};
        return .failed;
    };

    // Serialize state into memory buffer
    var list: std.ArrayList(u8) = .{};
    defer list.deinit(allocator);

    serialize(list.writer(allocator), sessions, next_session_id, next_pane_id) catch {
        stderr.writeAll("upgrade: serialization failed\n") catch {};
        return .failed;
    };

    // Write to temp file, then rename atomically
    var tmp_buf: [260]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{upgrade_path}) catch {
        stderr.writeAll("upgrade: path too long\n") catch {};
        return .failed;
    };

    const file = std.fs.createFileAbsolute(tmp_path, .{}) catch {
        stderr.writeAll("upgrade: cannot create state file\n") catch {};
        return .failed;
    };
    file.writeAll(list.items) catch {
        file.close();
        std.fs.deleteFileAbsolute(tmp_path) catch {};
        stderr.writeAll("upgrade: write failed\n") catch {};
        return .failed;
    };
    file.close();

    std.fs.renameAbsolute(tmp_path, upgrade_path) catch {
        std.fs.deleteFileAbsolute(tmp_path) catch {};
        stderr.writeAll("upgrade: rename failed\n") catch {};
        return .failed;
    };

    // Build exe path and args before closing sockets
    var exe_buf: [1024]u8 = undefined;
    const exe = session_connect.getExePath(&exe_buf) orelse "/usr/local/bin/attyx";
    var exe_z: [1024]u8 = undefined;
    const exe_z_ptr: [*:0]const u8 = std.fmt.bufPrintZ(&exe_z, "{s}", .{exe}) catch {
        stderr.writeAll("upgrade: exe path too long\n") catch {};
        cleanupAndReturn(upgrade_path);
        return .failed;
    };

    var restore_z: [260]u8 = undefined;
    const restore_arg: [*:0]const u8 = std.fmt.bufPrintZ(&restore_z, "{s}", .{upgrade_path}) catch {
        cleanupAndReturn(upgrade_path);
        return .failed;
    };

    // Count sessions — we'll verify the new daemon preserved all of them.
    var expected_sessions: u16 = 0;
    for (sessions) |s| {
        if (s != null) expected_sessions += 1;
    }

    stderr.writeAll("upgrade: state saved, spawning new daemon...\n") catch {};

    // Close all client sockets
    for (clients) |*slot| {
        if (slot.*) |*cl| {
            posix.close(cl.socket_fd);
            slot.* = null;
        }
    }

    // Close listener and unlink socket so new daemon can bind
    posix.close(listen_fd.*);
    listen_fd.* = -1;
    std.fs.deleteFileAbsolute(socket_path) catch {};

    // Spawn new daemon process instead of exec — allows recovery on failure.
    // PTY master fds are inherited by the child (not close-on-exec).
    const daemon_str: [*:0]const u8 = "daemon";
    const restore_flag: [*:0]const u8 = "--restore";
    const argv: [4:null]?[*:0]const u8 = .{ exe_z_ptr, daemon_str, restore_flag, restore_arg };
    const spawn_result = spawn.spawnp(exe_z_ptr, &argv, true);

    if (!spawn_result.ok) {
        stderr.writeAll("upgrade: spawn failed, recovering...\n") catch {};
        cleanupAndReturn(upgrade_path);
        if (!rebindSocket(listen_fd, socket_path, stderr)) return .fatal;
        return .failed;
    }

    // Wait for new daemon to start AND verify sessions are intact.
    // Phase 1: probe until socket is reachable.
    // Phase 2: verify session count matches (new daemon needs time to restore).
    var verified = false;
    var probed = false;

    for (0..80) |_| { // up to 8s total
        posix.nanosleep(0, 100_000_000); // 100ms
        if (!probed) {
            if (!probeNewDaemon(socket_path)) continue;
            probed = true;
            if (expected_sessions == 0) { verified = true; break; }
            continue; // give restore a moment before verifying
        }
        if (verifySessionCount(socket_path, expected_sessions)) {
            verified = true;
            break;
        }
    }

    if (verified) {
        stderr.writeAll("upgrade: new daemon verified, sessions intact\n") catch {};
        cleanupAndReturn(upgrade_path);
        return .success;
    }

    // Verification failed — kill new daemon, recover with old state
    if (probed) {
        stderr.writeAll("upgrade: session verification failed, rolling back\n") catch {};
    } else {
        stderr.writeAll("upgrade: new daemon failed to start, recovering...\n") catch {};
    }
    _ = kill(spawn_result.pid, posix.SIG.KILL);
    spawn.reapAsync(spawn_result.pid);
    cleanupAndReturn(upgrade_path);
    std.fs.deleteFileAbsolute(socket_path) catch {};
    if (!rebindSocket(listen_fd, socket_path, stderr)) return .fatal;
    return .failed;
}

/// Connect to new daemon, send a list request, verify session count matches.
/// Reads in a loop to handle partial reads on Unix stream sockets.
fn verifySessionCount(socket_path: []const u8, expected: u16) bool {
    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return false;
    defer posix.close(fd);
    const addr = std.net.Address.initUnix(socket_path) catch return false;
    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch return false;

    // Send list request (header only, no payload)
    var hdr: [protocol.header_size]u8 = undefined;
    protocol.encodeHeader(&hdr, .list, 0);
    _ = posix.write(fd, &hdr) catch return false;

    // Read response in a loop — stream sockets may deliver partial data.
    const timeout_ms: i64 = 2000;
    const start_ms = std.time.milliTimestamp();
    var resp: [4096]u8 = undefined;
    var received: usize = 0;

    while (true) {
        // Once we have the header, check if we have enough to verify.
        if (received >= protocol.header_size) {
            const header = protocol.decodeHeader(resp[0..protocol.header_size]) catch return false;
            if (header.msg_type != .session_list) return false;
            if (header.payload_len < 2) return false;
            // We only need the first 2 bytes of payload (session count).
            if (received >= protocol.header_size + 2) {
                const count = std.mem.readInt(u16, resp[protocol.header_size..][0..2], .little);
                return count >= expected;
            }
        }

        // Poll for more data with remaining timeout.
        const elapsed_ms = std.time.milliTimestamp() - start_ms;
        if (elapsed_ms >= timeout_ms) return false;
        const remaining: c_int = @intCast(timeout_ms - elapsed_ms);
        var fds_arr = [1]posix.pollfd{.{ .fd = fd, .events = 0x0001, .revents = 0 }};
        const poll_res = posix.poll(&fds_arr, remaining) catch return false;
        if (poll_res == 0) return false;
        if (fds_arr[0].revents & 0x0001 == 0) return false;

        if (received >= resp.len) return false;
        const n = posix.read(fd, resp[received..]) catch return false;
        if (n == 0) return false; // EOF
        received += n;
    }
}

fn probeNewDaemon(path: []const u8) bool {
    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return false;
    defer posix.close(fd);
    const addr = std.net.Address.initUnix(path) catch return false;
    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch return false;
    return true;
}

fn rebindSocket(listen_fd: *posix.fd_t, socket_path: []const u8, stderr: std.fs.File) bool {
    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch {
        stderr.writeAll("upgrade: socket() failed during recovery\n") catch {};
        return false;
    };
    var addr = std.net.Address.initUnix(socket_path) catch {
        posix.close(fd);
        return false;
    };
    posix.bind(fd, &addr.any, addr.getOsSockLen()) catch {
        posix.close(fd);
        stderr.writeAll("upgrade: bind failed during recovery\n") catch {};
        return false;
    };
    posix.listen(fd, 5) catch {
        posix.close(fd);
        return false;
    };
    setNonBlocking(fd);
    listen_fd.* = fd;
    stderr.writeAll("upgrade: recovered, continuing with old version\n") catch {};
    return true;
}

fn setNonBlocking(fd: posix.fd_t) void {
    const F_GETFL: i32 = 3;
    const F_SETFL: i32 = 4;
    const platform = @import("../../platform/platform.zig");
    const flags = std.posix.fcntl(fd, F_GETFL, 0) catch return;
    _ = std.posix.fcntl(fd, F_SETFL, flags | platform.O_NONBLOCK) catch {};
}

fn cleanupAndReturn(upgrade_path: []const u8) void {
    std.fs.deleteFileAbsolute(upgrade_path) catch {};
}

/// Recover dead sessions from an orphaned upgrade.bin (crash recovery).
/// If a previous upgrade spawned a new daemon that crashed before cleaning up,
/// the upgrade.bin file survives with session metadata (names, layouts, CWD).
/// We restore these as dead sessions — when a client attaches, reviveSession
/// spawns fresh shells preserving the tab/split layout.
///
/// Panes are stripped (their PTY fds are stale), but session structure is kept.
/// Returns the number of sessions recovered.
pub fn tryRecoverStale(
    sessions: *[max_sessions]?DaemonSession,
    next_session_id: *u32,
    next_pane_id: *u32,
    allocator: std.mem.Allocator,
) u8 {
    var path_buf: [256]u8 = undefined;
    const upgrade_path = getUpgradePath(&path_buf) orelse return 0;

    const data = std.fs.cwd().readFileAlloc(allocator, upgrade_path, 128 * 1024 * 1024) catch return 0;
    defer allocator.free(data);

    const restored = deserialize(data, sessions, next_session_id, next_pane_id, allocator) catch {
        std.fs.deleteFileAbsolute(upgrade_path) catch {};
        return 0;
    };

    if (restored == 0) {
        std.fs.deleteFileAbsolute(upgrade_path) catch {};
        return 0;
    }

    // Strip panes — their PTY fds are from a dead process. Closing them
    // via deinit is dangerous (posix.close may assert on -1, and waitpid
    // on a stale pid could reap unrelated children). Instead, free ring
    // buffers directly and null out pane slots.
    for (sessions) |*slot| {
        if (slot.*) |*s| {
            for (&s.panes) |*pslot| {
                if (pslot.*) |*p| {
                    p.freeTransferableState();
                    pslot.* = null;
                }
            }
            s.pane_count = 0;
            s.alive = false;
        }
    }

    std.fs.deleteFileAbsolute(upgrade_path) catch {};
    return restored;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "serialize/deserialize round-trip" {
    const allocator = std.testing.allocator;

    var sessions: [max_sessions]?DaemonSession = .{null} ** max_sessions;
    var s = DaemonSession{
        .id = 1,
        .rows = 24,
        .cols = 80,
    };
    s.name_len = 4;
    @memcpy(s.name[0..4], "test");
    s.cwd_len = 4;
    @memcpy(s.cwd[0..4], "/tmp");
    s.alive = true;

    var ring = try RingBuffer.init(allocator, 64);
    ring.write("hello world");

    s.panes[0] = DaemonPane{
        .id = 1,
        .pty = @import("../pty.zig").Pty.fromExisting(99, 12345),
        .replay = ring,
        .rows = 24,
        .cols = 80,
        .alive = true,
        .cursor_visible = true,
        .alt_screen = false,
    };
    s.pane_count = 1;
    sessions[0] = s;

    // Serialize
    var list: std.ArrayList(u8) = .{};
    defer list.deinit(allocator);
    try serialize(list.writer(allocator), &sessions, 5, 10);

    // Deserialize
    var out_sessions: [max_sessions]?DaemonSession = .{null} ** max_sessions;
    var next_sid: u32 = 0;
    var next_pid: u32 = 0;
    const count = try deserialize(list.items, &out_sessions, &next_sid, &next_pid, allocator);

    try std.testing.expectEqual(@as(u8, 1), count);
    try std.testing.expectEqual(@as(u32, 5), next_sid);
    try std.testing.expectEqual(@as(u32, 10), next_pid);

    const rs = out_sessions[0].?;
    try std.testing.expectEqual(@as(u32, 1), rs.id);
    try std.testing.expectEqualStrings("test", rs.name[0..rs.name_len]);
    try std.testing.expectEqualStrings("/tmp", rs.cwd[0..rs.cwd_len]);
    try std.testing.expect(rs.alive);

    const rp = rs.panes[0].?;
    try std.testing.expectEqual(@as(u32, 1), rp.id);
    try std.testing.expectEqual(@as(i32, 99), rp.pty.master);
    try std.testing.expectEqual(@as(i32, 12345), rp.pty.pid);
    try std.testing.expect(rp.alive);
    try std.testing.expect(rp.cursor_visible);
    try std.testing.expect(!rp.alt_screen);

    const slices = rp.replay.readSlices();
    try std.testing.expectEqualStrings("hello world", slices.first);

    // Clean up ring buffers + engines (don't deinit panes — fake fd/pid)
    sessions[0].?.panes[0].?.freeTransferableState();
    out_sessions[0].?.panes[0].?.freeTransferableState();
}

test "stale recovery strips panes and marks sessions dead" {
    const allocator = std.testing.allocator;

    // Build a session with 2 panes
    var sessions: [max_sessions]?DaemonSession = .{null} ** max_sessions;
    var s = DaemonSession{ .id = 1, .rows = 24, .cols = 80 };
    s.name_len = 6;
    @memcpy(s.name[0..6], "stale1");
    s.cwd_len = 5;
    @memcpy(s.cwd[0..5], "/home");
    s.alive = true;

    var ring1 = try RingBuffer.init(allocator, 64);
    ring1.write("pane1 output");
    s.panes[0] = DaemonPane{
        .id = 10,
        .pty = @import("../pty.zig").Pty.fromExisting(50, 999),
        .replay = ring1,
        .rows = 24,
        .cols = 80,
        .alive = true,
    };

    var ring2 = try RingBuffer.init(allocator, 64);
    ring2.write("pane2 output");
    s.panes[1] = DaemonPane{
        .id = 11,
        .pty = @import("../pty.zig").Pty.fromExisting(51, 1000),
        .replay = ring2,
        .rows = 24,
        .cols = 80,
        .alive = true,
    };
    s.pane_count = 2;
    sessions[0] = s;

    // Serialize to bytes (simulating upgrade.bin content)
    var list: std.ArrayList(u8) = .{};
    defer list.deinit(allocator);
    try serialize(list.writer(allocator), &sessions, 5, 20);

    // Deserialize into fresh session array, then strip panes (stale recovery logic)
    var recovered: [max_sessions]?DaemonSession = .{null} ** max_sessions;
    var next_sid: u32 = 0;
    var next_pid: u32 = 0;
    const count = try deserialize(list.items, &recovered, &next_sid, &next_pid, allocator);
    try std.testing.expectEqual(@as(u8, 1), count);

    // Simulate the stale recovery pane-stripping logic
    for (&recovered) |*slot| {
        if (slot.*) |*rs| {
            for (&rs.panes) |*pslot| {
                if (pslot.*) |*p| {
                    p.freeTransferableState();
                    pslot.* = null;
                }
            }
            rs.pane_count = 0;
            rs.alive = false;
        }
    }

    // Session metadata preserved
    const rs = recovered[0].?;
    try std.testing.expectEqual(@as(u32, 1), rs.id);
    try std.testing.expectEqualStrings("stale1", rs.name[0..rs.name_len]);
    try std.testing.expectEqualStrings("/home", rs.cwd[0..rs.cwd_len]);
    try std.testing.expectEqual(@as(u32, 5), next_sid);
    try std.testing.expectEqual(@as(u32, 20), next_pid);

    // Panes stripped, session dead
    try std.testing.expect(!rs.alive);
    try std.testing.expectEqual(@as(u8, 0), rs.pane_count);
    for (rs.panes) |p| try std.testing.expect(p == null);

    // Clean up original ring buffers
    sessions[0].?.panes[0].?.replay.deinit();
    sessions[0].?.panes[1].?.replay.deinit();
}

test "verifySessionCount parses session_list payload" {
    // Build a session_list response: header + payload with count=3
    var payload_buf: [256]u8 = undefined;
    const entries = [_]protocol.SessionEntry{
        .{ .id = 1, .name = "s1", .alive = true },
        .{ .id = 2, .name = "s2", .alive = true },
        .{ .id = 3, .name = "s3", .alive = false },
    };
    const payload = protocol.encodeSessionList(&payload_buf, &entries) catch unreachable;

    var resp: [512]u8 = undefined;
    protocol.encodeHeader(resp[0..protocol.header_size], .session_list, @intCast(payload.len));
    @memcpy(resp[protocol.header_size .. protocol.header_size + payload.len], payload);
    const total = protocol.header_size + payload.len;

    // Verify the count parsing logic directly: first 2 bytes of payload = u16 LE count
    const count = std.mem.readInt(u16, resp[protocol.header_size..][0..2], .little);
    try std.testing.expectEqual(@as(u16, 3), count);

    // Verify header decoding
    const header = protocol.decodeHeader(resp[0..protocol.header_size]) catch unreachable;
    try std.testing.expectEqual(protocol.MessageType.session_list, header.msg_type);
    try std.testing.expect(total >= protocol.header_size + 2);
}
