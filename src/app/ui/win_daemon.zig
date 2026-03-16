// Daemon socket drain for Windows event loop.
// Reads messages from the session daemon and routes output to panes.

const std = @import("std");
const logging = @import("../../logging/log.zig");
const ws = @import("../windows_stubs.zig");
const SessionClient = @import("../session_client.zig").SessionClient;
const DaemonMessage = @import("../session_client.zig").DaemonMessage;
const split_layout_mod = @import("../split_layout.zig");
const WinCtx = @import("event_loop_windows.zig").WinCtx;

/// Drain all pending daemon messages. Returns true if any pane output was received.
pub fn drainDaemon(ctx: *WinCtx) bool {
    const sc = ctx.session_client orelse return false;

    // Non-blocking read from daemon socket.
    if (!sc.recvData()) {
        // Pipe broken — daemon died. Clear daemon state.
        logging.warn("daemon", "daemon connection lost", .{});
        ctx.session_client = null;
        ws.g_session_client = null;
        ws.g_active_daemon_pane_id = 0;
        return false;
    }

    var got_output = false;
    while (sc.readMessage()) |msg| {
        switch (msg) {
            .pane_output => |po| {
                got_output = true;
                routePaneOutput(ctx, po.pane_id, po.data);
            },
            .pane_died => |pd| {
                logging.info("daemon", "pane {d} died (exit={d})", .{ pd.pane_id, pd.exit_code });
                handlePaneDied(ctx, pd.pane_id);
            },
            .pane_proc_name => {},
            .replay_end => {},
            .layout_sync => {},
            .session_list => {},
            .session_attached => {},
            .session_created => {},
            .pane_created => {},
            .err => {},
            .hello_ack => {},
        }
    }
    return got_output;
}

/// Route daemon pane output to the matching pane's engine.
fn routePaneOutput(ctx: *WinCtx, pane_id: u32, data: []const u8) void {
    const attyx = @import("attyx");
    const publish = @import("publish.zig");
    for (ctx.tab_mgr.tabs[0..ctx.tab_mgr.count]) |*maybe_layout| {
        const lay = &(maybe_layout.* orelse continue);
        var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
        const lc = lay.collectLeaves(&leaves);
        for (leaves[0..lc]) |leaf| {
            if (leaf.pane.daemon_pane_id) |dpid| {
                if (dpid == pane_id) {
                    // Deferred engine reinit: if the daemon is replaying
                    // scrollback for a newly-focused pane, reinit the
                    // engine before feeding data to avoid stale content.
                    if (leaf.pane.needs_engine_reinit) {
                        const rows: u16 = @intCast(leaf.pane.engine.state.ring.screen_rows);
                        const cols: u16 = @intCast(leaf.pane.engine.state.ring.cols);
                        const new_engine = attyx.Engine.init(
                            leaf.pane.allocator,
                            rows,
                            cols,
                            ctx.applied_scrollback_lines,
                        ) catch return;
                        leaf.pane.engine.deinit();
                        leaf.pane.engine = new_engine;
                        leaf.pane.engine.state.theme_colors = publish.themeToEngineColors(ctx.theme);
                        leaf.pane.needs_engine_reinit = false;
                    }
                    leaf.pane.feed(data);
                    return;
                }
            }
        }
    }
}

/// Handle a daemon pane dying — store exit code and close pane/tab.
fn handlePaneDied(ctx: *WinCtx, pane_id: u32) void {
    const c = @import("publish.zig").c;
    var tab_idx: u8 = 0;
    while (tab_idx < ctx.tab_mgr.count) : (tab_idx += 1) {
        const lay = &(ctx.tab_mgr.tabs[tab_idx] orelse continue);
        for (&lay.pool, 0..) |*node, i| {
            if (node.tag != .leaf) continue;
            const pane = node.pane orelse continue;
            const dpid = pane.daemon_pane_id orelse continue;
            if (dpid != pane_id) continue;

            pane.stored_exit_code = 0;
            if (lay.pane_count <= 1) {
                ctx.tab_mgr.closeTab(tab_idx);
                if (ctx.tab_mgr.count == 0) {
                    c.attyx_request_quit();
                    return;
                }
            } else {
                _ = lay.closePaneAt(@intCast(i), ctx.allocator);
                const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - ws.g_grid_top_offset - ws.g_grid_bottom_offset));
                lay.layout(pty_rows, ctx.grid_cols);
            }
            return;
        }
    }
}
