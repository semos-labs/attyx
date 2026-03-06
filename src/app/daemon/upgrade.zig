const std = @import("std");
const posix = std.posix;
const DaemonSession = @import("session.zig").DaemonSession;
const DaemonPane = @import("pane.zig").DaemonPane;
const DaemonClient = @import("client.zig").DaemonClient;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;
const session_connect = @import("../session_connect.zig");

const magic = "ATUP";
const format_version: u8 = 1;
const max_sessions: usize = 32;
const max_panes_per_session = @import("session.zig").max_panes_per_session;

extern "c" fn execvp(file: [*:0]const u8, argv: [*]const ?[*:0]const u8) c_int;

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
    if (ver != format_version) return error.UnsupportedVersion;

    next_session_id.* = try r.readU32();
    next_pane_id.* = try r.readU32();

    const session_count = try r.readByte();
    var restored: u8 = 0;

    for (0..session_count) |_| {
        const s = deserializeSession(&r, allocator) catch break;
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

fn deserializeSession(r: *SliceReader, allocator: std.mem.Allocator) !DaemonSession {
    var s = DaemonSession{
        .id = try r.readU32(),
        .rows = 24,
        .cols = 80,
    };
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
        const pane = try deserializePane(r, allocator);
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

fn deserializePane(r: *SliceReader, allocator: std.mem.Allocator) !DaemonPane {
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

    const ring_len = try r.readU32();
    const ring_data = try r.readSlice(ring_len);

    return DaemonPane.fromRestored(
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
}

/// Get the upgrade state file path.
fn getUpgradePath(buf: *[256]u8) ?[]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    const suffix = if (comptime @import("builtin").mode == .Debug) "-dev" else "";
    return std.fmt.bufPrint(buf, "{s}/.config/attyx/upgrade{s}.bin", .{ home, suffix }) catch null;
}

/// Perform the hot upgrade: serialize state, close sockets, exec self.
/// On exec failure, the state file is cleaned up and the function returns.
pub fn performUpgrade(
    sessions: *[max_sessions]?DaemonSession,
    clients: *[16]?DaemonClient,
    listen_fd: posix.fd_t,
    socket_path: []const u8,
    next_session_id: u32,
    next_pane_id: u32,
    allocator: std.mem.Allocator,
) void {
    const stderr = std.fs.File.stderr();

    var path_buf: [256]u8 = undefined;
    const upgrade_path = getUpgradePath(&path_buf) orelse {
        stderr.writeAll("upgrade: cannot determine state file path\n") catch {};
        return;
    };

    // Serialize state into memory buffer
    var list: std.ArrayList(u8) = .{};
    defer list.deinit(allocator);

    serialize(list.writer(allocator), sessions, next_session_id, next_pane_id) catch {
        stderr.writeAll("upgrade: serialization failed\n") catch {};
        return;
    };

    // Write to temp file, then rename atomically
    var tmp_buf: [260]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{upgrade_path}) catch {
        stderr.writeAll("upgrade: path too long\n") catch {};
        return;
    };

    const file = std.fs.createFileAbsolute(tmp_path, .{}) catch {
        stderr.writeAll("upgrade: cannot create state file\n") catch {};
        return;
    };
    file.writeAll(list.items) catch {
        file.close();
        std.fs.deleteFileAbsolute(tmp_path) catch {};
        stderr.writeAll("upgrade: write failed\n") catch {};
        return;
    };
    file.close();

    std.fs.renameAbsolute(tmp_path, upgrade_path) catch {
        std.fs.deleteFileAbsolute(tmp_path) catch {};
        stderr.writeAll("upgrade: rename failed\n") catch {};
        return;
    };

    stderr.writeAll("upgrade: state saved, exec'ing new binary...\n") catch {};

    // Close all client sockets
    for (clients) |*slot| {
        if (slot.*) |*cl| {
            posix.close(cl.socket_fd);
            slot.* = null;
        }
    }

    // Close listener and unlink socket
    posix.close(listen_fd);
    std.fs.deleteFileAbsolute(socket_path) catch {};

    // Exec self with --restore flag
    var exe_buf: [1024]u8 = undefined;
    const exe = session_connect.getExePath(&exe_buf) orelse "/usr/local/bin/attyx";
    var exe_z: [1024]u8 = undefined;
    const exe_z_ptr: [*:0]const u8 = std.fmt.bufPrintZ(&exe_z, "{s}", .{exe}) catch {
        stderr.writeAll("upgrade: exe path too long\n") catch {};
        cleanupAndReturn(upgrade_path);
        return;
    };

    var restore_z: [260]u8 = undefined;
    const restore_arg: [*:0]const u8 = std.fmt.bufPrintZ(&restore_z, "{s}", .{upgrade_path}) catch {
        cleanupAndReturn(upgrade_path);
        return;
    };

    const daemon_str: [*:0]const u8 = "daemon";
    const restore_flag: [*:0]const u8 = "--restore";
    const argv = [_]?[*:0]const u8{ exe_z_ptr, daemon_str, restore_flag, restore_arg, null };
    _ = execvp(exe_z_ptr, &argv);

    // exec failed — rollback
    stderr.writeAll("upgrade: exec failed, rolling back\n") catch {};
    cleanupAndReturn(upgrade_path);
}

fn cleanupAndReturn(upgrade_path: []const u8) void {
    std.fs.deleteFileAbsolute(upgrade_path) catch {};
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

    // Clean up ring buffers (don't deinit panes — fake fd/pid)
    sessions[0].?.panes[0].?.replay.deinit();
    out_sessions[0].?.panes[0].?.replay.deinit();
}
