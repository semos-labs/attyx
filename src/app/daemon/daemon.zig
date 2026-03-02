const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol.zig");
const DaemonSession = @import("session.zig").DaemonSession;
const DaemonClient = @import("client.zig").DaemonClient;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;
const platform = @import("../../platform/platform.zig");

const max_sessions: usize = 32;
const max_clients: usize = 16;
const replay_capacity: usize = RingBuffer.default_capacity;

var g_running: bool = true;

fn signalHandler(_: c_int) callconv(.c) void {
    g_running = false;
}

/// Get the default socket path: ~/.config/attyx/sessions.sock
fn getSocketPath(buf: *[256]u8) ?[]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/attyx/sessions.sock", .{home}) catch null;
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

    var clients: [max_clients]?DaemonClient = .{null} ** max_clients;
    var client_count: usize = 0;

    defer {
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

    while (g_running) {
        // Build poll fd array: listener + PTY masters + client sockets
        const max_fds = 1 + max_sessions + max_clients;
        var fds: [max_fds]posix.pollfd = undefined;
        var nfds: usize = 0;

        // [0] = listener
        fds[0] = .{ .fd = listen_fd, .events = 0x0001, .revents = 0 }; // POLLIN
        nfds = 1;

        // PTY master fds
        var pty_fd_map: [max_sessions]usize = undefined; // maps poll index → session slot
        var pty_fd_count: usize = 0;
        for (&sessions, 0..) |*slot, si| {
            if (slot.*) |*s| {
                if (s.alive) {
                    fds[nfds] = .{ .fd = s.pty.master, .events = 0x0001, .revents = 0 };
                    pty_fd_map[pty_fd_count] = si;
                    pty_fd_count += 1;
                    nfds += 1;
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

        // Read PTY data and forward to attached clients
        for (0..pty_fd_count) |pi| {
            const poll_idx = 1 + pi;
            const si = pty_fd_map[pi];
            if (fds[poll_idx].revents & 0x0001 != 0) {
                if (sessions[si]) |*s| {
                    while (true) {
                        const n = s.readPty(&pty_buf) catch break;
                        if (n == 0) break;
                        // Forward to all clients attached to this session
                        for (&clients) |*cslot| {
                            if (cslot.*) |*cl| {
                                if (cl.attached_session == s.id) {
                                    cl.sendOutput(pty_buf[0..n]);
                                }
                            }
                        }
                    }
                }
            }
            // Check POLLHUP
            if (fds[poll_idx].revents & 0x0010 != 0) {
                if (sessions[si]) |*s| {
                    if (s.checkExit()) |exit_code| {
                        // Notify attached clients
                        for (&clients) |*cslot| {
                            if (cslot.*) |*cl| {
                                if (cl.attached_session == s.id) {
                                    cl.sendSessionDied(s.id, exit_code);
                                    cl.attached_session = null;
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
                        handleMessage(cl, msg, &sessions, &session_count, &next_session_id, allocator);
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
                    if (s.checkExit()) |exit_code| {
                        for (&clients) |*cslot| {
                            if (cslot.*) |*cl| {
                                if (cl.attached_session == s.id) {
                                    cl.sendSessionDied(s.id, exit_code);
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

fn handleMessage(
    cl: *DaemonClient,
    msg: DaemonClient.Message,
    sessions: *[max_sessions]?DaemonSession,
    session_count: *usize,
    next_id: *u32,
    allocator: std.mem.Allocator,
) void {
    switch (msg.msg_type) {
        .create => {
            const create = protocol.decodeCreate(msg.payload) catch {
                cl.sendError(1, "invalid create payload");
                return;
            };
            if (session_count.* >= max_sessions) {
                cl.sendError(2, "max sessions reached");
                return;
            }
            // Find empty slot
            const slot_idx = for (sessions, 0..) |*slot, i| {
                if (slot.* == null) break i;
            } else {
                cl.sendError(2, "max sessions reached");
                return;
            };
            const id = next_id.*;
            next_id.* += 1;
            sessions[slot_idx] = DaemonSession.spawn(
                allocator,
                id,
                create.name,
                create.rows,
                create.cols,
                replay_capacity,
            ) catch {
                cl.sendError(3, "spawn failed");
                return;
            };
            session_count.* += 1;
            // Set non-blocking on PTY master
            setNonBlocking(sessions[slot_idx].?.pty.master);
            cl.sendCreated(id);
        },
        .list => {
            // Collect active sessions into contiguous slice for sendSessionList
            var active: [max_sessions]DaemonSession = undefined;
            var active_count: usize = 0;
            for (sessions) |*slot| {
                if (slot.*) |s| {
                    active[active_count] = s;
                    active_count += 1;
                }
            }
            cl.sendSessionList(active[0..active_count]);
        },
        .attach => {
            const attach = protocol.decodeAttach(msg.payload) catch {
                cl.sendError(1, "invalid attach payload");
                return;
            };
            const session = findSession(sessions, attach.session_id) orelse {
                cl.sendError(4, "session not found");
                return;
            };
            cl.attached_session = attach.session_id;
            // Resize to client's dimensions
            session.resize(attach.rows, attach.cols) catch {};
            cl.sendAttached(attach.session_id);
            // Send replay buffer
            cl.sendReplay(session);
        },
        .detach => {
            cl.attached_session = null;
        },
        .input => {
            if (cl.attached_session) |sid| {
                if (findSession(sessions, sid)) |session| {
                    session.writeInput(msg.payload) catch {};
                }
            }
        },
        .resize => {
            const r = protocol.decodeResize(msg.payload) catch return;
            if (cl.attached_session) |sid| {
                if (findSession(sessions, sid)) |session| {
                    session.resize(r.rows, r.cols) catch {};
                }
            }
        },
        .kill => {
            const kill_id = protocol.decodeKill(msg.payload) catch return;
            for (sessions) |*slot| {
                if (slot.*) |*s| {
                    if (s.id == kill_id) {
                        s.deinit();
                        slot.* = null;
                        session_count.* -= 1;
                        break;
                    }
                }
            }
        },
        // Ignore server→client messages
        else => {},
    }
}

fn findSession(sessions: *[max_sessions]?DaemonSession, id: u32) ?*DaemonSession {
    for (sessions) |*slot| {
        if (slot.*) |*s| {
            if (s.id == id) return s;
        }
    }
    return null;
}

fn acceptClient(listen_fd: posix.fd_t, clients: *[max_clients]?DaemonClient, count: *usize) void {
    const fd = posix.accept(listen_fd, null, null, 0) catch return;
    if (count.* >= max_clients) {
        posix.close(fd);
        return;
    }
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
