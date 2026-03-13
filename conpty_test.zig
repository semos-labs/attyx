const std = @import("std");
const windows = std.os.windows;

const HANDLE = windows.HANDLE;
const INVALID_HANDLE = windows.INVALID_HANDLE_VALUE;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
const LPVOID = windows.LPVOID;
const WORD = u16;
const BYTE = u8;
const LPCWSTR = [*:0]const u16;

const HPCON = *opaque {};
const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x00080000;
const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
const S_OK: c_long = 0;
const LPPROC_THREAD_ATTRIBUTE_LIST = *opaque {};

const COORD = extern struct { x: c_short, y: c_short };

const STARTUPINFOW = extern struct {
    cb: DWORD,
    lpReserved: ?LPCWSTR,
    lpDesktop: ?LPCWSTR,
    lpTitle: ?LPCWSTR,
    dwX: DWORD, dwY: DWORD, dwXSize: DWORD, dwYSize: DWORD,
    dwXCountChars: DWORD, dwYCountChars: DWORD, dwFillAttribute: DWORD,
    dwFlags: DWORD, wShowWindow: WORD, cbReserved2: WORD,
    lpReserved2: ?*BYTE,
    hStdInput: ?HANDLE, hStdOutput: ?HANDLE, hStdError: ?HANDLE,
};

const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW,
    lpAttributeList: ?LPPROC_THREAD_ATTRIBUTE_LIST,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE, hThread: HANDLE, dwProcessId: DWORD, dwThreadId: DWORD,
};

extern "kernel32" fn CreatePipe(r: *HANDLE, w: *HANDLE, sa: ?*anyopaque, sz: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn CreatePseudoConsole(size: COORD, hInput: HANDLE, hOutput: HANDLE, flags: DWORD, phPC: *HPCON) callconv(.winapi) c_long;
extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;
extern "kernel32" fn InitializeProcThreadAttributeList(l: ?LPPROC_THREAD_ATTRIBUTE_LIST, c_: DWORD, f: DWORD, s: *usize) callconv(.winapi) BOOL;
extern "kernel32" fn UpdateProcThreadAttribute(l: LPPROC_THREAD_ATTRIBUTE_LIST, f: DWORD, a: usize, v: ?*const anyopaque, s: usize, pv: ?LPVOID, rs: ?*usize) callconv(.winapi) BOOL;
extern "kernel32" fn CreateProcessW(app: ?LPCWSTR, cmd: ?[*:0]u16, pa: ?*anyopaque, ta: ?*anyopaque, inh: BOOL, flags: DWORD, env: ?LPVOID, cwd: ?LPCWSTR, si: *STARTUPINFOEXW, pi: *PROCESS_INFORMATION) callconv(.winapi) BOOL;
extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: DWORD, read_: ?*DWORD, ovl: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn GetExitCodeProcess(h: HANDLE, code: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn PeekNamedPipe(h: HANDLE, buf: ?[*]u8, n: DWORD, r: ?*DWORD, avail: ?*DWORD, left: ?*DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;

const pr = std.debug.print;

pub fn main() !void {
    pr("Creating pipes...\n", .{});
    var in_r: HANDLE = INVALID_HANDLE;
    var in_w: HANDLE = INVALID_HANDLE;
    var out_r: HANDLE = INVALID_HANDLE;
    var out_w: HANDLE = INVALID_HANDLE;

    if (CreatePipe(&in_r, &in_w, null, 0) == 0) return error.PipeFailed;
    if (CreatePipe(&out_r, &out_w, null, 0) == 0) return error.PipeFailed;

    pr("Creating pseudo console...\n", .{});
    const size = COORD{ .x = 80, .y = 24 };
    var hpc: HPCON = undefined;
    const hr = CreatePseudoConsole(size, in_r, out_w, 0, &hpc);
    if (hr != S_OK) {
        pr("CreatePseudoConsole FAILED: hr=0x{x}\n", .{@as(u32, @bitCast(hr))});
        return error.ConPTYFailed;
    }
    pr("ConPTY created OK\n", .{});

    var attr_size: usize = 0;
    _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
    pr("Attr list size: {d}\n", .{attr_size});

    var attr_buf: [256]u8 align(8) = undefined;
    const attr_list: LPPROC_THREAD_ATTRIBUTE_LIST = @ptrCast(&attr_buf);
    if (InitializeProcThreadAttributeList(attr_list, 1, 0, &attr_size) == 0) {
        pr("InitializeProcThreadAttributeList FAILED: {d}\n", .{GetLastError()});
        return error.AttrListFailed;
    }

    if (UpdateProcThreadAttribute(attr_list, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, @ptrCast(&hpc), @sizeOf(HPCON), null, null) == 0) {
        pr("UpdateProcThreadAttribute FAILED: {d}\n", .{GetLastError()});
        return error.AttrUpdateFailed;
    }
    pr("Attribute list OK\n", .{});

    // "cmd.exe" as UTF-16
    var cmd_buf = [_:0]u16{ 'c', 'm', 'd', '.', 'e', 'x', 'e' };
    var si = std.mem.zeroes(STARTUPINFOEXW);
    si.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
    si.lpAttributeList = attr_list;

    var pi: PROCESS_INFORMATION = undefined;
    if (CreateProcessW(null, &cmd_buf, null, null, 0, EXTENDED_STARTUPINFO_PRESENT, null, null, &si, &pi) == 0) {
        pr("CreateProcessW FAILED: {d}\n", .{GetLastError()});
        return error.CreateProcessFailed;
    }
    pr("Process created: pid={d}\n", .{pi.dwProcessId});

    _ = CloseHandle(in_r);
    _ = CloseHandle(out_w);
    _ = CloseHandle(pi.hThread);

    var code: DWORD = 0;
    _ = GetExitCodeProcess(pi.hProcess, &code);
    pr("Exit code: {d} (259=alive)\n", .{code});

    pr("Waiting 1s for output...\n", .{});
    Sleep(1000);

    var avail: DWORD = 0;
    const peek_ok = PeekNamedPipe(out_r, null, 0, null, &avail, null);
    pr("PeekNamedPipe: ok={d} avail={d} lastErr={d}\n", .{ peek_ok, avail, GetLastError() });

    if (avail > 0) {
        var buf: [4096]u8 = undefined;
        var bytes_read: DWORD = 0;
        _ = ReadFile(out_r, &buf, 4096, &bytes_read, null);
        pr("Read {d} bytes:\n{s}\n", .{ bytes_read, buf[0..bytes_read] });
    } else {
        pr("No data available. Writing 'dir\\r\\n'...\n", .{});
        var written: DWORD = 0;
        _ = windows.kernel32.WriteFile(in_w, "dir\r\n", 5, &written, null);
        pr("Wrote {d} bytes\n", .{written});

        Sleep(1000);
        _ = PeekNamedPipe(out_r, null, 0, null, &avail, null);
        pr("After write - avail={d}\n", .{avail});

        if (avail > 0) {
            var buf2: [4096]u8 = undefined;
            var br2: DWORD = 0;
            _ = ReadFile(out_r, &buf2, 4096, &br2, null);
            pr("Read {d} bytes:\n{s}\n", .{ br2, buf2[0..br2] });
        }
    }

    ClosePseudoConsole(hpc);
    _ = CloseHandle(pi.hProcess);
    _ = CloseHandle(in_w);
    _ = CloseHandle(out_r);
    pr("Done.\n", .{});
}
