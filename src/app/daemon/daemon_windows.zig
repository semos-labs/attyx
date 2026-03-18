/// Windows daemon — named pipe event loop.
///
/// Mirrors the POSIX daemon (daemon.zig) but uses Windows APIs:
///   - Named pipes instead of Unix domain sockets
///   - SetConsoleCtrlHandler for shutdown signals
///   - PeekNamedPipe + Sleep polling loop instead of poll()
///
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
const upgrade = @import("upgrade_windows.zig");
const host_pipe = @import("host_pipe.zig");
const HostConnection = host_pipe.HostConnection;

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

pub fn run(allocator: std.mem.Allocator, restore_path: ?[]const u8) !void {
    // Zig debug mode on aarch64 Windows generates stack frames that exceed
    // the default 1MB stack. Calling a separate function (even a small one)
    // triggers a stack probe crash. Work around by running the daemon loop
    // directly inside a thread entry with an 8MB stack.
    const RestoreInfo = struct { path: ?[]const u8, alloc: std.mem.Allocator };
    const info = RestoreInfo{ .path = restore_path, .alloc = allocator };
    const thread = std.Thread.spawn(.{ .stack_size = 8 * 1024 * 1024 }, struct {
        fn entry(ri: RestoreInfo) void {
            daemonLog("daemon thread started");
            const state = daemonSetup(ri.alloc) orelse return;
            if (ri.path) |rp| restoreFromUpgrade(state, rp);
            daemonLoop(state);
            daemonCleanup(ri.alloc, state);
        }
    }.entry, .{info}) catch {
        daemonLog("ERROR: failed to spawn daemon thread");
        return error.SpawnFailed;
    };
    thread.join();
}

/// Daemon state — heap-allocated to keep function stack frames small.
/// On aarch64 Windows, Zig debug mode can exceed the stack probe limit
/// if too many locals are in a single function.
const DaemonState = struct {
    sessions: *[max_sessions]?DaemonSession,
    clients: *[max_clients]?DaemonClient,
    pty_buf: *[65536]u8,
    session_count: usize = 0,
    next_session_id: u32 = 1,
    next_pane_id: u32 = 1,
    client_count: usize = 0,
    proc_name_tick: u32 = 0,
    upgrade_requested: bool = false,
    listen_pipe: ?HANDLE = null,
    connect_overlap: OVERLAPPED = .{},
    pipe_name_buf: [256]u16 = undefined,
    pipe_name_len: usize = 0,
    allocator: std.mem.Allocator,

    fn getPipeName(self: *DaemonState) LPCWSTR {
        return @ptrCast(self.pipe_name_buf[0..self.pipe_name_len :0]);
    }
};

// ── Daemon lifecycle (each function kept small for aarch64 Windows stack probes) ──

fn daemonSetup(alloc: std.mem.Allocator) ?*DaemonState {
    _ = SetConsoleCtrlHandler(@ptrCast(&ctrlHandler), 1);

    var path_buf: [256]u8 = undefined;
    const pipe_path = session_connect.getSocketPath(&path_buf) orelse {
        daemonLog("ERROR: no socket path");
        return null;
    };
    ensureStateDir();
    writeVersionFile();
    upgrade.cleanupOldExe();

    var wide_buf: [256]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wide_buf, pipe_path) catch return null;
    wide_buf[wlen] = 0;
    const pipe_name: LPCWSTR = @ptrCast(wide_buf[0..wlen :0]);

    const state = alloc.create(DaemonState) catch return null;
    const sessions_ptr = alloc.create([max_sessions]?DaemonSession) catch return null;
    sessions_ptr.* = .{null} ** max_sessions;
    const clients_ptr = alloc.create([max_clients]?DaemonClient) catch return null;
    clients_ptr.* = .{null} ** max_clients;
    const pty_buf_slice = alloc.alloc(u8, 65536) catch return null;

    state.* = .{
        .sessions = sessions_ptr,
        .clients = clients_ptr,
        .pty_buf = pty_buf_slice[0..65536],
        .allocator = alloc,
    };
    @memcpy(state.pipe_name_buf[0..wlen], wide_buf[0..wlen]);
    state.pipe_name_buf[wlen] = 0;
    state.pipe_name_len = wlen;

    state_persist.load(state.sessions, &state.next_session_id, &state.next_pane_id);
    for (state.sessions) |*slot| {
        if (slot.* != null) state.session_count += 1;
    }

    state.connect_overlap.hEvent = CreateEventW(null, 1, 0, null);
    state.listen_pipe = createPipeInstance(pipe_name);
    if (state.listen_pipe) |lp| {
        daemonLog("listening");
        startAsyncConnect(lp, &state.connect_overlap);
    } else {
        daemonLog("ERROR: CreateNamedPipeW failed");
        return null;
    }
    return state;
}

const update_check = @import("update_check_windows.zig");

fn daemonLoop(state: *DaemonState) void {
    var staged_check_tick: u32 = 0;
    var update_check_tick: u32 = 0;
    // ~6 hours in ticks: 6 * 3600 * 1000 / 50ms = 432000
    const update_check_interval: u32 = 432000;

    while (g_running) {
        pollAccept(state);
        pollPtyOutput(state);
        pollClients(state);
        pollProcNames(state);
        pollDeadSessions(state);

        // Check for staged binary every ~2s (40 ticks × 50ms).
        // The installer/dev script or auto-updater drops upgrade.exe.
        staged_check_tick += 1;
        if (staged_check_tick >= 40) {
            staged_check_tick = 0;
            if (!state.upgrade_requested and upgrade.hasStagedBinary()) {
                daemonLog("upgrade: staged binary detected");
                state.upgrade_requested = true;
            }
        }

        // Auto-update check every ~6 hours. First check at ~30s after startup.
        update_check_tick += 1;
        if (update_check_tick == 600 or update_check_tick % update_check_interval == 0) {
            if (!state.upgrade_requested) {
                update_check.checkAndDownload();
            }
        }

        // Hot upgrade: serialize state with inherited HANDLE values,
        // spawn new daemon, then enter HPCON keeper mode.
        if (state.upgrade_requested) {
            daemonLog("upgrade: performing hot upgrade");
            performUpgradeAndKeep(state);
            g_running = false;
        }

        Sleep(50);
    }
}

fn daemonCleanup(alloc: std.mem.Allocator, state: *DaemonState) void {
    state_persist.save(state.sessions, state.next_session_id, state.next_pane_id);
    for (state.sessions) |*slot| {
        if (slot.*) |*s| { s.deinit(); slot.* = null; }
    }
    for (state.clients) |*slot| {
        if (slot.*) |*cl| { cl.deinit(); slot.* = null; }
    }
    if (state.listen_pipe) |lp| _ = CloseHandle(lp);
    if (state.connect_overlap.hEvent) |ev| _ = CloseHandle(ev);
    alloc.destroy(state.sessions);
    alloc.destroy(state.clients);
    alloc.destroy(state);
    deleteVersionFile();
}

// ── Hot upgrade ──

fn performUpgradeAndKeep(state: *DaemonState) void {
    var pipe_utf8: [512]u8 = undefined;
    var utf8_len: usize = 0;
    for (state.pipe_name_buf[0..state.pipe_name_len]) |cp| {
        const n = std.unicode.utf8Encode(@intCast(cp), pipe_utf8[utf8_len..]) catch break;
        utf8_len += n;
    }

    // Close listener + clients BEFORE spawning new daemon.
    // The new daemon needs the pipe name free to bind its own listener.
    if (state.listen_pipe) |lp| { _ = CloseHandle(lp); state.listen_pipe = null; }
    if (state.connect_overlap.hEvent) |ev| { _ = CloseHandle(ev); state.connect_overlap.hEvent = null; }
    for (state.clients) |*slot| {
        if (slot.*) |*cl| { cl.deinit(); slot.* = null; }
    }
    state.client_count = 0;

    // Detach host pipe connections BEFORE spawning new daemon.
    // Host pipes use nMaxInstances=1, so the new daemon can't connect
    // while the old daemon still holds the pipe open. Closing without
    // sending KILL lets host processes enter reconnect mode.
    detachHostConnections(state);

    const result = upgrade.performUpgrade(
        state.sessions,
        state.next_session_id,
        state.next_pane_id,
        state.allocator,
        pipe_utf8[0..utf8_len],
    );

    switch (result) {
        .success => {
            // Host processes keep shells alive — old daemon exits cleanly.
            // Host connections already detached above (before spawn).
            daemonLog("upgrade: success, exiting cleanly");
        },
        .failed => {
            daemonLog("upgrade: failed, reconnecting to hosts");
            state.upgrade_requested = false;
            // Reconnect to host processes (we detached above).
            reconnectHostConnections(state);
            // Re-create listener so old daemon can continue serving
            state.connect_overlap.hEvent = CreateEventW(null, 1, 0, null);
            state.listen_pipe = createPipeInstance(state.getPipeName());
            if (state.listen_pipe) |lp| startAsyncConnect(lp, &state.connect_overlap);
        },
        .fatal => {
            daemonLog("upgrade: fatal failure");
        },
    }
}

/// Close host pipe handles without sending KILL. Called before cleanup
/// on successful upgrade so that host processes survive for the new daemon.
fn detachHostConnections(state: *DaemonState) void {
    for (state.sessions) |*slot| {
        if (slot.*) |*s| {
            for (&s.panes) |*pslot| {
                if (pslot.*) |*pane| {
                    if (pane.host_conn) |hc| {
                        hc.deinit(); // Close pipe, no KILL sent
                        pane.host_conn = null;
                    }
                }
            }
        }
    }
}

/// Reconnect to host processes after a failed upgrade attempt.
fn reconnectHostConnections(state: *DaemonState) void {
    const is_dev = !std.mem.eql(u8, attyx.env, "production");
    for (state.sessions) |*slot| {
        if (slot.*) |*s| {
            for (&s.panes) |*pslot| {
                if (pslot.*) |*pane| {
                    if (pane.host_conn == null and pane.alive) {
                        const conn = state.allocator.create(HostConnection) catch continue;
                        conn.* = HostConnection.connect(pane.id, is_dev) orelse {
                            state.allocator.destroy(conn);
                            daemonLog("reconnect: failed for pane");
                            pane.alive = false;
                            pane.exit_code = 1;
                            continue;
                        };
                        pane.host_conn = conn;
                    }
                }
            }
        }
    }
}

fn restoreFromUpgrade(state: *DaemonState, restore_path: []const u8) void {
    daemonLog("restore: loading upgrade state");
    const data = std.fs.cwd().readFileAlloc(state.allocator, restore_path, 128 * 1024 * 1024) catch {
        daemonLog("restore: failed to read upgrade file");
        return;
    };
    defer state.allocator.free(data);

    const restored = upgrade.deserialize(
        data, state.sessions, &state.next_session_id, &state.next_pane_id, state.allocator,
    ) catch {
        daemonLog("restore: deserialization failed");
        std.fs.deleteFileAbsolute(restore_path) catch {};
        return;
    };

    state.session_count = 0;
    for (state.sessions) |*slot| {
        if (slot.* != null) state.session_count += 1;
    }

    var msg_buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "restore: {d} sessions", .{restored}) catch "restore: done";
    daemonLog(msg);
    std.fs.deleteFileAbsolute(restore_path) catch {};
}

// ── Loop body split into small functions (aarch64 Windows stack probe workaround) ──

fn pollAccept(st: *DaemonState) void {
    if (st.listen_pipe == null) return;
    const ev = st.connect_overlap.hEvent orelse return;
    if (WaitForSingleObject(ev, 0) != WAIT_OBJECT_0) return;
    const client_pipe = st.listen_pipe.?;
    acceptClient(client_pipe, st.clients, &st.client_count);
    _ = ResetEvent(ev);
    st.listen_pipe = createPipeInstance(st.getPipeName());
    if (st.listen_pipe) |lp| startAsyncConnect(lp, &st.connect_overlap);
}

fn pollPtyOutput(st: *DaemonState) void {
    for (st.sessions) |*slot| {
        if (slot.*) |*s| {
            for (&s.panes) |*pslot| {
                if (pslot.*) |*pane| {
                    if (pane.alive) pollSinglePane(st, s, pane);
                }
            }
        }
    }
}

fn pollSinglePane(st: *DaemonState, s: *DaemonSession, pane: *DaemonPane) void {
    var n: usize = 0;

    // Host process mode: read from host pipe, process frames.
    if (pane.host_conn) |hc| {
        if (!hc.recvData()) {
            // Host pipe broken — host process died.
            pane.alive = false;
            pane.exit_code = pane.exit_code orelse 1;
        } else {
            while (hc.nextFrame()) |frame| {
                switch (frame.frame_type) {
                    .data_out => {
                        const copy = @min(frame.payload.len, st.pty_buf.len - n);
                        @memcpy(st.pty_buf[n .. n + copy], frame.payload[0..copy]);
                        n += copy;
                    },
                    .exited => {
                        pane.exit_code = if (frame.payload.len > 0) frame.payload[0] else 1;
                        pane.alive = false;
                    },
                    .ready => {}, // Already handled at spawn time
                    else => {},
                }
            }
        }

        // Track modes/replay for host-received data.
        if (n > 0) {
            pane.absorbHostOutput(st.pty_buf[0..n]);
        }
    } else {
        // Direct PTY mode (fallback / non-host path).
        if (pane.pty.checkAsyncRead()) |data| {
            n = pane.absorbPtyData(data, st.pty_buf);
        }
        while (pane.pty.peekAvail() > 0) {
            const extra = pane.readPty(st.pty_buf[n..]) catch break;
            if (extra == 0) break;
            n += extra;
        }
        pane.pty.startAsyncRead();
    }

    if (n > 0) {
        for (st.clients) |*cslot| {
            if (cslot.*) |*cl| {
                if (cl.attached_session == s.id and cl.isPaneActive(pane.id))
                    cl.sendPaneOutput(pane.id, st.pty_buf[0..n]);
            }
        }
    }
    if (pane.checkExit()) |exit_code| {
        pane.drainCapturedStdout();
        var any_alive = false;
        for (s.panes) |ps| {
            if (ps) |p| if (p.alive) { any_alive = true; break; };
        }
        if (!any_alive) s.alive = false;
        const stdout_data = pane.getCapturedStdout();
        for (st.clients) |*cslot| {
            if (cslot.*) |*cl| {
                if (cl.attached_session == s.id) {
                    cl.sendPaneDiedWithStdout(pane.id, exit_code, stdout_data);
                    if (!s.alive) cl.attached_session = null;
                }
            }
        }
    }
}

fn pollClients(st: *DaemonState) void {
    for (st.clients, 0..) |*slot, ci| {
        if (slot.*) |*cl| {
            if (!cl.recvData()) {
                cl.deinit();
                slot.* = null;
                st.client_count -= 1;
                _ = ci;
                continue;
            }
            while (cl.nextMessage()) |msg| {
                handler.handleMessage(cl, msg, st.sessions, &st.session_count, &st.next_session_id, &st.next_pane_id, st.allocator, st.clients, &st.upgrade_requested);
            }
            if (cl.dead) {
                cl.deinit();
                slot.* = null;
                st.client_count -= 1;
            }
        }
    }
}

fn pollProcNames(st: *DaemonState) void {
    st.proc_name_tick += 1;
    if (st.proc_name_tick < 20) return;
    st.proc_name_tick = 0;
    for (st.sessions) |*slot| {
        if (slot.*) |*s| {
            for (&s.panes) |*pslot| {
                if (pslot.*) |*pane| {
                    if (pane.alive) {
                        if (pane.checkProcNameChanged()) |name| {
                            for (st.clients) |*cslot| {
                                if (cslot.*) |*cl| {
                                    if (cl.attached_session == s.id and cl.isPaneActive(pane.id))
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

fn pollDeadSessions(st: *DaemonState) void {
    for (st.sessions) |*slot| {
        if (slot.*) |*s| {
            if (s.alive) {
                if (s.checkExit()) |_| {
                    for (st.clients) |*cslot| {
                        if (cslot.*) |*cl| {
                            if (cl.attached_session == s.id) cl.attached_session = null;
                        }
                    }
                }
            }
        }
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
