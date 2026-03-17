/// Host↔Daemon pipe protocol.
///
/// Each pane has a dedicated host process (`attyx.exe --host <pane_id>`) that
/// owns the ConPTY + shell. The daemon communicates with hosts via named pipes.
///
/// Frame format: [type:u8] [length:u16-LE] [payload:N]
/// Max payload: 65533 bytes. Overhead: 3 bytes/frame.
const std = @import("std");
const windows = std.os.windows;

const HANDLE = windows.HANDLE;
const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
const LPCWSTR = [*:0]const u16;

extern "kernel32" fn CreateFileW(
    lpFileName: LPCWSTR,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*const anyopaque,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;

extern "kernel32" fn PeekNamedPipe(
    hPipe: HANDLE,
    lpBuffer: ?[*]u8,
    nBufferSize: DWORD,
    lpBytesRead: ?*DWORD,
    lpTotalBytesAvail: ?*DWORD,
    lpBytesLeftThisMessage: ?*DWORD,
) callconv(.winapi) BOOL;

extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: DWORD,
    lpNumberOfBytesRead: ?*DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;

extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: ?*DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;

extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;

const GENERIC_READ: DWORD = 0x80000000;
const GENERIC_WRITE: DWORD = 0x40000000;
const OPEN_EXISTING: DWORD = 3;

// ── Frame types ──

pub const FrameType = enum(u8) {
    // Daemon → Host
    data_in = 0x01,
    resize = 0x02,
    kill = 0x03,

    // Host → Daemon
    data_out = 0x81,
    exited = 0x82,
    ready = 0x83,
};

pub const frame_header_size: usize = 3;
pub const max_payload: usize = 65533;

pub fn encodeFrame(buf: []u8, frame_type: FrameType, payload: []const u8) ?[]u8 {
    if (payload.len > max_payload) return null;
    if (buf.len < frame_header_size + payload.len) return null;
    buf[0] = @intFromEnum(frame_type);
    std.mem.writeInt(u16, buf[1..3], @intCast(payload.len), .little);
    if (payload.len > 0) {
        @memcpy(buf[frame_header_size .. frame_header_size + payload.len], payload);
    }
    return buf[0 .. frame_header_size + payload.len];
}

pub const FrameHeader = struct {
    frame_type: FrameType,
    length: u16,
};

pub fn decodeFrameHeader(buf: []const u8) ?FrameHeader {
    if (buf.len < frame_header_size) return null;
    const raw_type = buf[0];
    const frame_type: FrameType = std.meta.intToEnum(FrameType, raw_type) catch return null;
    const length = std.mem.readInt(u16, buf[1..3], .little);
    return .{ .frame_type = frame_type, .length = length };
}

// ── Pipe name helpers ──

/// Format the host pipe name for a given pane_id into a UTF-16 buffer.
/// Returns the length (in u16 units) or null on failure.
pub fn formatPipeName(buf: *[128]u16, pane_id: u32, is_dev: bool) ?usize {
    var ascii: [128]u8 = undefined;
    const name = if (is_dev)
        std.fmt.bufPrint(&ascii, "\\\\.\\pipe\\attyx-host-{d}-dev", .{pane_id}) catch return null
    else
        std.fmt.bufPrint(&ascii, "\\\\.\\pipe\\attyx-host-{d}", .{pane_id}) catch return null;
    for (name, 0..) |ch, i| buf[i] = ch;
    buf[name.len] = 0;
    return name.len;
}

/// Format the host pipe name as UTF-8.
pub fn formatPipeNameUtf8(buf: *[128]u8, pane_id: u32, is_dev: bool) ?[]const u8 {
    return if (is_dev)
        std.fmt.bufPrint(buf, "\\\\.\\pipe\\attyx-host-{d}-dev", .{pane_id}) catch return null
    else
        std.fmt.bufPrint(buf, "\\\\.\\pipe\\attyx-host-{d}", .{pane_id}) catch return null;
}

// ── HostConnection (daemon-side handle to a host process) ──

pub const HostConnection = struct {
    pipe: HANDLE,
    pane_id: u32,
    read_buf: [65536 + frame_header_size]u8 = undefined,
    read_len: usize = 0,
    /// Stable copy of the last frame's payload (avoids use-after-move
    /// when copyForwards shifts read_buf after extracting a frame).
    frame_buf: [65536]u8 = undefined,

    /// Connect to an existing host process pipe. Retries for up to ~5 seconds.
    pub fn connect(pane_id: u32, is_dev: bool) ?HostConnection {
        var name_buf: [128]u16 = undefined;
        const name_len = formatPipeName(&name_buf, pane_id, is_dev) orelse return null;
        const pipe_name: LPCWSTR = @ptrCast(name_buf[0..name_len :0]);

        // Retry loop — host may still be creating the pipe.
        for (0..50) |_| {
            const h = CreateFileW(pipe_name, GENERIC_READ | GENERIC_WRITE, 0, null, OPEN_EXISTING, 0, null);
            if (h != INVALID_HANDLE_VALUE) {
                return .{ .pipe = h, .pane_id = pane_id };
            }
            Sleep(100);
        }
        return null;
    }

    pub fn deinit(self: *HostConnection) void {
        _ = CloseHandle(self.pipe);
        self.pipe = INVALID_HANDLE_VALUE;
    }

    // ── Send commands (daemon → host) ──

    pub fn sendDataIn(self: *HostConnection, data: []const u8) bool {
        var offset: usize = 0;
        while (offset < data.len) {
            const chunk = @min(data.len - offset, max_payload);
            if (!self.sendFrame(.data_in, data[offset .. offset + chunk])) return false;
            offset += chunk;
        }
        return true;
    }

    pub fn sendResize(self: *HostConnection, rows: u16, cols: u16) bool {
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u16, payload[0..2], rows, .little);
        std.mem.writeInt(u16, payload[2..4], cols, .little);
        return self.sendFrame(.resize, &payload);
    }

    pub fn sendKill(self: *HostConnection) bool {
        return self.sendFrame(.kill, &.{});
    }

    fn sendFrame(self: *HostConnection, frame_type: FrameType, payload: []const u8) bool {
        var header: [frame_header_size]u8 = undefined;
        header[0] = @intFromEnum(frame_type);
        std.mem.writeInt(u16, header[1..3], @intCast(payload.len), .little);
        if (!writeAll(self.pipe, &header)) return false;
        if (payload.len > 0) {
            if (!writeAll(self.pipe, payload)) return false;
        }
        return true;
    }

    // ── Receive frames (host → daemon) ──

    /// Non-blocking: read available data from the pipe.
    /// Returns false if the pipe is broken.
    pub fn recvData(self: *HostConnection) bool {
        const space = self.read_buf[self.read_len..];
        if (space.len == 0) return true; // buffer full, will drain via nextFrame

        var avail: DWORD = 0;
        if (PeekNamedPipe(self.pipe, null, 0, null, &avail, null) == 0) return false;
        if (avail == 0) return true;

        const to_read: DWORD = @intCast(@min(avail, space.len));
        var bytes_read: DWORD = 0;
        if (ReadFile(self.pipe, space.ptr, to_read, &bytes_read, null) == 0) return false;
        if (bytes_read == 0) return false;
        self.read_len += bytes_read;
        return true;
    }

    /// Extract the next complete frame from the read buffer.
    /// Payload is copied to frame_buf so it survives the read_buf shift.
    pub fn nextFrame(self: *HostConnection) ?struct { frame_type: FrameType, payload: []const u8 } {
        const header = decodeFrameHeader(self.read_buf[0..self.read_len]) orelse return null;
        const total = frame_header_size + @as(usize, header.length);
        if (self.read_len < total) return null;

        // Copy payload to stable buffer before shifting read_buf.
        const plen: usize = header.length;
        @memcpy(self.frame_buf[0..plen], self.read_buf[frame_header_size..total]);

        // Consume the frame from read_buf.
        const remaining = self.read_len - total;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.read_buf[0..remaining], self.read_buf[total..self.read_len]);
        }
        self.read_len = remaining;

        return .{ .frame_type = header.frame_type, .payload = self.frame_buf[0..plen] };
    }
};

// ── Helpers ──

fn writeAll(pipe: HANDLE, data: []const u8) bool {
    var offset: usize = 0;
    var stalls: u32 = 0;
    while (offset < data.len) {
        var written: DWORD = 0;
        if (WriteFile(pipe, data[offset..].ptr, @intCast(data.len - offset), &written, null) == 0) {
            stalls += 1;
            if (stalls > 20) return false;
            Sleep(10);
            continue;
        }
        offset += written;
        stalls = 0;
    }
    return true;
}

// ── Host process spawning (used by daemon to launch host processes) ──

const session_connect = @import("../session_connect.zig");

const STARTUPINFOW = extern struct {
    cb: DWORD,
    lpReserved: ?LPCWSTR,
    lpDesktop: ?LPCWSTR,
    lpTitle: ?LPCWSTR,
    dwX: DWORD,
    dwY: DWORD,
    dwXSize: DWORD,
    dwYSize: DWORD,
    dwXCountChars: DWORD,
    dwYCountChars: DWORD,
    dwFillAttribute: DWORD,
    dwFlags: DWORD,
    wShowWindow: u16,
    cbReserved2: u16,
    lpReserved2: ?*u8,
    hStdInput: ?HANDLE,
    hStdOutput: ?HANDLE,
    hStdError: ?HANDLE,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

extern "kernel32" fn CreateProcessW(
    app: ?LPCWSTR,
    cmd: ?[*:0]u16,
    pa: ?*const anyopaque,
    ta: ?*const anyopaque,
    inh: BOOL,
    flags: DWORD,
    env: ?*anyopaque,
    cwd: ?LPCWSTR,
    si: *STARTUPINFOW,
    pi: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;

const CREATE_NEW_PROCESS_GROUP: DWORD = 0x00000200;

/// Spawn a host process for a pane. Returns true on success.
pub fn spawnHostProcess(
    pane_id: u32,
    shell_type: []const u8,
    rows: u16,
    cols: u16,
    cwd: ?[*:0]const u8,
    startup_cmd: ?[*:0]const u8,
    is_dev: bool,
) bool {
    _ = is_dev;
    var exe_buf: [1024]u8 = undefined;
    const exe_path = session_connect.getExePath(&exe_buf) orelse return false;

    // Build command line: "exe" --host <id> --shell <type> --rows <r> --cols <c> [--cwd <path>]
    var cmd_ascii: [4096]u8 = undefined;
    var pos: usize = 0;

    // Quote the exe path
    pos += (std.fmt.bufPrint(cmd_ascii[pos..], "\"{s}\" --host {d} --shell {s} --rows {d} --cols {d}", .{
        exe_path, pane_id, shell_type, rows, cols,
    }) catch return false).len;

    if (cwd) |c| {
        const cwd_str = std.mem.sliceTo(c, 0);
        pos += (std.fmt.bufPrint(cmd_ascii[pos..], " --cwd \"{s}\"", .{cwd_str}) catch return false).len;
    }

    if (startup_cmd) |sc| {
        const cmd_str = std.mem.sliceTo(sc, 0);
        pos += (std.fmt.bufPrint(cmd_ascii[pos..], " --startup-cmd \"{s}\"", .{cmd_str}) catch return false).len;
    }

    // Convert to UTF-16
    var cmd_wide: [4096:0]u16 = undefined;
    for (cmd_ascii[0..pos], 0..) |ch, i| cmd_wide[i] = ch;
    cmd_wide[pos] = 0;

    var si = std.mem.zeroes(STARTUPINFOW);
    si.cb = @sizeOf(STARTUPINFOW);
    var pi: PROCESS_INFORMATION = undefined;

    // No DETACHED_PROCESS or CREATE_NO_WINDOW — host inherits the daemon's
    // hidden console, so MSYS2 fork() works without per-tab AllocConsole flash.
    if (CreateProcessW(null, &cmd_wide, null, null, 0, CREATE_NEW_PROCESS_GROUP, null, null, &si, &pi) == 0) {
        return false;
    }
    _ = CloseHandle(pi.hThread);
    _ = CloseHandle(pi.hProcess);
    return true;
}

/// Wait for READY frame from a host connection (with timeout).
pub fn waitForReady(conn: *HostConnection, timeout_ms: u32) bool {
    var elapsed: u32 = 0;
    while (elapsed < timeout_ms) {
        if (!conn.recvData()) return false;
        while (conn.nextFrame()) |frame| {
            if (frame.frame_type == .ready) return true;
            if (frame.frame_type == .exited) return false;
        }
        Sleep(50);
        elapsed += 50;
    }
    return false;
}

// ── Tests ──

test "frame encode/decode roundtrip" {
    var buf: [256]u8 = undefined;
    const payload = "hello";
    const frame = encodeFrame(&buf, .data_out, payload).?;
    try std.testing.expectEqual(@as(usize, 8), frame.len);

    const header = decodeFrameHeader(frame).?;
    try std.testing.expectEqual(FrameType.data_out, header.frame_type);
    try std.testing.expectEqual(@as(u16, 5), header.length);
    try std.testing.expectEqualStrings("hello", frame[frame_header_size..]);
}

test "frame encode empty payload" {
    var buf: [16]u8 = undefined;
    const frame = encodeFrame(&buf, .kill, &.{}).?;
    try std.testing.expectEqual(@as(usize, 3), frame.len);

    const header = decodeFrameHeader(frame).?;
    try std.testing.expectEqual(FrameType.kill, header.frame_type);
    try std.testing.expectEqual(@as(u16, 0), header.length);
}

test "pipe name format" {
    var buf: [128]u16 = undefined;
    const len = formatPipeName(&buf, 42, false).?;
    var ascii: [128]u8 = undefined;
    for (buf[0..len], 0..) |cp, i| ascii[i] = @intCast(cp);
    try std.testing.expectEqualStrings("\\\\.\\pipe\\attyx-host-42", ascii[0..len]);
}

test "pipe name format dev" {
    var buf: [128]u16 = undefined;
    const len = formatPipeName(&buf, 7, true).?;
    var ascii: [128]u8 = undefined;
    for (buf[0..len], 0..) |cp, i| ascii[i] = @intCast(cp);
    try std.testing.expectEqualStrings("\\\\.\\pipe\\attyx-host-7-dev", ascii[0..len]);
}
