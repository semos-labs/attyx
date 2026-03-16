/// Windows hot-upgrade: serialize state with HANDLE values, spawn new daemon,
/// transition old daemon to HPCON keeper mode.
///
/// Strategy (Option 4 — pipe proxy without relay):
///   1. Old daemon marks ConPTY pipe handles as inheritable
///   2. Serializes session state + HANDLE values to upgrade.bin
///   3. Spawns new daemon with bInheritHandles=TRUE + --restore <path>
///   4. Verifies new daemon started (probes named pipe)
///   5. Old daemon enters HPCON keeper mode: holds HPCON alive, waits for
///      all shells to die, then exits
///   6. New daemon uses inherited pipe handles directly to talk to shells
const std = @import("std");
const attyx = @import("attyx");
const DaemonSession = @import("session.zig").DaemonSession;
const DaemonPane = @import("pane.zig").DaemonPane;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;
const session_connect = @import("../session_connect.zig");
const protocol = @import("protocol.zig");
const Pty = @import("../pty.zig").Pty;

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
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetExitCodeProcess(h: HANDLE, code: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

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
const WAIT_OBJECT_0: DWORD = 0;
const STILL_ACTIVE: DWORD = 259;

const magic = "ATUW"; // "AT Upgrade Windows" — distinct from POSIX "ATUP"
const format_version: u8 = 1;
const max_sessions: usize = 32;
const max_panes_per_session = @import("session.zig").max_panes_per_session;

// ── Binary format helpers ──

const ListWriter = std.ArrayList(u8).Writer;

fn writeBytes(w: ListWriter, data: []const u8) !void { try w.writeAll(data); }
fn writeByte(w: ListWriter, b: u8) !void { try w.writeByte(b); }
fn writeU16(w: ListWriter, v: u16) !void { try w.writeInt(u16, v, .little); }
fn writeU32(w: ListWriter, v: u32) !void { try w.writeInt(u32, v, .little); }
fn writeU64(w: ListWriter, v: u64) !void { try w.writeInt(u64, v, .little); }

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
    fn readU64(self: *SliceReader) !u64 {
        if (self.pos + 8 > self.data.len) return error.EndOfStream;
        const v = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
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

// ── Serialization ──

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
    try writeU32(w, p.id);
    // Windows: three HANDLE values (u64 each) instead of fd+pid
    try writeU64(w, @intFromPtr(p.pty.pipe_out_read));
    try writeU64(w, @intFromPtr(p.pty.pipe_in_write));
    try writeU64(w, @intFromPtr(p.pty.process));
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

// ── Deserialization ──

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
        const s = deserializeSession(&r, allocator) catch continue;
        for (sessions) |*slot| {
            if (slot.* == null) { slot.* = s; restored += 1; break; }
        }
    }
    return restored;
}

fn deserializeSession(r: *SliceReader, allocator: std.mem.Allocator) !DaemonSession {
    var s = DaemonSession{ .id = try r.readU32(), .rows = 24, .cols = 80 };
    errdefer {
        for (&s.panes) |*pslot| {
            if (pslot.*) |*p| { p.replay.deinit(); pslot.* = null; }
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
        const pane = try deserializePane(r, allocator);
        for (&s.panes) |*pslot| {
            if (pslot.* == null) { pslot.* = pane; s.pane_count += 1; break; }
        }
    }
    return s;
}

fn deserializePane(r: *SliceReader, allocator: std.mem.Allocator) !DaemonPane {
    const id = try r.readU32();
    const pipe_out_read: HANDLE = @ptrFromInt(try r.readU64());
    const pipe_in_write: HANDLE = @ptrFromInt(try r.readU64());
    const process: HANDLE = @ptrFromInt(try r.readU64());
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

    var pane = try DaemonPane.fromRestored(
        allocator, id,
        pipe_out_read, pipe_in_write, process,
        rows, cols, alive, exit_code,
        cursor_visible, alt_screen,
        proc_name_slice, ring_data,
        RingBuffer.default_capacity,
    );
    const clen: u16 = @intCast(@min(osc7_cwd_slice.len, pane.osc7_cwd.len));
    @memcpy(pane.osc7_cwd[0..clen], osc7_cwd_slice[0..clen]);
    pane.osc7_cwd_len = clen;
    const plen: u16 = @intCast(@min(osc7337_path_slice.len, pane.osc7337_path.len));
    @memcpy(pane.osc7337_path[0..plen], osc7337_path_slice[0..plen]);
    pane.osc7337_path_len = plen;
    return pane;
}

// ── Upgrade path helpers ──

fn getUpgradePath(buf: *[256]u8) ?[]const u8 {
    return session_connect.statePath(buf, "upgrade{s}.bin");
}

fn getStagedExePath(buf: *[256]u8) ?[]const u8 {
    return session_connect.statePath(buf, "upgrade{s}.exe");
}

/// Check if a staged binary exists (installer or dev script dropped it).
pub fn hasStagedBinary() bool {
    var buf: [256]u8 = undefined;
    const path = getStagedExePath(&buf) orelse return false;
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

// ── Upgrade orchestration ──

pub const UpgradeResult = enum { success, failed, fatal };

/// Perform hot-upgrade: swap exe, serialize state, spawn new daemon with
/// inherited handles, verify handoff. On success, caller enters HPCON keeper.
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
    // The installer/updater stages the new binary at upgrade.exe in state dir.
    // We rename the running exe → .old (works on locked files), then move
    // the staged binary into place. If no staged binary, the installer already
    // replaced the exe via rename (e.g. external updater).
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
        if (has_staged) swapExe(exe, staged);
    }

    // ── Step 2: Mark handles inheritable ──
    for (sessions) |*slot| {
        if (slot.*) |*s| {
            for (&s.panes) |*pslot| {
                if (pslot.*) |*pane| {
                    if (pane.alive) pane.pty.markHandlesInheritable();
                }
            }
        }
    }

    // ── Step 3: Serialize state ──
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

    // ── Step 4: Spawn new daemon ──
    var expected: u16 = 0;
    for (sessions) |s| { if (s != null) expected += 1; }

    daemonLog("upgrade: state saved, spawning new daemon");

    if (!spawnNewDaemon(exe, upgrade_path)) {
        daemonLog("upgrade: spawn failed");
        cleanup(upgrade_path);
        return .failed;
    }

    // ── Step 5: Verify ──
    if (!probeNewDaemon(pipe_name, expected)) {
        daemonLog("upgrade: verification failed");
        cleanup(upgrade_path);
        return .failed;
    }

    daemonLog("upgrade: new daemon verified, entering HPCON keeper mode");
    cleanup(upgrade_path);
    return .success;
}

/// Swap the running exe with a staged new binary.
/// 1. Rename running exe → .old (works on locked files)
/// 2. Move staged binary → exe path
/// If anything fails, try to roll back.
fn swapExe(exe_path: []const u8, staged_path: []const u8) void {
    var old_buf: [1028]u8 = undefined;
    const old_path = std.fmt.bufPrint(&old_buf, "{s}.old", .{exe_path}) catch return;

    // Clean up any leftover .old from a previous upgrade
    std.fs.deleteFileAbsolute(old_path) catch {};

    // Rename running exe → .old (Windows allows renaming locked files)
    std.fs.renameAbsolute(exe_path, old_path) catch {
        daemonLog("upgrade: rename exe → .old failed");
        return;
    };

    // Move staged binary into place
    std.fs.renameAbsolute(staged_path, exe_path) catch {
        daemonLog("upgrade: move staged → exe failed, rolling back");
        // Roll back: restore the old exe
        std.fs.renameAbsolute(old_path, exe_path) catch {};
        return;
    };

    daemonLog("upgrade: exe swapped successfully");
}

/// Clean up attyx.exe.old from a previous upgrade. Called on daemon startup.
pub fn cleanupOldExe() void {
    var exe_buf: [1024]u8 = undefined;
    const exe = session_connect.getExePath(&exe_buf) orelse return;
    var old_buf: [1028]u8 = undefined;
    const old_path = std.fmt.bufPrint(&old_buf, "{s}.old", .{exe}) catch return;
    std.fs.deleteFileAbsolute(old_path) catch {};
}

/// Spawn a new daemon process with bInheritHandles=TRUE.
fn spawnNewDaemon(exe_path: []const u8, restore_path: []const u8) bool {
    // Build command line: "exe_path" daemon --restore "restore_path"
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

    // bInheritHandles=1 so the child gets the ConPTY pipe handles.
    // DETACHED_PROCESS so the child doesn't share our console.
    if (CreateProcessW(null, &cmd_buf, null, null, 1, DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP, null, null, &si, &pi) == 0) {
        return false;
    }
    _ = CloseHandle(pi.hThread);
    _ = CloseHandle(pi.hProcess);
    return true;
}

/// Probe the named pipe to verify the new daemon is listening.
/// Also verifies session count if expected > 0.
fn probeNewDaemon(pipe_name: []const u8, expected: u16) bool {
    _ = expected;
    // Try connecting to the named pipe up to 80 times (8 seconds)
    for (0..80) |_| {
        Sleep(100);
        if (probeConnect(pipe_name)) return true;
    }
    return false;
}

fn probeConnect(pipe_name: []const u8) bool {
    // Try to open the named pipe as a client
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

/// HPCON keeper mode: hold HPCONs alive, wait for all shells to die, then exit.
/// Called by the old daemon after the new daemon is verified.
/// `sessions` still contains the original panes with their HPCON handles.
pub fn hpconKeeperLoop(sessions: *[max_sessions]?DaemonSession) void {
    daemonLog("hpcon-keeper: monitoring shells");
    while (true) {
        var any_alive = false;
        for (sessions) |*slot| {
            if (slot.*) |*s| {
                for (&s.panes) |*pslot| {
                    if (pslot.*) |*pane| {
                        if (pane.alive) {
                            if (pane.pty.childExited()) {
                                pane.alive = false;
                                daemonLog("hpcon-keeper: shell exited");
                            } else {
                                any_alive = true;
                            }
                        }
                    }
                }
            }
        }
        if (!any_alive) break;
        Sleep(500);
    }
    daemonLog("hpcon-keeper: all shells dead, exiting");
}

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
