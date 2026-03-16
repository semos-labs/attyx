/// Connection helpers for the session daemon client.
/// Extracted from session_client.zig to reduce file size.
///
/// On POSIX: uses Unix domain sockets.
/// On Windows: uses named pipes.
const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const is_posix = !is_windows;
const protocol = @import("daemon/protocol.zig");
const platform = @import("../platform/platform.zig");
const spawn = @import("spawn.zig");
const logging = @import("../logging/log.zig");

/// Direct debug print to a file — works even when stderr is detached.
fn dbg(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[session_connect] " ++ fmt ++ "\n", args) catch return;
    // Write to a known debug log file in the state directory.
    var path_buf: [256]u8 = undefined;
    const path = statePath(&path_buf, "session-debug{s}.log") orelse return;
    const file = std.fs.createFileAbsolute(path, .{ .truncate = false }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch {};
    file.writeAll(msg) catch {};
}

// Windows API imports — only resolved when targeting Windows.
const win32 = if (is_windows) struct {
    const windows = std.os.windows;
    const HANDLE = windows.HANDLE;
    const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
    const DWORD = windows.DWORD;
    const BOOL = windows.BOOL;
    const LPCWSTR = [*:0]const u16;

    const GENERIC_READ: DWORD = 0x80000000;
    const GENERIC_WRITE: DWORD = 0x40000000;
    const OPEN_EXISTING: DWORD = 3;
    const FILE_ATTRIBUTE_NORMAL: DWORD = 0x00000080;
    const ERROR_PIPE_BUSY: DWORD = 231;

    extern "kernel32" fn CreateFileW(
        lpFileName: LPCWSTR,
        dwDesiredAccess: DWORD,
        dwShareMode: DWORD,
        lpSecurityAttributes: ?*const anyopaque,
        dwCreationDisposition: DWORD,
        dwFlagsAndAttributes: DWORD,
        hTemplateFile: ?HANDLE,
    ) callconv(.winapi) HANDLE;
    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn GetModuleFileNameW(hModule: ?HANDLE, lpFilename: [*]u16, nSize: DWORD) callconv(.winapi) DWORD;
    extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;
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
    extern "kernel32" fn PeekNamedPipe(
        hNamedPipe: HANDLE,
        lpBuffer: ?[*]u8,
        nBufferSize: DWORD,
        lpBytesRead: ?*DWORD,
        lpTotalBytesAvail: ?*DWORD,
        lpBytesLeftThisMessage: ?*DWORD,
    ) callconv(.winapi) BOOL;

    fn toWide(comptime s: []const u8) [s.len:0]u16 {
        comptime {
            var result: [s.len:0]u16 = undefined;
            for (s, 0..) |c, i| result[i] = c;
            return result;
        }
    }
} else struct {};

// POSIX-only extern declarations.
const posix_ffi = if (is_posix) struct {
    extern "c" fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;
    extern "c" fn readlink(path: [*:0]const u8, b: [*]u8, bufsiz: usize) isize;
} else struct {};

/// Cross-platform getenv — returns a slice or null.
fn getEnv(key: []const u8) ?[]const u8 {
    if (comptime is_windows) {
        // On Windows, std.posix.getenv is a @compileError.
        // Use a static buffer for the result. Not thread-safe but matches
        // POSIX getenv semantics (returns pointer to internal storage).
        const S = struct {
            var buf: [4096]u8 = undefined;
        };
        const val = std.process.getEnvVarOwned(std.heap.page_allocator, key) catch return null;
        if (val.len >= S.buf.len) {
            std.heap.page_allocator.free(val);
            return null;
        }
        @memcpy(S.buf[0..val.len], val);
        std.heap.page_allocator.free(val);
        return S.buf[0..val.len];
    } else {
        return std.posix.getenv(key);
    }
}

pub fn connectToSocket() !std.posix.fd_t {
    if (comptime is_windows) return connectToSocketWindows();

    const posix = std.posix;
    var path_buf: [256]u8 = undefined;
    const socket_path = getSocketPath(&path_buf) orelse return error.NoHome;

    // First attempt — connect and verify the daemon is alive
    if (tryConnect(socket_path)) |fd| {
        if (probeAlive(fd)) return fd;
        posix.close(fd);
    }

    // If upgrade.bin exists, a hot-upgrade is in progress — do NOT start a
    // competing daemon.  Wait for the new daemon to come up instead.
    if (isUpgradeInProgress()) {
        var delay_ns: u64 = 100_000_000;
        for (0..100) |_| { // up to ~20s total
            posix.nanosleep(0, delay_ns);
            if (tryConnect(socket_path)) |fd| return fd;
            if (delay_ns < 200_000_000) delay_ns *= 2;
            // Check if upgrade finished (file deleted)
            if (!isUpgradeInProgress()) break;
        }
        // Upgrade may have finished — try one more connect, then fall through
        // to normal startup if the new daemon is up.
        if (tryConnect(socket_path)) |fd| return fd;
    }

    // Remove stale socket file before starting daemon.
    std.fs.deleteFileAbsolute(socket_path) catch {};

    // Auto-start daemon
    try startDaemon();

    // Retry with backoff: 100ms, 200ms, 400ms, 800ms, 1600ms (total ~3.1s)
    var delay_ns: u64 = 100_000_000;
    for (0..5) |_| {
        posix.nanosleep(0, delay_ns);
        if (tryConnect(socket_path)) |fd| return fd;
        delay_ns *= 2;
    }

    return error.DaemonConnectFailed;
}

// ── Windows named pipe connection ──

fn connectToSocketWindows() !std.posix.fd_t {
    if (comptime !is_windows) unreachable;

    var path_buf: [256]u8 = undefined;
    const pipe_path = getSocketPath(&path_buf) orelse return error.NoHome;

    dbg("connecting to daemon pipe: {s}", .{pipe_path});

    // Try connecting directly — each CreateFileW on a named pipe gives a
    // fresh connection with no stale data, so no probe needed.
    if (tryConnectWindows(pipe_path)) |h| {
        dbg("connected to existing daemon", .{});
        return h;
    }
    dbg("no existing daemon pipe found", .{});

    if (isUpgradeInProgress()) {
        var delay_ms: u32 = 100;
        for (0..100) |_| {
            win32.Sleep(delay_ms);
            if (tryConnectWindows(pipe_path)) |h| return h;
            if (delay_ms < 200) delay_ms *= 2;
            if (!isUpgradeInProgress()) break;
        }
        if (tryConnectWindows(pipe_path)) |h| return h;
    }

    try startDaemon();

    var delay_ms: u32 = 100;
    for (0..5) |attempt| {
        win32.Sleep(delay_ms);
        if (tryConnectWindows(pipe_path)) |h| {
            dbg("connected to daemon after spawn", .{});
            return h;
        }
        dbg("retry {d}/5 failed, delay={d}ms", .{ attempt + 1, delay_ms });
        delay_ms *= 2;
    }

    dbg("daemon connect FAILED after 5 retries", .{});
    return error.DaemonConnectFailed;
}

pub fn tryConnectWindows(path: []const u8) ?std.posix.fd_t {
    if (comptime !is_windows) return null;
    var wide_buf: [256]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wide_buf, path) catch return null;
    wide_buf[wlen] = 0;
    const wide: win32.LPCWSTR = @ptrCast(wide_buf[0..wlen :0]);
    const h = win32.CreateFileW(
        wide,
        win32.GENERIC_READ | win32.GENERIC_WRITE,
        0,
        null,
        win32.OPEN_EXISTING,
        win32.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (h == win32.INVALID_HANDLE_VALUE) return null;
    return h;
}

fn probeAliveWindows(handle: std.posix.fd_t) bool {
    if (comptime !is_windows) return false;
    var buf: [protocol.header_size]u8 = undefined;
    protocol.encodeHeader(&buf, .list, 0);
    var written: win32.DWORD = 0;
    if (win32.WriteFile(handle, &buf, protocol.header_size, &written, null) == 0) return false;
    // Wait up to 500ms for a response
    for (0..50) |_| {
        var avail: win32.DWORD = 0;
        if (win32.PeekNamedPipe(handle, null, 0, null, &avail, null) == 0) return false;
        if (avail > 0) return true;
        win32.Sleep(10);
    }
    return false;
}

/// Close a daemon connection handle (cross-platform).
pub fn closeHandle(fd: std.posix.fd_t) void {
    if (comptime is_windows) {
        _ = win32.CloseHandle(fd);
    } else {
        std.posix.close(fd);
    }
}

/// Check whether upgrade.bin exists, indicating a hot-upgrade is in progress.
pub fn isUpgradeInProgress() bool {
    var ubuf: [256]u8 = undefined;
    const upath = statePath(&ubuf, "upgrade{s}.bin") orelse return false;
    std.fs.accessAbsolute(upath, .{}) catch return false;
    return true;
}

/// Build a path under the attyx state directory.
/// POSIX: XDG_STATE_HOME or ~/.local/state/attyx.
/// Windows: %LOCALAPPDATA%\attyx (Phase 1+).
/// `name` must contain one `{s}` placeholder for the dev-mode suffix.
pub fn statePath(buf: []u8, comptime name: []const u8) ?[]const u8 {
    const suffix = if (comptime @import("builtin").mode == .Debug) "-dev" else "";
    if (comptime is_windows) {
        const appdata = getEnv("LOCALAPPDATA") orelse return null;
        return std.fmt.bufPrint(buf, "{s}\\attyx\\" ++ name, .{ appdata, suffix }) catch null;
    }
    if (getEnv("XDG_STATE_HOME")) |sh| {
        if (sh.len > 0)
            return std.fmt.bufPrint(buf, "{s}/attyx/" ++ name, .{ sh, suffix }) catch null;
    }
    const home = getEnv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/state/attyx/" ++ name, .{ home, suffix }) catch null;
}

pub fn getSocketPath(buf: *[256]u8) ?[]const u8 {
    if (comptime is_windows) {
        // Windows named pipe path (Phase 1+)
        const suffix = if (comptime @import("builtin").mode == .Debug) "-dev" else "";
        return std.fmt.bufPrint(buf, "\\\\.\\pipe\\attyx-sessions{s}", .{suffix}) catch null;
    }
    return statePath(buf, "sessions{s}.sock");
}

/// Return the attyx state directory path (with trailing slash/backslash).
pub fn stateDir(buf: []u8) ?[]const u8 {
    if (comptime is_windows) {
        const appdata = getEnv("LOCALAPPDATA") orelse return null;
        return std.fmt.bufPrint(buf, "{s}\\attyx\\", .{appdata}) catch null;
    }
    if (getEnv("XDG_STATE_HOME")) |sh| {
        if (sh.len > 0)
            return std.fmt.bufPrint(buf, "{s}/attyx/", .{sh}) catch null;
    }
    const home = getEnv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/state/attyx/", .{home}) catch null;
}

fn probeAlive(fd: std.posix.fd_t) bool {
    const posix = std.posix;
    var buf: [protocol.header_size]u8 = undefined;
    protocol.encodeHeader(&buf, .list, 0);
    _ = posix.write(fd, &buf) catch return false;
    var fds = [1]posix.pollfd{.{ .fd = fd, .events = 0x0001, .revents = 0 }};
    _ = posix.poll(&fds, 500) catch return false;
    if (fds[0].revents & (0x0010 | 0x0008) != 0) return false;
    if (fds[0].revents & 0x0001 != 0) return true;
    return false;
}

pub fn tryConnect(path: []const u8) ?std.posix.fd_t {
    const posix = std.posix;
    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return null;
    const addr = std.net.Address.initUnix(path) catch {
        posix.close(fd);
        return null;
    };
    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch {
        posix.close(fd);
        return null;
    };
    return fd;
}

fn startDaemon() !void {
    var exe_buf: [1024]u8 = undefined;
    const exe = getExePath(&exe_buf) orelse if (comptime is_windows) "attyx.exe" else "/usr/local/bin/attyx";
    var exe_z_buf: [1024]u8 = undefined;
    const exe_z: [*:0]const u8 = std.fmt.bufPrintZ(&exe_z_buf, "{s}", .{exe}) catch return error.SpawnFailed;

    dbg("starting daemon: {s}", .{std.mem.sliceTo(exe_z, 0)});

    const daemon_str: [*:0]const u8 = "daemon";
    const argv: [3:null]?[*:0]const u8 = .{ exe_z, daemon_str, null };

    // posix_spawn instead of fork+exec — safe in multithreaded processes.
    const result = spawn.spawnp(exe_z, &argv, true);
    if (!result.ok) {
        dbg("CreateProcessW FAILED for daemon", .{});
        return error.SpawnFailed;
    }
    dbg("daemon spawned with pid {d}", .{result.pid});
}

pub fn getExePath(buf: *[1024]u8) ?[]const u8 {
    if (comptime builtin.os.tag == .macos) {
        var size: u32 = buf.len;
        if (posix_ffi._NSGetExecutablePath(buf, &size) == 0) {
            return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(buf)), 0);
        }
    } else if (comptime is_windows) {
        var wide_buf: [512]u16 = undefined;
        const len = win32.GetModuleFileNameW(null, &wide_buf, wide_buf.len);
        if (len == 0 or len >= wide_buf.len) return null;
        const utf8_len = std.unicode.utf16LeToUtf8(buf, wide_buf[0..len]) catch return null;
        return buf[0..utf8_len];
    } else {
        const n = posix_ffi.readlink("/proc/self/exe", buf, buf.len);
        if (n > 0) return buf[0..@intCast(n)];
    }
    return null;
}

pub fn getLastSessionPath(buf: *[256]u8) ?[]const u8 {
    return statePath(buf, "last-session{s}");
}

pub fn saveLastSession(session_id: u32) void {
    var path_buf: [256]u8 = undefined;
    const path = getLastSessionPath(&path_buf) orelse return;
    var id_buf: [16]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{session_id}) catch return;
    const file = std.fs.createFileAbsolute(path, .{}) catch return;
    defer file.close();
    file.writeAll(id_str) catch {};
}

pub fn loadLastSession() ?u32 {
    var path_buf: [256]u8 = undefined;
    const path = getLastSessionPath(&path_buf) orelse return null;
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    var buf: [16]u8 = undefined;
    const n = file.read(&buf) catch return null;
    if (n == 0) return null;
    return std.fmt.parseInt(u32, buf[0..n], 10) catch null;
}

// ── One-time migration: move runtime files from config dir to state dir ──

/// Migrate runtime files from ~/.config/attyx/ to the XDG state directory.
/// Idempotent — silently skips files that don't exist or already moved.
/// No-op on Windows (no legacy paths to migrate).
pub fn migrateToStateDir() void {
    if (comptime is_windows) return;
    // Only release builds migrate — dev builds must not move files
    // that the production app still expects in the old location.
    if (comptime @import("builtin").mode == .Debug) return;

    const home = std.posix.getenv("HOME") orelse return;
    const suffix = if (comptime @import("builtin").mode == .Debug) "-dev" else "";

    // Old location: config dir
    var old_buf: [256]u8 = undefined;
    const old_dir = blk: {
        const xdg = std.posix.getenv("XDG_CONFIG_HOME") orelse "";
        if (xdg.len > 0)
            break :blk std.fmt.bufPrint(&old_buf, "{s}/attyx", .{xdg}) catch return;
        break :blk std.fmt.bufPrint(&old_buf, "{s}/.config/attyx", .{home}) catch return;
    };

    // New location: state dir
    var new_buf: [256]u8 = undefined;
    const new_dir = blk: {
        const xdg = std.posix.getenv("XDG_STATE_HOME") orelse "";
        if (xdg.len > 0)
            break :blk std.fmt.bufPrint(&new_buf, "{s}/attyx", .{xdg}) catch return;
        break :blk std.fmt.bufPrint(&new_buf, "{s}/.local/state/attyx", .{home}) catch return;
    };

    // Ensure state dir exists (create parent + dir)
    if (std.mem.lastIndexOfScalar(u8, new_dir, '/')) |i| {
        std.fs.makeDirAbsolute(new_dir[0..i]) catch {};
    }
    std.fs.makeDirAbsolute(new_dir) catch {};

    // Move each runtime file
    const files = [_][]const u8{
        "sessions" ++ suffix ++ ".sock",
        "last-session" ++ suffix,
        "daemon" ++ suffix ++ ".version",
        "upgrade" ++ suffix ++ ".bin",
        "auth.json",
    };
    for (files) |name| {
        moveFile(old_dir, new_dir, name);
    }

    // macOS: also migrate recent.json from ~/Library/Application Support/attyx/
    if (comptime @import("builtin").os.tag == .macos) {
        var macos_buf: [512]u8 = undefined;
        const macos_dir = std.fmt.bufPrint(&macos_buf, "{s}/Library/Application Support/attyx", .{home}) catch return;
        moveFile(macos_dir, new_dir, "recent" ++ suffix ++ ".json");
    }
}

fn moveFile(old_dir: []const u8, new_dir: []const u8, name: []const u8) void {
    var src_buf: [512]u8 = undefined;
    var dst_buf: [512]u8 = undefined;
    const src = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ old_dir, name }) catch return;
    const dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ new_dir, name }) catch return;
    std.fs.renameAbsolute(src, dst) catch {};
}

/// Set a file descriptor to non-blocking mode. POSIX only.
pub fn setNonBlocking(fd: std.posix.fd_t) void {
    if (comptime is_windows) return; // Windows handles don't use fcntl
    const F_GETFL: i32 = 3;
    const F_SETFL: i32 = 4;
    const flags = std.posix.fcntl(fd, F_GETFL, 0) catch return;
    _ = std.posix.fcntl(fd, F_SETFL, flags | platform.O_NONBLOCK) catch {};
}
