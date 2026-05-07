// Daemon socket drain for Windows event loop.
// Reads messages from the session daemon and routes output to panes.

const std = @import("std");
const logging = @import("../../logging/log.zig");
const ws = @import("../windows_stubs.zig");
const SessionClient = @import("../session_client.zig").SessionClient;
const DaemonMessage = @import("../session_client.zig").DaemonMessage;
const split_layout_mod = @import("../split_layout.zig");
const layout_codec = @import("../layout_codec.zig");
const session_connect = @import("../session_connect.zig");
const event_loop = @import("event_loop_windows.zig");
const WinCtx = event_loop.WinCtx;
const publish = @import("publish.zig");
const c = publish.c;

extern "kernel32" fn Sleep(dwMilliseconds: std.os.windows.DWORD) callconv(.winapi) void;

/// Drain all pending daemon messages. Returns true if any pane output was received.
pub fn drainDaemon(ctx: *WinCtx) bool {
    const sc = ctx.session_client orelse return false;

    // Non-blocking read from daemon socket.
    if (!sc.recvData()) {
        handleDaemonDeath(ctx);
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
                handlePaneDied(ctx, pd.pane_id, pd.exit_code);
            },
            .pane_proc_name => |pn| {
                if (findPaneByDaemonId(ctx, pn.pane_id)) |result| {
                    const len: u8 = @intCast(@min(pn.name.len, 64));
                    @memcpy(result.pane.daemon_proc_name[0..len], pn.name[0..len]);
                    result.pane.daemon_proc_name_len = len;
                    if (result.tab_idx == ctx.tab_mgr.active) got_output = true;
                }
            },
            .pane_fg_cwd => |fc| {
                if (findPaneByDaemonId(ctx, fc.pane_id)) |result| {
                    const len: u16 = @intCast(@min(fc.cwd.len, 512));
                    @memcpy(result.pane.daemon_fg_cwd[0..len], fc.cwd[0..len]);
                    result.pane.daemon_fg_cwd_len = len;
                }
            },
            .replay_end => |pane_id| {
                if (findPaneByDaemonId(ctx, pane_id)) |result| {
                    const rows: u16 = @intCast(result.pane.engine.state.ring.screen_rows);
                    const cols: u16 = @intCast(result.pane.engine.state.ring.cols);
                    if (ctx.session_client) |scc| {
                        const nudged = if (cols > 1) cols - 1 else cols + 1;
                        scc.sendPaneResize(pane_id, rows, nudged) catch {};
                        scc.sendPaneResize(pane_id, rows, cols) catch {};
                    }
                }
            },
            .layout_sync => |sync| {
                handleLayoutSync(ctx, sync.layout);
                got_output = true;
            },
            .session_list => {},
            .session_attached => {},
            .session_created => {},
            .pane_created => {},
            .err => {},
            .hello_ack => {},
            // Grid-sync messages: ignored on Windows until the grid-sync
            // receivers in event_loop.zig are ported over. The Windows
            // build advertises caps=0 in its hello, so a spec-conforming
            // daemon won't send these — but in practice a mixed-version
            // daemon or rogue server could, and we must not panic on them.
            .grid_snapshot => {},
            .scrollback_chunk => {},
            .scrollback_range => {},
            .pane_title => {},
        }
    }
    return got_output;
}

/// Route daemon pane output to the matching pane's engine.
fn routePaneOutput(ctx: *WinCtx, pane_id: u32, data: []const u8) void {
    const attyx = @import("attyx");
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

/// Handle a daemon pane dying — store exit code, close pane/tab, follow up.
fn handlePaneDied(ctx: *WinCtx, pane_id: u32, exit_code: u8) void {
    const result = findPaneByDaemonId(ctx, pane_id) orelse {
        logging.info("daemon", "pane_died: pane_id={d} NOT FOUND in any tab", .{pane_id});
        return;
    };

    result.pane.stored_exit_code = exit_code;

    if (ctx.tab_mgr.tabs[result.tab_idx]) |*lay| {
        const close_result = lay.closePaneAt(result.pool_idx, ctx.allocator);
        if (close_result == .last_pane) {
            ctx.tab_mgr.closeTab(result.tab_idx);
            if (ctx.tab_mgr.count == 0) {
                // Try switching to another alive session before quitting.
                if (switchToNextSession(ctx)) return;
                c.attyx_request_quit();
                return;
            }
            event_loop.updateGridOffsets(ctx);
        } else {
            // Re-layout and resize surviving daemon panes.
            const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - ws.g_grid_top_offset - ws.g_grid_bottom_offset));
            lay.layout(pty_rows, ctx.grid_cols);
            if (ctx.session_client) |sc| {
                var rl: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
                const rlc = lay.collectLeaves(&rl);
                for (rl[0..rlc]) |leaf| {
                    if (leaf.pane.daemon_pane_id) |dpid|
                        sc.sendPaneResize(dpid, leaf.rect.rows, leaf.rect.cols) catch {};
                }
            }
        }
        event_loop.switchActiveTab(ctx);
        sendFocusPanesForActiveTab(ctx);
        saveLayoutToDaemon(ctx);
    }
}

/// Try to switch to another alive session. Returns true if switched.
fn switchToNextSession(ctx: *WinCtx) bool {
    const sc = ctx.session_client orelse return false;
    const current_id = sc.attached_session_id orelse return false;
    sc.requestListSync(2000) catch return false;
    for (sc.pending_list[0..sc.pending_list_count]) |entry| {
        if (entry.alive and entry.id != current_id) {
            doSessionSwitch(ctx, entry.id);
            if (ctx.tab_mgr.count > 0) return true;
        }
    }
    return false;
}

/// Switch to a different session by ID.
fn doSessionSwitch(ctx: *WinCtx, session_id: u32) void {
    const sc = ctx.session_client orelse return;
    const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - ws.g_grid_top_offset - ws.g_grid_bottom_offset));

    if (sc.attached_session_id) |current| {
        if (current == session_id) return;
    }

    saveLayoutToDaemon(ctx);
    sc.detach() catch {};
    ctx.tab_mgr.reset();

    sc.attach(session_id, pty_rows, ctx.grid_cols) catch return;
    const attach_result = sc.waitForAttach(3000) catch return;

    // Reconstruct tabs from layout blob
    if (sc.layout_len > 0) {
        if (layout_codec.deserialize(sc.layout_buf[0..sc.layout_len])) |info| {
            ctx.tab_mgr.reconstructFromLayout(&info, pty_rows, ctx.grid_cols, ctx.applied_scrollback_lines) catch {};
        } else |_| {}
    }

    // Fallback: single daemon-backed pane
    if (ctx.tab_mgr.count == 0 and attach_result.pane_count > 0) {
        const Pane = @import("../pane.zig").Pane;
        const pane = ctx.allocator.create(Pane) catch return;
        pane.* = Pane.initDaemonBacked(ctx.allocator, pty_rows, ctx.grid_cols, ctx.applied_scrollback_lines) catch {
            ctx.allocator.destroy(pane);
            return;
        };
        pane.daemon_pane_id = attach_result.pane_ids[0];
        ctx.tab_mgr.tabs[0] = split_layout_mod.SplitLayout.init(pane);
        ctx.tab_mgr.count = 1;
        ctx.tab_mgr.active = 0;
    }

    if (ctx.tab_mgr.count == 0) return;

    ctx.last_focus_count = 0;
    event_loop.switchActiveTab(ctx);
    c.attyx_mark_all_dirty();
    session_connect.saveLastSession(session_id);
    logging.info("daemon", "switched to session {d}", .{session_id});
}

/// Handle layout_sync broadcast from daemon (another window changed tabs/splits).
fn handleLayoutSync(ctx: *WinCtx, layout_data: []const u8) void {
    if (layout_data.len == 0) return;
    const info = layout_codec.deserialize(layout_data) catch return;
    const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - ws.g_grid_top_offset - ws.g_grid_bottom_offset));

    ctx.tab_mgr.syncFromLayout(&info, pty_rows, ctx.grid_cols, ctx.applied_scrollback_lines) catch return;

    if (ctx.tab_mgr.count == 0) {
        c.attyx_request_quit();
        return;
    }

    // Resize daemon PTYs to match each pane's layout dimensions
    if (ctx.session_client) |sc| {
        for (ctx.tab_mgr.tabs[0..ctx.tab_mgr.count]) |*maybe_layout| {
            if (maybe_layout.*) |*lay| {
                var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
                const lc = lay.collectLeaves(&leaves);
                for (leaves[0..lc]) |leaf| {
                    if (leaf.pane.daemon_pane_id) |dpid|
                        sc.sendPaneResize(dpid, leaf.rect.rows, leaf.rect.cols) catch {};
                }
            }
        }
    }

    // Update globals and focus
    const ap = ctx.tab_mgr.activePane();
    ws.g_engine = &ap.engine;
    ws.g_active_daemon_pane_id = ap.daemon_pane_id orelse 0;

    ctx.last_focus_count = 0;
    event_loop.switchActiveTab(ctx);
    c.attyx_mark_all_dirty();

    event_loop.generateTabBar(ctx);
    event_loop.generateStatusbar(ctx);

    logging.info("layout-sync", "synced layout from another window", .{});
}

/// Handle daemon connection loss — attempt reconnect with exponential backoff.
fn handleDaemonDeath(ctx: *WinCtx) void {
    logging.warn("daemon", "daemon connection lost, attempting reconnect...", .{});

    // Save session ID and CWD for re-attach after reconnect
    var saved_session_id: ?u32 = null;
    var saved_cwd: [std.fs.max_path_bytes]u8 = undefined;
    var saved_cwd_len: usize = 0;
    if (ctx.tab_mgr.count > 0) {
        if (ctx.tab_mgr.activePane().engine.state.working_directory) |wd| {
            saved_cwd_len = @min(wd.len, saved_cwd.len);
            @memcpy(saved_cwd[0..saved_cwd_len], wd[0..saved_cwd_len]);
        }
    }
    if (ctx.session_client) |sc| {
        saved_session_id = sc.attached_session_id;
        sc.deinit();
        ctx.allocator.destroy(sc);
    }
    ctx.session_client = null;
    ws.g_session_client = null;
    ws.g_active_daemon_pane_id = 0;

    // Attempt reconnect with backoff (up to ~15s total).
    var delay_ms: u32 = 200;
    for (0..20) |_| {
        if (c.attyx_should_quit() != 0) return;
        Sleep(delay_ms);

        const heap_sc = ctx.allocator.create(SessionClient) catch {
            if (delay_ms < 800) delay_ms *= 2;
            continue;
        };
        heap_sc.* = SessionClient.connect(ctx.allocator) catch {
            ctx.allocator.destroy(heap_sc);
            if (delay_ms < 800) delay_ms *= 2;
            continue;
        };

        // Drain the probe response left by connectToSocket's probeAlive
        _ = heap_sc.recvData();
        while (heap_sc.readMessage()) |_| {}

        const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - ws.g_grid_top_offset - ws.g_grid_bottom_offset));

        // Try re-attach to old session (works after hot-upgrade).
        if (saved_session_id) |sid| {
            heap_sc.attach(sid, pty_rows, ctx.grid_cols) catch {
                heap_sc.deinit();
                ctx.allocator.destroy(heap_sc);
                if (delay_ms < 800) delay_ms *= 2;
                continue;
            };

            if (heap_sc.waitForAttach(1000)) |_| {
                ctx.session_client = heap_sc;
                ws.g_session_client = heap_sc;
                reconstructTabsFromDaemon(ctx, heap_sc, pty_rows);
                sendFocusPanesForActiveTab(ctx);
                c.attyx_mark_all_dirty();
                logging.info("daemon", "soft reconnect successful", .{});
                return;
            } else |_| {
                // Session gone — create a fresh one on the new daemon.
                const cwd = if (saved_cwd_len > 0) saved_cwd[0..saved_cwd_len] else null;
                if (createFreshSession(ctx, heap_sc, pty_rows, cwd)) {
                    sendFocusPanesForActiveTab(ctx);
                    c.attyx_mark_all_dirty();
                    logging.info("daemon", "reconnect: created new session on new daemon", .{});
                    return;
                }
                heap_sc.deinit();
                ctx.allocator.destroy(heap_sc);
                break;
            }
        }

        // No saved session — create a fresh one
        const cwd = if (saved_cwd_len > 0) saved_cwd[0..saved_cwd_len] else null;
        if (createFreshSession(ctx, heap_sc, pty_rows, cwd)) {
            sendFocusPanesForActiveTab(ctx);
            c.attyx_mark_all_dirty();
            logging.info("daemon", "reconnect (no prior session) successful", .{});
            return;
        }

        heap_sc.deinit();
        ctx.allocator.destroy(heap_sc);
        if (delay_ms < 800) delay_ms *= 2;
    }

    // Reconnect failed — fall back to local PTY.
    logging.warn("daemon", "soft reconnect failed, falling back to local PTY", .{});
    hardResetToLocalPty(ctx);
}

/// Reconstruct tabs from the daemon's layout blob after reconnect.
fn reconstructTabsFromDaemon(ctx: *WinCtx, sc: *SessionClient, pty_rows: u16) void {
    if (sc.layout_len == 0) return;

    const info = layout_codec.deserialize(sc.layout_buf[0..sc.layout_len]) catch {
        logging.warn("daemon", "reconnect: layout deserialization failed", .{});
        return;
    };
    if (info.tab_count == 0) return;

    ctx.tab_mgr.reset();
    ctx.tab_mgr.reconstructFromLayout(&info, pty_rows, ctx.grid_cols, ctx.applied_scrollback_lines) catch {
        logging.err("daemon", "reconnect: layout reconstruction failed, creating fallback pane", .{});
        const Pane = @import("../pane.zig").Pane;
        const pane = ctx.allocator.create(Pane) catch return;
        pane.* = Pane.initDaemonBacked(ctx.allocator, pty_rows, ctx.grid_cols, ctx.applied_scrollback_lines) catch {
            ctx.allocator.destroy(pane);
            return;
        };
        ctx.tab_mgr.tabs[0] = split_layout_mod.SplitLayout.init(pane);
        ctx.tab_mgr.count = 1;
        ctx.tab_mgr.active = 0;
    };
    if (ctx.tab_mgr.count == 0) return;

    // Update globals for the new active pane
    const ap = ctx.tab_mgr.activePane();
    ws.g_engine = &ap.engine;
    ws.g_active_daemon_pane_id = ap.daemon_pane_id orelse 0;

    // Push theme colors to all reconstructed engines
    const tc = publish.themeToEngineColors(ctx.theme);
    for (ctx.tab_mgr.tabs[0..ctx.tab_mgr.count]) |*maybe_layout| {
        if (maybe_layout.*) |*lay| {
            var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
            const lc = lay.collectLeaves(&leaves);
            for (leaves[0..lc]) |leaf| {
                leaf.pane.engine.state.theme_colors = tc;
            }
        }
    }

    logging.info("daemon", "reconstructed {d} tab(s) from daemon layout", .{ctx.tab_mgr.count});
}

/// Create a new session on the daemon, set up tab/pane, install session client.
fn createFreshSession(ctx: *WinCtx, sc: *SessionClient, pty_rows: u16, saved_cwd: ?[]const u8) bool {
    const Pane = @import("../pane.zig").Pane;
    const SplitLayout = split_layout_mod.SplitLayout;

    const cwd = saved_cwd orelse "C:\\";
    const new_id = sc.createSession("default", pty_rows, ctx.grid_cols, cwd, "") catch return false;
    sc.attach(new_id, pty_rows, ctx.grid_cols) catch return false;
    const attach_result = sc.waitForAttach(3000) catch return false;

    if (attach_result.pane_count == 0) return false;

    ctx.tab_mgr.reset();
    const pane = ctx.allocator.create(Pane) catch return false;
    pane.* = Pane.initDaemonBacked(ctx.allocator, pty_rows, ctx.grid_cols, ctx.applied_scrollback_lines) catch {
        ctx.allocator.destroy(pane);
        return false;
    };
    pane.daemon_pane_id = attach_result.pane_ids[0];
    ctx.tab_mgr.tabs[0] = SplitLayout.init(pane);
    ctx.tab_mgr.count = 1;
    ctx.tab_mgr.active = 0;

    ws.g_engine = &pane.engine;
    ws.g_active_daemon_pane_id = pane.daemon_pane_id orelse 0;
    ctx.session_client = sc;
    ws.g_session_client = sc;
    return true;
}

/// Fall back to a local ConPTY when daemon reconnect fails.
fn hardResetToLocalPty(ctx: *WinCtx) void {
    const Pane = @import("../pane.zig").Pane;
    const SplitLayout = split_layout_mod.SplitLayout;
    ctx.tab_mgr.reset();
    ctx.session_client = null;
    ws.g_session_client = null;
    ws.g_active_daemon_pane_id = 0;
    const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - ws.g_grid_top_offset - ws.g_grid_bottom_offset));
    const pane = ctx.allocator.create(Pane) catch return;
    pane.* = Pane.spawn(ctx.allocator, pty_rows, ctx.grid_cols, null, null, ctx.applied_scrollback_lines) catch {
        ctx.allocator.destroy(pane);
        return;
    };
    ctx.tab_mgr.tabs[0] = SplitLayout.init(pane);
    ctx.tab_mgr.count = 1;
    ctx.tab_mgr.active = 0;
    ws.g_engine = &pane.engine;
    ws.g_active_daemon_pane_id = 0;
}

/// Find a pane by its daemon pane ID across all tabs.
fn findPaneByDaemonId(ctx: *WinCtx, pane_id: u32) ?struct { pane: *@import("../pane.zig").Pane, tab_idx: u8, pool_idx: u8 } {
    for (ctx.tab_mgr.tabs[0..ctx.tab_mgr.count], 0..) |*maybe, ti| {
        if (maybe.*) |*lay| {
            for (&lay.pool, 0..) |*node, i| {
                if (node.tag != .leaf) continue;
                const pane = node.pane orelse continue;
                const dpid = pane.daemon_pane_id orelse continue;
                if (dpid == pane_id) return .{ .pane = pane, .tab_idx = @intCast(ti), .pool_idx = @intCast(i) };
            }
        }
    }
    return null;
}

// Re-export helpers used from event_loop_windows.zig
pub fn sendFocusPanesForActiveTab(ctx: *WinCtx) void {
    event_loop.sendFocusPanesForActiveTab(ctx);
}

fn saveLayoutToDaemon(ctx: *WinCtx) void {
    event_loop.saveLayoutToDaemon(ctx);
}
