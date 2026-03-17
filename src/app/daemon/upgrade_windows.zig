/// Windows hot-upgrade: serialize state, spawn new daemon, exit cleanly.
///
/// With the host process model, ConPTY ownership lives in per-pane host
/// processes (`attyx.exe --host <pane_id>`). The daemon only holds pipe
/// connections to hosts. On upgrade:
///   1. Serialize session state + pane IDs to upgrade.bin
///   2. Spawn new daemon (no handle inheritance needed)
///   3. Old daemon exits cleanly
///   4. New daemon reconnects to existing host pipes
///   5. No HPCON keeper — hosts survive independently
const std = @import("std");
const attyx = @import("attyx");
const DaemonSession = @import("session.zig").DaemonSession;
const DaemonPane = @import("pane.zig").DaemonPane;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;
const session_connect = @import("../session_connect.zig");
const protocol = @import("protocol.zig");
const Pty = @import("../pty.zig").Pty;
const HostConnection = @import("host_pipe.zig").HostConnection;
const host_pipe = @import("host_pipe.zig");

const windows = std.os.windows;
const HANDLE = windows.HANDLE;
const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
const LPCWSTR = [*:0]const u16;

extern "kernel32" fn CreateProcessW(
    app: ?LPCWSTR,
    cmd: ?[*:0]u16,
    pa: ?*const anyopaque,
    ta: ?*const anyopaque,
    inh: BOOL,
    flags: DWORD,
    env: ?windows.LPVOID,
    cwd: ?LPCWSTR,
    si: *STARTUPINFOW,
    pi: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;

const STARTUPINFOW = extern struct {
    cb: DWORD,
    lpReserved: ?LPCWSTR,
    lpDesktop: ?LPCWSTR,
    lpTitle: ?LPCWSTR,
    dwX: DWORD, dwY: DWORD, dwXSize: DWORD, dwYSize: DWORD,
    dwXCountChars: DWORD, dwYCountChars: DWORD, dwFillAttribute: DWORD,
    dwFlags: DWORD, wShowWindow: u16, cbReserved2: u16,
    lpReserved2: ?*u8,
    hStdInput: ?HANDLE, hStdOutput: ?HANDLE, hStdError: ?HANDLE,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE, hThread: HANDLE, dwProcessId: DWORD, dwThreadId: DWORD,
};

const DETACHED_PROCESS: DWORD = 0x00000008;
const CREATE_NEW_PROCESS_GROUP: DWORD = 0x00000200;

const magic = "ATUW";
const format_version: u8 = 2; // v2: host process model (no HANDLE inheritance)
const max_sessions: usize = 32;
const max_panes_per_session = @import("session.zig").max_panes_per_session;

// ── Binary format helpers ──

const ListWriter = std.ArrayList(u8).Writer;

fn writeBytes(w: ListWriter, data: []const u8) !void { try w.writeAll(data); }
fn writeByte(w: ListWriter, b: u8) !void { try w.writeByte(b); }
fn writeU16(w: ListWriter, v: u16) !void { try w.writeInt(u16, v, .little); }
fn writeU32(w: ListWriter, v: u32) !void { try w.writeInt(u32, v, .little); }

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
        const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }
    fn readU32(self: *SliceReader) !u32 {
        if (self.pos + 4 > self.data.len) return error.EndOfStream;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }
    fn readSlice(self: *SliceReader, len: usize) ![]const u8 {
        if (self.pos + len > self.data.len) return error.EndOfStream;
        const s = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return s;
    }
    fn readInto(self: *SliceReader, dest: []u8) !void {
        if (self.pos + dest.len > self.data.len) return error.EndOfStream;
        @memcpy(dest, self.data[self.pos .. self.pos + dest.len]);
        self.pos += dest.len;
    }
};

// ── Serialization (v2: pane_id instead of HANDLEs) ──

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

    var count: u8 = 0;
    for (sessions) |*slot| { if (slot.* != null) count += 1; }
    try writeByte(w, count);
    for (sessions) |*slot| {
        if (slot.*) |*s| try serializeSession(w, s);
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
    for (s.panes) |p| { if (p != null) pane_count += 1; }
    try writeByte(w, pane_count);
    for (&s.panes) |*pslot| {
        if (pslot.*) |*p| try serializePane(w, p);
    }
}

fn serializePane(w: ListWriter, p: *DaemonPane) !void {
    // v2: only pane_id — host process pipe name is derived deterministically.
    // No HANDLE values needed since hosts own ConPTY independently.
    try writeU32(w, p.id);
    try writeU16(w, p.rows);
    try writeU16(w, p.cols);
    try writeByte(w, if (p.alive) 1 else 0);
    try writeByte(w, p.exit_code orelse 0xFF);
    try writeByte(w, if (p.cursor_visible) 1 else 0);
    try writeByte(w, if (p.alt_screen) 1 else 0);
    try writeByte(w, p.proc_name_len);
    try writeBytes(w, p.proc_name[0..p.proc_name_len]);
    try writeU16(w, p.osc7_cwd_len);
    try writeBytes(w, p.osc7_cwd[0..p.osc7_cwd_len]);
    try writeU16(w, p.osc7337_path_len);
    try writeBytes(w, p.osc7337_path[0..p.osc7337_path_len]);

    const slices = p.replay.readSlices();
    const ring_len: u32 = @intCast(slices.totalLen());
    try writeU32(w, ring_len);
    if (slices.first.len > 0) try writeBytes(w, slices.first);
    if (slices.second.len > 0) try writeBytes(w, slices.second);
}

// ── Deserialization (v2: reconnect to host pipes) ──

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
    daemonLog2("deserialize: session_count={d}", .{session_count});
    var restored: u8 = 0;
    for (0..session_count) |si| {
        const slot = for (sessions) |*slot| {
            if (slot.* == null) break slot;
        } else continue;
        deserializeSessionInto(&r, allocator, slot) catch |err| {
            daemonLog2("deserialize: session {d} failed: {s} at pos {d}/{d}", .{ si, @errorName(err), r.pos, r.data.len });
            continue;
        };
        restored += 1;
    }
    return restored;
}

fn deserializeSessionInto(r: *SliceReader, allocator: std.mem.Allocator, slot: *?DaemonSession) !void {
    slot.* = DaemonSession{ .id = try r.readU32(), .rows = 24, .cols = 80 };
    var s = &(slot.*.?);
    errdefer {
        for (&s.panes) |*pslot| {
            if (pslot.*) |*p| { p.replay.deinit(); pslot.* = null; }
        }
        slot.* = null;
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
        const pane_slot = for (&s.panes) |*pslot| {
            if (pslot.* == null) break pslot;
        } else continue;
        try deserializePaneInto(r, allocator, pane_slot);
        s.pane_count += 1;
    }
}

/// Deserialize a pane and reconnect to its host process pipe.
fn deserializePaneInto(r: *SliceReader, allocator: std.mem.Allocator, slot: *?DaemonPane) !void {
    const id = try r.readU32();
    const rows = try r.readU16();
    const cols = try r.readU16();
    const alive = (try r.readByte()) != 0;
    const exit_raw = try r.readByte();
    const exit_code: ?u8 = if (exit_raw == 0xFF) null else exit_raw;
    const cursor_visible = (try r.readByte()) != 0;
    const alt_screen = (try r.readByte()) != 0;
    const proc_name_len = try r.readByte();
    const proc_name_slice = try r.readSlice(proc_name_len);
    const osc7_cwd_len = try r.readU16();
    const osc7_cwd_slice = try r.readSlice(osc7_cwd_len);
    const osc7337_path_len = try r.readU16();
    const osc7337_path_slice = try r.readSlice(osc7337_path_len);
    const ring_len = try r.readU32();
    const ring_data = try r.readSlice(ring_len);

    // Reconnect to host process pipe.
    const is_dev = !std.mem.eql(u8, attyx.env, "production");
    const conn = allocator.create(HostConnection) catch return error.OutOfMemory;
    conn.* = HostConnection.connect(id, is_dev) orelse {
        allocator.destroy(conn);
        daemonLog2("deserialize: host connect failed for pane {d}", .{id});
        return error.HostConnectFailed;
    };

    slot.* = DaemonPane{
        .id = id,
        .pty = Pty.initInactive(),
        .host_conn = conn,
        .replay = try RingBuffer.init(allocator, RingBuffer.default_capacity),
        .rows = rows,
        .cols = cols,
        .alive = alive,
        .exit_code = exit_code,
        .cursor_visible = cursor_visible,
        .alt_screen = alt_screen,
    };

    var pane = &(slot.*.?);
    const nlen: u8 = @intCast(@min(proc_name_slice.len, 64));
    @memcpy(pane.proc_name[0..nlen], proc_name_slice[0..nlen]);
    pane.proc_name_len = nlen;
    if (ring_data.len > 0) pane.replay.write(ring_data);
    const clen: u16 = @intCast(@min(osc7_cwd_slice.len, pane.osc7_cwd.len));
    @memcpy(pane.osc7_cwd[0..clen], osc7_cwd_slice[0..clen]);
    pane.osc7_cwd_len = clen;
    const plen: u16 = @intCast(@min(osc7337_path_slice.len, pane.osc7337_path.len));
    @memcpy(pane.osc7337_path[0..plen], osc7337_path_slice[0..plen]);
    pane.osc7337_path_len = plen;
}

// ── Upgrade path helpers ──

fn getUpgradePath(buf: *[256]u8) ?[]const u8 {
    return session_connect.statePath(buf, "upgrade{s}.bin");
}

fn getStagedExePath(buf: *[256]u8) ?[]const u8 {
    return session_connect.statePath(buf, "upgrade{s}.exe");
}

pub fn hasStagedBinary() bool {
    var buf: [256]u8 = undefined;
    const path = getStagedExePath(&buf) orelse return false;
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

// ── Upgrade orchestration ──

pub const UpgradeResult = enum { success, failed, fatal };

/// Perform hot-upgrade: swap exe, serialize state, spawn new daemon, exit.
/// No HPCON keeper needed — host processes keep shells alive independently.
pub fn performUpgrade(
    sessions: *[max_sessions]?DaemonSession,
    next_session_id: u32,
    next_pane_id: u32,
    allocator: std.mem.Allocator,
    pipe_name: []const u8,
) UpgradeResult {
    var path_buf: [256]u8 = undefined;
    const upgrade_path = getUpgradePath(&path_buf) orelse return .failed;

    // ── Step 1: Exe swap ──
    var exe_buf: [1024]u8 = undefined;
    const exe = session_connect.getExePath(&exe_buf) orelse {
        daemonLog("upgrade: cannot find exe path");
        return .failed;
    };

    var staged_buf: [256]u8 = undefined;
    if (getStagedExePath(&staged_buf)) |staged| {
        const has_staged = blk: {
            std.fs.accessAbsolute(staged, .{}) catch break :blk false;
            break :blk true;
        };
        if (has_staged) {
            swapExe(exe, staged);
            std.fs.deleteFileAbsolute(staged) catch {};
        }
    }

    // ── Step 2: Serialize state (no handle inheritance needed) ──
    var list: std.ArrayList(u8) = .{};
    defer list.deinit(allocator);
    serialize(list.writer(allocator), sessions, next_session_id, next_pane_id) catch {
        daemonLog("upgrade: serialization failed");
        return .failed;
    };

    var tmp_buf: [260]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{upgrade_path}) catch return .failed;

    const file = std.fs.createFileAbsolute(tmp_path, .{}) catch return .failed;
    file.writeAll(list.items) catch { file.close(); return .failed; };
    file.close();
    std.fs.renameAbsolute(tmp_path, upgrade_path) catch {
        std.fs.deleteFileAbsolute(tmp_path) catch {};
        return .failed;
    };

    // ── Step 3: Spawn new daemon (no bInheritHandles) ──
    daemonLog("upgrade: state saved, spawning new daemon");

    if (!spawnNewDaemon(exe, upgrade_path)) {
        daemonLog("upgrade: spawn failed");
        cleanup(upgrade_path);
        return .failed;
    }

    // ── Step 4: Verify new daemon is listening ──
    if (!probeNewDaemon(pipe_name)) {
        daemonLog("upgrade: verification failed");
        cleanup(upgrade_path);
        return .failed;
    }

    daemonLog("upgrade: new daemon verified, old daemon exiting cleanly");
    cleanup(upgrade_path);
    return .success;
}

fn swapExe(exe_path: []const u8, staged_path: []const u8) void {
    var old_buf: [1028]u8 = undefined;
    const old_path = std.fmt.bufPrint(&old_buf, "{s}.old", .{exe_path}) catch return;
    std.fs.deleteFileAbsolute(old_path) catch {};
    std.fs.renameAbsolute(exe_path, old_path) catch {
        daemonLog("upgrade: rename exe → .old failed");
        return;
    };
    std.fs.renameAbsolute(staged_path, exe_path) catch {
        daemonLog("upgrade: move staged → exe failed, rolling back");
        std.fs.renameAbsolute(old_path, exe_path) catch {};
        return;
    };
    daemonLog("upgrade: exe swapped successfully");
}

pub fn cleanupOldExe() void {
    var exe_buf: [1024]u8 = undefined;
    const exe = session_connect.getExePath(&exe_buf) orelse return;
    var old_buf: [1028]u8 = undefined;
    const old_path = std.fmt.bufPrint(&old_buf, "{s}.old", .{exe}) catch return;
    std.fs.deleteFileAbsolute(old_path) catch {};
}

/// Spawn new daemon — no handle inheritance needed.
fn spawnNewDaemon(exe_path: []const u8, restore_path: []const u8) bool {
    var cmd_buf: [4096:0]u16 = undefined;
    var pos: usize = 0;

    cmd_buf[pos] = '"';
    pos += 1;
    const exe_len = std.unicode.utf8ToUtf16Le(cmd_buf[pos..], exe_path) catch return false;
    pos += exe_len;
    const suffix = "\" daemon --restore \"";
    for (suffix) |c| { cmd_buf[pos] = c; pos += 1; }
    const rp_len = std.unicode.utf8ToUtf16Le(cmd_buf[pos..], restore_path) catch return false;
    pos += rp_len;
    cmd_buf[pos] = '"';
    pos += 1;
    cmd_buf[pos] = 0;

    var si = std.mem.zeroes(STARTUPINFOW);
    si.cb = @sizeOf(STARTUPINFOW);
    var pi: PROCESS_INFORMATION = undefined;

    // bInheritHandles=0 — no handle inheritance needed with host process model.
    if (CreateProcessW(null, &cmd_buf, null, null, 0, DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP, null, null, &si, &pi) == 0) {
        return false;
    }
    _ = CloseHandle(pi.hThread);
    _ = CloseHandle(pi.hProcess);
    return true;
}

fn probeNewDaemon(pipe_name: []const u8) bool {
    for (0..80) |_| {
        Sleep(100);
        if (probeConnect(pipe_name)) return true;
    }
    return false;
}

fn probeConnect(pipe_name: []const u8) bool {
    var wide: [256:0]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wide, pipe_name) catch return false;
    wide[wlen] = 0;

    const GENERIC_READ: DWORD = 0x80000000;
    const GENERIC_WRITE: DWORD = 0x40000000;
    const OPEN_EXISTING: DWORD = 3;
    const h = CreateFileW(
        @ptrCast(wide[0..wlen :0]),
        GENERIC_READ | GENERIC_WRITE,
        0, null, OPEN_EXISTING, 0, null,
    );
    if (h == INVALID_HANDLE_VALUE) return false;
    _ = CloseHandle(h);
    return true;
}

extern "kernel32" fn CreateFileW(
    lpFileName: LPCWSTR,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*const anyopaque,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;

fn cleanup(path: []const u8) void {
    std.fs.deleteFileAbsolute(path) catch {};
}

fn daemonLog(msg: []const u8) void {
    var path_buf: [256]u8 = undefined;
    const path = session_connect.statePath(&path_buf, "daemon-debug{s}.log") orelse return;
    const file = std.fs.createFileAbsolute(path, .{ .truncate = false }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch {};
    file.writeAll("[upgrade] ") catch {};
    file.writeAll(msg) catch {};
    file.writeAll("\n") catch {};
}

fn daemonLog2(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    daemonLog(msg);
}
