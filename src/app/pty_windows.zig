const std = @import("std");
const windows = std.os.windows;
const win_shell = @import("pty_windows_shell.zig");
const bundled_shell = @import("bundled_shell.zig");

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

const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
const PSEUDOCONSOLE_PASSTHROUGH: DWORD = 0x00000008;
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
extern "kernel32" fn SetHandleInformation(hObject: HANDLE, dwMask: DWORD, dwFlags: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: c_uint) callconv(.winapi) BOOL;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;

const HANDLE_FLAG_INHERIT: DWORD = 0x00000001;

extern "kernel32" fn SetEnvironmentVariableW(
    lpName: LPCWSTR,
    lpValue: ?LPCWSTR,
) callconv(.winapi) BOOL;

extern "kernel32" fn GetEnvironmentVariableW(
    lpName: LPCWSTR,
    lpBuffer: ?[*]u16,
    nSize: DWORD,
) callconv(.winapi) DWORD;

extern "kernel32" fn SearchPathW(
    lpPath: ?LPCWSTR,
    lpFileName: LPCWSTR,
    lpExtension: ?LPCWSTR,
    nBufferLength: DWORD,
    lpBuffer: [*]u16,
    lpFilePart: ?*?[*]u16,
) callconv(.winapi) DWORD;

extern "kernel32" fn GetFileAttributesW(
    lpFileName: LPCWSTR,
) callconv(.winapi) DWORD;

extern "kernel32" fn CreateNamedPipeW(
    lpName: LPCWSTR,
    dwOpenMode: DWORD,
    dwPipeMode: DWORD,
    nMaxInstances: DWORD,
    nOutBufferSize: DWORD,
    nInBufferSize: DWORD,
    nDefaultTimeOut: DWORD,
    lpSecurityAttributes: ?*const SECURITY_ATTRIBUTES,
) callconv(.winapi) HANDLE;

extern "kernel32" fn CreateFileW(
    lpFileName: LPCWSTR,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*const SECURITY_ATTRIBUTES,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;

extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*const SECURITY_ATTRIBUTES,
    bManualReset: BOOL,
    bInitialState: BOOL,
    lpName: ?LPCWSTR,
) callconv(.winapi) HANDLE;

extern "kernel32" fn GetOverlappedResult(
    hFile: HANDLE,
    lpOverlapped: *OVERLAPPED,
    lpNumberOfBytesTransferred: *DWORD,
    bWait: BOOL,
) callconv(.winapi) BOOL;

extern "kernel32" fn CancelIo(hFile: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn ResetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;

const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    Offset: DWORD = 0,
    OffsetHigh: DWORD = 0,
    hEvent: ?HANDLE = null,
};

const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFFFFFF;
const PIPE_ACCESS_INBOUND: DWORD = 0x00000001;
const PIPE_TYPE_BYTE_WAIT: DWORD = 0x00000000;
const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;
const WIN_GENERIC_WRITE: DWORD = 0x40000000;
const OPEN_EXISTING: DWORD = 3;

// ── Hidden console for MSYS2 fork() ──

extern "kernel32" fn AllocConsole() callconv(.winapi) BOOL;
extern "kernel32" fn GetConsoleWindow() callconv(.winapi) ?std.os.windows.HWND;
extern "user32" fn ShowWindow(hWnd: std.os.windows.HWND, nCmdShow: i32) callconv(.winapi) BOOL;

var hidden_console_ready: bool = false;

pub fn ensureHiddenConsole() void {
    if (hidden_console_ready) return;
    hidden_console_ready = true;
    if (AllocConsole() != 0) {
        if (GetConsoleWindow()) |con_hwnd| {
            _ = ShowWindow(con_hwnd, 0); // SW_HIDE
        }
    }
}

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
    /// Event handle for overlapped I/O on pipe_out_read.
    read_event: HANDLE = INVALID_HANDLE,
    /// Persistent async read state — keeps a read pending so ConPTY flushes output.
    async_pending: bool = false,
    async_overlapped: OVERLAPPED = .{},
    async_buf: [65536]u8 = undefined,

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

    // fromInherited and markHandlesInheritable removed — host processes
    // own ConPTY independently; no handle inheritance needed for upgrades.

    pub const ShellType = enum { auto, zsh, pwsh, cmd };

    pub const SpawnOpts = struct {
        rows: u16 = 24,
        cols: u16 = 80,
        argv: ?[]const [:0]const u8 = null,
        cwd: ?[*:0]const u8 = null,
        capture_stdout: bool = false,
        preserve_tmux: bool = false,
        skip_shell_integration: bool = false,
        startup_cmd: ?[*:0]const u8 = null,
        shell: ShellType = .auto,
        /// Skip AllocConsole — host processes don't need their own console
        /// because ConPTY provides the console context for the shell.
        /// Allocating one causes a visible window flash + focus steal.
        skip_console_alloc: bool = false,
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

        // Output pipe needs overlapped I/O — ConPTY only flushes its buffer
        // when there's a pending ReadFile, not for PeekNamedPipe.
        const out_pipe = createOverlappedOutputPipe() orelse return error.CreatePipeFailed;
        pty_out_read = out_pipe.read;
        pty_out_write = out_pipe.write;
        const read_evt = out_pipe.event;
        errdefer {
            _ = CloseHandle(pty_out_read);
            _ = CloseHandle(pty_out_write);
            _ = CloseHandle(read_evt);
        }

        // Create the pseudo console.
        // For VT-native shells (zsh/MSYS2), try passthrough mode (Win11 22H2+)
        // which bypasses ConPTY's diff engine and passes raw VT sequences
        // through, avoiding scroll-related rendering artifacts.
        // cmd.exe and PowerShell use Win32 console APIs and need ConPTY's
        // translation layer — passthrough would produce no output.
        const size = COORD{
            .x = @intCast(opts.cols),
            .y = @intCast(opts.rows),
        };
        var hpc: HPCON = undefined;
        const use_passthrough = (opts.shell == .auto or opts.shell == .zsh);
        const passthrough_ok = use_passthrough and
            CreatePseudoConsole(size, pty_in_read, pty_out_write, PSEUDOCONSOLE_PASSTHROUGH, &hpc) == S_OK;
        if (!passthrough_ok) {
            if (CreatePseudoConsole(size, pty_in_read, pty_out_write, 0, &hpc) != S_OK)
                return error.CreatePseudoConsoleFailed;
        }
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

        // Build the command line and set up shell integration.
        const cmd_line = buildCommandLine(opts) orelse return error.CommandLineFailed;
        if (!opts.skip_shell_integration) {
            win_shell.setupShellIntegration(cmd_line);
        }

        // Convert CWD to wide string if provided.
        // Buffer must outlive CreateProcessW — declare at function scope.
        var cwd_wide_buf: [std.fs.max_path_bytes]u16 = undefined;
        const cwd_wide: ?LPCWSTR = if (opts.cwd) |cwd_ptr| blk: {
            const cwd_slice = std.mem.span(cwd_ptr);
            const len = std.unicode.utf8ToUtf16Le(&cwd_wide_buf, cwd_slice) catch break :blk null;
            cwd_wide_buf[len] = 0;
            break :blk @ptrCast(cwd_wide_buf[0..len :0]);
        } else null;

        // Set ATTYX_PID so child shells can discover the IPC control pipe.
        {
            const pid = GetCurrentProcessId();
            var pid_buf: [16]u16 = undefined;
            var ascii_buf: [16]u8 = undefined;
            const ascii = std.fmt.bufPrint(&ascii_buf, "{d}", .{pid}) catch "";
            for (ascii, 0..) |ch, i| pid_buf[i] = ch;
            pid_buf[ascii.len] = 0;
            const env_name = comptime toUtf16Literal("ATTYX_PID");
            _ = SetEnvironmentVariableW(&env_name, pid_buf[0..ascii.len :0]);
        }

        // Inject attyx executable directory into PATH so child shells can use `attyx` CLI.
        win_shell.injectExeDirIntoPath();

        // MSYS2's fork() emulation needs an inheritable console. Without one
        // (Windows subsystem), each forked child allocates a new visible console
        // window causing flash. Allocate a hidden console so children inherit it.
        // Host processes skip this — ConPTY provides the shell's console context.
        if (!opts.skip_console_alloc) ensureHiddenConsole();

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

        var pty = Pty{
            .pipe_out_read = pty_out_read,
            .pipe_in_write = pty_in_write,
            .hpc = hpc,
            .process = pi.hProcess,
            .thread = INVALID_HANDLE, // thread handle already closed above
            .attr_list_buf = attr_buf,
            .allocator = allocator,
            .read_event = read_evt,
        };

        // Start first async read immediately — ConPTY only flushes output
        // to the pipe when a ReadFile is pending. Without this, fast shells
        // (cmd.exe, PowerShell) produce their banner before any read is
        // queued and ConPTY never flushes it, causing a blank screen.
        pty.startAsyncRead();

        return pty;
    }

    pub fn deinit(self: *Pty) void {
        // Inactive PTY (host-backed panes) — nothing to clean up.
        if (self.pipe_out_read == INVALID_HANDLE and self.pipe_in_write == INVALID_HANDLE) return;
        self.cancelAsyncRead();
        ClosePseudoConsole(self.hpc);
        _ = CloseHandle(self.pipe_out_read);
        _ = CloseHandle(self.pipe_in_write);
        _ = CloseHandle(self.process);
        if (self.read_event != INVALID_HANDLE) _ = CloseHandle(self.read_event);
        if (self.attr_list_buf.len > 0) {
            DeleteProcThreadAttributeList(@ptrCast(self.attr_list_buf.ptr));
            self.allocator.free(self.attr_list_buf);
        }
    }

    pub fn peekAvail(self: *Pty) usize {
        var avail: DWORD = 0;
        if (PeekNamedPipe(self.pipe_out_read, null, 0, null, &avail, null) == 0) return 0;
        return avail;
    }

    pub fn read(self: *Pty, buf: []u8) !usize {
        if (self.read_event == INVALID_HANDLE) {
            // Fallback: synchronous read (anonymous pipe).
            var bytes_read: DWORD = 0;
            if (ReadFile(self.pipe_out_read, buf.ptr, @intCast(buf.len), &bytes_read, null) == 0)
                return error.ReadFailed;
            return bytes_read;
        }

        // Overlapped handle: do an overlapped read that waits for completion.
        _ = ResetEvent(self.read_event);
        var overlapped = OVERLAPPED{ .hEvent = self.read_event };
        var bytes_read: DWORD = 0;

        if (ReadFile(self.pipe_out_read, buf.ptr, @intCast(buf.len), &bytes_read, @ptrCast(&overlapped)) != 0) {
            return bytes_read;
        }
        if (windows.kernel32.GetLastError() != .IO_PENDING) return error.ReadFailed;

        _ = WaitForSingleObject(self.read_event, INFINITE);
        if (GetOverlappedResult(self.pipe_out_read, &overlapped, &bytes_read, 0) != 0) {
            return bytes_read;
        }
        return error.ReadFailed;
    }

    /// Start an async read into the internal buffer if one isn't already pending.
    /// The pending read triggers ConPTY to flush its output buffer.
    pub fn startAsyncRead(self: *Pty) void {
        if (self.async_pending or self.read_event == INVALID_HANDLE) return;

        _ = ResetEvent(self.read_event);
        self.async_overlapped = OVERLAPPED{ .hEvent = self.read_event };

        var bytes_read: DWORD = 0;
        if (ReadFile(self.pipe_out_read, &self.async_buf, @intCast(self.async_buf.len), &bytes_read, @ptrCast(&self.async_overlapped)) != 0) {
            self.async_pending = true; // Sync completion — event is signaled, checkAsyncRead will pick it up.
            return;
        }
        if (windows.kernel32.GetLastError() == .IO_PENDING) {
            self.async_pending = true;
        }
    }

    /// Non-blocking check: did the pending async read complete?
    /// Returns the data slice if yes, null if still pending or no read active.
    pub fn checkAsyncRead(self: *Pty) ?[]u8 {
        if (!self.async_pending) return null;

        const wait = WaitForSingleObject(self.read_event, 0);
        if (wait != WAIT_OBJECT_0) return null; // Still pending.

        var bytes_read: DWORD = 0;
        self.async_pending = false;
        if (GetOverlappedResult(self.pipe_out_read, &self.async_overlapped, &bytes_read, 0) != 0 and bytes_read > 0) {
            return self.async_buf[0..bytes_read];
        }
        return null;
    }

    /// Cancel a pending async read (must be called before deinit or sync reads).
    pub fn cancelAsyncRead(self: *Pty) void {
        if (!self.async_pending) return;
        _ = CancelIo(self.pipe_out_read);
        var bytes_read: DWORD = 0;
        _ = GetOverlappedResult(self.pipe_out_read, &self.async_overlapped, &bytes_read, 1);
        self.async_pending = false;
    }

    pub fn writeToPty(self: *Pty, bytes: []const u8) !usize {
        var bytes_written: DWORD = 0;
        if (WriteFile(self.pipe_in_write, bytes.ptr, @intCast(bytes.len), &bytes_written, null) == 0)
            return error.WriteFailed;
        return bytes_written;
    }

    pub fn resize(self: *Pty, rows: u16, cols: u16) !void {
        if (self.pipe_out_read == INVALID_HANDLE) return; // Inactive PTY
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

/// Create a pipe pair where the read end supports overlapped I/O.
/// Returns read handle, write handle, and event for overlapped operations.
/// Uses a named pipe because CreatePipe doesn't support FILE_FLAG_OVERLAPPED.
fn createOverlappedOutputPipe() ?struct { read: HANDLE, write: HANDLE, event: HANDLE } {
    // Build unique pipe name using process ID and sequence counter.
    const pid = GetCurrentProcessId();
    const seq = blk: {
        const S = struct {
            var counter: u32 = 0;
        };
        break :blk @atomicRmw(u32, &S.counter, .Add, 1, .seq_cst);
    };

    var name_ascii: [128]u8 = undefined;
    const name_str = std.fmt.bufPrint(&name_ascii, "\\\\.\\pipe\\attyx-pty-{d}-{d}", .{ pid, seq }) catch return null;

    var name_wide: [128:0]u16 = undefined;
    for (name_str, 0..) |ch, i| name_wide[i] = ch;
    name_wide[name_str.len] = 0;
    const pipe_name: LPCWSTR = name_wide[0..name_str.len :0];

    // Server end: our read handle with overlapped support.
    const read_handle = CreateNamedPipeW(
        pipe_name,
        PIPE_ACCESS_INBOUND | FILE_FLAG_OVERLAPPED,
        PIPE_TYPE_BYTE_WAIT,
        1,
        0,
        65536,
        0,
        null,
    );
    if (read_handle == INVALID_HANDLE) return null;

    // Client end: ConPTY's write handle (synchronous is fine).
    const write_handle = CreateFileW(
        pipe_name,
        WIN_GENERIC_WRITE,
        0,
        null,
        OPEN_EXISTING,
        0,
        null,
    );
    if (write_handle == INVALID_HANDLE) {
        _ = CloseHandle(read_handle);
        return null;
    }

    // Manual-reset event for overlapped reads.
    // CreateEventW returns NULL on failure — compare via @intFromPtr since HANDLE is non-optional.
    const event = CreateEventW(null, 1, 0, null);
    if (@intFromPtr(event) == 0) {
        _ = CloseHandle(read_handle);
        _ = CloseHandle(write_handle);
        return null;
    }

    return .{ .read = read_handle, .write = write_handle, .event = event };
}

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
    const S = struct {
        var buf: [4096:0]u16 = undefined;
    };

    // If custom argv provided, join into a single command line.
    if (opts.argv) |argv| {
        if (argv.len == 0) return null;
        var pos: usize = 0;
        for (argv, 0..) |arg, i| {
            if (i > 0) {
                if (pos >= S.buf.len - 1) return null;
                S.buf[pos] = ' ';
                pos += 1;
            }
            for (arg) |ch| {
                if (pos >= S.buf.len - 1) return null;
                S.buf[pos] = ch;
                pos += 1;
            }
        }
        S.buf[pos] = 0;
        return &S.buf;
    }

    // Shell override — skip auto-detection and use the requested shell.
    switch (opts.shell) {
        .zsh => {
            if (bundled_shell.findBundledZsh()) |zsh| {
                bundled_shell.setupMsysEnv();
                @memcpy(S.buf[0..zsh.zsh_len], zsh.zsh_path[0..zsh.zsh_len]);
                S.buf[zsh.zsh_len] = 0;
                return &S.buf;
            }
            if (findGitBash(&S.buf)) |shell_len| {
                S.buf[shell_len] = 0;
                return &S.buf;
            }
        },
        .pwsh => {
            if (findOnPath("pwsh.exe", &S.buf)) |shell_len| {
                S.buf[shell_len] = 0;
                return &S.buf;
            }
            if (findOnPath("powershell.exe", &S.buf)) |shell_len| {
                S.buf[shell_len] = 0;
                return &S.buf;
            }
        },
        .cmd => {
            const cmd = comptime toUtf16Literal("cmd.exe");
            @memcpy(S.buf[0..cmd.len], &cmd);
            S.buf[cmd.len] = 0;
            return &S.buf;
        },
        .auto => {},
    }

    // Auto-detection: bundled zsh is the highest priority.
    // Return just the path; setupShellIntegration adds --login.
    if (bundled_shell.findBundledZsh()) |zsh| {
        bundled_shell.setupMsysEnv();
        @memcpy(S.buf[0..zsh.zsh_len], zsh.zsh_path[0..zsh.zsh_len]);
        S.buf[zsh.zsh_len] = 0;

        return &S.buf;
    }

    // Try Git Bash — best fallback terminal experience on Windows.
    if (findGitBash(&S.buf)) |shell_len| {
        S.buf[shell_len] = 0;

        return &S.buf;
    }

    // Try PowerShell: pwsh.exe (PS 7+), then powershell.exe (PS 5.1).
    if (findOnPath("pwsh.exe", &S.buf)) |shell_len| {
        S.buf[shell_len] = 0;

        return &S.buf;
    }
    if (findOnPath("powershell.exe", &S.buf)) |shell_len| {
        S.buf[shell_len] = 0;

        return &S.buf;
    }

    // Fallback to COMSPEC (usually cmd.exe).
    const comspec_name = comptime toUtf16Literal("COMSPEC");
    var comspec_buf: [1024]u16 = undefined;
    const comspec_len = GetEnvironmentVariableW(&comspec_name, &comspec_buf, @intCast(comspec_buf.len));

    if (comspec_len > 0 and comspec_len < comspec_buf.len) {
        @memcpy(S.buf[0..comspec_len], comspec_buf[0..comspec_len]);
        S.buf[comspec_len] = 0;
        return &S.buf;
    }

    // Last resort.
    const cmd = comptime toUtf16Literal("cmd.exe");
    @memcpy(S.buf[0..cmd.len], &cmd);
    S.buf[cmd.len] = 0;
    return &S.buf;
}

/// Search PATH for an executable. If found, writes the full path into
/// the provided buffer and returns the length. Uses SearchPathW which
/// checks the system directories and PATH.
fn findOnPath(comptime name: []const u8, buf: *[4096:0]u16) ?usize {
    const name_w = comptime toUtf16Literal(name);
    var file_part: ?[*]u16 = null;
    const len = SearchPathW(null, &name_w, null, @intCast(buf.len), buf, &file_part);
    if (len > 0 and len < buf.len) return len;
    return null;
}

/// Resolve Git Bash path as a UTF-8 string. Returns a static slice or null.
/// Used by popup spawn to get the full path for "bash" commands.
pub fn findGitBashUtf8() ?[]const u8 {
    const S = struct {
        var utf8_buf: [1024]u8 = undefined;
    };
    var wide_buf: [4096:0]u16 = undefined;
    const wide_len = findGitBash(&wide_buf) orelse return null;
    var utf8_len: usize = 0;
    for (wide_buf[0..wide_len]) |cp| {
        const n = std.unicode.utf8Encode(@intCast(cp), S.utf8_buf[utf8_len..]) catch return null;
        utf8_len += n;
    }
    return S.utf8_buf[0..utf8_len];
}

/// Find Git Bash by checking GIT_INSTALL_ROOT env var and standard
/// Git for Windows install locations. We don't use SearchPathW("bash.exe")
/// because Windows 10+ has a WSL bash.exe in System32.
fn findGitBash(buf: *[4096:0]u16) ?usize {
    // Try GIT_INSTALL_ROOT env var first.
    const git_root_name = comptime toUtf16Literal("GIT_INSTALL_ROOT");
    var git_root: [1024]u16 = undefined;
    const git_root_len = GetEnvironmentVariableW(&git_root_name, &git_root, @intCast(git_root.len));

    if (git_root_len > 0 and git_root_len < git_root.len) {
        const suffix = comptime toUtf16Literal("\\bin\\bash.exe");
        const total = git_root_len + suffix.len;
        if (total < buf.len) {
            @memcpy(buf[0..git_root_len], git_root[0..git_root_len]);
            @memcpy(buf[git_root_len..total], &suffix);
            buf[total] = 0;
            if (GetFileAttributesW(buf) != INVALID_FILE_ATTRIBUTES) return total;
        }
    }

    // Try standard install locations.
    return tryGitBashPath(buf, "C:\\Program Files\\Git\\bin\\bash.exe") orelse
        tryGitBashPath(buf, "C:\\Program Files (x86)\\Git\\bin\\bash.exe");
}

fn tryGitBashPath(buf: *[4096:0]u16, comptime path: []const u8) ?usize {
    const wide = comptime toUtf16Literal(path);
    @memcpy(buf[0..wide.len], &wide);
    buf[wide.len] = 0;
    if (GetFileAttributesW(buf) != INVALID_FILE_ATTRIBUTES) return wide.len;
    return null;
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
