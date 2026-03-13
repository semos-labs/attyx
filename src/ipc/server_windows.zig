// Attyx — Windows IPC control socket server (named pipe)
//
// Listens on \\.\pipe\attyx-ctl-<pid> for incoming control commands.
// Runs on a dedicated thread; enqueues commands into the lockfree
// ring buffer for the PTY thread to drain.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const queue = @import("queue.zig");
const logging = @import("../logging/log.zig");

const windows = std.os.windows;
const HANDLE = windows.HANDLE;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;

extern "kernel32" fn CreateNamedPipeW(
    lpName: [*:0]const u16,
    dwOpenMode: DWORD,
    dwPipeMode: DWORD,
    nMaxInstances: DWORD,
    nOutBufSize: DWORD,
    nInBufSize: DWORD,
    nDefaultTimeout: DWORD,
    lpSecurityAttributes: ?*anyopaque,
) callconv(.winapi) HANDLE;
extern "kernel32" fn ConnectNamedPipe(hPipe: HANDLE, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn DisconnectNamedPipe(hPipe: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nRead: DWORD, lpBytesRead: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nWrite: DWORD, lpWritten: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;
extern "kernel32" fn DuplicateHandle(
    hSourceProcessHandle: HANDLE,
    hSourceHandle: HANDLE,
    hTargetProcessHandle: HANDLE,
    lpTargetHandle: *HANDLE,
    dwDesiredAccess: DWORD,
    bInheritHandle: BOOL,
    dwOptions: DWORD,
) callconv(.winapi) BOOL;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;

const PIPE_ACCESS_DUPLEX: DWORD = 0x00000003;
const PIPE_TYPE_BYTE: DWORD = 0x00000000;
const PIPE_READMODE_BYTE: DWORD = 0x00000000;
const PIPE_WAIT: DWORD = 0x00000000;
const PIPE_UNLIMITED_INSTANCES: DWORD = 255;
const DUPLICATE_SAME_ACCESS: DWORD = 0x00000002;

pub var g_ipc_shutdown: i32 = 0;

var pipe_name_buf: [128]u16 = undefined;
var pipe_name_len: usize = 0;
var started: bool = false;

pub fn isStarted() bool {
    return started;
}

pub fn start() !void {
    const suffix = if (comptime builtin.mode == .Debug) "-dev" else "";
    const pid = GetCurrentProcessId();

    // Build the pipe name as UTF-16
    var ascii_buf: [128]u8 = undefined;
    const ascii = std.fmt.bufPrint(&ascii_buf, "\\\\.\\pipe\\attyx-ctl-{d}{s}", .{ pid, suffix }) catch
        return error.PathTooLong;

    pipe_name_len = ascii.len;
    for (ascii, 0..) |ch, i| {
        pipe_name_buf[i] = ch;
    }
    pipe_name_buf[ascii.len] = 0;

    started = true;
    logging.info("ipc", "control pipe: {s}", .{ascii});
}

/// Accept loop — run on a dedicated thread.
pub fn run() void {
    if (!started) return;

    while (@atomicLoad(i32, &g_ipc_shutdown, .seq_cst) == 0) {
        // Create a new pipe instance for each client
        const pipe = CreateNamedPipeW(
            pipe_name_buf[0..pipe_name_len :0],
            PIPE_ACCESS_DUPLEX,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
            PIPE_UNLIMITED_INSTANCES,
            4096,
            4096,
            200, // 200ms timeout (so ConnectNamedPipe doesn't block forever)
            null,
        );
        if (pipe == INVALID_HANDLE_VALUE) {
            Sleep(100);
            continue;
        }

        // Wait for a client to connect (blocking, but timeout is 200ms)
        if (ConnectNamedPipe(pipe, null) == 0) {
            // ERROR_PIPE_CONNECTED (535) means client already connected — that's ok
            const err = std.os.windows.GetLastError();
            if (err != .PIPE_CONNECTED) {
                _ = CloseHandle(pipe);
                if (@atomicLoad(i32, &g_ipc_shutdown, .seq_cst) != 0) break;
                continue;
            }
        }

        handleClient(pipe);
    }
}

fn handleClient(pipe: HANDLE) void {
    defer {
        _ = DisconnectNamedPipe(pipe);
        _ = CloseHandle(pipe);
    }

    // Read header
    var hdr: [protocol.header_size]u8 = undefined;
    readExactPipe(pipe, &hdr) catch return;
    const h = protocol.decodeHeader(&hdr) catch return;

    if (h.payload_len > queue.max_payload) {
        var err_buf: [128]u8 = undefined;
        const err_msg = protocol.encodeMessage(&err_buf, .err, "payload too large") catch return;
        writeAllPipe(pipe, err_msg) catch {};
        return;
    }

    // Duplicate the pipe handle for the PTY thread to write the response
    var dup_handle: HANDLE = INVALID_HANDLE_VALUE;
    if (DuplicateHandle(
        GetCurrentProcess(),
        pipe,
        GetCurrentProcess(),
        &dup_handle,
        0,
        0,
        DUPLICATE_SAME_ACCESS,
    ) == 0) {
        var err_buf: [128]u8 = undefined;
        const err_msg = protocol.encodeMessage(&err_buf, .err, "internal error") catch return;
        writeAllPipe(pipe, err_msg) catch {};
        return;
    }

    var cmd = queue.IpcCommand{
        .msg_type = @intFromEnum(h.msg_type),
        .payload = undefined,
        .payload_len = @intCast(h.payload_len),
        .response_fd = dup_handle,
    };

    if (h.payload_len > 0) {
        readExactPipe(pipe, cmd.payload[0..h.payload_len]) catch {
            _ = CloseHandle(dup_handle);
            return;
        };
    }

    // Unwrap session envelope
    if (h.msg_type == .session_envelope) {
        if (h.payload_len < 5) {
            _ = CloseHandle(dup_handle);
            var err_buf: [128]u8 = undefined;
            const err_msg = protocol.encodeMessage(&err_buf, .err, "invalid session envelope") catch return;
            writeAllPipe(pipe, err_msg) catch {};
            return;
        }
        cmd.session_id = std.mem.readInt(u32, cmd.payload[0..4], .little);
        cmd.msg_type = cmd.payload[4];
        const inner_len = h.payload_len - 5;
        if (inner_len > 0) {
            std.mem.copyForwards(u8, cmd.payload[0..inner_len], cmd.payload[5 .. 5 + inner_len]);
        }
        cmd.payload_len = @intCast(inner_len);
    }

    if (!queue.enqueue(cmd)) {
        _ = CloseHandle(dup_handle);
        var err_buf: [128]u8 = undefined;
        const err_msg = protocol.encodeMessage(&err_buf, .err, "command queue full") catch return;
        writeAllPipe(pipe, err_msg) catch {};
    }
    // PTY thread now owns dup_handle
}

pub fn shutdown() void {
    @atomicStore(i32, &g_ipc_shutdown, 1, .seq_cst);
    started = false;
}

fn readExactPipe(pipe: HANDLE, out: []u8) !void {
    var total: usize = 0;
    while (total < out.len) {
        var bytes_read: DWORD = 0;
        if (ReadFile(pipe, out[total..].ptr, @intCast(out.len - total), &bytes_read, null) == 0)
            return error.ConnectionClosed;
        if (bytes_read == 0) return error.ConnectionClosed;
        total += bytes_read;
    }
}

fn writeAllPipe(pipe: HANDLE, data: []const u8) !void {
    var total: usize = 0;
    while (total < data.len) {
        var written: DWORD = 0;
        if (WriteFile(pipe, data[total..].ptr, @intCast(data.len - total), &written, null) == 0)
            return error.BrokenPipe;
        total += written;
    }
}
