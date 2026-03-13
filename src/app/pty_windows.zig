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
const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x00080000;
const CREATE_NO_WINDOW: DWORD = 0x08000000;
const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
const S_OK: c_long = 0;
const INFINITE: DWORD = 0xFFFFFFFF;
const WAIT_OBJECT_0: DWORD = 0;
const STILL_ACTIVE: DWORD = 259;

const COORD = extern struct {
    x: c_short,
    y: c_short,
};

const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD,
    lpSecurityDescriptor: ?LPVOID,
    bInheritHandle: BOOL,
};

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
    wShowWindow: WORD,
    cbReserved2: WORD,
    lpReserved2: ?*BYTE,
    hStdInput: ?HANDLE,
    hStdOutput: ?HANDLE,
    hStdError: ?HANDLE,
};

const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW,
    lpAttributeList: ?LPPROC_THREAD_ATTRIBUTE_LIST,
};

const LPPROC_THREAD_ATTRIBUTE_LIST = *opaque {};

const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

// ── Windows API imports ──

extern "kernel32" fn CreatePipe(
    hReadPipe: *HANDLE,
    hWritePipe: *HANDLE,
    lpPipeAttributes: ?*const SECURITY_ATTRIBUTES,
    nSize: DWORD,
) callconv(.winapi) BOOL;

extern "kernel32" fn CreatePseudoConsole(
    size: COORD,
    hInput: HANDLE,
    hOutput: HANDLE,
    dwFlags: DWORD,
    phPC: *HPCON,
) callconv(.winapi) c_long;

extern "kernel32" fn ResizePseudoConsole(
    hPC: HPCON,
    size: COORD,
) callconv(.winapi) c_long;

extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;

extern "kernel32" fn InitializeProcThreadAttributeList(
    lpAttributeList: ?LPPROC_THREAD_ATTRIBUTE_LIST,
    dwAttributeCount: DWORD,
    dwFlags: DWORD,
    lpSize: *usize,
) callconv(.winapi) BOOL;

extern "kernel32" fn UpdateProcThreadAttribute(
    lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
    dwFlags: DWORD,
    Attribute: usize,
    lpValue: ?*const anyopaque,
    cbSize: usize,
    lpPreviousValue: ?LPVOID,
    lpReturnSize: ?*usize,
) callconv(.winapi) BOOL;

extern "kernel32" fn DeleteProcThreadAttributeList(
    lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
) callconv(.winapi) void;

extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?LPCWSTR,
    lpCommandLine: ?[*:0]u16,
    lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
    lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?LPVOID,
    lpCurrentDirectory: ?LPCWSTR,
    lpStartupInfo: *STARTUPINFOEXW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;

extern "kernel32" fn PeekNamedPipe(
    hNamedPipe: HANDLE,
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
    lpOverlapped: ?LPVOID,
) callconv(.winapi) BOOL;

extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: ?*DWORD,
    lpOverlapped: ?LPVOID,
) callconv(.winapi) BOOL;

extern "kernel32" fn WaitForSingleObject(
    hHandle: HANDLE,
    dwMilliseconds: DWORD,
) callconv(.winapi) DWORD;

extern "kernel32" fn GetExitCodeProcess(
    hProcess: HANDLE,
    lpExitCode: *DWORD,
) callconv(.winapi) BOOL;

extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;

extern "kernel32" fn SetEnvironmentVariableW(
    lpName: LPCWSTR,
    lpValue: ?LPCWSTR,
) callconv(.winapi) BOOL;

// ── Pty ──

pub const Pty = struct {
    /// Read from this to get PTY output (child → parent).
    pipe_out_read: HANDLE,
    /// Write to this to send input to the PTY (parent → child).
    pipe_in_write: HANDLE,
    /// ConPTY handle.
    hpc: HPCON,
    /// Child process handle.
    process: HANDLE,
    /// Child process thread handle.
    thread: HANDLE,
    /// Attribute list backing memory (must outlive the process).
    attr_list_buf: []align(8) u8,
    /// Allocator used for attr_list_buf.
    allocator: std.mem.Allocator,

    exit_status: ?c_int = null,

    /// Return an inactive Pty (no process, no handles). Used for daemon-backed panes.
    pub fn initInactive() Pty {
        return .{
            .pipe_out_read = INVALID_HANDLE,
            .pipe_in_write = INVALID_HANDLE,
            .hpc = undefined,
            .process = INVALID_HANDLE,
            .thread = INVALID_HANDLE,
            .attr_list_buf = &.{},
            .allocator = undefined,
        };
    }

    pub const SpawnOpts = struct {
        rows: u16 = 24,
        cols: u16 = 80,
        argv: ?[]const [:0]const u8 = null,
        cwd: ?[*:0]const u8 = null,
        capture_stdout: bool = false,
        preserve_tmux: bool = false,
        skip_shell_integration: bool = false,
        startup_cmd: ?[*:0]const u8 = null,
    };

    pub fn spawn(allocator: std.mem.Allocator, opts: SpawnOpts) !Pty {
        // Create pipes: pty_in feeds ConPTY input, pty_out receives ConPTY output.
        var pty_in_read: HANDLE = INVALID_HANDLE;
        var pty_in_write: HANDLE = INVALID_HANDLE;
        var pty_out_read: HANDLE = INVALID_HANDLE;
        var pty_out_write: HANDLE = INVALID_HANDLE;

        if (CreatePipe(&pty_in_read, &pty_in_write, null, 0) == 0)
            return error.CreatePipeFailed;
        errdefer {
            _ = CloseHandle(pty_in_read);
            _ = CloseHandle(pty_in_write);
        }

        if (CreatePipe(&pty_out_read, &pty_out_write, null, 0) == 0)
            return error.CreatePipeFailed;
        errdefer {
            _ = CloseHandle(pty_out_read);
            _ = CloseHandle(pty_out_write);
        }

        // Create the pseudo console.
        const size = COORD{
            .x = @intCast(opts.cols),
            .y = @intCast(opts.rows),
        };
        var hpc: HPCON = undefined;
        if (CreatePseudoConsole(size, pty_in_read, pty_out_write, 0, &hpc) != S_OK)
            return error.CreatePseudoConsoleFailed;
        errdefer ClosePseudoConsole(hpc);

        // Build the proc thread attribute list.
        var attr_list_size: usize = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_list_size);
        const attr_buf = try allocator.alignedAlloc(u8, .@"8", attr_list_size);
        errdefer allocator.free(attr_buf);

        const attr_list: LPPROC_THREAD_ATTRIBUTE_LIST = @ptrCast(attr_buf.ptr);
        if (InitializeProcThreadAttributeList(attr_list, 1, 0, &attr_list_size) == 0)
            return error.InitAttrListFailed;

        if (UpdateProcThreadAttribute(
            attr_list,
            0,
            PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            @ptrCast(hpc), // pass the HPCON value directly, not a pointer to it
            @sizeOf(HPCON),
            null,
            null,
        ) == 0)
            return error.UpdateAttrFailed;

        // Set environment variables for the child.
        setEnvW("TERM", "xterm-256color");
        setEnvW("COLORTERM", "truecolor");
        setEnvW("TERM_PROGRAM", "attyx");
        setEnvW("ATTYX", "1");

        // Build the command line.
        const cmd_line = buildCommandLine(opts) orelse return error.CommandLineFailed;

        // Convert CWD to wide string if provided.
        const cwd_wide = if (opts.cwd) |cwd_ptr| blk: {
            const cwd_slice = std.mem.span(cwd_ptr);
            var buf: [std.fs.max_path_bytes]u16 = undefined;
            const len = std.unicode.utf8ToUtf16Le(&buf, cwd_slice) catch break :blk null;
            buf[len] = 0;
            break :blk @as(LPCWSTR, buf[0..len :0]);
        } else null;

        // Set up STARTUPINFOEXW.
        var si = std.mem.zeroes(STARTUPINFOEXW);
        si.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
        si.lpAttributeList = attr_list;

        var pi: PROCESS_INFORMATION = undefined;
        if (CreateProcessW(
            null,
            cmd_line,
            null,
            null,
            0, // don't inherit handles
            EXTENDED_STARTUPINFO_PRESENT,
            null,
            cwd_wide,
            &si,
            &pi,
        ) == 0)
            return error.CreateProcessFailed;

        // Close pipe ends that belong to the ConPTY side.
        _ = CloseHandle(pty_in_read);
        _ = CloseHandle(pty_out_write);

        _ = CloseHandle(pi.hThread);

        return .{
            .pipe_out_read = pty_out_read,
            .pipe_in_write = pty_in_write,
            .hpc = hpc,
            .process = pi.hProcess,
            .thread = pi.hThread,
            .attr_list_buf = attr_buf,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Pty) void {
        ClosePseudoConsole(self.hpc);
        _ = CloseHandle(self.pipe_out_read);
        _ = CloseHandle(self.pipe_in_write);
        _ = CloseHandle(self.process);
        DeleteProcThreadAttributeList(@ptrCast(self.attr_list_buf.ptr));
        self.allocator.free(self.attr_list_buf);
    }

    pub fn peekAvail(self: *Pty) usize {
        var avail: DWORD = 0;
        if (PeekNamedPipe(self.pipe_out_read, null, 0, null, &avail, null) == 0) return 0;
        return avail;
    }

    pub fn read(self: *Pty, buf: []u8) !usize {
        var bytes_read: DWORD = 0;
        if (ReadFile(self.pipe_out_read, buf.ptr, @intCast(buf.len), &bytes_read, null) == 0)
            return error.ReadFailed;
        return bytes_read;
    }

    pub fn writeToPty(self: *Pty, bytes: []const u8) !usize {
        var bytes_written: DWORD = 0;
        if (WriteFile(self.pipe_in_write, bytes.ptr, @intCast(bytes.len), &bytes_written, null) == 0)
            return error.WriteFailed;
        return bytes_written;
    }

    pub fn resize(self: *Pty, rows: u16, cols: u16) !void {
        const size = COORD{
            .x = @intCast(cols),
            .y = @intCast(rows),
        };
        if (ResizePseudoConsole(self.hpc, size) != S_OK)
            return error.ResizeFailed;
    }

    pub fn waitForExit(self: *Pty) void {
        if (self.exit_status != null) return;
        _ = WaitForSingleObject(self.process, INFINITE);
        var code: DWORD = 0;
        if (GetExitCodeProcess(self.process, &code) != 0) {
            self.exit_status = @intCast(code);
        }
    }

    pub fn childExited(self: *Pty) bool {
        if (self.exit_status != null) return true;
        var code: DWORD = 0;
        if (GetExitCodeProcess(self.process, &code) == 0) return true;
        if (code == STILL_ACTIVE) return false;
        self.exit_status = @intCast(code);
        return true;
    }

    pub fn exitCode(self: *const Pty) ?u8 {
        const status = self.exit_status orelse return null;
        return @intCast(status & 0xff);
    }

    /// sendSigwinch is a no-op on Windows; resize via ResizePseudoConsole.
    pub fn sendSigwinch(_: *Pty) void {}

    /// fromExisting is not supported on Windows.
    pub fn fromExisting(_: HANDLE, _: HANDLE) Pty {
        @compileError("fromExisting is not supported on Windows");
    }
};

// ── Helpers ──

fn setEnvW(comptime name: []const u8, comptime value: []const u8) void {
    const name_w = comptime toUtf16Literal(name);
    const value_w = comptime toUtf16Literal(value);
    _ = SetEnvironmentVariableW(&name_w, &value_w);
}

fn toUtf16Literal(comptime s: []const u8) [s.len:0]u16 {
    comptime {
        var result: [s.len:0]u16 = undefined;
        for (s, 0..) |c, i| {
            result[i] = c;
        }
        return result;
    }
}

fn buildCommandLine(opts: Pty.SpawnOpts) ?[*:0]u16 {
    _ = opts;
    // Default to cmd.exe. A more complete implementation would
    // read COMSPEC and handle opts.argv, but this is sufficient
    // for initial ConPTY bring-up.
    const cmd = comptime toUtf16Literal("cmd.exe");
    const static = struct {
        var buf: [cmd.len:0]u16 = cmd;
    };
    return &static.buf;
}

// ── Tests ──

test "Pty struct has expected fields" {
    // Compile-time verification that the public API shape is correct.
    const info = @typeInfo(Pty);
    const fields = info.@"struct".fields;

    comptime {
        var found_exit_status = false;
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, "exit_status")) found_exit_status = true;
        }
        if (!found_exit_status) @compileError("Pty missing exit_status field");
    }
}

test "SpawnOpts defaults are reasonable" {
    const opts = Pty.SpawnOpts{};
    try std.testing.expectEqual(@as(u16, 24), opts.rows);
    try std.testing.expectEqual(@as(u16, 80), opts.cols);
    try std.testing.expect(opts.argv == null);
    try std.testing.expect(opts.cwd == null);
}

test "ConPTY spawn and read output" {
    const allocator = std.testing.allocator;
    var pty = try Pty.spawn(allocator, .{ .rows = 24, .cols = 80 });
    defer pty.deinit();

    // Give cmd.exe a moment to start
    std.time.sleep(500 * std.time.ns_per_ms);

    // Check if process is alive
    var code: DWORD = 0;
    _ = GetExitCodeProcess(pty.process, &code);
    std.debug.print("\nProcess exit code: {d} (259=STILL_ACTIVE)\n", .{code});

    // Try a non-blocking peek to see if there's data
    var avail: DWORD = 0;
    const peek_ok = PeekNamedPipe(pty.pipe_out_read, null, 0, null, &avail, null);
    std.debug.print("PeekNamedPipe: ok={d} avail={d}\n", .{peek_ok, avail});

    if (avail > 0) {
        var buf: [4096]u8 = undefined;
        const n = try pty.read(&buf);
        std.debug.print("Read {d} bytes: [{s}]\n", .{n, buf[0..n]});
    } else {
        // Write a command to trigger output
        _ = try pty.writeToPty("echo hello\r\n");
        std.time.sleep(500 * std.time.ns_per_ms);

        const peek2_ok = PeekNamedPipe(pty.pipe_out_read, null, 0, null, &avail, null);
        std.debug.print("After write - PeekNamedPipe: ok={d} avail={d}\n", .{peek2_ok, avail});

        if (avail > 0) {
            var buf2: [4096]u8 = undefined;
            const n2 = try pty.read(&buf2);
            std.debug.print("Read {d} bytes: [{s}]\n", .{n2, buf2[0..n2]});
        }
    }
}
