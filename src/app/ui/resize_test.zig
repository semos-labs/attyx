// Attyx — pre-resize drain tests.
//
// Regression coverage for the "switch session + resize → blank screen" bug.
// Before resizing, handleResize drains every buffered daemon message via
// SessionClient.readMessage (which is destructive). The old drain only acted
// on pane_output and dropped everything else, so a focus-reply grid_snapshot
// (the only thing that fills a freshly-switched session's empty engine) or a
// replay_end (which swaps the shadow engine in and clears needs_engine_reinit)
// that landed during a resize was silently discarded — leaving the pane blank.
// drainPreResize now routes each message through the same path as the main
// event loop. These tests drive buffered messages through it and assert the
// pane ends up populated, not stranded.

const std = @import("std");
const testing = std.testing;

const resize = @import("resize.zig");
const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;

const TabManager = @import("../tab_manager.zig").TabManager;
const SplitLayout = @import("../split_layout.zig").SplitLayout;
const Pane = @import("../pane.zig").Pane;
const SessionClient = @import("../session_client.zig").SessionClient;
const protocol = @import("../daemon/protocol.zig");
const grid_sync = @import("../daemon/grid_sync.zig");

const attyx = @import("attyx");
const Engine = attyx.Engine;
const Cell = attyx.Cell;

const scrollback = attyx.RingBuffer.default_max_scrollback;

/// Build a single-tab TabManager around one daemon-backed pane.
fn makeManager(allocator: std.mem.Allocator, daemon_pane_id: u32, rows: u16, cols: u16) !TabManager {
    const pane = try allocator.create(Pane);
    pane.* = try Pane.initDaemonBacked(allocator, rows, cols, scrollback);
    pane.daemon_pane_id = daemon_pane_id;
    return TabManager.init(allocator, pane);
}

/// Minimal ctx: drainPreResize only reaches ctx.tab_mgr (via findPaneByDaemonId)
/// for the message kinds exercised here. The remaining fields are left
/// undefined deliberately — touching them would be a bug in the code under test.
fn makeCtx(tab_mgr: *TabManager) PtyThreadCtx {
    var ctx: PtyThreadCtx = undefined;
    ctx.tab_mgr = tab_mgr;
    ctx.session_client = null;
    ctx.applied_scrollback_lines = scrollback;
    return ctx;
}

fn injectMessage(sc: *SessionClient, msg: []const u8) void {
    @memcpy(sc.read_buf[sc.read_len..][0..msg.len], msg);
    sc.read_len += msg.len;
}

test "drainPreResize finalizes a buffered replay_end (shadow swaps in, reinit clears)" {
    const allocator = testing.allocator;

    var tab_mgr = try makeManager(allocator, 42, 24, 80);
    defer tab_mgr.reset();
    const pane = tab_mgr.activePane();

    // Mid-reinit state: live engine is blank, replay bytes have accumulated in
    // a shadow engine, and we're waiting on replay_end to swap it in.
    pane.needs_engine_reinit = true;
    pane.shadow_engine = try Engine.init(allocator, 24, 80, scrollback);
    pane.shadow_engine.?.feed("HELLO");

    // Sanity: the visible engine has nothing yet.
    try testing.expectEqual(@as(u21, ' '), pane.engine.state.ring.getScreenCell(0, 0).char);

    var sc = SessionClient{ .allocator = allocator };
    var framed: [64]u8 = undefined;
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u32, &payload, 42, .little);
    const msg = try protocol.encodeMessage(&framed, .replay_end, &payload);
    injectMessage(&sc, msg);

    var ctx = makeCtx(&tab_mgr);
    resize.drainPreResize(&ctx, &sc);

    // The replay_end was applied, not dropped: shadow swapped into the live
    // engine and the reinit flag cleared, so future output renders live.
    try testing.expect(!pane.needs_engine_reinit);
    try testing.expect(pane.shadow_engine == null);
    try testing.expectEqual(@as(u21, 'H'), pane.engine.state.ring.getScreenCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'E'), pane.engine.state.ring.getScreenCell(0, 1).char);
}

test "drainPreResize applies a buffered grid_snapshot (fills the live engine)" {
    const allocator = testing.allocator;

    const rows: u16 = 2;
    const cols: u16 = 4;
    var tab_mgr = try makeManager(allocator, 7, rows, cols);
    defer tab_mgr.reset();
    const pane = tab_mgr.activePane();

    // Build a full-grid snapshot for pane 7: row 0 = "HI", rest blank.
    const cell_count: usize = @as(usize, rows) * @as(usize, cols);
    const payload_len = grid_sync.snapshot_header_size + cell_count * @sizeOf(grid_sync.PackedCell);
    var payload: [256]u8 = undefined;
    _ = try grid_sync.encodeSnapshotHeader(&payload, .{
        .pane_id = 7,
        .generation = 1,
        .rows = rows,
        .cols = cols,
        .cursor_row = 0,
        .cursor_col = 2,
        .cursor_visible = true,
        .cursor_shape = 0,
        .alt_active = false,
        .start_row = 0,
        .row_count = rows,
        .final_chunk = true,
        .scrollback_delta = 0,
    });
    const cell_bytes = payload[grid_sync.snapshot_header_size..payload_len];
    const chars = [_]u21{ 'H', 'I', ' ', ' ', ' ', ' ', ' ', ' ' };
    for (0..cell_count) |i| {
        grid_sync.writePackedCell(cell_bytes, i, grid_sync.packCell(Cell{ .char = chars[i] }));
    }

    var sc = SessionClient{ .allocator = allocator };
    var framed: [512]u8 = undefined;
    const msg = try protocol.encodeMessage(&framed, .grid_snapshot, payload[0..payload_len]);
    injectMessage(&sc, msg);

    var ctx = makeCtx(&tab_mgr);
    resize.drainPreResize(&ctx, &sc);

    // The snapshot was applied, not dropped: the pane is no longer blank.
    try testing.expectEqual(@as(u21, 'H'), pane.engine.state.ring.getScreenCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'I'), pane.engine.state.ring.getScreenCell(0, 1).char);
}
