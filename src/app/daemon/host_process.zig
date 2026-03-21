/// Per-pane host process: owns ConPTY + shell, communicates with daemon via named pipe.
///
/// Invoked as: attyx.exe --host <pane_id> --shell <auto|zsh|pwsh|cmd> --rows <N> --cols <N>
///             [--cwd <path>] [--startup-cmd <cmd>] [--capture-stdout]
///
/// The host creates a named pipe server, spawns the shell via ConPTY, and relays
/// I/O between the daemon and ConPTY. On daemon disconnect (upgrade), the host
/// buffers ConPTY output in a ring buffer and waits for a new daemon to reconnect.
const std = @import("std");
const attyx = @import("attyx");
const Pty = @import("../pty_windows.zig").Pty;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;
const host_pipe = @import("host_pipe.zig");
const session_connect = @import("../session_connect.zig");

const FrameType = host_pipe.FrameType;

const windows = std.os.windows;
const HANDLE = windows.HANDLE;
const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
const LPCWSTR = [*:0]const u16;

extern "kernel32" fn CreateNamedPipeW(
    lpName: LPCWSTR,
    dwOpenMode: DWORD,
    dwPipeMode: DWORD,
    nMaxInstances: DWORD,
    nOutBufferSize: DWORD,
    nInBufferSize: DWORD,
    nDefaultTimeOut: DWORD,
    lpSecurityAttributes: ?*const anyopaque,
) callconv(.winapi) HANDLE;

extern "kernel32" fn ConnectNamedPipe(hNamedPipe: HANDLE, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn DisconnectNamedPipe(hNamedPipe: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

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

extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetExitCodeProcess(h: HANDLE, code: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: c_uint) callconv(.winapi) BOOL;

const PIPE_ACCESS_DUPLEX: DWORD = 0x00000003;
const PIPE_TYPE_BYTE: DWORD = 0x00000000;
const PIPE_READMODE_BYTE: DWORD = 0x00000000;
const PIPE_WAIT: DWORD = 0x00000000;
const ERROR_PIPE_CONNECTED: DWORD = 535;
const WAIT_OBJECT_0: DWORD = 0;
const STILL_ACTIVE: DWORD = 259;
const S_OK: c_long = 0;

// ── CLI args ──

pub const HostArgs = struct {
    pane_id: u32,
    shell: Pty.ShellType = .auto,
    rows: u16 = 24,
    cols: u16 = 80,
    cwd: ?[*:0]const u8 = null,
    startup_cmd: ?[*:0]const u8 = null,
    capture_stdout: bool = false,
};

pub fn parseHostArgs(args: []const [:0]const u8) ?HostArgs {
    var result = HostArgs{ .pane_id = 0 };
    var got_pane_id = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= args.len) return null;
            result.pane_id = std.fmt.parseInt(u32, args[i], 10) catch return null;
            got_pane_id = true;
        } else if (std.mem.eql(u8, arg, "--shell")) {
            i += 1;
            if (i >= args.len) return null;
            const s = args[i];
            if (std.mem.eql(u8, s, "auto")) {
                result.shell = .auto;
            } else if (std.mem.eql(u8, s, "zsh")) {
                result.shell = .zsh;
            } else if (std.mem.eql(u8, s, "pwsh")) {
                result.shell = .pwsh;
            } else if (std.mem.eql(u8, s, "cmd")) {
                result.shell = .cmd;
            } else if (std.mem.eql(u8, s, "wsl")) {
                result.shell = .wsl;
            }
        } else if (std.mem.eql(u8, arg, "--rows")) {
            i += 1;
            if (i >= args.len) return null;
            result.rows = std.fmt.parseInt(u16, args[i], 10) catch 24;
        } else if (std.mem.eql(u8, arg, "--cols")) {
            i += 1;
            if (i >= args.len) return null;
            result.cols = std.fmt.parseInt(u16, args[i], 10) catch 80;
        } else if (std.mem.eql(u8, arg, "--cwd")) {
            i += 1;
            if (i >= args.len) return null;
            result.cwd = args[i];
        } else if (std.mem.eql(u8, arg, "--startup-cmd")) {
            i += 1;
            if (i >= args.len) return null;
            result.startup_cmd = args[i];
        } else if (std.mem.eql(u8, arg, "--capture-stdout")) {
            result.capture_stdout = true;
        }
    }

    if (!got_pane_id) return null;
    return result;
}

// ── Host process entry point ──

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    const host_args = parseHostArgs(args) orelse {
        hostLog("ERROR: invalid --host arguments");
        return error.InvalidArgs;
    };

    // Run in a thread with a larger stack to avoid aarch64 stack probe issues.
    const Info = struct { alloc: std.mem.Allocator, ha: HostArgs };
    const info = Info{ .alloc = allocator, .ha = host_args };
    const thread = try std.Thread.spawn(.{ .stack_size = 8 * 1024 * 1024 }, struct {
        fn entry(i: Info) void {
            hostMain(i.alloc, i.ha);
        }
    }.entry, .{info});
    thread.join();
}

fn hostMain(allocator: std.mem.Allocator, args: HostArgs) void {
    const is_dev = !std.mem.eql(u8, attyx.env, "production");

    // Create the named pipe server.
    var pipe_name_buf: [128]u16 = undefined;
    const pipe_name_len = host_pipe.formatPipeName(&pipe_name_buf, args.pane_id, is_dev) orelse {
        hostLog("ERROR: cannot format pipe name");
        return;
    };
    const pipe_name: LPCWSTR = @ptrCast(pipe_name_buf[0..pipe_name_len :0]);

    // Refresh PATH from registry — picks up tools installed after the daemon
    // started (e.g. bun, node, cargo). The daemon's inherited PATH is stale.
    refreshPathFromRegistry();

    // Spawn the shell via ConPTY.
    var pty = Pty.spawn(allocator, .{
        .rows = args.rows,
        .cols = args.cols,
        .cwd = args.cwd,
        .shell = args.shell,
        .startup_cmd = args.startup_cmd,
        .capture_stdout = args.capture_stdout,
        .skip_console_alloc = true, // ConPTY provides the shell's console
    }) catch {
        hostLog("ERROR: ConPTY spawn failed");
        return;
    };
    defer pty.deinit();

    // Ring buffer for ConPTY output during daemon disconnect.
    var ring = RingBuffer.init(allocator, RingBuffer.default_capacity) catch {
        hostLog("ERROR: ring buffer alloc failed");
        return;
    };
    defer ring.deinit();

    hostLog("host started, entering connection loop");

    // Outer reconnection loop: create pipe, wait for daemon, relay, repeat.
    while (true) {
        const daemon_pipe = createHostPipe(pipe_name);
        if (daemon_pipe == INVALID_HANDLE_VALUE) {
            hostLog("ERROR: CreateNamedPipeW failed");
            return;
        }

        // Wait for daemon to connect.
        if (ConnectNamedPipe(daemon_pipe, null) == 0) {
            const err = GetLastError();
            if (err != ERROR_PIPE_CONNECTED) {
                _ = CloseHandle(daemon_pipe);
                // Check if shell is still alive before retrying.
                if (shellExited(&pty)) return;
                Sleep(100);
                continue;
            }
        }

        // Send READY frame.
        _ = sendFrame(daemon_pipe, .ready, &.{});

        // Replay output buffered during daemon disconnect, then clear
        // so the ring only holds data from the next disconnect gap.
        // (The daemon has its own replay buffer for historical output.)
        replayBuffer(daemon_pipe, &ring);
        ring.clear();

        // Enter relay loop.
        const reason = relayLoop(daemon_pipe, &pty, &ring);

        _ = DisconnectNamedPipe(daemon_pipe);
        _ = CloseHandle(daemon_pipe);

        switch (reason) {
            .shell_died => {
                // Shell exited — try to notify, then exit.
                hostLog("shell exited, host process ending");
                return;
            },
            .daemon_disconnected => {
                // Daemon disconnected (upgrade) — drain ConPTY output into
                // ring buffer while waiting for new daemon to reconnect.
                hostLog("daemon disconnected, waiting for reconnect");
                if (shellExited(&pty)) return;
                drainPtyIntoRing(&pty, &ring);
                continue;
            },
        }
    }
}

const RelayResult = enum { shell_died, daemon_disconnected };

fn relayLoop(daemon_pipe: HANDLE, pty: *Pty, _: *RingBuffer) RelayResult {
    var pty_buf: [65536]u8 = undefined;
    var daemon_read_buf: [65536 + host_pipe.frame_header_size]u8 = undefined;
    var daemon_read_len: usize = 0;

    while (true) {
        // 1. Check for data from daemon → forward to ConPTY.
        {
            const space = daemon_read_buf[daemon_read_len..];
            if (space.len > 0) {
                var avail: DWORD = 0;
                if (PeekNamedPipe(daemon_pipe, null, 0, null, &avail, null) == 0) {
                    return .daemon_disconnected;
                }
                if (avail > 0) {
                    const to_read: DWORD = @intCast(@min(avail, space.len));
                    var bytes_read: DWORD = 0;
                    if (ReadFile(daemon_pipe, space.ptr, to_read, &bytes_read, null) == 0) {
                        return .daemon_disconnected;
                    }
                    daemon_read_len += bytes_read;
                }
            }

            // Process complete frames.
            while (true) {
                const header = host_pipe.decodeFrameHeader(daemon_read_buf[0..daemon_read_len]) orelse break;
                const total = host_pipe.frame_header_size + @as(usize, header.length);
                if (daemon_read_len < total) break;

                const payload = daemon_read_buf[host_pipe.frame_header_size..total];
                switch (header.frame_type) {
                    .data_in => {
                        _ = pty.writeToPty(payload) catch {};
                    },
                    .resize => {
                        if (payload.len >= 4) {
                            const rows = std.mem.readInt(u16, payload[0..2], .little);
                            const cols = std.mem.readInt(u16, payload[2..4], .little);
                            pty.resize(rows, cols) catch {};
                        }
                    },
                    .kill => {
                        _ = TerminateProcess(pty.process, 0);
                        return .shell_died;
                    },
                    else => {},
                }

                // Consume frame.
                const remaining = daemon_read_len - total;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, daemon_read_buf[0..remaining], daemon_read_buf[total..daemon_read_len]);
                }
                daemon_read_len = remaining;
            }
        }

        // 2. Check for data from ConPTY → forward to daemon.
        //    Don't buffer in ring during normal relay — the ring is only
        //    for data that arrives while the daemon is disconnected.
        //    If sendDataOut fails, we return immediately; the outer loop
        //    will then drain ConPTY into the ring while waiting for reconnect.
        {
            if (pty.checkAsyncRead()) |data| {
                if (!sendDataOut(daemon_pipe, data)) return .daemon_disconnected;
            }

            while (pty.peekAvail() > 0) {
                const n = pty.read(&pty_buf) catch break;
                if (n == 0) break;
                if (!sendDataOut(daemon_pipe, pty_buf[0..n])) return .daemon_disconnected;
            }

            pty.startAsyncRead();
        }

        // 3. Check if shell exited.
        if (shellExited(pty)) {
            // Send EXITED frame with exit code.
            const code = pty.exitCode() orelse 1;
            _ = sendFrame(daemon_pipe, .exited, &.{code});
            return .shell_died;
        }

        Sleep(5); // ~200Hz polling
    }
}

/// Drain any pending ConPTY output into the ring buffer.
/// Called after daemon disconnect, before blocking on ConnectNamedPipe.
fn drainPtyIntoRing(pty: *Pty, ring: *RingBuffer) void {
    var buf: [65536]u8 = undefined;
    if (pty.checkAsyncRead()) |data| {
        ring.write(data);
    }
    while (pty.peekAvail() > 0) {
        const n = pty.read(&buf) catch break;
        if (n == 0) break;
        ring.write(buf[0..n]);
    }
    pty.startAsyncRead();
}

fn replayBuffer(daemon_pipe: HANDLE, ring: *RingBuffer) void {
    const slices = ring.readSlices();
    if (slices.first.len > 0) {
        _ = sendDataOut(daemon_pipe, slices.first);
    }
    if (slices.second.len > 0) {
        _ = sendDataOut(daemon_pipe, slices.second);
    }
}

fn sendDataOut(pipe: HANDLE, data: []const u8) bool {
    var offset: usize = 0;
    while (offset < data.len) {
        const chunk = @min(data.len - offset, host_pipe.max_payload);
        if (!sendFrame(pipe, .data_out, data[offset .. offset + chunk])) return false;
        offset += chunk;
    }
    return true;
}

fn sendFrame(pipe: HANDLE, frame_type: FrameType, payload: []const u8) bool {
    var header: [host_pipe.frame_header_size]u8 = undefined;
    header[0] = @intFromEnum(frame_type);
    std.mem.writeInt(u16, header[1..3], @intCast(payload.len), .little);
    if (!pipeWriteAll(pipe, &header)) return false;
    if (payload.len > 0) {
        if (!pipeWriteAll(pipe, payload)) return false;
    }
    return true;
}

fn pipeWriteAll(pipe: HANDLE, data: []const u8) bool {
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

fn shellExited(pty: *Pty) bool {
    if (pty.exit_status != null) return true;
    return pty.childExited();
}

fn createHostPipe(pipe_name: LPCWSTR) HANDLE {
    return CreateNamedPipeW(
        pipe_name,
        PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
        1, // max 1 instance — one daemon at a time
        65536, // out buffer
        65536, // in buffer
        5000, // 5 second default timeout
        null,
    );
}

fn hostLog(msg: []const u8) void {
    var path_buf: [256]u8 = undefined;
    const path = session_connect.statePath(&path_buf, "daemon-debug{s}.log") orelse return;
    const file = std.fs.createFileAbsolute(path, .{ .truncate = false }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch {};
    file.writeAll("[host] ") catch {};
    file.writeAll(msg) catch {};
    file.writeAll("\n") catch {};
}

// ── Registry PATH refresh ──
// The daemon's PATH is frozen from startup. Tools installed after (bun, cargo,
// node, etc.) modify the registry PATH but the daemon doesn't see them.
// Read fresh PATH from registry so each new tab picks up new installations.

const HKEY = *opaque {};
const HKEY_LOCAL_MACHINE: HKEY = @ptrFromInt(0x80000002);
const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
const KEY_READ: DWORD = 0x20019;
const ERROR_SUCCESS: DWORD = 0;

extern "advapi32" fn RegOpenKeyExW(
    hKey: HKEY,
    lpSubKey: LPCWSTR,
    ulOptions: DWORD,
    samDesired: DWORD,
    phkResult: *HKEY,
) callconv(.winapi) DWORD;

extern "advapi32" fn RegQueryValueExW(
    hKey: HKEY,
    lpValueName: ?LPCWSTR,
    lpReserved: ?*DWORD,
    lpType: ?*DWORD,
    lpData: ?[*]u8,
    lpcbData: ?*DWORD,
) callconv(.winapi) DWORD;

extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) DWORD;

extern "kernel32" fn SetEnvironmentVariableW(
    lpName: LPCWSTR,
    lpValue: ?LPCWSTR,
) callconv(.winapi) BOOL;

extern "kernel32" fn GetEnvironmentVariableW(
    lpName: LPCWSTR,
    lpBuffer: ?[*]u16,
    nSize: DWORD,
) callconv(.winapi) DWORD;

fn refreshPathFromRegistry() void {
    const S = struct {
        var sys_path: [16384]u16 = undefined;
        var usr_path: [16384]u16 = undefined;
        var new_path: [32768]u16 = undefined;
        var old_path: [32768]u16 = undefined;
    };

    const sys_subkey = comptime toUtf16("SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment");
    const usr_subkey = comptime toUtf16("Environment");
    const sys_len = readRegPath(HKEY_LOCAL_MACHINE, &sys_subkey, &S.sys_path);
    const usr_len = readRegPath(HKEY_CURRENT_USER, &usr_subkey, &S.usr_path);

    if (sys_len == 0 and usr_len == 0) return;

    // Build fresh PATH: user + system (standard Windows order).
    var pos: usize = 0;
    if (usr_len > 0) {
        @memcpy(S.new_path[pos .. pos + usr_len], S.usr_path[0..usr_len]);
        pos += usr_len;
    }
    if (sys_len > 0) {
        if (pos > 0) {
            S.new_path[pos] = ';';
            pos += 1;
        }
        @memcpy(S.new_path[pos .. pos + sys_len], S.sys_path[0..sys_len]);
        pos += sys_len;
    }

    // Preserve entries from the current PATH that aren't in the registry
    // (e.g. MSYS2 sysroot, attyx bin dir added by setupMsysEnv).
    const path_name = comptime toUtf16("PATH");
    const old_len = GetEnvironmentVariableW(&path_name, &S.old_path, @intCast(S.old_path.len));
    if (old_len > 0) {
        // Scan old PATH for entries not in the new registry PATH.
        var start: usize = 0;
        var i: usize = 0;
        while (i <= old_len) : (i += 1) {
            if (i == old_len or S.old_path[i] == ';') {
                if (i > start and !containsPathEntry(S.new_path[0..pos], S.old_path[start..i])) {
                    if (pos > 0 and pos + 1 + (i - start) < S.new_path.len) {
                        S.new_path[pos] = ';';
                        pos += 1;
                        @memcpy(S.new_path[pos .. pos + (i - start)], S.old_path[start..i]);
                        pos += (i - start);
                    }
                }
                start = i + 1;
            }
        }
    }

    if (pos > 0) {
        S.new_path[pos] = 0;
        _ = SetEnvironmentVariableW(&path_name, S.new_path[0..pos :0]);
    }
}

fn readRegPath(root: HKEY, subkey: LPCWSTR, buf: *[16384]u16) usize {
    var hkey: HKEY = undefined;
    if (RegOpenKeyExW(root, subkey, 0, KEY_READ, &hkey) != ERROR_SUCCESS) return 0;
    defer _ = RegCloseKey(hkey);

    const val_name_lit = comptime toUtf16("Path");
    var data_size: DWORD = @intCast(@sizeOf(@TypeOf(buf.*)));
    if (RegQueryValueExW(hkey, &val_name_lit, null, null, @ptrCast(buf), &data_size) != ERROR_SUCCESS) return 0;

    // data_size is in bytes; convert to u16 count, strip null terminator.
    const u16_count = data_size / 2;
    if (u16_count > 0 and buf[u16_count - 1] == 0) return u16_count - 1;
    return u16_count;
}

fn containsPathEntry(haystack: []const u16, needle: []const u16) bool {
    if (needle.len == 0) return true;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= haystack.len) : (i += 1) {
        if (i == haystack.len or haystack[i] == ';') {
            if (i - start == needle.len and std.mem.eql(u16, haystack[start..i], needle)) return true;
            start = i + 1;
        }
    }
    return false;
}

fn toUtf16(comptime s: []const u8) [s.len:0]u16 {
    comptime {
        var result: [s.len:0]u16 = undefined;
        for (s, 0..) |c, i| result[i] = c;
        return result;
    }
}
