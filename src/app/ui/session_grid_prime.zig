const std = @import("std");
const attyx = @import("attyx");
const split_layout_mod = @import("../split_layout.zig");
const grid_sync = @import("../daemon/grid_sync.zig");
const protocol = @import("../daemon/protocol.zig");
const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const Pane = @import("../pane.zig").Pane;
const SessionClient = @import("../session_client.zig").SessionClient;
const TabManager = @import("../tab_manager.zig").TabManager;

/// Synchronously drain the first real grid frame for the active tab after a
/// session switch. Session switches rebuild client panes from layout metadata,
/// so they start as blank placeholder engines; waiting here prevents the normal
/// render loop from ever publishing that placeholder.
pub fn primeActiveTab(ctx: *PtyThreadCtx, timeout_ms: u32) void {
    primeManager(ctx, ctx.tab_mgr, timeout_ms);
}

pub fn primeManager(ctx: *PtyThreadCtx, mgr: *TabManager, timeout_ms: u32) void {
    const sc = ctx.session_client orelse return;
    if (!sc.hasGridSync() or mgr.count == 0) return;

    var active_ids: [split_layout_mod.max_panes]u32 = undefined;
    const active_count = activePaneIds(mgr, &active_ids);
    if (active_count == 0) return;

    sc.flushOut();
    const deadline_ns = std.time.nanoTimestamp() + @as(i128, @intCast(timeout_ms)) * std.time.ns_per_ms;
    while (!allPrimed(mgr, active_ids[0..active_count])) {
        if (drainPrimeMessages(sc, mgr)) continue;

        const now_ns = std.time.nanoTimestamp();
        if (now_ns >= deadline_ns) break;

        if (!sc.recvData()) return;
        if (drainPrimeMessages(sc, mgr)) continue;

        const wait_now_ns = std.time.nanoTimestamp();
        if (wait_now_ns >= deadline_ns) break;
        waitForReadable(sc.pollFd(), deadline_ns - wait_now_ns);
    }

    // If the pane is genuinely blank, don't hold the previous session forever.
    // The timeout gives resize-redraw recovery enough time to produce a nonblank
    // frame when one exists; after that, publish the authoritative state we have.
    if (!allPrimed(mgr, active_ids[0..active_count])) {
        for (active_ids[0..active_count]) |id| {
            if (findPane(mgr, id)) |pane| pane.grid_has_frame = true;
        }
    }
}

pub fn activeFramePending(ctx: *PtyThreadCtx) bool {
    if (ctx.tab_mgr.count == 0) return false;
    const sc = ctx.session_client orelse return false;
    if (!sc.hasGridSync()) return false;
    const pane = ctx.tab_mgr.activePane();
    return pane.daemon_pane_id != null and !pane.grid_has_frame;
}

pub fn activePaneIds(mgr: *TabManager, out: []u32) usize {
    var count: usize = 0;
    const layout = mgr.activeLayout();
    var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
    const lc = layout.collectLeaves(&leaves);
    for (leaves[0..lc]) |leaf| {
        if (leaf.pane.daemon_pane_id) |dpid| {
            if (count >= out.len) break;
            out[count] = dpid;
            count += 1;
        }
    }
    return count;
}

fn drainPrimeMessages(sc: *SessionClient, mgr: *TabManager) bool {
    var drained_any = false;
    while (sc.readMessage()) |msg| {
        drained_any = true;
        switch (msg) {
            .grid_snapshot => |payload| applyGridSnapshot(mgr, payload),
            .pane_title => |pt| if (findPane(mgr, pt.pane_id)) |pane| pane.engine.state.setTitle(pt.title),
            .pane_fg_cwd => |fc| if (findPane(mgr, fc.pane_id)) |pane| {
                const len: u16 = @intCast(@min(fc.cwd.len, pane.daemon_fg_cwd.len));
                @memcpy(pane.daemon_fg_cwd[0..len], fc.cwd[0..len]);
                pane.daemon_fg_cwd_len = len;
            },
            .pane_agent_status => |pas| if (findPane(mgr, pas.pane_id)) |pane| {
                pane.engine.state.setAgentStatus(attyx.actions.AgentStatus.fromU8(pas.status), pas.message);
            },
            .pane_agent_usage => |pau| if (findPane(mgr, pau.pane_id)) |pane| pane.engine.state.setAgentUsage(pau.usage),
            else => {},
        }
    }
    return drained_any;
}

fn waitForReadable(fd: std.posix.fd_t, remaining_ns: i128) void {
    if (remaining_ns <= 0) return;
    const max_wait_ns: i128 = 20 * std.time.ns_per_ms;
    const wait_ns = @min(remaining_ns, max_wait_ns);
    const timeout_ms_i128 = @max(@as(i128, 1), @divTrunc(wait_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms));
    const timeout_ms: i32 = @intCast(@min(timeout_ms_i128, @as(i128, std.math.maxInt(i32))));
    var fds = [1]std.posix.pollfd{.{ .fd = fd, .events = 0x0001, .revents = 0 }};
    _ = std.posix.poll(&fds, timeout_ms) catch {};
}

fn allPrimed(mgr: *TabManager, ids: []const u32) bool {
    for (ids) |id| {
        const pane = findPane(mgr, id) orelse return false;
        if (!pane.grid_has_frame) return false;
    }
    return true;
}

fn findPane(mgr: *TabManager, daemon_pane_id: u32) ?*Pane {
    for (mgr.tabs[0..mgr.count]) |*maybe_layout| {
        if (maybe_layout.*) |*lay| {
            var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
            const lc = lay.collectLeaves(&leaves);
            for (leaves[0..lc]) |leaf| {
                if (leaf.pane.daemon_pane_id == daemon_pane_id) return leaf.pane;
            }
        }
    }
    return null;
}

fn applyGridSnapshot(mgr: *TabManager, payload: []const u8) void {
    const info = grid_sync.decodeSnapshotHeader(payload) catch return;
    const pane = findPane(mgr, info.pane_id) orelse return;
    const ring = &pane.engine.state.ring;
    const cols_changed = ring.cols != info.cols;
    if (ring.screen_rows != info.rows or cols_changed) {
        pane.engine.state.resize(info.rows, info.cols) catch return;
        if (cols_changed) {
            pane.engine.state.ring.count = pane.engine.state.ring.screen_rows;
        }
    }

    const cell_bytes = grid_sync.snapshotCellBytes(payload, info) catch return;
    var idx: usize = 0;
    const end_row: usize = @as(usize, info.start_row) + info.row_count;
    var row: usize = info.start_row;
    while (row < end_row) : (row += 1) {
        var col: usize = 0;
        while (col < info.cols) : (col += 1) {
            pane.engine.state.ring.setScreenCell(row, col, grid_sync.unpackCell(grid_sync.readPackedCell(cell_bytes, idx)));
            idx += 1;
        }
        pane.engine.state.dirty.mark(row);
    }
    pane.engine.state.cursor.row = info.cursor_row;
    pane.engine.state.cursor.col = info.cursor_col;
    pane.engine.state.cursor_visible = info.cursor_visible;
    pane.engine.state.cursor_shape = @enumFromInt(info.cursor_shape);
    pane.engine.state.alt_active = info.alt_active;
    pane.engine.state.mouse_tracking = @enumFromInt(info.mouse_tracking);
    pane.engine.state.mouse_sgr = info.mouse_sgr;

    if (info.final_chunk and !screenBlank(pane)) pane.grid_has_frame = true;
}

fn screenBlank(pane: *Pane) bool {
    const ring = &pane.engine.state.ring;
    for (0..ring.screen_rows) |row| {
        for (ring.getScreenRow(row)) |cell| {
            if (!attyx.grid.isDefaultCell(cell)) return false;
        }
    }
    return true;
}

const testing = std.testing;
const scrollback = attyx.RingBuffer.default_max_scrollback;

fn makeTestManager(allocator: std.mem.Allocator, daemon_pane_id: u32, rows: u16, cols: u16) !TabManager {
    const pane = try allocator.create(Pane);
    pane.* = try Pane.initDaemonBacked(allocator, rows, cols, scrollback);
    pane.daemon_pane_id = daemon_pane_id;
    return TabManager.init(allocator, pane);
}

fn injectSnapshotRow(
    sc: *SessionClient,
    pane_id: u32,
    rows: u16,
    cols: u16,
    start_row: u16,
    final_chunk: bool,
    chars: []const u21,
) !void {
    const payload_len = grid_sync.snapshot_header_size + @as(usize, cols) * @sizeOf(grid_sync.PackedCell);
    var payload: [512]u8 = undefined;
    _ = try grid_sync.encodeSnapshotHeader(&payload, .{
        .pane_id = pane_id,
        .generation = 1,
        .rows = rows,
        .cols = cols,
        .cursor_row = start_row,
        .cursor_col = cols,
        .cursor_visible = true,
        .cursor_shape = 0,
        .alt_active = false,
        .start_row = start_row,
        .row_count = 1,
        .final_chunk = final_chunk,
        .scrollback_delta = 0,
    });
    const cell_bytes = payload[grid_sync.snapshot_header_size..payload_len];
    for (0..cols) |i| {
        grid_sync.writePackedCell(cell_bytes, i, grid_sync.packCell(attyx.Cell{ .char = chars[i] }));
    }

    var framed: [1024]u8 = undefined;
    const msg = try protocol.encodeMessage(&framed, .grid_snapshot, payload[0..payload_len]);
    @memcpy(sc.read_buf[sc.read_len..][0..msg.len], msg);
    sc.read_len += msg.len;
}

test "primeManager drains buffered snapshot chunks before reading socket" {
    const allocator = testing.allocator;
    const rows: u16 = 2;
    const cols: u16 = 4;
    const pane_id: u32 = 77;

    var tab_mgr = try makeTestManager(allocator, pane_id, rows, cols);
    defer tab_mgr.reset();

    var sc = SessionClient{
        .allocator = allocator,
        .socket_fd = -1,
        .daemon_caps = protocol.Capabilities.GRID_SYNC,
    };
    const row0 = [_]u21{ 'O', 'K', ' ', ' ' };
    const row1 = [_]u21{ '!', '!', ' ', ' ' };
    try injectSnapshotRow(&sc, pane_id, rows, cols, 0, false, &row0);
    try injectSnapshotRow(&sc, pane_id, rows, cols, 1, true, &row1);

    var ctx: PtyThreadCtx = undefined;
    ctx.session_client = &sc;
    primeManager(&ctx, &tab_mgr, 1000);

    const pane = tab_mgr.activePane();
    try testing.expect(pane.grid_has_frame);
    try testing.expectEqual(@as(u21, 'O'), pane.engine.state.ring.getScreenCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'K'), pane.engine.state.ring.getScreenCell(0, 1).char);
    try testing.expectEqual(@as(u21, '!'), pane.engine.state.ring.getScreenCell(1, 0).char);
    try testing.expectEqual(@as(u21, '!'), pane.engine.state.ring.getScreenCell(1, 1).char);
}
