/// Windows daemon — named pipe event loop.
///
/// Mirrors the POSIX daemon (daemon.zig) but uses Windows APIs:
///   - Named pipes instead of Unix domain sockets
///   - SetConsoleCtrlHandler for shutdown signals
///   - PeekNamedPipe + Sleep polling loop instead of poll()
///
/// Hot-upgrade is not supported on Windows yet.
const std = @import("std");
const attyx = @import("attyx");
const protocol = @import("protocol.zig");
const DaemonSession = @import("session.zig").DaemonSession;
const DaemonPane = @import("pane.zig").DaemonPane;
const DaemonClient = @import("client.zig").DaemonClient;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;
const handler = @import("handler.zig");
const session_connect = @import("../session_connect.zig");
const state_persist = @import("state_persist.zig");

/// File-based debug logging for daemon (no console available).
fn daemonLog(msg: []const u8) void {
    var path_buf: [256]u8 = undefined;
    const path = session_connect.statePath(&path_buf, "daemon-debug{s}.log") orelse return;
    const file = std.fs.createFileAbsolute(path, .{ .truncate = false }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch {};
    file.writeAll("[daemon] ") catch {};
    file.writeAll(msg) catch {};
    file.writeAll("\n") catch {};
}

const windows = std.os.windows;
const HANDLE = windows.HANDLE;
const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
const LPCWSTR = [*:0]const u16;

const PIPE_ACCESS_DUPLEX: DWORD = 0x00000003;
const PIPE_TYPE_BYTE: DWORD = 0x00000000;
const PIPE_READMODE_BYTE: DWORD = 0x00000000;
const PIPE_WAIT: DWORD = 0x00000000;
const PIPE_NOWAIT: DWORD = 0x00000001;
const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;
const FILE_FLAG_FIRST_PIPE_INSTANCE: DWORD = 0x00080000;
const ERROR_PIPE_CONNECTED: DWORD = 535;
const ERROR_IO_PENDING: DWORD = 997;
const WAIT_OBJECT_0: DWORD = 0;
const WAIT_TIMEOUT: DWORD = 258;
const WAIT_FAILED: DWORD = 0xFFFFFFFF;

const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    Offset: DWORD = 0,
    OffsetHigh: DWORD = 0,
    hEvent: ?HANDLE = null,
};

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

extern "kernel32" fn ConnectNamedPipe(hNamedPipe: HANDLE, lpOverlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
extern "kernel32" fn DisconnectNamedPipe(hNamedPipe: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

extern "kernel32" fn PeekNamedPipe(
    hPipe: HANDLE,
    lpBuffer: ?[*]u8,
    nBufferSize: DWORD,
    lpBytesRead: ?*DWORD,
    lpTotalBytesAvail: ?*DWORD,
    lpBytesLeftThisMessage: ?*DWORD,
) callconv(.winapi) BOOL;

extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*const anyopaque,
    bManualReset: BOOL,
    bInitialState: BOOL,
    lpName: ?LPCWSTR,
) callconv(.winapi) ?HANDLE;

extern "kernel32" fn SetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn ResetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;

extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;

const CTRL_C_EVENT: DWORD = 0;
const CTRL_BREAK_EVENT: DWORD = 1;
const CTRL_CLOSE_EVENT: DWORD = 2;

extern "kernel32" fn SetConsoleCtrlHandler(
    HandlerRoutine: ?*const anyopaque,
    Add: BOOL,
) callconv(.winapi) BOOL;

const max_sessions: usize = 32;
const max_clients: usize = 16;
const max_panes_per_session = @import("session.zig").max_panes_per_session;
const replay_capacity: usize = RingBuffer.default_capacity;

var g_running: bool = true;

fn ctrlHandler(ctrl_type: DWORD) callconv(.winapi) BOOL {
    switch (ctrl_type) {
        CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT => {
            g_running = false;
            return 1; // handled
        },
        else => return 0,
    }
}

pub fn testLog() void {
    daemonLog("testLog: daemon module is reachable");
}

pub fn run(allocator: std.mem.Allocator, _: ?[]const u8) !void {
    daemonLog("daemon_windows.run: ENTERED");
    daemonLog("daemon starting");

    _ = SetConsoleCtrlHandler(@ptrCast(&ctrlHandler), 1);

    var path_buf: [256]u8 = undefined;
    const pipe_path_utf8 = session_connect.getSocketPath(&path_buf) orelse {
        daemonLog("ERROR: getSocketPath returned null (no LOCALAPPDATA?)");
        return error.NoHome;
    };

    daemonLog(pipe_path_utf8);

    // Convert pipe path to UTF-16 for Windows API
    var wide_buf: [256]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wide_buf, pipe_path_utf8) catch return error.PathTooLong;
    wide_buf[wlen] = 0;
    const pipe_name: LPCWSTR = @ptrCast(wide_buf[0..wlen :0]);

    // Ensure state directory exists
    ensureStateDir();
    daemonLog("state dir ensured");

    // Write daemon version file
    writeVersionFile();

    daemonLog("creating named pipe");

    // Sessions array is heap-allocated because DaemonPane.pty contains a 64KB
    // async buffer, making each ?DaemonSession ~2MB. 32 sessions = ~67MB,
    // far exceeding the default stack size.
    const sessions_ptr = allocator.create([max_sessions]?DaemonSession) catch {
        daemonLog("ERROR: failed to allocate sessions array");
        return error.OutOfMemory;
    };
    defer allocator.destroy(sessions_ptr);
    sessions_ptr.* = .{null} ** max_sessions;
    const sessions: *[max_sessions]?DaemonSession = sessions_ptr;

    var session_count: usize = 0;
    var next_session_id: u32 = 1;
    var next_pane_id: u32 = 1;

    // Load persisted dead sessions from previous daemon run.
    state_persist.load(sessions, &next_session_id, &next_pane_id);
    for (sessions.*) |slot| {
        if (slot != null) session_count += 1;
    }

    // Clients array is heap-allocated (same reason as sessions — each
    // DaemonClient has ~128KB of buffers, 16 clients = ~2MB).
    const clients_ptr = allocator.create([max_clients]?DaemonClient) catch {
        daemonLog("ERROR: failed to allocate clients array");
        return error.OutOfMemory;
    };
    defer allocator.destroy(clients_ptr);
    clients_ptr.* = .{null} ** max_clients;
    const clients: *[max_clients]?DaemonClient = clients_ptr;
    var client_count: usize = 0;

    // Create a pipe instance with overlapped I/O for async accept
    var connect_overlap = OVERLAPPED{};
    connect_overlap.hEvent = CreateEventW(null, 1, 0, null); // manual-reset
    var listen_pipe: ?HANDLE = createPipeInstance(pipe_name);

    if (listen_pipe) |_| {
        daemonLog("pipe created successfully, starting async connect");
    } else {
        daemonLog("ERROR: CreateNamedPipeW failed!");
    }

    if (listen_pipe) |lp| {
        startAsyncConnect(lp, &connect_overlap);
    }

    daemonLog("entering main loop");

    defer {
        state_persist.save(sessions, next_session_id, next_pane_id);
        for (sessions) |*slot| {
            if (slot.*) |*s| {
                s.deinit();
                slot.* = null;
            }
        }
        for (clients) |*slot| {
            if (slot.*) |*cl| {
                cl.deinit();
                slot.* = null;
            }
        }
        if (listen_pipe) |lp| _ = CloseHandle(lp);
        if (connect_overlap.hEvent) |ev| _ = CloseHandle(ev);
        deleteVersionFile();
    }

    const pty_buf_ptr = try allocator.alloc(u8, 65536);
    defer allocator.free(pty_buf_ptr);
    const pty_buf: *[65536]u8 = pty_buf_ptr[0..65536];
    var proc_name_tick: u32 = 0;
    var g_upgrade_requested: bool = false;

    while (g_running) {
        // 1. Check for new connections (non-blocking via overlapped connect)
        if (listen_pipe != null) {
            if (connect_overlap.hEvent) |ev| {
                if (WaitForSingleObject(ev, 0) == WAIT_OBJECT_0) {
                    // Client connected
                    const client_pipe = listen_pipe.?;
                    acceptClient(client_pipe, clients, &client_count);
                    _ = ResetEvent(ev);
                    // Create new pipe instance for next client
                    listen_pipe = createPipeInstance(pipe_name);
                    if (listen_pipe) |lp| startAsyncConnect(lp, &connect_overlap);
                }
            }
        }

        // 2. Read PTY output from all alive panes, forward to clients.
        //
        // ConPTY only flushes its internal buffer when there's a pending
        // ReadFile on the output pipe — PeekNamedPipe alone won't trigger
        // it. We use the async read pattern: check if a previous async
        // read completed, drain any additional data via peek+read, then
        // start a new async read to keep ConPTY flushing.
        for (sessions) |*slot| {
            if (slot.*) |*s| {
                for (&s.panes) |*pslot| {
                    if (pslot.*) |*pane| {
                        if (pane.alive) {
                            // Check async read completion first (non-blocking).
                            var n: usize = 0;
                            if (pane.pty.checkAsyncRead()) |data| {
                                n = pane.absorbPtyData(data, pty_buf);
                            }
                            // Drain any additional data available via peek.
                            while (pane.pty.peekAvail() > 0) {
                                const extra = pane.readPty(pty_buf[n..]) catch break;
                                if (extra == 0) break;
                                n += extra;
                            }
                            // Keep an async read pending so ConPTY flushes.
                            pane.pty.startAsyncRead();
                            if (n > 0) {
                                for (clients) |*cslot| {
                                    if (cslot.*) |*cl| {
                                        if (cl.attached_session == s.id and cl.isPaneActive(pane.id)) {
                                            cl.sendPaneOutput(pane.id, pty_buf[0..n]);
                                        }
                                    }
                                }
                            }
                            // Check for process exit
                            if (pane.checkExit()) |exit_code| {
                                pane.drainCapturedStdout();
                                var any_alive = false;
                                for (s.panes) |ps| {
                                    if (ps) |p| if (p.alive) {
                                        any_alive = true;
                                        break;
                                    };
                                }
                                if (!any_alive) s.alive = false;
                                const stdout_data = pane.getCapturedStdout();
                                for (clients) |*cslot| {
                                    if (cslot.*) |*cl| {
                                        if (cl.attached_session == s.id) {
                                            cl.sendPaneDiedWithStdout(pane.id, exit_code, stdout_data);
                                            if (!s.alive) cl.attached_session = null;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // 3. Read client messages
        for (clients, 0..) |*slot, ci| {
            if (slot.*) |*cl| {
                if (!cl.recvData()) {
                    cl.deinit();
                    slot.* = null;
                    client_count -= 1;
                    _ = ci;
                    continue;
                }
                while (cl.nextMessage()) |msg| {
                    handler.handleMessage(cl, msg, sessions, &session_count, &next_session_id, &next_pane_id, allocator, clients, &g_upgrade_requested);
                }
                if (cl.dead) {
                    cl.deinit();
                    slot.* = null;
                    client_count -= 1;
                }
            }
        }

        // 4. Periodic process name check (~1s interval, every 20 ticks)
        proc_name_tick += 1;
        if (proc_name_tick >= 20) {
            proc_name_tick = 0;
            for (sessions) |*slot| {
                if (slot.*) |*s| {
                    for (&s.panes) |*pslot| {
                        if (pslot.*) |*pane| {
                            if (pane.alive) {
                                if (pane.checkProcNameChanged()) |name| {
                                    for (clients) |*cslot| {
                                        if (cslot.*) |*cl| {
                                            if (cl.attached_session == s.id and cl.isPaneActive(pane.id)) {
                                                cl.sendPaneProcName(pane.id, name);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // 5. Check for dead sessions
        for (sessions) |*slot| {
            if (slot.*) |*s| {
                if (s.alive) {
                    if (s.checkExit()) |_| {
                        for (clients) |*cslot| {
                            if (cslot.*) |*cl| {
                                if (cl.attached_session == s.id) cl.attached_session = null;
                            }
                        }
                    }
                }
            }
        }

        // 6. Sleep for poll interval (50ms, matching POSIX daemon)
        Sleep(50);
    }
}

fn createPipeInstance(pipe_name: LPCWSTR) ?HANDLE {
    const h = CreateNamedPipeW(
        pipe_name,
        PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
        max_clients, // max instances
        65536, // out buffer
        65536, // in buffer
        0, // default timeout
        null, // default security
    );
    if (h == INVALID_HANDLE_VALUE) return null;
    return h;
}

fn startAsyncConnect(pipe: HANDLE, overlap: *OVERLAPPED) void {
    _ = ConnectNamedPipe(pipe, overlap);
    // If ERROR_PIPE_CONNECTED, the event is already signaled.
    // If ERROR_IO_PENDING, will signal when a client connects.
}

fn acceptClient(pipe_handle: HANDLE, clients: *[max_clients]?DaemonClient, count: *usize) void {
    if (count.* >= max_clients) {
        _ = DisconnectNamedPipe(pipe_handle);
        _ = CloseHandle(pipe_handle);
        return;
    }
    for (clients) |*slot| {
        if (slot.* == null) {
            slot.* = DaemonClient.init(pipe_handle);
            count.* += 1;
            return;
        }
    }
    _ = DisconnectNamedPipe(pipe_handle);
    _ = CloseHandle(pipe_handle);
}

fn ensureStateDir() void {
    var dir_buf: [256]u8 = undefined;
    const dir = session_connect.stateDir(&dir_buf) orelse return;
    // Create directory (and parent) if needed
    std.fs.makeDirAbsolute(dir) catch {};
}

fn writeVersionFile() void {
    var vbuf: [256]u8 = undefined;
    const vpath = session_connect.statePath(&vbuf, "daemon{s}.version") orelse return;
    const file = std.fs.createFileAbsolute(vpath, .{}) catch return;
    defer file.close();
    file.writeAll(attyx.version) catch {};
}

fn deleteVersionFile() void {
    var vbuf: [256]u8 = undefined;
    const vpath = session_connect.statePath(&vbuf, "daemon{s}.version") orelse return;
    std.fs.deleteFileAbsolute(vpath) catch {};
}
