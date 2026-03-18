/// Cross-platform process spawning, safe in multithreaded programs.
///
/// On POSIX: uses posix_spawnp to avoid fork() atfork handler issues.
/// On Windows: uses CreateProcessW (Phase 1+, currently stubs).
const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

// ── POSIX implementation ──

// On Linux, Zig std doesn't expose posix_spawn, so we declare it here.
// On macOS, we use std.c.posix_spawnp (declared in std/c/darwin.zig).
const linux_ffi = if (!is_windows and !builtin.os.tag.isDarwin()) struct {
    extern "c" fn posix_spawnp(
        pid: *std.c.pid_t,
        file: [*:0]const u8,
        file_actions: ?*anyopaque,
        attrp: ?*anyopaque,
        argv: [*:null]const ?[*:0]const u8,
        envp: [*:null]const ?[*:0]const u8,
    ) c_int;
} else struct {};

pub const PidType = if (is_windows) u32 else std.c.pid_t;

pub const SpawnResult = struct {
    pid: PidType,
    ok: bool,
};

/// Spawn a process using posix_spawnp (POSIX) or CreateProcessW (Windows).
/// Returns the child PID on success.
/// If `setsid` is true, the child gets its own session (POSIX only).
pub fn spawnp(
    file: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    setsid_flag: bool,
) SpawnResult {
    if (comptime is_windows) {
        return spawnWindows(file, argv);
    }
    return spawnpEnv(file, argv, setsid_flag, std.c.environ);
}

/// Like spawnp but with a custom environment. POSIX only.
pub fn spawnpEnv(
    file: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    setsid_flag: bool,
    envp: [*:null]const ?[*:0]const u8,
) SpawnResult {
    if (comptime is_windows) return spawnWindows(file, argv);
    if (comptime builtin.os.tag.isDarwin()) {
        const c = std.c;
        var attr: c.posix_spawnattr_t = undefined;
        if (c.posix_spawnattr_init(&attr) != 0) return .{ .pid = 0, .ok = false };
        defer _ = c.posix_spawnattr_destroy(&attr);

        if (setsid_flag) {
            if (c.posix_spawnattr_setflags(&attr, c.POSIX_SPAWN.SETSID) != 0)
                return .{ .pid = 0, .ok = false };
        }

        var pid: c.pid_t = 0;
        if (c.posix_spawnp(&pid, file, null, &attr, argv, envp) != 0)
            return .{ .pid = 0, .ok = false };
        return .{ .pid = pid, .ok = true };
    } else {
        var pid: std.c.pid_t = 0;
        if (linux_ffi.posix_spawnp(&pid, file, null, null, argv, envp) != 0)
            return .{ .pid = 0, .ok = false };
        return .{ .pid = pid, .ok = true };
    }
}

/// Windows process spawn via CreateProcessW with DETACHED_PROCESS.
/// Creates the child suspended, assigns it to a new unrestricted Job object
/// (so it's removed from the parent's kill-on-close Job), then resumes.
fn spawnWindows(
    file: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
) SpawnResult {
    if (comptime !is_windows) return .{ .pid = 0, .ok = false };

    const win = struct {
        const HANDLE = std.os.windows.HANDLE;
        const DWORD = std.os.windows.DWORD;
        const BOOL = std.os.windows.BOOL;
        const LPCWSTR = [*:0]const u16;
        const LPVOID = std.os.windows.LPVOID;
        const WORD = u16;
        const BYTE = u8;

        const DETACHED_PROCESS: DWORD = 0x00000008;
        const CREATE_BREAKAWAY_FROM_JOB: DWORD = 0x01000000;
        const CREATE_NEW_PROCESS_GROUP: DWORD = 0x00000200;
        const CREATE_SUSPENDED: DWORD = 0x00000004;

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

        const PROCESS_INFORMATION = extern struct {
            hProcess: HANDLE,
            hThread: HANDLE,
            dwProcessId: DWORD,
            dwThreadId: DWORD,
        };

        // JOBOBJECT_EXTENDED_LIMIT_INFORMATION for SetInformationJobObject
        const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
            PerProcessUserTimeLimit: i64,
            PerJobUserTimeLimit: i64,
            LimitFlags: DWORD,
            MinimumWorkingSetSize: usize,
            MaximumWorkingSetSize: usize,
            ActiveProcessLimit: DWORD,
            Affinity: usize,
            PriorityClass: DWORD,
            SchedulingClass: DWORD,
        };

        const IO_COUNTERS = extern struct {
            ReadOperationCount: u64,
            WriteOperationCount: u64,
            OtherOperationCount: u64,
            ReadTransferCount: u64,
            WriteTransferCount: u64,
            OtherTransferCount: u64,
        };

        const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
            BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
            IoInfo: IO_COUNTERS,
            ProcessMemoryLimit: usize,
            JobMemoryLimit: usize,
            PeakProcessMemoryUsed: usize,
            PeakJobMemoryUsed: usize,
        };

        const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: DWORD = 0x00002000;
        const JOB_OBJECT_LIMIT_BREAKAWAY_OK: DWORD = 0x00000800;
        const JobObjectExtendedLimitInformation: c_int = 9;

        extern "kernel32" fn CreateProcessW(
            lpApplicationName: ?LPCWSTR,
            lpCommandLine: ?[*:0]u16,
            lpProcessAttributes: ?*const anyopaque,
            lpThreadAttributes: ?*const anyopaque,
            bInheritHandles: BOOL,
            dwCreationFlags: DWORD,
            lpEnvironment: ?LPVOID,
            lpCurrentDirectory: ?LPCWSTR,
            lpStartupInfo: *STARTUPINFOW,
            lpProcessInformation: *PROCESS_INFORMATION,
        ) callconv(.winapi) BOOL;
        extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
        extern "kernel32" fn ResumeThread(hThread: HANDLE) callconv(.winapi) DWORD;
        extern "kernel32" fn CreateJobObjectW(lpJobAttributes: ?*const anyopaque, lpName: ?LPCWSTR) callconv(.winapi) ?HANDLE;
        extern "kernel32" fn SetInformationJobObject(hJob: HANDLE, JobObjectInformationClass: c_int, lpJobObjectInformation: *const anyopaque, cbJobObjectInformationLength: DWORD) callconv(.winapi) BOOL;
        extern "kernel32" fn AssignProcessToJobObject(hJob: HANDLE, hProcess: HANDLE) callconv(.winapi) BOOL;
    };

    // Build command line from argv: "exe_path" arg1 arg2 ...
    const file_slice = std.mem.sliceTo(file, 0);
    var cmd_buf: [4096]u16 = undefined;
    cmd_buf[0] = '"';
    const exe_len = std.unicode.utf8ToUtf16Le(cmd_buf[1..], file_slice) catch return .{ .pid = 0, .ok = false };
    var pos: usize = 1 + exe_len;
    cmd_buf[pos] = '"';
    pos += 1;
    // Append remaining argv entries (skip argv[0] which is the exe)
    var ai: usize = 1;
    while (argv[ai]) |arg| : (ai += 1) {
        if (pos + 1 >= cmd_buf.len) break;
        cmd_buf[pos] = ' ';
        pos += 1;
        const arg_slice = std.mem.sliceTo(arg, 0);
        const arg_len = std.unicode.utf8ToUtf16Le(cmd_buf[pos..], arg_slice) catch break;
        pos += arg_len;
    }
    cmd_buf[pos] = 0;

    var si = std.mem.zeroes(win.STARTUPINFOW);
    si.cb = @sizeOf(win.STARTUPINFOW);

    var pi: win.PROCESS_INFORMATION = undefined;

    // Strategy: create the child SUSPENDED + DETACHED, assign it to a new
    // unrestricted Job (which removes it from the parent's kill-on-close Job),
    // then resume. If breakaway is allowed we try that first (simpler path).
    const flags_breakaway = win.DETACHED_PROCESS | win.CREATE_BREAKAWAY_FROM_JOB | win.CREATE_NEW_PROCESS_GROUP;
    const flags_suspended = win.DETACHED_PROCESS | win.CREATE_SUSPENDED | win.CREATE_NEW_PROCESS_GROUP;

    var used_suspended = false;
    if (win.CreateProcessW(null, @ptrCast(&cmd_buf), null, null, 0, flags_breakaway, null, null, &si, &pi) == 0) {
        // Breakaway not allowed — create suspended and reassign Job.
        if (win.CreateProcessW(null, @ptrCast(&cmd_buf), null, null, 0, flags_suspended, null, null, &si, &pi) == 0)
            return .{ .pid = 0, .ok = false };
        used_suspended = true;
    }

    if (used_suspended) {
        // Create a new Job object that does NOT kill children on close.
        // Assigning the suspended process to this Job removes it from
        // the parent's implicit kill-on-close Job (Windows 8+).
        if (win.CreateJobObjectW(null, null)) |job| {
            var info = std.mem.zeroes(win.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
            // Explicitly do NOT set JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE.
            // Set BREAKAWAY_OK so grandchildren can also escape if needed.
            info.BasicLimitInformation.LimitFlags = win.JOB_OBJECT_LIMIT_BREAKAWAY_OK;
            _ = win.SetInformationJobObject(
                job,
                win.JobObjectExtendedLimitInformation,
                @ptrCast(&info),
                @sizeOf(win.JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
            );
            _ = win.AssignProcessToJobObject(job, pi.hProcess);
            // Don't close Job handle — it must stay alive while the daemon runs.
            // The handle is leaked intentionally (one per daemon lifetime).
        }
        _ = win.ResumeThread(pi.hThread);
    }

    // Close handles — the daemon runs independently.
    _ = win.CloseHandle(pi.hProcess);
    _ = win.CloseHandle(pi.hThread);
    return .{ .pid = pi.dwProcessId, .ok = true };
}

/// Spawn a detached thread that waits for `pid` to exit, preventing zombies.
/// On Windows, process handles are closed by the caller; this is a no-op.
pub fn reapAsync(pid: PidType) void {
    if (comptime is_windows) return;
    _ = std.Thread.spawn(.{}, reapChild, .{pid}) catch {};
}

fn reapChild(pid: std.c.pid_t) void {
    _ = std.c.waitpid(pid, null, 0);
}

// ── Environment helpers (POSIX only) ──

const posix_env = if (!is_windows) struct {
    extern "c" fn getuid() c_uint;
    extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
} else struct {};

/// Build a copy of environ with TMUX auto-detected and injected.
/// Returns null if TMUX is already set or detection fails.
/// Caller must free with `freeEnvp`. POSIX only — always returns null on Windows.
pub fn buildEnvWithTmux(allocator: std.mem.Allocator) ?[*:null]const ?[*:0]const u8 {
    if (comptime is_windows) return null;

    if (posix_env.getenv("TMUX") != null) return null;

    const uid = posix_env.getuid();
    const base = posix_env.getenv("TMUX_TMPDIR") orelse "/tmp";
    var socket_buf: [256]u8 = undefined;
    const sp = std.fmt.bufPrintZ(&socket_buf, "{s}/tmux-{d}/default", .{ base, uid }) catch return null;
    if (posix_env.access(sp, 0) != 0) return null;

    var tmux_env_buf: [512]u8 = undefined;
    const tmux_val = std.fmt.bufPrintZ(&tmux_env_buf, "TMUX={s},0,0", .{sp}) catch return null;

    // Count existing env entries
    var count: usize = 0;
    const env = std.c.environ;
    while (env[count] != null) : (count += 1) {}

    // Allocate new envp: existing + TMUX + sentinel
    const new_envp = allocator.alloc(?[*:0]const u8, count + 2) catch return null;
    for (0..count) |i| new_envp[i] = env[i];
    new_envp[count] = @ptrCast(allocator.dupeZ(u8, tmux_val) catch {
        allocator.free(new_envp);
        return null;
    });
    new_envp[count + 1] = null;
    return @ptrCast(new_envp.ptr);
}

/// Free an envp allocated by `buildEnvWithTmux`.
pub fn freeEnvp(allocator: std.mem.Allocator, envp: [*:null]const ?[*:0]const u8) void {
    if (comptime is_windows) return;
    var count: usize = 0;
    while (envp[count] != null) : (count += 1) {}
    if (count > 0) {
        const tmux_entry = envp[count - 1].?;
        const len = std.mem.len(tmux_entry);
        allocator.free(tmux_entry[0 .. len + 1]);
    }
    const slice: []const ?[*:0]const u8 = @as([*]const ?[*:0]const u8, @ptrCast(envp))[0 .. count + 1];
    allocator.free(slice);
}
