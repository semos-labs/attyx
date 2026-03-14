// Attyx — Windows-specific IPC client helpers
//
// Named pipe discovery and connection for the Windows IPC transport.
// Extracted from client.zig to keep file sizes under 600 lines.

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

pub const win32 = if (is_windows) struct {
    const windows = std.os.windows;
    pub const HANDLE = windows.HANDLE;
    pub const DWORD = windows.DWORD;
    pub const BOOL = windows.BOOL;
    pub const GENERIC_READ: DWORD = 0x80000000;
    pub const GENERIC_WRITE: DWORD = 0x40000000;
    pub const OPEN_EXISTING: DWORD = 3;

    pub extern "kernel32" fn CreateFileW(
        lpFileName: [*:0]const u16,
        dwDesiredAccess: DWORD,
        dwShareMode: DWORD,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: DWORD,
        dwFlagsAndAttributes: DWORD,
        hTemplateFile: ?HANDLE,
    ) callconv(.winapi) HANDLE;
    pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetEnvironmentVariableW(
        lpName: [*:0]const u16,
        lpBuffer: [*]u16,
        nSize: DWORD,
    ) callconv(.winapi) DWORD;
    pub extern "kernel32" fn WaitNamedPipeW(
        lpNamedPipeName: [*:0]const u16,
        nTimeOut: DWORD,
    ) callconv(.winapi) BOOL;
} else struct {};

/// Windows: discover named pipe for a running instance.
/// Returns the pipe path built from ATTYX_PID (or target_pid).
/// No probing — the actual connection attempt in sendCommand validates it.
pub fn discoverPipe(buf: *[256]u8, target_pid: ?u32) ?[]const u8 {
    if (comptime !is_windows) unreachable;

    const pid: u32 = target_pid orelse blk: {
        // Check ATTYX_PID env var
        const env_name: [*:0]const u16 = std.os.windows.L("ATTYX_PID");
        var val_buf: [32]u16 = undefined;
        const len = win32.GetEnvironmentVariableW(env_name, &val_buf, val_buf.len);
        if (len > 0 and len < val_buf.len) {
            var ascii: [32]u8 = undefined;
            for (0..len) |i| ascii[i] = @intCast(val_buf[i] & 0xFF);
            break :blk std.fmt.parseInt(u32, ascii[0..len], 10) catch return null;
        }
        return null;
    };

    const suffix = if (comptime builtin.mode == .Debug) "-dev" else "";
    return std.fmt.bufPrint(buf, "\\\\.\\pipe\\attyx-ctl-{d}{s}", .{ pid, suffix }) catch null;
}

/// Connect to a Windows named pipe, returning the HANDLE as fd_t.
pub fn connectPipe(path: []const u8) !std.posix.fd_t {
    if (comptime !is_windows) unreachable;
    var wide_buf: [256]u16 = undefined;
    for (path, 0..) |ch, i| {
        wide_buf[i] = ch;
    }
    wide_buf[path.len] = 0;
    const handle = win32.CreateFileW(
        wide_buf[0..path.len :0],
        win32.GENERIC_READ | win32.GENERIC_WRITE,
        0,
        null,
        win32.OPEN_EXISTING,
        0,
        null,
    );
    if (handle == std.os.windows.INVALID_HANDLE_VALUE) return error.ConnectionRefused;
    return handle;
}
