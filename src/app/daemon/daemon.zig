const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol.zig");
const DaemonSession = @import("session.zig").DaemonSession;
const DaemonPane = @import("pane.zig").DaemonPane;
const DaemonClient = @import("client.zig").DaemonClient;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;
const platform = @import("../../platform/platform.zig");
const handler = @import("handler.zig");
const session_connect = @import("../session_connect.zig");
const state_persist = @import("state_persist.zig");

const max_sessions: usize = 32;
const max_clients: usize = 16;
const replay_capacity: usize = RingBuffer.default_capacity;

var g_running: bool = true;

fn signalHandler(_: c_int) callconv(.c) void {
    g_running = false;
}

/// Socket path — delegates to session_connect so client and daemon agree.
fn getSocketPath(buf: *[256]u8) ?[]const u8 {
    return session_connect.getSocketPath(buf);
}

/// Ensure parent directory exists.
fn ensureDir(path: []const u8) void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| {
        const dir = path[0..i];
        std.fs.makeDirAbsolute(dir) catch {};
    }
}

pub fn run(allocator: std.mem.Allocator) !void {
    // Install signal handlers for clean shutdown
    const sa = posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &sa, null);
    posix.sigaction(posix.SIG.INT, &sa, null);

    // Ignore SIGPIPE — writes to dead client sockets must return EPIPE, not kill us.
    const sa_ign = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &sa_ign, null);

    var path_buf: [256]u8 = undefined;
    const socket_path = getSocketPath(&path_buf) orelse return error.NoHome;

    ensureDir(socket_path);

    // Handle stale socket: try connect, if fails → unlink + rebind
    cleanStaleSocket(socket_path);

    // Bind Unix socket
    const listen_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    errdefer posix.close(listen_fd);

    var addr = std.net.Address.initUnix(socket_path) catch return error.PathTooLong;
    posix.bind(listen_fd, &addr.any, addr.getOsSockLen()) catch return error.BindFailed;
    posix.listen(listen_fd, 5) catch return error.ListenFailed;

    // Set non-blocking on listener
    setNonBlocking(listen_fd);

    const stderr = std.fs.File.stderr();
    stderr.writeAll("attyx daemon: listening\n") catch {};

    var sessions: [max_sessions]?DaemonSession = .{null} ** max_sessions;
    var session_count: usize = 0;
    var next_session_id: u32 = 1;
    var next_pane_id: u32 = 1;

    // Load persisted dead sessions from previous daemon run.
    state_persist.load(&sessions, &next_session_id, &next_pane_id);

    var clients: [max_clients]?DaemonClient = .{null} ** max_clients;
    var client_count: usize = 0;

    defer {
        // Save dead sessions before final cleanup.
        state_persist.save(&sessions, next_session_id, next_pane_id);
        // Clean shutdown: close all sessions and clients
        for (&sessions) |*slot| {
            if (slot.*) |*s| {
                s.deinit();
                slot.* = null;
            }
        }
        for (&clients) |*slot| {
            if (slot.*) |*cl| {
                cl.deinit();
                slot.* = null;
            }
        }
        posix.close(listen_fd);
        std.fs.deleteFileAbsolute(socket_path) catch {};
    }

    var pty_buf: [65536]u8 = undefined;
    var proc_name_tick: u32 = 0;

    const max_panes_total = max_sessions * @import("session.zig").max_panes_per_session;

    while (g_running) {
        // Build poll fd array: listener + PTY masters (all panes) + client sockets
        const max_fds = 1 + max_panes_total + max_clients;
        var fds: [max_fds]posix.pollfd = undefined;
        var nfds: usize = 0;

        // [0] = listener
        fds[0] = .{ .fd = listen_fd, .events = 0x0001, .revents = 0 }; // POLLIN
        nfds = 1;

        // PTY master fds — iterate all panes across all sessions
        const PaneFdEntry = struct { session_idx: usize, pane_idx: usize };
        var pty_fd_map: [max_panes_total]PaneFdEntry = undefined;
        var pty_fd_count: usize = 0;
        for (&sessions, 0..) |*slot, si| {
            if (slot.*) |*s| {
                for (&s.panes, 0..) |*pslot, pi| {
                    if (pslot.*) |*p| {
                        if (p.alive) {
                            fds[nfds] = .{ .fd = p.pty.master, .events = 0x0001, .revents = 0 };
                            pty_fd_map[pty_fd_count] = .{ .session_idx = si, .pane_idx = pi };
                            pty_fd_count += 1;
                            nfds += 1;
                        }
                    }
                }
            }
        }

        // Client socket fds
        const client_fd_start = nfds;
        var client_fd_map: [max_clients]usize = undefined;
        var client_fd_count: usize = 0;
        for (&clients, 0..) |*slot, ci| {
            if (slot.*) |*cl| {
                fds[nfds] = .{ .fd = cl.socket_fd, .events = 0x0001, .revents = 0 };
                client_fd_map[client_fd_count] = ci;
                client_fd_count += 1;
                nfds += 1;
            }
        }

        _ = posix.poll(fds[0..nfds], 50) catch break;

        // Accept new connections
        if (fds[0].revents & 0x0001 != 0) {
            acceptClient(listen_fd, &clients, &client_count);
        }

        // Read PTY data from all panes and forward to attached clients
        for (0..pty_fd_count) |pi| {
            const poll_idx = 1 + pi;
            const entry = pty_fd_map[pi];
            if (fds[poll_idx].revents & 0x0001 != 0) {
                if (sessions[entry.session_idx]) |*s| {
                    if (s.panes[entry.pane_idx]) |*pane| {
                        while (true) {
                            const n = pane.readPty(&pty_buf) catch break;
                            if (n == 0) break;
                            for (&clients) |*cslot| {
                                if (cslot.*) |*cl| {
                                    if (cl.attached_session == s.id and cl.isPaneActive(pane.id)) {
                                        cl.sendPaneOutput(pane.id, pty_buf[0..n]);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // Check POLLHUP on pane PTY
            if (fds[poll_idx].revents & 0x0010 != 0) {
                if (sessions[entry.session_idx]) |*s| {
                    if (s.panes[entry.pane_idx]) |*pane| {
                        if (pane.checkExit()) |exit_code| {
                            // Check if session is still alive
                            var any_alive = false;
                            for (s.panes) |slot| {
                                if (slot) |p| if (p.alive) {
                                    any_alive = true;
                                    break;
                                };
                            }
                            if (!any_alive) s.alive = false;

                            for (&clients) |*cslot| {
                                if (cslot.*) |*cl| {
                                    if (cl.attached_session == s.id) {
                                        cl.sendPaneDied(pane.id, exit_code);
                                        if (!s.alive) {
                                            cl.attached_session = null;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Periodically check foreground process name for active panes (~1s interval)
        proc_name_tick += 1;
        if (proc_name_tick >= 20) {
            proc_name_tick = 0;
            for (&sessions) |*slot| {
                if (slot.*) |*s| {
                    for (&s.panes) |*pslot| {
                        if (pslot.*) |*pane| {
                            if (pane.alive) {
                                if (pane.checkProcNameChanged()) |name| {
                                    for (&clients) |*cslot| {
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

        // Read client messages
        for (0..client_fd_count) |ci| {
            const poll_idx = client_fd_start + ci;
            const slot_idx = client_fd_map[ci];
            if (fds[poll_idx].revents & (0x0001 | 0x0010) != 0) {
                if (clients[slot_idx]) |*cl| {
                    if (!cl.recvData()) {
                        cl.deinit();
                        clients[slot_idx] = null;
                        client_count -= 1;
                        continue;
                    }
                    // Process complete messages
                    while (cl.nextMessage()) |msg| {
                        handler.handleMessage(cl, msg, &sessions, &session_count, &next_session_id, &next_pane_id, allocator);
                    }
                    if (cl.dead) {
                        cl.deinit();
                        clients[slot_idx] = null;
                        client_count -= 1;
                    }
                }
            }
        }

        // Check for dead sessions (child exit without POLLHUP)
        for (&sessions) |*slot| {
            if (slot.*) |*s| {
                if (s.alive) {
                    if (s.checkExit()) |_| {
                        for (&clients) |*cslot| {
                            if (cslot.*) |*cl| {
                                if (cl.attached_session == s.id) {
                                    cl.attached_session = null;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// handleMessage and findSession moved to handler.zig

fn acceptClient(listen_fd: posix.fd_t, clients: *[max_clients]?DaemonClient, count: *usize) void {
    const fd = posix.accept(listen_fd, null, null, 0) catch return;
    if (count.* >= max_clients) {
        posix.close(fd);
        return;
    }
    // Non-blocking client sockets — writeAll polls for writability on
    // WouldBlock with a 200ms timeout, so the daemon never blocks
    // indefinitely when a client's recv buffer is full.
    setNonBlocking(fd);
    for (clients) |*slot| {
        if (slot.* == null) {
            slot.* = DaemonClient.init(fd);
            count.* += 1;
            return;
        }
    }
    posix.close(fd);
}

fn cleanStaleSocket(path: []const u8) void {
    // Try connecting — if it succeeds, a daemon is already running
    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return;
    defer posix.close(fd);
    const addr = std.net.Address.initUnix(path) catch return;
    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch {
        // Connection failed — stale socket, remove it
        std.fs.deleteFileAbsolute(path) catch {};
        return;
    };
    // Connection succeeded — another daemon is running
    std.fs.File.stderr().writeAll("attyx daemon: already running\n") catch {};
    std.process.exit(0);
}

fn setNonBlocking(fd: posix.fd_t) void {
    const F_GETFL: i32 = 3;
    const F_SETFL: i32 = 4;
    const flags = std.posix.fcntl(fd, F_GETFL, 0) catch return;
    _ = std.posix.fcntl(fd, F_SETFL, flags | platform.O_NONBLOCK) catch {};
}
