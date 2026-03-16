/// Test: Option 4 — old daemon keeps HPCON alive, new daemon uses inherited pipes.
///
/// This simulates the "pipe proxy" upgrade strategy:
///   - Old daemon (parent) owns the HPCON and keeps it open
///   - New daemon (child) inherits pipe handles and talks to the shell directly
///   - Parent stays alive as HPCON keeper until child is done
///
/// Parent mode (default):
///   1. Create ConPTY + cmd.exe
///   2. Verify shell is alive
///   3. Mark pipe handles as inheritable
///   4. Spawn child with bInheritHandles=TRUE
///   5. Keep HPCON alive, wait for child to finish
///   6. Clean up
///
/// Child mode (--child):
///   1. Read inherited handle values from temp file
///   2. Write "echo CONPTY_INHERIT_TEST" via inherited pipe_in_write
///   3. Read response via inherited pipe_out_read
///   4. Print PASS or FAIL
///
/// Build:  zig build-exe conpty_test.zig -lkernel32 -luser32
/// Run:    .\conpty_test.exe
const std = @import("std");
const windows = std.os.windows;

const HANDLE = windows.HANDLE;
const INVALID_HANDLE = windows.INVALID_HANDLE_VALUE;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
const LPVOID = windows.LPVOID;
const LPCWSTR = [*:0]const u16;
const WORD = u16;
const BYTE = u8;

const HPCON = *opaque {};
const LPPROC_THREAD_ATTRIBUTE_LIST = *opaque {};

const S_OK: c_long = 0;
const STILL_ACTIVE: DWORD = 259;
const HANDLE_FLAG_INHERIT: DWORD = 0x00000001;
const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x00080000;
const CREATE_NEW_CONSOLE: DWORD = 0x00000010;
const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;

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

// ── Windows API imports ──

extern "kernel32" fn CreatePipe(r: *HANDLE, w: *HANDLE, sa: ?*anyopaque, sz: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn CreatePseudoConsole(size: COORD, hInput: HANDLE, hOutput: HANDLE, flags: DWORD, phPC: *HPCON) callconv(.winapi) c_long;
extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;
extern "kernel32" fn InitializeProcThreadAttributeList(l: ?LPPROC_THREAD_ATTRIBUTE_LIST, c_: DWORD, f: DWORD, s: *usize) callconv(.winapi) BOOL;
extern "kernel32" fn UpdateProcThreadAttribute(l: LPPROC_THREAD_ATTRIBUTE_LIST, f: DWORD, a: usize, v: ?*const anyopaque, s: usize, pv: ?LPVOID, rs: ?*usize) callconv(.winapi) BOOL;
extern "kernel32" fn DeleteProcThreadAttributeList(l: LPPROC_THREAD_ATTRIBUTE_LIST) callconv(.winapi) void;
extern "kernel32" fn CreateProcessW(app: ?LPCWSTR, cmd: ?[*:0]u16, pa: ?*anyopaque, ta: ?*anyopaque, inh: BOOL, flags: DWORD, env: ?LPVOID, cwd: ?LPCWSTR, si: *STARTUPINFOEXW, pi: *PROCESS_INFORMATION) callconv(.winapi) BOOL;
extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: DWORD, read_: ?*DWORD, ovl: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: DWORD, written: ?*DWORD, ovl: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn PeekNamedPipe(h: HANDLE, buf: ?[*]u8, n: DWORD, r: ?*DWORD, avail: ?*DWORD, left: ?*DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetExitCodeProcess(h: HANDLE, code: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn SetHandleInformation(h: HANDLE, mask: DWORD, flags: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetModuleFileNameW(hModule: ?HANDLE, buf: [*]u16, sz: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn AllocConsole() callconv(.winapi) BOOL;
extern "kernel32" fn GetConsoleWindow() callconv(.winapi) ?std.os.windows.HWND;
extern "user32" fn ShowWindow(hWnd: std.os.windows.HWND, nCmdShow: i32) callconv(.winapi) BOOL;

const TEMP_FILE = "conpty_test_handles.tmp";
const LOG_FILE = "conpty_test_result.log";

var log_file: ?std.fs.File = null;

/// Print to both stderr and the log file.
fn pr(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
    if (log_file) |f| {
        var buf: [1024]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
        f.writeAll(s) catch {};
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const is_child = for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--child")) break true;
    } else false;

    if (is_child) {
        runChild();
    } else {
        try runParent(allocator);
    }
}

// ════════════════════════════════════════════════════════════════
// Parent (old daemon): create ConPTY, keep it alive, let child
// use inherited pipe handles
// ════════════════════════════════════════════════════════════════

fn runParent(allocator: std.mem.Allocator) !void {
    pr("[parent] PID={d} — creating ConPTY + cmd.exe\n", .{GetCurrentProcessId()});

    // Create pipes
    var in_r: HANDLE = INVALID_HANDLE;
    var in_w: HANDLE = INVALID_HANDLE;
    var out_r: HANDLE = INVALID_HANDLE;
    var out_w: HANDLE = INVALID_HANDLE;

    if (CreatePipe(&in_r, &in_w, null, 0) == 0) return error.PipeFailed;
    if (CreatePipe(&out_r, &out_w, null, 0) == 0) return error.PipeFailed;

    // Create ConPTY
    var hpc: HPCON = undefined;
    const hr = CreatePseudoConsole(COORD{ .x = 80, .y = 24 }, in_r, out_w, 0, &hpc);
    if (hr != S_OK) {
        pr("[parent] CreatePseudoConsole FAILED: hr=0x{x}\n", .{@as(u32, @bitCast(hr))});
        return error.ConPTYFailed;
    }
    pr("[parent] ConPTY created\n", .{});

    // Build attribute list
    var attr_size: usize = 0;
    _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
    const attr_buf = try allocator.alignedAlloc(u8, .@"8", attr_size);
    defer allocator.free(attr_buf);
    const attr_list: LPPROC_THREAD_ATTRIBUTE_LIST = @ptrCast(attr_buf.ptr);
    if (InitializeProcThreadAttributeList(attr_list, 1, 0, &attr_size) == 0)
        return error.AttrListFailed;
    defer DeleteProcThreadAttributeList(attr_list);

    if (UpdateProcThreadAttribute(attr_list, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, @ptrCast(hpc), @sizeOf(HPCON), null, null) == 0)
        return error.AttrUpdateFailed;

    // Hidden console for MSYS2 fork() compat
    _ = AllocConsole();
    if (GetConsoleWindow()) |hwnd| _ = ShowWindow(hwnd, 0);

    // Spawn cmd.exe
    var cmd_buf = [_:0]u16{ 'c', 'm', 'd', '.', 'e', 'x', 'e' };
    var si = std.mem.zeroes(STARTUPINFOEXW);
    si.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
    si.lpAttributeList = attr_list;

    var pi: PROCESS_INFORMATION = undefined;
    if (CreateProcessW(null, &cmd_buf, null, null, 0, EXTENDED_STARTUPINFO_PRESENT, null, null, &si, &pi) == 0) {
        pr("[parent] CreateProcessW FAILED: {d}\n", .{GetLastError()});
        return error.CreateProcessFailed;
    }
    _ = CloseHandle(pi.hThread);
    pr("[parent] cmd.exe started (pid={d})\n", .{pi.dwProcessId});

    // Close ConPTY-side pipe ends (parent keeps in_w and out_r)
    _ = CloseHandle(in_r);
    _ = CloseHandle(out_w);

    // Wait for shell to start
    pr("[parent] Waiting 2s for shell startup...\n", .{});
    Sleep(2000);

    var avail: DWORD = 0;
    _ = PeekNamedPipe(out_r, null, 0, null, &avail, null);
    pr("[parent] Bytes available: {d}\n", .{avail});

    if (avail > 0) {
        var buf: [4096]u8 = undefined;
        var n: DWORD = 0;
        _ = ReadFile(out_r, &buf, @min(avail, buf.len), &n, null);
        pr("[parent] Shell output ({d} bytes) — shell is alive\n", .{n});
    }

    // Mark handles as inheritable
    _ = SetHandleInformation(in_w, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
    _ = SetHandleInformation(out_r, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
    _ = SetHandleInformation(pi.hProcess, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);

    pr("[parent] Handles marked inheritable: in_w={x} out_r={x} proc={x}\n", .{
        @intFromPtr(in_w), @intFromPtr(out_r), @intFromPtr(pi.hProcess),
    });

    // Write handle values to temp file
    {
        const file = try std.fs.cwd().createFile(TEMP_FILE, .{});
        defer file.close();
        var tmp: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{x}\n{x}\n{x}\n", .{
            @intFromPtr(in_w),
            @intFromPtr(out_r),
            @intFromPtr(pi.hProcess),
        }) catch unreachable;
        try file.writeAll(s);
    }

    // Spawn child (ourselves with --child)
    var exe_path: [1024]u16 = undefined;
    const exe_len = GetModuleFileNameW(null, &exe_path, exe_path.len);
    if (exe_len == 0) return error.GetModuleFileNameFailed;

    var child_cmd: [2048:0]u16 = undefined;
    var pos: usize = 0;
    child_cmd[pos] = '"';
    pos += 1;
    @memcpy(child_cmd[pos .. pos + exe_len], exe_path[0..exe_len]);
    pos += exe_len;
    const suffix_str = "\" --child";
    for (suffix_str) |c| {
        child_cmd[pos] = c;
        pos += 1;
    }
    child_cmd[pos] = 0;

    var child_si = std.mem.zeroes(STARTUPINFOEXW);
    child_si.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
    var child_pi: PROCESS_INFORMATION = undefined;

    if (CreateProcessW(null, &child_cmd, null, null, 1, CREATE_NEW_CONSOLE, null, null, &child_si, &child_pi) == 0) {
        pr("[parent] Spawn child FAILED: {d}\n", .{GetLastError()});
        return error.SpawnChildFailed;
    }
    _ = CloseHandle(child_pi.hThread);

    pr("[parent] Child spawned (pid={d}).\n", .{child_pi.dwProcessId});
    pr("[parent] HPCON stays open. Waiting for child to finish...\n", .{});

    // ── KEY DIFFERENCE: parent keeps HPCON alive ──
    // Wait for child to complete (up to 30s)
    _ = WaitForSingleObject(child_pi.hProcess, 30000);
    _ = CloseHandle(child_pi.hProcess);

    // Now clean up — HPCON closure will kill the shell, but we're done.
    pr("[parent] Child finished. Closing HPCON and cleaning up.\n", .{});
    ClosePseudoConsole(hpc);
    _ = CloseHandle(in_w);
    _ = CloseHandle(out_r);
    _ = CloseHandle(pi.hProcess);

    // Print the child's log
    printLogFile();
}

// ════════════════════════════════════════════════════════════════
// Child (new daemon): use inherited pipe handles to talk to shell
// ════════════════════════════════════════════════════════════════

fn runChild() void {
    log_file = std.fs.cwd().createFile(LOG_FILE, .{}) catch null;
    pr("[child] PID={d} — reading inherited handles\n", .{GetCurrentProcessId()});

    // Read handle values from temp file
    const file = std.fs.cwd().openFile(TEMP_FILE, .{}) catch {
        pr("[child] FAIL: could not open {s}\n", .{TEMP_FILE});
        return;
    };
    defer file.close();

    var buf: [256]u8 = undefined;
    const n = file.readAll(&buf) catch {
        pr("[child] FAIL: could not read handle file\n", .{});
        return;
    };

    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    const in_w_val = parseHex(lines.next()) orelse return fail("parse pipe_in_write");
    const out_r_val = parseHex(lines.next()) orelse return fail("parse pipe_out_read");
    const proc_val = parseHex(lines.next()) orelse return fail("parse process");

    const pipe_in_write: HANDLE = @ptrFromInt(in_w_val);
    const pipe_out_read: HANDLE = @ptrFromInt(out_r_val);
    const shell_process: HANDLE = @ptrFromInt(proc_val);

    pr("[child] Handles: in_w={x} out_r={x} proc={x}\n", .{ in_w_val, out_r_val, proc_val });

    // Give parent a moment to settle (it's still alive, HPCON is open)
    Sleep(1000);

    // ── Test 1: Is shell still alive? ──
    var exit_code: DWORD = 0;
    if (GetExitCodeProcess(shell_process, &exit_code) == 0) {
        pr("[child] WARNING: GetExitCodeProcess failed (err={d})\n", .{GetLastError()});
    } else {
        pr("[child] Shell exit code: {d} (259=STILL_ACTIVE)\n", .{exit_code});
        if (exit_code != STILL_ACTIVE) {
            pr("\n========================================\n", .{});
            pr("FAIL: Shell already dead (code={d})\n", .{exit_code});
            pr("========================================\n", .{});
            cleanup();
            return;
        }
    }

    // ── Test 2: Can we peek? ──
    var avail: DWORD = 0;
    const peek_ok = PeekNamedPipe(pipe_out_read, null, 0, null, &avail, null);
    pr("[child] PeekNamedPipe: ok={d} avail={d}\n", .{ peek_ok, avail });

    if (peek_ok == 0) {
        pr("\n========================================\n", .{});
        pr("FAIL: pipe_out_read broken (err={d})\n", .{GetLastError()});
        pr("========================================\n", .{});
        cleanup();
        return;
    }

    // Drain any pending data
    if (avail > 0) {
        var drain: [4096]u8 = undefined;
        var drain_n: DWORD = 0;
        _ = ReadFile(pipe_out_read, &drain, @min(avail, drain.len), &drain_n, null);
        pr("[child] Drained {d} bytes\n", .{drain_n});
    }

    // ── Test 3: Write a command via inherited pipe ──
    const cmd = "echo CONPTY_INHERIT_TEST\r\n";
    var written: DWORD = 0;
    if (WriteFile(pipe_in_write, cmd, cmd.len, &written, null) == 0) {
        pr("\n========================================\n", .{});
        pr("FAIL: WriteFile failed (err={d})\n", .{GetLastError()});
        pr("========================================\n", .{});
        cleanup();
        return;
    }
    pr("[child] Wrote {d} bytes: \"echo CONPTY_INHERIT_TEST\"\n", .{written});

    // ── Test 4: Read response ──
    pr("[child] Waiting 2s for response...\n", .{});
    Sleep(2000);

    avail = 0;
    const peek2 = PeekNamedPipe(pipe_out_read, null, 0, null, &avail, null);
    pr("[child] PeekNamedPipe after cmd: ok={d} avail={d}\n", .{ peek2, avail });

    if (avail > 0) {
        var read_buf: [4096]u8 = undefined;
        var read_n: DWORD = 0;
        _ = ReadFile(pipe_out_read, &read_buf, @min(avail, read_buf.len), &read_n, null);
        const output = read_buf[0..read_n];
        pr("[child] Got {d} bytes: [{s}]\n", .{ read_n, output });

        if (std.mem.indexOf(u8, output, "CONPTY_INHERIT_TEST") != null) {
            pr("\n========================================\n", .{});
            pr("PASS: Child can talk to shell via inherited pipes!\n", .{});
            pr("Parent keeps HPCON alive, child uses pipes directly.\n", .{});
            pr("Pipe-proxy upgrade approach is VIABLE.\n", .{});
            pr("========================================\n", .{});
        } else {
            pr("\n========================================\n", .{});
            pr("PARTIAL: Got data but marker not found.\n", .{});
            pr("========================================\n", .{});
        }
    } else if (peek2 != 0) {
        pr("\n========================================\n", .{});
        pr("AMBIGUOUS: Pipes alive but no response.\n", .{});
        pr("ConPTY may need active ReadFile to flush.\n", .{});
        pr("========================================\n", .{});
    } else {
        pr("\n========================================\n", .{});
        pr("FAIL: Pipe broken.\n", .{});
        pr("========================================\n", .{});
    }

    cleanup();
}

fn printLogFile() void {
    const f = std.fs.cwd().openFile(LOG_FILE, .{}) catch return;
    defer f.close();
    var buf: [4096]u8 = undefined;
    const n = f.readAll(&buf) catch return;
    if (n > 0) {
        std.debug.print("\n── child log ({s}) ──\n{s}\n── end ──\n", .{ LOG_FILE, buf[0..n] });
    }
}

fn parseHex(maybe_line: ?[]const u8) ?usize {
    const line = maybe_line orelse return null;
    const trimmed = std.mem.trim(u8, line, &[_]u8{ '\r', ' ', '\n' });
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(usize, trimmed, 16) catch null;
}

fn fail(what: []const u8) void {
    pr("[child] FAIL: could not {s}\n", .{what});
    cleanup();
}

fn cleanup() void {
    if (log_file) |f| f.close();
    log_file = null;
    std.fs.cwd().deleteFile(TEMP_FILE) catch {};
}
