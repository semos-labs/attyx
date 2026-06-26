// Attyx — agent status watch subscriptions
//
// Streaming counterpart to the one-shot `list agents` query. A `watch agents`
// IPC request is NOT answered-and-closed like every other command; instead its
// response fd is parked in a small registry and fed one framed JSON line on
// every agent status transition (NDJSON over the control socket).
//
// Threading: both register() (from the IPC handler) and broadcast() (from the
// event-loop tick) run on the PTY thread — the handler is drained inside the
// same tick that detects status changes. So the registry needs no locking; the
// IPC listener thread never touches it (it only hands fds over via the queue).
//
// Backpressure: watcher fds are non-blocking and each frame is written in a
// single shot. If a write can't complete (slow/dead client, full socket
// buffer) the watcher is dropped rather than risk stalling the PTY thread or
// corrupting the frame stream. Status changes are low-frequency, so a healthy
// client never hits this.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const is_windows = builtin.os.tag == .windows;
const platform = @import("../platform/platform.zig");
const protocol = @import("protocol.zig");
const queue = @import("queue.zig");
const agents = @import("agents.zig");
const terminal = @import("../app/terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const Pane = @import("../app/pane.zig").Pane;
const split_layout_mod = @import("../app/split_layout.zig");

const max_watchers = 16;
/// Worst-case framed JSON line: header + a generous JSON object cap.
const frame_cap = protocol.header_size + 1024;

const Watcher = struct {
    fd: posix.fd_t,
    session_id: u32,
    /// Only stream this pane's agent; 0 = all agents.
    pane_filter: u32,
};

var watchers: [max_watchers]Watcher = undefined;
var watcher_count: usize = 0;

/// Handle a `watch_agents` IPC request. On success the fd is retained (not
/// closed) and parked in the registry after an initial snapshot. On failure
/// the fd is closed here.
pub fn handleWatchAgents(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
    const fd = cmd.response_fd;
    if (fd == queue.invalid_fd) return;

    if (is_windows) {
        sendErrAndClose(fd, "watch is not supported on this platform");
        return;
    }
    if (watcher_count >= max_watchers) {
        sendErrAndClose(fd, "too many watchers");
        return;
    }

    setNonBlocking(fd);

    // Optional pane filter: payload is [pane_filter:u32 LE] (0 = all agents).
    const pane_filter: u32 = if (cmd.payload_len >= 4)
        std.mem.readInt(u32, cmd.payload[0..4], .little)
    else
        0;

    // Send the current set of active agents up front so a freshly-attached
    // watcher has full state without waiting for the next transition. If the
    // client is already unwritable, drop it before parking.
    if (!writeSnapshot(ctx, fd, pane_filter)) {
        protocol.closeFd(fd);
        return;
    }

    watchers[watcher_count] = .{ .fd = fd, .session_id = cmd.session_id, .pane_filter = pane_filter };
    watcher_count += 1;
}

/// Broadcast a single agent's current status to all watchers. Called from the
/// event loop when a pane's agent_status_changed flag fires (includes the
/// transition to `.none` when a session ends, so watchers see agents leave).
/// `tab_id` is the agent's tab's stable handle (its focused pane's IPC id).
pub fn broadcastAgent(ctx: *PtyThreadCtx, pane: *Pane, tab_id: u32) void {
    if (watcher_count == 0) return;

    var frame_buf: [frame_cap]u8 = undefined;
    const frame = buildFrame(&frame_buf, sessionId(ctx), pane, tab_id) orelse return;

    var i: usize = 0;
    while (i < watcher_count) {
        const wt = watchers[i];
        // Skip watchers filtered to a different pane.
        if (wt.pane_filter != 0 and wt.pane_filter != pane.ipc_id) {
            i += 1;
            continue;
        }
        if (tryWriteFrame(wt.fd, frame)) {
            i += 1;
        } else {
            dropWatcher(i);
        }
    }
}

/// Close every parked watcher fd. Called on instance shutdown.
pub fn closeAll() void {
    for (watchers[0..watcher_count]) |wt| protocol.closeFd(wt.fd);
    watcher_count = 0;
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

fn sessionId(ctx: *PtyThreadCtx) u32 {
    if (ctx.session_client) |sc| return sc.attached_session_id orelse 0;
    return 0;
}

/// Build a framed (.success) NDJSON line for one agent. Returns null if the
/// JSON object overflowed the buffer (never expected for our field set).
fn buildFrame(buf: []u8, session: u32, pane: *Pane, tab_id: u32) ?[]const u8 {
    var json_buf: [frame_cap - protocol.header_size]u8 = undefined;
    var stream = std.io.fixedBufferStream(&json_buf);
    agents.writeAgentJson(
        stream.writer(),
        pane.ipc_id,
        tab_id,
        session,
        agents.panePid(pane.pty.master),
        pane.engine.state.agent_status,
        pane.engine.state.agentMsg(),
        pane.engine.state.agentUsage(),
    ) catch return null;
    return protocol.encodeMessage(buf, .success, stream.getWritten()) catch null;
}

/// Write the current active agents (status != none) to a single fd as one
/// frame each. With pane_filter != 0, only that pane is included. Returns false
/// if any write fails (caller drops the watcher).
fn writeSnapshot(ctx: *PtyThreadCtx, fd: posix.fd_t, pane_filter: u32) bool {
    const session = sessionId(ctx);
    const mgr = ctx.tab_mgr;
    var frame_buf: [frame_cap]u8 = undefined;
    for (0..mgr.count) |i| {
        const layout = &(mgr.tabs[i] orelse continue);
        const tab_id = layout.focusedPane().ipc_id;
        var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
        const lc = layout.collectLeaves(&leaves);
        for (leaves[0..lc]) |leaf| {
            if (leaf.pane.engine.state.agent_status == .none) continue;
            if (pane_filter != 0 and pane_filter != leaf.pane.ipc_id) continue;
            const frame = buildFrame(&frame_buf, session, leaf.pane, tab_id) orelse continue;
            if (!tryWriteFrame(fd, frame)) return false;
        }
    }
    return true;
}

/// Single-shot, non-blocking write. Returns true only when the entire frame
/// was written. WouldBlock, partial writes, and broken pipes all fail (and the
/// caller drops the watcher) — never blocks the PTY thread.
fn tryWriteFrame(fd: posix.fd_t, frame: []const u8) bool {
    if (is_windows) return false;
    const n = posix.write(fd, frame) catch return false;
    return n == frame.len;
}

fn dropWatcher(idx: usize) void {
    protocol.closeFd(watchers[idx].fd);
    watcher_count -= 1;
    if (idx != watcher_count) watchers[idx] = watchers[watcher_count];
}

fn sendErrAndClose(fd: posix.fd_t, msg: []const u8) void {
    var buf: [128]u8 = undefined;
    if (protocol.encodeMessage(&buf, .err, msg)) |m| {
        protocol.writeAll(fd, m) catch {};
    } else |_| {}
    protocol.closeFd(fd);
}

fn setNonBlocking(fd: posix.fd_t) void {
    if (is_windows) return;
    if (fd < 0) return;
    const F_GETFL: i32 = 3;
    const F_SETFL: i32 = 4;
    const flags = posix.fcntl(fd, F_GETFL, 0) catch return;
    _ = posix.fcntl(fd, F_SETFL, flags | platform.O_NONBLOCK) catch {};
}
