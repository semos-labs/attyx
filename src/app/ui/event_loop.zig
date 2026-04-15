const std = @import("std");
const posix = std.posix;
const attyx = @import("attyx");
const SearchState = attyx.SearchState;
const state_hash = attyx.hash;
const logging = @import("../../logging/log.zig");
const split_layout_mod = @import("../split_layout.zig");
const split_render = @import("../split_render.zig");

const overlay_mod = attyx.overlay_mod;
const update_check = attyx.overlay_update_check;

const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const c = terminal.c;
const publish = @import("publish.zig");
const input = @import("input.zig");
const search = @import("search.zig");
const ai = @import("ai.zig");
const actions = @import("actions.zig");
const session_actions = @import("session_actions.zig");
const resize_mod = @import("resize.zig");
const hup_mod = @import("hup.zig");
const overlay_input = @import("overlay_input.zig");
const session_picker_ui = @import("session_picker_ui.zig");
const command_palette_ui = @import("command_palette_ui.zig");
const theme_picker_ui = @import("theme_picker_ui.zig");
const tab_picker_ui = @import("tab_picker_ui.zig");
const copy_mode = @import("copy_mode.zig");
const selection = @import("selection.zig");
const toast = attyx.overlay_toast;
const ipc_queue = @import("../../ipc/queue.zig");
const ipc_handler = @import("../../ipc/handler.zig");
const grid_sync = @import("../daemon/grid_sync.zig");

/// Re-export from actions module for external access.
pub const computeSplitGaps = actions.computeSplitGaps;
pub const updateSplitActive = actions.updateSplitActive;
pub const switchActiveTab = actions.switchActiveTab;
pub const doReloadConfig = actions.doReloadConfig;
pub const closePopup = actions.closePopup;
pub const handlePopupExit = actions.handlePopupExit;

pub fn ptyReaderThread(ctx: *PtyThreadCtx) void {
    const POLLIN: i16 = 0x0001;
    const POLLHUP: i16 = 0x0010;
    var buf: [65536]u8 = undefined;
    var last_published_vp: usize = 0;
    var last_publish_ns: i128 = 0;
    const min_frame_ns: i128 = 16 * std.time.ns_per_ms; // ~60fps publish cap

    // Save layout and last-session on clean shutdown (before terminal.zig closes the socket).
    defer {
        if (ctx.session_client) |sc| {
            var save_buf: [4096]u8 = undefined;
            const save_len = ctx.tab_mgr.serializeLayout(&save_buf) catch 0;
            if (save_len > 0) {
                sc.sendSaveLayout(save_buf[0..save_len]) catch {};
            }
            if (sc.attached_session_id) |sid| {
                const session_connect = @import("../session_connect.zig");
                session_connect.saveLastSession(sid);
            }
        }
    }

    search.g_search = SearchState.init(publish.ctxEngine(ctx).state.ring.allocator);
    defer {
        if (search.g_search) |*s| s.deinit();
        search.g_search = null;
    }

    // Configure session finder from config
    session_picker_ui.setFinderConfig(
        ctx.session_finder_root,
        ctx.session_finder_depth,
        ctx.session_finder_show_hidden,
    );

    // Self-pipe for waking the poll loop on UI events.  Must be initialized
    // before any code path that calls input.wake().
    input.initWakePipe();

    // Apply initial grid offsets (statusbar/tab bar) and resize PTY
    publish.updateGridOffsets(ctx);
    publish.generateStatusbar(ctx);
    publish.publishOverlays(ctx);

    // Start update checker if enabled
    if (ctx.check_updates) {
        logging.info("update", "starting update checker", .{});
        ai.g_update_checker = .{ .allocator = ctx.allocator };
        if (ai.g_update_checker) |*uc| uc.start();
    } else {
        logging.info("update", "update check disabled by config", .{});
    }
    defer {
        if (ai.g_update_checker) |*uc| {
            uc.tryJoin();
        }
        ai.g_update_checker = null;
    }

    // Show legacy daemon notification if connected to an outdated daemon
    if (ctx.session_client) |sc| {
        if (sc.legacy_daemon) showLegacyDaemonOverlay(ctx);
    }

    // Startup drain: process initial shell output (prompt, DA1 responses, etc.)
    // before entering the main loop.  The main-thread GL setup may complete
    // before the shell sends its prompt, leaving g_cells empty.  On macOS the
    // Metal display-link continuously calls drawFrame so the first update is
    // picked up within 16ms.  On Linux the GLFW event loop only renders on
    // events — if glfwPostEmptyEvent was dropped (g_window not yet set), the
    // cells stay blank until an input event arrives.  Draining here ensures the
    // cell buffer has content before the first drawFrame.
    if (ctx.session_client == null) {
        const startup_pane = ctx.tab_mgr.activePane();

        var startup_fds = [1]posix.pollfd{.{
            .fd = startup_pane.pty.master,
            .events = POLLIN,
            .revents = 0,
        }};
        // Poll in short bursts: the shell may need a DA1 response (written
        // back from pane.feed → drainResponse → writeToPty) before it sends
        // the prompt, so we iterate to allow that round-trip.
        //
        // On each iteration, also check for window resize. WMs like aerospace
        // reposition/resize the window right after launch. If the resize
        // arrives mid-drain, apply it immediately (bypass debounce) so the
        // PTY has the correct size before the shell draws its prompt.
        for (0..20) |_| {
            // Check for WM resize on each drain iteration
            {
                var rr: c_int = 0;
                var rc: c_int = 0;
                if (c.attyx_check_resize(&rr, &rc) != 0) {
                    const gaps = actions.computeSplitGaps();
                    ctx.tab_mgr.updateGaps(gaps.h, gaps.v);
                    ctx.grid_rows = @intCast(rr);
                    ctx.grid_cols = @intCast(rc);
                    const pty_rows: u16 = @intCast(@max(1, rr - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
                    ctx.tab_mgr.resizeAll(pty_rows, @intCast(rc));
                    // Send TIOCSWINSZ immediately so the shell starts at the
                    // correct size — no debounce during startup.
                    startup_pane.pty.resize(pty_rows, @intCast(rc)) catch {};
                    startup_pane.pending_pty_resize = false;
                    c.attyx_set_grid_size(rc, rr);
                }
            }
            startup_fds[0].revents = 0;
            _ = posix.poll(&startup_fds, 50) catch break;
            if (startup_fds[0].revents & POLLIN == 0) break;
            while (true) {
                const sn = startup_pane.pty.read(&buf) catch break;
                if (sn == 0) break;
                ctx.session.appendOutput(buf[0..sn]);
                ctx.throughput.add(sn);
                startup_pane.feed(buf[0..sn]);
            }
        }
        // Publish whatever the engine has to the cell buffer.
        {
            const eng = &startup_pane.engine;
            const total = eng.state.ring.screen_rows * eng.state.ring.cols;
            c.attyx_begin_cell_update();
            publish.fillCells(ctx.cells[0..total], eng, total, &ctx.active_theme, null);
            c.attyx_set_cursor(
                @intCast(eng.state.cursor.row + @as(usize, @intCast(terminal.g_grid_top_offset))),
                @intCast(eng.state.cursor.col),
            );
            c.attyx_mark_all_dirty();
            eng.state.dirty.clear();
            c.attyx_end_cell_update();
        }
    }

    // When xyron is enabled in session mode, the daemon may not have output
    // yet (xyron just started). Wait briefly for initial prompt data.
    if (ctx.session_client != null and ctx.xyron_path != null) {
        const startup_pane = ctx.tab_mgr.activePane();
        if (startup_pane.daemon_pane_id != null) {
            for (0..40) |_| { // up to 2 seconds
                if (ctx.session_client) |sc| {
                    _ = sc.recvData();
                    while (sc.readMessage()) |msg| {
                        switch (msg) {
                            .pane_output => |out| {
                                startup_pane.engine.feed(out.data);
                                _ = startup_pane.engine.state.drainResponse();
                            },
                            .grid_snapshot => |payload| {
                                // Grid-sync path: apply the snapshot to the
                                // startup pane so the cursor check below sees
                                // the daemon's current state and the initial
                                // publish (just after this loop) draws the
                                // shell's prompt.
                                _ = applyGridSnapshot(ctx, payload);
                            },
                            else => {},
                        }
                    }
                }
                if (startup_pane.engine.state.cursor.row > 0 or startup_pane.engine.state.cursor.col > 0) break;
                posix.nanosleep(0, 50_000_000); // 50ms
            }
            // Publish whatever we got
            const eng = &startup_pane.engine;
            const total = eng.state.ring.screen_rows * eng.state.ring.cols;
            c.attyx_begin_cell_update();
            publish.fillCells(ctx.cells[0..total], eng, total, &ctx.active_theme, null);
            c.attyx_set_cursor(
                @intCast(eng.state.cursor.row + @as(usize, @intCast(terminal.g_grid_top_offset))),
                @intCast(eng.state.cursor.col),
            );
            c.attyx_mark_all_dirty();
            eng.state.dirty.clear();
            c.attyx_end_cell_update();
        }
    }

    var got_data = false;
    var throttled_frames: u8 = 0; // count frames skipped by rate limiter
    outer: while (c.attyx_should_quit() == 0) {
        // Safety: if tab_mgr has no tabs (e.g. failed session attach after
        // reset), quit gracefully rather than crashing on activePane().
        if (ctx.tab_mgr.count == 0) {
            c.attyx_request_quit();
            return;
        }

        // Config reload check (atomic read-and-reset)
        if (@atomicRmw(i32, &terminal.g_needs_reload_config, .Xchg, 0, .seq_cst) != 0) {
            actions.doReloadConfig(ctx);
        }

        // Handle resize BEFORE IPC commands so that layout rects reflect
        // current window dimensions.  Without this, an IPC split arriving
        // in the same iteration as a pending resize would check stale
        // rects and incorrectly report "pane too small to split".
        // Engine state is resized immediately for correct display, but
        // TIOCSWINSZ is throttled to avoid flooding shells with SIGWINCH
        // during continuous window resizing.
        resize_mod.handleResize(ctx, &buf);
        // Flush any debounced PTY resizes (SIGWINCH) across all panes.
        for (ctx.tab_mgr.tabs[0..ctx.tab_mgr.count]) |*maybe_layout| {
            if (maybe_layout.*) |*lay| {
                var flush_leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
                const flush_lc = lay.collectLeaves(&flush_leaves);
                for (flush_leaves[0..flush_lc]) |fleaf| {
                    const was_pending = fleaf.pane.pending_pty_resize;
                    const pr = fleaf.pane.pending_pty_rows;
                    const pc = fleaf.pane.pending_pty_cols;
                    fleaf.pane.flushPtyResize();
                    // Forward to daemon if this flush actually sent TIOCSWINSZ
                    if (was_pending and !fleaf.pane.pending_pty_resize) {
                        if (fleaf.pane.daemon_pane_id) |dpid| {
                            if (ctx.session_client) |sc| {
                                sc.sendPaneResize(dpid, pr, pc) catch {};
                            }
                        }
                    }
                }
            }
        }
        // Flush debounced PTY resize for popup pane too.
        if (ctx.popup_state) |ps| {
            ps.pane.flushPtyResize();
        }

        // Drain IPC command queue
        while (ipc_queue.dequeue()) |cmd| {
            ipc_handler.handle(cmd, ctx);
            ipc_queue.advance();
        }
        // IPC handlers may call waitForPaneCreated/requestListSync
        switch (drainBufferedDeaths(ctx)) {
            .quit => return,
            .switched => continue :outer,
            .ok => {},
        }

        // Tick statusbar widgets (skip if quitting — widget ticks fork child
        // processes which crash if the parent is mid-teardown).
        if (c.attyx_should_quit() != 0) break;
        var statusbar_refreshed = false;
        if (ctx.statusbar) |sb| if (sb.config.enabled) {
            // Resolve theme palette into statusbar ANSI colors
            for (ctx.active_theme.palette, 0..) |opt_color, i| {
                if (opt_color) |p| sb.ansi_palette[i] = .{ .r = p.r, .g = p.g, .b = p.b };
            }
            statusbar_refreshed = sb.tick(std.time.timestamp(), publish.ctxPty(ctx).master, publish.ctxEngine(ctx).state.working_directory);
        };

        // Debug overlay toggle check
        if (@atomicRmw(i32, &terminal.g_toggle_debug_overlay, .Xchg, 0, .seq_cst) != 0) {
            if (ctx.overlay_mgr) |mgr| {
                mgr.toggle(.debug_card);
                publish.generateDebugCard(ctx);
                publish.publishOverlays(ctx);
            }
        }

        // Anchor demo toggle check
        if (@atomicRmw(i32, &terminal.g_toggle_anchor_demo, .Xchg, 0, .seq_cst) != 0) {
            if (ctx.overlay_mgr) |mgr| {
                if (mgr.isVisible(.anchor_demo)) {
                    publish.g_anchor_mode_counter +%= 1;
                    if (publish.g_anchor_mode_counter % 4 == 0) {
                        mgr.hide(.anchor_demo);
                    } else {
                        publish.generateAnchorDemo(ctx);
                    }
                } else {
                    publish.g_anchor_mode_counter = 0;
                    mgr.show(.anchor_demo);
                    publish.generateAnchorDemo(ctx);
                }
                publish.publishOverlays(ctx);
            }
        }

        // AI demo toggle check
        if (@atomicRmw(i32, &terminal.g_toggle_ai_demo, .Xchg, 0, .seq_cst) != 0) {
            if (ctx.overlay_mgr) |mgr| {
                if (mgr.isVisible(.ai_demo)) {
                    ai.cancelAi(ctx);
                } else {
                    mgr.show(.ai_demo);
                    ai.startAiInvocation(ctx);
                }
                publish.publishOverlays(ctx);
            }
        }

        // Session switcher toggle check (overlay-based)
        if (@atomicRmw(i32, &terminal.g_toggle_session_switcher, .Xchg, 0, .seq_cst) != 0) {
            if (terminal.g_session_picker_active != 0) {
                session_picker_ui.closeSessionPicker(ctx);
            } else {
                session_picker_ui.openSessionPicker(ctx);
            }
        }

        // Command palette toggle check
        if (@atomicRmw(i32, &terminal.g_toggle_command_palette, .Xchg, 0, .seq_cst) != 0) {
            if (terminal.g_command_palette_active != 0) {
                command_palette_ui.closeCommandPalette(ctx);
            } else {
                command_palette_ui.openCommandPalette(ctx);
            }
        }

        // Theme picker toggle check
        if (@atomicRmw(i32, &terminal.g_toggle_theme_picker, .Xchg, 0, .seq_cst) != 0) {
            if (terminal.g_theme_picker_active != 0) {
                theme_picker_ui.closeThemePicker(ctx);
            } else {
                theme_picker_ui.openThemePicker(ctx);
            }
        }

        // Tab picker toggle check
        if (@atomicRmw(i32, &terminal.g_toggle_tab_picker, .Xchg, 0, .seq_cst) != 0) {
            if (terminal.g_tab_picker_active != 0) {
                tab_picker_ui.closeTabPicker(ctx);
            } else {
                tab_picker_ui.openTabPicker(ctx);
            }
        }

        // Direct session create (Ctrl+Shift+N without picker)
        if (@atomicRmw(i32, &terminal.g_create_session_direct, .Xchg, 0, .seq_cst) != 0) {
            session_actions.createSessionDirect(ctx);
            if (ctx.tab_mgr.count == 0) continue :outer;
        }

        // Session dropdown: switch to session by ID (main thread → PTY thread)
        {
            const switch_id = @atomicRmw(i32, @as(*i32, @ptrCast(@volatileCast(&c.g_session_switch_id))), .Xchg, -1, .seq_cst);
            if (switch_id >= 0 and ctx.sessions_enabled) {
                session_actions.doSessionSwitch(ctx, @intCast(switch_id));
                if (ctx.tab_mgr.count == 0) continue :outer;
            }
        }

        // Publish session list for native tab bar dropdown
        if (ctx.sessions_enabled and c.g_native_tabs_enabled != 0) {
            publishSessionList(ctx);
            // requestListSync may have buffered pane_died events
            switch (drainBufferedDeaths(ctx)) {
                .quit => return,
                .switched => continue :outer,
                .ok => {},
            }
        }

        // Tick AI (auth/SSE state + streaming reveal)
        ai.tickAi(ctx);

        // AI edit prompt input polling
        if (ai.g_ai_edit) |*edit| {
            if (edit.state == .prompt_input) {
                if (ai.consumeAiPromptInput(ctx)) {
                    if (ai.g_ai_edit) |*e2| {
                        if (e2.state == .prompt_input) {
                            ai.renderEditPromptCard(ctx);
                        }
                    }
                }
            }
        }

        // Session picker input polling
        if (terminal.g_session_picker_active != 0) {
            _ = session_picker_ui.consumePickerInput(ctx);
            if (ctx.tab_mgr.count == 0) continue :outer;
            session_picker_ui.tickFinder(ctx);
        }

        // Command palette input polling
        if (terminal.g_command_palette_active != 0) {
            _ = command_palette_ui.consumePaletteInput(ctx);
        }

        // Theme picker input polling
        if (terminal.g_theme_picker_active != 0) {
            _ = theme_picker_ui.consumePickerInput(ctx);
        }

        // Tab picker input polling
        if (terminal.g_tab_picker_active != 0) {
            _ = tab_picker_ui.consumePickerInput(ctx);
        }

        // Tick update check notification
        ai.tickUpdateCheck(ctx);

        // Overlay interactions: dismiss, focus cycle, activate, mouse click/scroll
        overlay_input.processOverlayInteractions(ctx);

        // Context menu action: focus pane at click position, then dispatch
        if (@atomicRmw(i32, &input.g_ctx_action_pending, .Xchg, 0, .seq_cst) != 0) {
            const ctx_col: u16 = @intCast(@max(0, @atomicLoad(i32, &input.g_ctx_action_col, .seq_cst)));
            const ctx_row_raw = @atomicLoad(i32, &input.g_ctx_action_row, .seq_cst);
            const ctx_row: u16 = @intCast(@max(0, ctx_row_raw - terminal.g_grid_top_offset));
            const ctx_action: u8 = @intCast(@atomicLoad(i32, &input.g_ctx_action_id, .seq_cst));
            const layout = ctx.tab_mgr.activeLayout();
            if (layout.paneAt(ctx_row, ctx_col)) |target_idx| {
                if (target_idx != layout.focused) {
                    layout.focused = target_idx;
                    actions.switchActiveTab(ctx);
                }
            }
            // Now dispatch the action on the (now-focused) pane
            input.splitAction(@intCast(ctx_action));
        }

        actions.processTabActions(ctx);
        actions.processSplitActions(ctx);

        // Drain pane_died events that were buffered during blocking waits
        // inside processTabActions/processSplitActions (waitForPaneCreated).
        switch (drainBufferedDeaths(ctx)) {
            .quit => return,
            .switched => continue :outer,
            .ok => {},
        }

        actions.processSplitDrag(ctx);

        // Split pane click focus
        if (@atomicRmw(i32, &input.g_split_click_pending, .Xchg, 0, .seq_cst) != 0) {
            const click_col: u16 = @intCast(@max(0, @atomicLoad(i32, &input.g_split_click_col, .seq_cst)));
            const click_row_raw = @atomicLoad(i32, &input.g_split_click_row, .seq_cst);
            const click_row: u16 = @intCast(@max(0, click_row_raw - terminal.g_grid_top_offset));
            const layout = ctx.tab_mgr.activeLayout();
            if (layout.paneAt(click_row, click_col)) |target_idx| {
                if (target_idx != layout.focused) {
                    layout.focused = target_idx;
                    actions.switchActiveTab(ctx);
                }
            }
        }

        // Tab bar click handling
        {
            const click_idx = @atomicRmw(i32, &input.g_tab_click_index, .Xchg, -1, .seq_cst);
            if (click_idx >= 0 and click_idx < ctx.tab_mgr.count) {
                const idx: u8 = @intCast(click_idx);
                if (idx != ctx.tab_mgr.active) {
                    ctx.tab_mgr.switchTo(idx);
                    actions.switchActiveTab(ctx);
                }
            }
        }

        // Native tab click handling (main thread → PTY thread)
        {
            const native_click = @atomicRmw(i32, @as(*i32, @ptrCast(@volatileCast(&c.g_native_tab_click))), .Xchg, -1, .seq_cst);
            if (native_click >= 0 and native_click < ctx.tab_mgr.count) {
                const idx: u8 = @intCast(native_click);
                if (idx != ctx.tab_mgr.active) {
                    ctx.tab_mgr.switchTo(idx);
                    actions.switchActiveTab(ctx);
                }
            }
        }

        // Native tab drag-reorder (main thread → PTY thread)
        {
            const reorder_val = @atomicRmw(i32, @as(*i32, @ptrCast(@volatileCast(&c.g_native_tab_reorder))), .Xchg, -1, .seq_cst);
            if (reorder_val >= 0) {
                const from: u8 = @intCast((reorder_val >> 8) & 0xFF);
                const to: u8 = @intCast(reorder_val & 0xFF);
                if (from < ctx.tab_mgr.count and to < ctx.tab_mgr.count and from != to) {
                    ctx.tab_mgr.moveTabTo(from, to);
                    actions.switchActiveTab(ctx);
                    actions.saveSessionLayout(ctx);
                    logging.info("tabs", "reordered tab {d} → {d}", .{ from + 1, to + 1 });
                }
            }
        }

        // Popup toggle handling
        actions.processPopupToggle(ctx);

        // Clear screen + scrollback (Cmd+K / Ctrl+Shift+K)
        if (@atomicRmw(i32, &input.g_clear_screen_pending, .Xchg, 0, .seq_cst) != 0) {
            const eng = publish.ctxEngine(ctx);
            // Clear scrollback
            eng.state.ring.clearScrollback();
            eng.state.viewport_offset = 0;
            // Clear screen
            for (0..eng.state.ring.screen_rows) |r| {
                eng.state.ring.clearScreenRow(r);
                eng.state.ring.setScreenWrapped(r, false);
            }
            // Move cursor home
            eng.state.cursor.row = 0;
            eng.state.cursor.col = 0;
            eng.state.dirty.markAll(eng.state.ring.screen_rows);
            // Send form feed to shell so it redraws its prompt
            _ = posix.write(terminal.g_pty_master, "\x0c") catch {};
        }

        // Close dead popup on Ctrl-C from input thread
        if (@atomicRmw(i32, &input.g_popup_close_request, .Xchg, 0, .seq_cst) != 0) {
            actions.closePopup(ctx);
        }

        // Check popup child exit
        if (ctx.popup_state) |ps| {
            if (!ps.child_exited and ps.pane.childExited()) {
                actions.handlePopupExit(ctx, ps);
            }
        }

        // Check all tabs for child exit (handles split panes)
        {
            var ti: u8 = 0;
            while (ti < ctx.tab_mgr.count) {
                if (ctx.tab_mgr.tabs[ti]) |*lay| {
                    if (lay.findExitedPane()) |exited_idx| {
                        logging.info("tabs", "pane exited: tab {d}, pool idx {d}, count {d}", .{ ti, exited_idx, ctx.tab_mgr.count });
                        const result = lay.closePaneAt(exited_idx, ctx.allocator);
                        if (result == .last_pane) {
                            ctx.tab_mgr.closeTab(ti);
                            logging.info("tabs", "closed tab {d}, remaining {d}", .{ ti, ctx.tab_mgr.count });
                            if (ctx.tab_mgr.count == 0) {
                                if (session_actions.switchToNextSession(ctx)) continue :outer;
                                c.attyx_request_quit();
                                return;
                            }
                            publish.updateGridTopOffset(ctx);
                            actions.switchActiveTab(ctx);
                            continue;
                        } else {
                            const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
                            lay.layout(pty_rows, ctx.grid_cols);
                            if (ti == ctx.tab_mgr.active) {
                                actions.updateSplitActive(ctx);
                                actions.switchActiveTab(ctx);
                            }
                            continue;
                        }
                    }
                }
                ti += 1;
            }
        }

        // Update viewport tracking after potential resize
        if (ctx.tab_mgr.count > 0) {
            if (publish.ctxEngine(ctx).state.viewport_offset != last_published_vp) {
                last_published_vp = publish.ctxEngine(ctx).state.viewport_offset;
            }
        }

        // Build poll fd array:
        // - Session socket (one fd for all daemon-backed panes)
        // - Local PTY fds (for non-session panes)
        // - Popup fd
        const tab_max = @import("../tab_manager.zig").max_tabs;
        const max_fds = 1 + tab_max * split_layout_mod.max_panes + 1;
        var fds: [max_fds]posix.pollfd = undefined;
        var fd_panes: [max_fds]*@import("../pane.zig").Pane = undefined;
        var fd_tab_idx: [max_fds]u8 = undefined;
        var nfds: usize = 0;

        // Session socket fd (shared by all daemon-backed panes)
        const session_fd_idx: ?usize = if (ctx.session_client) |sc| blk: {
            const idx = nfds;
            fds[nfds] = .{ .fd = sc.pollFd(), .events = POLLIN, .revents = 0 };
            nfds += 1;
            break :blk idx;
        } else null;

        // Local PTY fds (non-session panes only)
        for (ctx.tab_mgr.tabs[0..ctx.tab_mgr.count], 0..) |*maybe_layout, tab_i| {
            if (maybe_layout.*) |*lay| {
                var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
                const lc = lay.collectLeaves(&leaves);
                for (leaves[0..lc]) |leaf| {
                    if (leaf.pane.daemon_pane_id != null) continue;
                    fds[nfds] = .{ .fd = leaf.pane.pty.master, .events = POLLIN, .revents = 0 };
                    fd_panes[nfds] = leaf.pane;
                    fd_tab_idx[nfds] = @intCast(tab_i);
                    nfds += 1;
                }
            }
        }
        const popup_fd_idx = nfds;
        if (ctx.popup_state) |ps| {
            if (!ps.child_exited) {
                fds[nfds] = .{ .fd = ps.pane.pty.master, .events = POLLIN, .revents = 0 };
                fd_panes[nfds] = ps.pane;
                fd_tab_idx[nfds] = 0xFF;
                nfds += 1;
            }
        }

        // Xyron IPC event fd — poll the active pane's persistent connection
        const xyron_event_fd_idx = nfds;
        if (ctx.tab_mgr.activePane().xyron_ipc) |xi| {
            if (xi.eventPollFd()) |efd| {
                fds[nfds] = .{ .fd = efd, .events = POLLIN, .revents = 0 };
                nfds += 1;
            }
        }

        // Wake pipe — lets UI actions (tab switch, IPC, etc.) interrupt the
        // poll immediately rather than waiting for the 16ms timer tick.
        // Tracked separately so the PTY-drain loops below can skip it
        // (fd_panes[wake_fd_idx] is intentionally not populated).
        const wake_fd_idx: ?usize = if (input.g_wake_read_fd >= 0) blk: {
            const idx = nfds;
            fds[nfds] = .{ .fd = input.g_wake_read_fd, .events = POLLIN, .revents = 0 };
            nfds += 1;
            break :blk idx;
        } else null;

        // Drain any buffered paste data before polling — this interleaves
        // writing paste input with reading shell output, preventing deadlock
        // when the kernel PTY buffer fills in both directions.
        input.drainPasteBuffer();

        // Shorten poll timeout when there's still pending paste data so we
        // drain it promptly instead of waiting the full 16ms.
        const poll_timeout: i32 = if (input.hasPendingPaste()) 1 else 16;
        _ = posix.poll(fds[0..nfds], poll_timeout) catch break;
        // Drain the wake pipe so it doesn't stay readable and burn CPU.
        input.drainWake();

        if (ctx.tab_mgr.count == 0) continue :outer;
        const active_focused_pane = ctx.tab_mgr.activePane();

        // Sync viewport from C BEFORE feeding PTY data, so that
        // fullScreenScroll's viewport_offset bump is not overwritten.
        // Snapshot the C value so we can detect user scrolls later.
        const synced_vp: i32 = @bitCast(c.g_viewport_offset);
        publish.syncViewportFromC(&publish.ctxEngine(ctx).state);

        // Snapshot scrollback count before feeding data — used to adjust
        // selection coordinates when new content scrolls the viewport.
        const sb_before: i32 = @intCast(publish.ctxEngine(ctx).state.ring.scrollbackCount());

        // Drain session socket — route pane_output by daemon_pane_id.
        // First read new data from the socket, then process all buffered
        // messages (including leftovers from a previous continue :outer).
        if (session_fd_idx) |si| {
            if (fds[si].revents & (POLLIN | POLLHUP) != 0) {
                if (ctx.session_client) |sc_recv| {
                    if (!sc_recv.recvData()) {
                        handleDaemonDeath(ctx);
                        continue :outer;
                    }
                }
            }
        }
        if (ctx.session_client) |sc| {
            while (sc.readMessage()) |msg| {
                switch (msg) {
                    .pane_output => |out| {
                        if (findPaneByDaemonId(ctx, out.pane_id)) |result| {
                            // Replay routing: when the daemon is replaying
                            // scrollback for a newly-focused pane, feed the
                            // bytes into a shadow engine instead of the live
                            // one.  The live engine keeps rendering the last
                            // known frame (no blank-pane gap, no "Tab N"
                            // fallback title) while the shadow catches up
                            // invisibly.  On `replay_end` we swap shadow →
                            // live in one atomic transition.
                            if (result.pane.needs_engine_reinit) {
                                if (result.pane.shadow_engine == null) {
                                    const rows: u16 = @intCast(result.pane.engine.state.ring.screen_rows);
                                    const cols: u16 = @intCast(result.pane.engine.state.ring.cols);
                                    const shadow = @import("attyx").Engine.init(
                                        result.pane.allocator,
                                        rows,
                                        cols,
                                        ctx.applied_scrollback_lines,
                                    ) catch continue;
                                    result.pane.shadow_engine = shadow;
                                    result.pane.shadow_engine.?.state.theme_colors = publish.themeToEngineColors(&ctx.active_theme);
                                }
                                result.pane.shadow_engine.?.feed(out.data);
                                _ = result.pane.shadow_engine.?.state.drainResponse();
                                // Do NOT set got_data — live engine is
                                // unchanged, the periodic publish should
                                // keep showing the old frame.  Do NOT
                                // appendOutput — replay bytes are historical,
                                // not new output.
                            } else {
                                if (result.pane == active_focused_pane) {
                                    ctx.session.appendOutput(out.data);
                                    ctx.throughput.add(out.data.len);
                                }
                                if (result.tab_idx == ctx.tab_mgr.active) got_data = true;
                                result.pane.engine.feed(out.data);
                                // Discard engine responses — the daemon intercepts
                                // all queries (DA1, DECRPM, kitty keyboard, OSC
                                // color queries, etc.) and responds directly to
                                // avoid round-trip latency and duplicate responses.
                                _ = result.pane.engine.state.drainResponse();
                            }
                        }
                    },
                    .pane_died => |died| {
                        logging.info("tabs", "daemon pane_died: pane_id={d}", .{died.pane_id});
                        if (findPaneByDaemonId(ctx, died.pane_id)) |result| {
                            logging.info("tabs", "pane_died: found pane at tab={d} pool={d} pane_count={d}", .{ result.tab_idx, result.pool_idx, ctx.tab_mgr.tabs[result.tab_idx].?.pane_count });
                            // Store exit code so pane.deinit() can notify --wait clients.
                            result.pane.stored_exit_code = died.exit_code;
                            // Store captured stdout for --wait panes
                            if (died.stdout.len > 0 and result.pane.ipc_wait_fd != -1) {
                                if (result.pane.captured_stdout == null) {
                                    const new_cs = ctx.allocator.create(std.ArrayList(u8)) catch null;
                                    if (new_cs) |ncs| {
                                        ncs.* = .empty;
                                        result.pane.captured_stdout = ncs;
                                    }
                                }
                                if (result.pane.captured_stdout) |cs| {
                                    cs.appendSlice(ctx.allocator, died.stdout) catch {};
                                }
                            }
                            // Close pane BEFORE clearing daemon_pane_id to avoid
                            // waitpid(0) reaping random children.
                            if (ctx.tab_mgr.tabs[result.tab_idx]) |*lay| {
                                const close_result = lay.closePaneAt(result.pool_idx, ctx.allocator);
                                if (close_result == .last_pane) {
                                    ctx.tab_mgr.closeTab(result.tab_idx);
                                    if (ctx.tab_mgr.count == 0) {
                                        if (session_actions.switchToNextSession(ctx)) continue :outer;
                                        c.attyx_request_quit();
                                        return;
                                    }
                                    publish.updateGridTopOffset(ctx);
                                }
                                // Re-layout and resize surviving daemon panes.
                                // After closeTab, result.tab_idx is stale (tabs shifted
                                // left), so only access it when the tab wasn't removed.
                                const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
                                if (close_result != .last_pane) {
                                    if (ctx.tab_mgr.tabs[result.tab_idx]) |*l| {
                                        l.layout(pty_rows, ctx.grid_cols);
                                        var rl: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
                                        const rlc = l.collectLeaves(&rl);
                                        for (rl[0..rlc]) |leaf| {
                                            if (leaf.pane.daemon_pane_id) |dpid|
                                                sc.sendPaneResize(dpid, leaf.rect.rows, leaf.rect.cols) catch {};
                                        }
                                    }
                                }
                                logging.info("tabs", "pane_died: close_result={s}, remaining tabs={d}", .{ if (close_result == .last_pane) "last_pane" else "closed", ctx.tab_mgr.count });
                                actions.updateSplitActive(ctx);
                                actions.switchActiveTab(ctx);
                                session_actions.sendActiveFocusPanes(ctx);
                                session_actions.saveSessionLayout(ctx);
                                // Restart event loop: fds/fd_panes arrays
                                // are stale after tab close and must be
                                // rebuilt before the next poll.
                                continue :outer;
                            }
                        } else {
                            logging.info("tabs", "pane_died: pane_id={d} NOT FOUND in any tab", .{died.pane_id});
                        }
                    },
                    .pane_proc_name => |pn| {
                        if (findPaneByDaemonId(ctx, pn.pane_id)) |result| {
                            const len: u8 = @intCast(@min(pn.name.len, 64));
                            @memcpy(result.pane.daemon_proc_name[0..len], pn.name[0..len]);
                            result.pane.daemon_proc_name_len = len;
                            if (result.tab_idx == ctx.tab_mgr.active) got_data = true;
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
                            // Atomic swap: shadow engine (with fully
                            // replayed state) replaces the live engine in
                            // one step.  Mark all rows dirty and force a
                            // full redraw so the renderer lands on the new
                            // frame on its very next tick — single clean
                            // transition, no intermediate states visible.
                            if (result.pane.shadow_engine) |shadow| {
                                var old_engine = result.pane.engine;
                                result.pane.engine = shadow;
                                result.pane.shadow_engine = null;
                                old_engine.deinit();
                                result.pane.needs_engine_reinit = false;
                                result.pane.engine.state.dirty.markAll(result.pane.engine.state.ring.screen_rows);
                                if (result.tab_idx == ctx.tab_mgr.active) {
                                    got_data = true;
                                    actions.g_force_full_redraw = true;
                                }
                            }
                            // Windows still col-nudges to force repaint;
                            // restore dims here.  POSIX uses SIGWINCH at
                            // current dims so no restore needed.
                            if (@import("builtin").os.tag == .windows) {
                                const rows: u16 = @intCast(result.pane.engine.state.ring.screen_rows);
                                const cols: u16 = @intCast(result.pane.engine.state.ring.cols);
                                if (ctx.session_client) |scc| {
                                    scc.sendPaneResize(pane_id, rows, cols) catch {};
                                }
                            }
                        }
                    },
                    .layout_sync => |sync| {
                        session_actions.handleLayoutSync(ctx, sync.layout);
                        got_data = true;
                    },
                    .grid_snapshot => |payload| {
                        if (applyGridSnapshot(ctx, payload)) |res| {
                            if (res.final_chunk and res.tab_idx == ctx.tab_mgr.active) {
                                got_data = true;
                                actions.g_force_full_redraw = true;
                            }
                        }
                    },
                    .pane_title => |pt| {
                        if (findPaneByDaemonId(ctx, pt.pane_id)) |result| {
                            result.pane.engine.state.setTitle(pt.title);
                            if (result.tab_idx == ctx.tab_mgr.active) got_data = true;
                        }
                    },
                    else => {},
                }
            }
        }

        // Drain local PTY data from non-session panes
        {
            const local_start = if (session_fd_idx != null) @as(usize, 1) else @as(usize, 0);
            for (local_start..nfds) |i| {
                if (fd_tab_idx[i] == 0xFF) continue; // popup handled separately
                if (i == xyron_event_fd_idx) continue; // xyron IPC handled separately
                if (wake_fd_idx) |w| if (i == w) continue; // wake pipe — drained above
                if (fds[i].revents & POLLIN == 0) continue;
                const p = fd_panes[i];
                while (true) {
                    const n = p.pty.read(&buf) catch break;
                    if (n == 0) break;
                    if (p == active_focused_pane) {
                        ctx.session.appendOutput(buf[0..n]);
                        ctx.throughput.add(n);
                    }
                    if (fd_tab_idx[i] == ctx.tab_mgr.active) got_data = true;
                    p.feed(buf[0..n]);
                }
                // Drain stdout capture pipe for --wait panes (non-blocking)
                p.drainCapturedStdout();
            }
        }

        // Drain popup PTY data
        var popup_got_data = false;
        if (ctx.popup_state) |ps| {
            if (popup_fd_idx < nfds and fds[popup_fd_idx].revents & POLLIN != 0) {
                while (true) {
                    const n = ps.pane.pty.read(&buf) catch break;
                    if (n == 0) break;
                    popup_got_data = true;
                    ps.feed(buf[0..n]);
                    if (ps.pane.engine.state.drainMainInject()) |inject| {
                        _ = publish.ctxPty(ctx).writeToPty(inject) catch {};
                    }
                }
            }
            if (popup_fd_idx < nfds and fds[popup_fd_idx].revents & POLLHUP != 0) {
                if (!ps.child_exited) {
                    _ = ps.pane.childExited();
                    actions.handlePopupExit(ctx, ps);
                }
            } else if (popup_got_data) {
                const pcfg = ctx.popup_configs[ps.config_index];
                ps.publishCells(&ctx.active_theme, pcfg);
                ps.publishImagePlacements(pcfg);
                // Publish popup mouse mode so input handlers can route mouse events
                c.g_popup_mouse_tracking = @intFromEnum(ps.pane.engine.state.mouse_tracking);
                c.g_popup_mouse_sgr = @intFromBool(ps.pane.engine.state.mouse_sgr);
            }
        }

        // Drain xyron IPC push events (completion overlay show/update/dismiss)
        if (ctx.tab_mgr.activePane().xyron_ipc) |xi| {
            if (xyron_event_fd_idx < nfds and (fds[xyron_event_fd_idx].revents & (POLLIN | POLLHUP) != 0)) {
                const xyron_proto = @import("../../xyron/protocol.zig");
                const completion_mod = @import("attyx").overlay_completion;
                const overlay_mod2 = @import("attyx").overlay_mod;
                while (xi.readEvent()) |frame| {
                    logging.info("xyron", "IPC event: 0x{x:0>2} ({d} bytes)", .{ @intFromEnum(frame.msg_type), frame.payload.len });
                    switch (frame.msg_type) {
                        .evt_overlay_show, .evt_overlay_update => {
                            var r = xyron_proto.PayloadReader.init(frame.payload);
                            const selected: i64 = r.readInt();
                            const scroll_off: i64 = r.readInt();
                            const total: i64 = r.readInt();
                            const visible_count: i64 = r.readInt();

                            // Parse candidates into completion state
                            const count: u16 = @intCast(@min(@max(visible_count, 0), completion_mod.max_candidates));
                            ctx.xyron_completion.count = count;
                            for (0..count) |i| {
                                const text = r.readStr();
                                const desc = r.readStr();
                                const kind = r.readU8();
                                _ = r.readInt(); // score
                                var cand = &ctx.xyron_completion.candidates[i];
                                const tl: u16 = @intCast(@min(text.len, 256));
                                @memcpy(cand.text[0..tl], text[0..tl]);
                                cand.text_len = tl;
                                const dl: u16 = @intCast(@min(desc.len, 80));
                                @memcpy(cand.desc[0..dl], desc[0..dl]);
                                cand.desc_len = dl;
                                cand.kind = kind;
                            }
                            ctx.xyron_completion.show(
                                @intCast(@max(selected, 0)),
                                @intCast(@max(scroll_off, 0)),
                                @intCast(@max(total, 0)),
                                ctx.tab_mgr.activePane().ipc_id,
                            );

                            // Render and set on overlay
                            if (ctx.overlay_mgr) |mgr| {
                                const theme = publish.overlayThemeFromTheme(&ctx.active_theme);
                                if (completion_mod.render(ctx.allocator, &ctx.xyron_completion, theme)) |result| {
                                    if (result.width > 0 and result.height > 0) {
                                        mgr.setContent(.completion, 0, 0, result.width, result.height, result.cells) catch {};
                                        mgr.layers[@intFromEnum(overlay_mod2.OverlayId.completion)].anchor = .{ .kind = .cursor_line };
                                        mgr.layers[@intFromEnum(overlay_mod2.OverlayId.completion)].placement_constraints = .{
                                            .max_width_frac = 0.80,
                                            .max_height_frac = 0.50,
                                            .margin = 0,
                                        };
                                        mgr.show(.completion);
                                        ctx.allocator.free(result.cells);
                                    }
                                } else |_| {}
                            }
                            got_data = true;
                        },
                        .evt_overlay_dismiss => {
                            ctx.xyron_completion.dismiss();
                            if (ctx.overlay_mgr) |mgr| mgr.hide(.completion);
                            got_data = true;
                        },
                        else => {},
                    }
                }
            }
        }

        // Check all panes for title changes (background tabs included).
        // This ensures tab bar / statusbar update even when the active tab
        // is idle but a background tab's process sends an OSC title.
        var title_changed = false;
        for (ctx.tab_mgr.tabs[0..ctx.tab_mgr.count]) |*maybe_layout| {
            if (maybe_layout.*) |*lay| {
                var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
                const lc = lay.collectLeaves(&leaves);
                for (leaves[0..lc]) |leaf| {
                    if (leaf.pane.engine.state.title_changed) {
                        leaf.pane.engine.state.title_changed = false;
                        title_changed = true;
                    }
                }
            }
        }
        if (title_changed) got_data = true;

        // Per-pane xyron handshake: iterate all panes, handshake any that
        // discovered a socket (OSC 7339) but haven't handshaked yet.
        for (ctx.tab_mgr.tabs[0..ctx.tab_mgr.count]) |*maybe_layout| {
            if (maybe_layout.*) |*lay| {
                var hs_leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
                const hs_lc = lay.collectLeaves(&hs_leaves);
                for (hs_leaves[0..hs_lc]) |leaf| {
                    const pane = leaf.pane;
                    if (pane.xyron_handshake_done) continue;
                    const sock_path = pane.engine.state.xyron_ipc_socket orelse continue;

                    const xyron_ipc = @import("../../xyron/ipc.zig");
                    const ipc_server = @import("../../ipc/server.zig");
                    const ipc = xyron_ipc.IpcClient.init(sock_path);
                    const attyx_sock = ipc_server.getSocketPath() orelse "";
                    var pane_id_buf: [16]u8 = undefined;
                    const pane_id = std.fmt.bufPrint(&pane_id_buf, "{d}", .{pane.ipc_id}) catch "0";
                    logging.info("xyron", "pane {s}: sending handshake to {s}", .{ pane_id, sock_path });
                    if (ipc.sendHandshake(attyx_sock, pane_id)) |hs| {
                        logging.info("xyron", "pane {s}: handshake complete: {s} {s}", .{ pane_id, hs.name, hs.version });
                        pane.xyron_handshake_done = true;

                        // Open persistent connection for push events
                        const heap_ipc = ctx.allocator.create(xyron_ipc.IpcClient) catch null;
                        if (heap_ipc) |hi| {
                            hi.* = xyron_ipc.IpcClient.init(sock_path);
                            if (hi.connectEvents()) {
                                pane.xyron_ipc = hi;
                                logging.info("xyron", "pane {s}: persistent event connection established", .{pane_id});
                            } else {
                                ctx.allocator.destroy(hi);
                            }
                        }
                    } else {
                        logging.warn("xyron", "pane {s}: handshake failed", .{pane_id});
                    }
                }
            }
        }

        // When viewport is pinned to bottom and new content pushes lines
        // into scrollback, adjust selection coordinates so the highlight
        // tracks the same text instead of staying at stale row positions.
        if (c.g_sel_active != 0 and got_data) {
            const sb_after: i32 = @intCast(publish.ctxEngine(ctx).state.ring.scrollbackCount());
            const sb_delta = sb_after - sb_before;
            if (sb_delta > 0 and publish.ctxEngine(ctx).state.viewport_offset == 0) {
                c.g_sel_start_row -= sb_delta;
                c.g_sel_end_row -= sb_delta;
            }
        }

        const viewport_changed = (publish.ctxEngine(ctx).state.viewport_offset != last_published_vp);
        const need_update = got_data or viewport_changed;

        const search_input_changed = search.consumeSearchInput();
        search.processSearch(&publish.ctxEngine(ctx).state);

        if (search_input_changed or got_data or @as(i32, @bitCast(c.g_search_active)) != 0) {
            search.generateSearchBar(ctx);
        }

        const search_vp_changed = (publish.ctxEngine(ctx).state.viewport_offset != last_published_vp);
        const need_update_final = need_update or search_vp_changed or actions.g_force_full_redraw;

        // DEC 2026 Synchronized Output
        if (publish.ctxEngine(ctx).state.synchronized_output) {
            if (ctx.sync_start_ns == 0)
                ctx.sync_start_ns = std.time.nanoTimestamp();
            const elapsed_ms = @divTrunc(std.time.nanoTimestamp() - ctx.sync_start_ns, std.time.ns_per_ms);
            if (elapsed_ms < 100) continue;
        } else {
            ctx.sync_start_ns = 0;
        }

        // Frame-rate throttle: always drain PTY data (above) to prevent
        // kernel buffer backpressure, but only publish to the renderer at
        // ~60fps. Viewport changes and force redraws bypass the throttle.
        if (need_update_final and !viewport_changed and !search_vp_changed and !actions.g_force_full_redraw) {
            const now_ns = std.time.nanoTimestamp();
            if (now_ns - last_publish_ns < min_frame_ns) {
                throttled_frames +|= 1;
                // Always keep scrollback count current so scroll
                // clamping uses the real range, even on throttled frames.
                c.g_scrollback_count = @intCast(publish.ctxEngine(ctx).state.ring.scrollbackCount());
                continue;
            }
        }

        if (need_update_final) {
            const layout = ctx.tab_mgr.activeLayout();
            if (layout.pane_count > 1 and !layout.isZoomed()) {
                const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
                // Compose the split layout into the scratch buffer first, then
                // memcpy into the live buffer under the cell-update guard.
                // fillCellsSplit clears the entire grid to bg before re-filling
                // each pane region — doing that on the live buffer leaves a
                // window where the renderer can observe a blank/partial frame
                // even with the gen guard, because mark_all_dirty + the
                // multiple non-atomic global writes (g_pane_rect_*) span the
                // begin/end window.
                const scratch_total: usize = @as(usize, ctx.grid_rows) * @as(usize, ctx.grid_cols);
                split_render.fillCellsSplit(
                    @ptrCast(ctx.scratch_cells),
                    layout,
                    pty_rows,
                    ctx.grid_cols,
                    &ctx.active_theme,
                );
                c.attyx_begin_cell_update();
                @memcpy(ctx.cells[0..scratch_total], ctx.scratch_cells[0..scratch_total]);
                const rect = layout.pool[layout.focused].rect;
                terminal.g_pane_rect_row = @intCast(rect.row);
                terminal.g_pane_rect_col = @intCast(rect.col);
                terminal.g_pane_rect_rows = @intCast(rect.rows);
                terminal.g_pane_rect_cols = @intCast(rect.cols);
                const eng = publish.ctxEngine(ctx);
                const vp_cur = @min(eng.state.viewport_offset, eng.state.ring.scrollbackCount());
                c.attyx_set_cursor(
                    @intCast(eng.state.cursor.row + vp_cur + rect.row + @as(usize, @intCast(terminal.g_grid_top_offset))),
                    @intCast(eng.state.cursor.col + rect.col),
                );
                c.attyx_mark_all_dirty();
                actions.g_force_full_redraw = false;
            } else {
                const pty_rows_s: i32 = @max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset);
                terminal.g_pane_rect_row = 0;
                terminal.g_pane_rect_col = 0;
                terminal.g_pane_rect_rows = pty_rows_s;
                terminal.g_pane_rect_cols = @intCast(ctx.grid_cols);
                const eng = publish.ctxEngine(ctx);
                // Force full redraw when frames were throttled during rapid
                // output — incremental dirty tracking may miss rows when
                // the engine processes many screenfuls between publishes.
                const full_redraw = viewport_changed or search_vp_changed or actions.g_force_full_redraw or (throttled_frames > 0);
                if (full_redraw) {
                    // Compose into scratch with grid_cols stride and atomically
                    // swap into the live buffer.  This avoids two flicker
                    // sources on full redraws: (1) eng.cols != grid_cols stride
                    // mismatch in fillCells (text-wrap appearance), and (2) any
                    // window where the renderer can land on a partially-written
                    // frame.  For sparse dirty-row updates the direct write is
                    // fine — only changed rows are touched and stride matches.
                    eng.state.dirty.markAll(eng.state.ring.screen_rows);
                    const scratch_total: usize = @as(usize, ctx.grid_rows) * @as(usize, ctx.grid_cols);
                    const bg_cell = publish.bgCell(&ctx.active_theme);
                    @memset(ctx.scratch_cells[0..scratch_total], bg_cell);
                    publish.fillCellsStride(ctx.scratch_cells[0..scratch_total], eng, &ctx.active_theme, ctx.grid_cols, null);
                    c.attyx_begin_cell_update();
                    @memcpy(ctx.cells[0..scratch_total], ctx.scratch_cells[0..scratch_total]);
                } else {
                    c.attyx_begin_cell_update();
                    const total = eng.state.ring.screen_rows * eng.state.ring.cols;
                    publish.fillCells(ctx.cells[0..total], eng, total, &ctx.active_theme, &eng.state.dirty);
                }

                const vp_cur = @min(eng.state.viewport_offset, eng.state.ring.scrollbackCount());
                c.attyx_set_cursor(
                    @intCast(eng.state.cursor.row + vp_cur + @as(usize, @intCast(terminal.g_grid_top_offset))),
                    @intCast(eng.state.cursor.col),
                );
                if (full_redraw) {
                    c.attyx_mark_all_dirty();
                    actions.g_force_full_redraw = false;
                } else {
                    c.attyx_set_dirty(&eng.state.dirty.bits);
                }
            }
            publish.ctxEngine(ctx).state.dirty.clear();
            publish.publishImagePlacements(ctx);
            publish.generateDebugCard(ctx);
            publish.generateAnchorDemo(ctx);
            publish.generateTabBar(ctx);
            publish.generateStatusbar(ctx);
            publish.publishNativeTabTitles(ctx);
            // Reposition cursor-anchored overlays (completion dropdown).
            // Dismiss if focus has moved away from the xyron source pane
            // (pane/tab/session switch) — completions are per-pane state.
            if (ctx.overlay_mgr) |mgr| {
                if (ctx.xyron_completion.active) {
                    const active_id = ctx.tab_mgr.activePane().ipc_id;
                    if (ctx.xyron_completion.source_pane_id != active_id) {
                        ctx.xyron_completion.dismiss();
                        mgr.hide(.completion);
                    } else if (publish.viewportInfoForPane(ctx, ctx.xyron_completion.source_pane_id)) |vp| {
                        mgr.relayoutAnchored(vp);
                    } else {
                        ctx.xyron_completion.dismiss();
                        mgr.hide(.completion);
                    }
                }
            }
            publish.publishOverlays(ctx);
            c.attyx_end_cell_update();
            publish.publishState(ctx);
            // Write viewport offset back to C only if the user hasn't
            // scrolled since we synced — avoids overwriting scroll events
            // that arrived on the main thread during this iteration.
            const engine_vp: i32 = @intCast(publish.ctxEngine(ctx).state.viewport_offset);
            const current_c_vp: i32 = @bitCast(c.g_viewport_offset);
            if (current_c_vp == synced_vp) {
                c.g_viewport_offset = engine_vp;
            }
            last_published_vp = publish.ctxEngine(ctx).state.viewport_offset;
            last_publish_ns = std.time.nanoTimestamp();

            throttled_frames = 0;
            if (got_data) {
                const h = state_hash.hash(&publish.ctxEngine(ctx).state);
                ctx.session.appendFrame(h, publish.ctxEngine(ctx).state.alt_active);
            }
            got_data = false;
        }

        // Statusbar widgets may have refreshed outside the cell-update path
        // (e.g. after session switch when engine is idle). Re-generate overlay.
        const copy_search_dirty = (@atomicRmw(i32, &copy_mode.g_copy_search_dirty, .Xchg, 0, .seq_cst) != 0);
        if ((statusbar_refreshed or copy_search_dirty) and !need_update_final) {
            publish.generateStatusbar(ctx);
            publish.publishOverlays(ctx);
        }

        // Show "Copied" toast when selection was copied to clipboard.
        if (selection.g_copy_toast_pending) {
            selection.g_copy_toast_pending = false;
            if (ctx.overlay_mgr) |mgr| {
                const eng2 = publish.ctxEngine(ctx);
                const tc: u16 = @intCast(eng2.state.ring.cols);
                const tr: u16 = @intCast(eng2.state.ring.screen_rows);
                toast.showToast(mgr, "Copied", tc, tr);
                publish.publishOverlays(ctx);
            }
        }

        // Auto-dismiss toast after timeout.
        if (ctx.overlay_mgr) |mgr| {
            if (toast.tickDismiss(mgr)) {
                publish.publishOverlays(ctx);
            }
        }

        // Periodically refresh tab titles for background tabs (~1s).
        // Process name changes in inactive tabs aren't detected by the
        // normal data-driven render path, so poll them on a timer.
        if (ctx.tab_mgr.count > 1 and !need_update_final) {
            tab_title_tick +%= 1;
            if (tab_title_tick % 60 == 0) { // ~1s at 16ms poll
                publish.generateTabBar(ctx);
                publish.generateStatusbar(ctx);
                publish.publishNativeTabTitles(ctx);
                publish.publishOverlays(ctx);
            }
        }

        hup_mod.handleActiveHup(ctx, fds[0..nfds], fd_panes[0..nfds], nfds, popup_fd_idx);
    }
}

fn handleDaemonDeath(ctx: *PtyThreadCtx) void {
    const SessionClient = @import("../session_client.zig").SessionClient;
    const sess_connect = @import("../session_connect.zig");

    // Save session ID and CWD for re-attach/fresh session after reconnect
    var saved_session_id: ?u32 = null;
    var saved_cwd: [std.fs.max_path_bytes]u8 = undefined;
    var saved_cwd_len: usize = 0;
    if (ctx.tab_mgr.count > 0) {
        if (publish.ctxEngine(ctx).state.working_directory) |wd| {
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
    terminal.g_session_client = null;

    // Attempt soft reconnect with backoff.
    // Use generous retry count — a hot-upgrade verification loop runs up to
    // 10s, so we need to wait at least that long before giving up.
    var delay_ns: u64 = 200_000_000;
    for (0..20) |_| { // up to ~15s total wait with capped backoff
        if (c.attyx_should_quit() != 0) return;
        posix.nanosleep(0, delay_ns);

        const heap_sc = ctx.allocator.create(SessionClient) catch {
            if (delay_ns < 800_000_000) delay_ns *= 2;
            continue;
        };
        heap_sc.* = SessionClient.connect(ctx.allocator) catch {
            ctx.allocator.destroy(heap_sc);
            if (delay_ns < 800_000_000) delay_ns *= 2; // cap at 800ms
            continue;
        };

        // Drain the probe response left by connectToSocket's probeAlive
        _ = heap_sc.recvData();
        while (heap_sc.readMessage()) |_| {}

        const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));

        // Try to re-attach to old session (works after hot-upgrade).
        if (saved_session_id) |sid| {
            heap_sc.attach(sid, pty_rows, ctx.grid_cols) catch {
                heap_sc.deinit();
                ctx.allocator.destroy(heap_sc);
                if (delay_ns < 800_000_000) delay_ns *= 2;
                continue;
            };

            // Wait briefly for attached response to confirm session exists
            if (heap_sc.waitForAttach(1000)) |_| {
                ctx.session_client = heap_sc;
                terminal.g_session_client = heap_sc;
                sess_connect.setNonBlocking(heap_sc.socket_fd);
                // Reconstruct tabs from the daemon's layout blob so pane IDs
                // match the (potentially remapped) state after hot-upgrade.
                reconstructTabsFromDaemon(ctx, heap_sc, pty_rows);
                session_actions.sendActiveFocusPanes(ctx);
                actions.g_force_full_redraw = true;
                logging.info("daemon", "soft reconnect successful", .{});
                return;
            } else |_| {
                // Session gone (daemon was killed, not upgraded).
                // Create a fresh session on the new daemon instead of
                // falling back to a daemon-less local PTY.
                const cwd = if (saved_cwd_len > 0) saved_cwd[0..saved_cwd_len] else null;
                if (createFreshSession(ctx, heap_sc, pty_rows, cwd)) {
                    sess_connect.setNonBlocking(heap_sc.socket_fd);
                    session_actions.sendActiveFocusPanes(ctx);
                    actions.g_force_full_redraw = true;
                    logging.info("daemon", "reconnect: created new session on new daemon", .{});
                    return;
                }
                heap_sc.deinit();
                ctx.allocator.destroy(heap_sc);
                break;
            }
        }

        // No saved session — create a fresh one on the new daemon
        const cwd = if (saved_cwd_len > 0) saved_cwd[0..saved_cwd_len] else null;
        if (createFreshSession(ctx, heap_sc, pty_rows, cwd)) {
            sess_connect.setNonBlocking(heap_sc.socket_fd);
            session_actions.sendActiveFocusPanes(ctx);
            actions.g_force_full_redraw = true;
            logging.info("daemon", "reconnect (no prior session) successful", .{});
            return;
        }

        // Session creation failed — clean up and retry
        heap_sc.deinit();
        ctx.allocator.destroy(heap_sc);
        if (delay_ns < 800_000_000) delay_ns *= 2;
        continue;
    }

    // Reconnect failed — fall back to local PTY
    logging.warn("daemon", "soft reconnect failed, falling back to local PTY", .{});
    hardResetToLocalPty(ctx);
}

/// Reconstruct the tab manager from the daemon's layout blob after reconnect.
/// This ensures daemon_pane_ids match the (potentially remapped) daemon state
/// and that the correct active tab is restored.
fn reconstructTabsFromDaemon(
    ctx: *PtyThreadCtx,
    sc: *@import("../session_client.zig").SessionClient,
    pty_rows: u16,
) void {
    const layout_codec = @import("../layout_codec.zig");

    if (sc.layout_len == 0) return;

    const info = layout_codec.deserialize(sc.layout_buf[0..sc.layout_len]) catch {
        logging.warn("daemon", "reconnect: layout deserialization failed", .{});
        return;
    };
    if (info.tab_count == 0) return;

    // Reset AFTER validating the layout to avoid leaving tab_mgr empty on error.
    ctx.tab_mgr.reset();
    ctx.tab_mgr.reconstructFromLayout(&info, pty_rows, ctx.grid_cols, ctx.applied_scrollback_lines) catch {
        logging.err("daemon", "reconnect: layout reconstruction failed, creating fallback pane", .{});
        // Reconstruction failed — tab_mgr is empty after reset(). Create a
        // single fallback pane so activePane() doesn't crash.
        const Pane = @import("../pane.zig").Pane;
        const pane = ctx.tab_mgr.allocator.create(Pane) catch return;
        pane.* = Pane.initDaemonBacked(ctx.tab_mgr.allocator, pty_rows, ctx.grid_cols, ctx.applied_scrollback_lines) catch {
            ctx.tab_mgr.allocator.destroy(pane);
            return;
        };
        ctx.tab_mgr.tabs[0] = split_layout_mod.SplitLayout.init(pane);
        ctx.tab_mgr.count = 1;
        ctx.tab_mgr.active = 0;
    };
    if (ctx.tab_mgr.count == 0) return;

    // Update terminal globals for the new active pane
    const active_pane = ctx.tab_mgr.activePane();
    terminal.g_engine = &active_pane.engine;
    terminal.g_pty_master = active_pane.pty.master;
    terminal.g_active_daemon_pane_id = active_pane.daemon_pane_id orelse 0;

    // Push theme colors to all reconstructed engines
    publish.publishThemeToEngines(ctx);
    actions.updateSplitActive(ctx);

    logging.info("daemon", "reconstructed {d} tab(s) from daemon layout", .{ctx.tab_mgr.count});
}

/// Create a new session on the daemon after reconnect, set up tab/pane, and
/// install the session client into ctx. Returns true on success.
fn createFreshSession(ctx: *PtyThreadCtx, sc: *@import("../session_client.zig").SessionClient, pty_rows: u16, saved_cwd: ?[]const u8) bool {
    const Pane = @import("../pane.zig").Pane;
    const SplitLayout = split_layout_mod.SplitLayout;

    const cwd = saved_cwd orelse (std.posix.getenv("HOME") orelse "/tmp");
    const new_id = sc.createSession("default", pty_rows, ctx.grid_cols, cwd, "") catch return false;
    sc.attach(new_id, pty_rows, ctx.grid_cols) catch return false;
    const attach_result = sc.waitForAttach(3000) catch return false;

    if (attach_result.pane_count == 0) return false;

    ctx.tab_mgr.reset();
    const pane = ctx.tab_mgr.allocator.create(Pane) catch return false;
    pane.* = Pane.initDaemonBacked(ctx.tab_mgr.allocator, pty_rows, ctx.grid_cols, ctx.applied_scrollback_lines) catch {
        ctx.tab_mgr.allocator.destroy(pane);
        return false;
    };
    pane.daemon_pane_id = attach_result.pane_ids[0];
    ctx.tab_mgr.tabs[0] = SplitLayout.init(pane);
    ctx.tab_mgr.count = 1;
    ctx.tab_mgr.active = 0;

    terminal.g_engine = &pane.engine;
    terminal.g_pty_master = pane.pty.master;
    terminal.g_active_daemon_pane_id = pane.daemon_pane_id orelse 0;
    ctx.session_client = sc;
    terminal.g_session_client = sc;
    return true;
}

fn hardResetToLocalPty(ctx: *PtyThreadCtx) void {
    const Pane = @import("../pane.zig").Pane;
    const SplitLayout = split_layout_mod.SplitLayout;
    ctx.tab_mgr.reset();
    ctx.session_client = null;
    terminal.g_session_client = null;
    const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
    const pane = ctx.tab_mgr.allocator.create(Pane) catch return;
    pane.* = Pane.spawn(ctx.tab_mgr.allocator, pty_rows, ctx.grid_cols, null, null, ctx.applied_scrollback_lines) catch {
        ctx.tab_mgr.allocator.destroy(pane);
        return;
    };
    ctx.tab_mgr.tabs[0] = SplitLayout.init(pane);
    ctx.tab_mgr.count = 1;
    ctx.tab_mgr.active = 0;
    terminal.g_engine = &pane.engine;
    terminal.g_pty_master = pane.pty.master;
    terminal.g_active_daemon_pane_id = 0;
    @import("../session_connect.zig").setNonBlocking(pane.pty.master);
}

fn allDaemonPanesDead(ctx: *PtyThreadCtx) bool {
    for (ctx.tab_mgr.tabs[0..ctx.tab_mgr.count]) |*maybe| {
        if (maybe.*) |*lay| {
            var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
            const lc = lay.collectLeaves(&leaves);
            for (leaves[0..lc]) |leaf| {
                if (leaf.pane.daemon_pane_id != null) return false;
            }
        }
    }
    return true;
}

fn showLegacyDaemonOverlay(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    const result = update_check.layoutLegacyDaemonCard(mgr.allocator) catch return;

    const eng = publish.ctxEngine(ctx);
    const cols: u16 = @intCast(eng.state.ring.cols);
    const rows: u16 = @intCast(eng.state.ring.screen_rows);
    const card_col = if (cols > result.width + 1) cols - result.width - 1 else 0;
    const card_row = if (rows > result.height + 1) rows - result.height - 1 else 0;

    mgr.setContent(.update_notification, card_col, card_row, result.width, result.height, result.cells) catch {
        mgr.allocator.free(result.cells);
        return;
    };
    mgr.allocator.free(result.cells);
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.update_notification)].action_bar = result.action_bar;
    mgr.show(.update_notification);
    publish.publishOverlays(ctx);
}

/// Process pane_died events that were buffered during blocking waits
/// (e.g. waitForPaneCreated). Returns .quit if the last tab was closed
/// and no session switch happened, .switched if a session switch occurred,
/// or .ok if normal processing should continue.
const DrainResult = enum { ok, quit, switched };

fn drainBufferedDeaths(ctx: *PtyThreadCtx) DrainResult {
    const sc = ctx.session_client orelse return .ok;
    while (sc.popBufferedDeath()) |death| {
        logging.info("tabs", "draining buffered pane_died: pane_id={d}", .{death.pane_id});
        if (findPaneByDaemonId(ctx, death.pane_id)) |result| {
            result.pane.stored_exit_code = death.exit_code;
            if (ctx.tab_mgr.tabs[result.tab_idx]) |*lay| {
                const close_result = lay.closePaneAt(result.pool_idx, ctx.allocator);
                if (close_result == .last_pane) {
                    ctx.tab_mgr.closeTab(result.tab_idx);
                    if (ctx.tab_mgr.count == 0) {
                        if (session_actions.switchToNextSession(ctx)) return .switched;
                        c.attyx_request_quit();
                        return .quit;
                    }
                    publish.updateGridTopOffset(ctx);
                }
                // Re-layout surviving panes (use active tab after potential shift)
                const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
                if (close_result == .last_pane) {
                    // Tab was removed — don't access result.tab_idx (shifted).
                } else if (ctx.tab_mgr.tabs[result.tab_idx]) |*l| {
                    l.layout(pty_rows, ctx.grid_cols);
                    var rl: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
                    const rlc = l.collectLeaves(&rl);
                    for (rl[0..rlc]) |leaf| {
                        if (leaf.pane.daemon_pane_id) |dpid|
                            sc.sendPaneResize(dpid, leaf.rect.rows, leaf.rect.cols) catch {};
                    }
                }
                actions.updateSplitActive(ctx);
                actions.switchActiveTab(ctx);
                session_actions.sendActiveFocusPanes(ctx);
                session_actions.saveSessionLayout(ctx);
                actions.g_force_full_redraw = true;
            }
        }
    }
    // Also drain buffered proc name updates
    while (sc.popBufferedProcName()) |pn| {
        if (findPaneByDaemonId(ctx, pn.pane_id)) |result| {
            @memcpy(result.pane.daemon_proc_name[0..pn.name_len], pn.name[0..pn.name_len]);
            result.pane.daemon_proc_name_len = pn.name_len;
        }
    }
    // Drain buffered fg cwd updates
    while (sc.popBufferedFgCwd()) |fc| {
        if (findPaneByDaemonId(ctx, fc.pane_id)) |result| {
            @memcpy(result.pane.daemon_fg_cwd[0..fc.cwd_len], fc.cwd[0..fc.cwd_len]);
            result.pane.daemon_fg_cwd_len = fc.cwd_len;
        }
    }
    return .ok;
}

/// Apply a grid_snapshot payload to the matching client-side pane. Returns
/// info on success so the caller can decide whether to force a redraw.
/// Shared by the startup drain (xyron path) and the main event loop so
/// snapshots aren't silently dropped during startup.
const GridApplyResult = struct { final_chunk: bool, tab_idx: u8, pane_id: u32 };
fn applyGridSnapshot(ctx: *PtyThreadCtx, payload: []const u8) ?GridApplyResult {
    const info = grid_sync.decodeSnapshotHeader(payload) catch {
        logging.warn("grid", "snapshot decode failed", .{});
        return null;
    };
    const result = findPaneByDaemonId(ctx, info.pane_id) orelse {
        logging.warn("grid", "snapshot for unknown pane {d}", .{info.pane_id});
        return null;
    };
    // Resize engine if daemon's grid differs from ours.
    if (result.pane.engine.state.ring.screen_rows != info.rows or
        result.pane.engine.state.ring.cols != info.cols)
    {
        result.pane.engine.state.resize(info.rows, info.cols) catch return null;
    }
    const cell_bytes = grid_sync.snapshotCellBytes(payload, info) catch return null;
    var idx: usize = 0;
    const end_row: usize = @as(usize, info.start_row) + info.row_count;
    var row: usize = info.start_row;
    while (row < end_row) : (row += 1) {
        var col: usize = 0;
        while (col < info.cols) : (col += 1) {
            const packed_cell = grid_sync.readPackedCell(cell_bytes, idx);
            result.pane.engine.state.ring.setScreenCell(
                row,
                col,
                grid_sync.unpackCell(packed_cell),
            );
            idx += 1;
        }
        result.pane.engine.state.dirty.mark(row);
    }
    result.pane.engine.state.cursor.row = info.cursor_row;
    result.pane.engine.state.cursor.col = info.cursor_col;
    result.pane.engine.state.cursor_visible = info.cursor_visible;
    result.pane.engine.state.cursor_shape = @enumFromInt(info.cursor_shape);
    result.pane.engine.state.alt_active = info.alt_active;
    return .{ .final_chunk = info.final_chunk, .tab_idx = result.tab_idx, .pane_id = info.pane_id };
}

fn findPaneByDaemonId(ctx: *PtyThreadCtx, pane_id: u32) ?struct { pane: *@import("../pane.zig").Pane, tab_idx: u8, pool_idx: u8 } {
    for (ctx.tab_mgr.tabs[0..ctx.tab_mgr.count], 0..) |*maybe, ti| {
        if (maybe.*) |*lay| {
            var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
            const lc = lay.collectLeaves(&leaves);
            for (leaves[0..lc]) |leaf| {
                if (leaf.pane.daemon_pane_id) |dpid| {
                    if (dpid == pane_id) return .{ .pane = leaf.pane, .tab_idx = @intCast(ti), .pool_idx = leaf.index };
                }
            }
        }
    }
    return null;
}

/// Publish session list to bridge globals for the native tab bar dropdown.
/// Called each tick when sessions are enabled and native tabs are active.
/// Uses requestListSync with a short timeout; skips if list request fails.
var tab_title_tick: u32 = 0;
var session_list_tick: u32 = 0;
fn publishSessionList(ctx: *PtyThreadCtx) void {
    const SessionClient = @import("../session_client.zig").SessionClient;
    // Only refresh every ~60 ticks (~1 second at 16ms poll)
    session_list_tick +%= 1;
    if (session_list_tick % 60 != 0) {
        // Still mark sessions as active even between refreshes
        @atomicStore(i32, @as(*i32, @ptrCast(@volatileCast(&c.g_sessions_active))), 1, .seq_cst);
        return;
    }
    const sc: *SessionClient = ctx.session_client orelse return;
    sc.requestListSync(200) catch return;
    if (!sc.pending_list_ready) return;

    const raw_count: usize = @min(sc.pending_list_count, 32);
    const current_id = sc.attached_session_id;
    var active_idx: i32 = -1;
    var out: usize = 0;

    for (0..raw_count) |i| {
        const entry = &sc.pending_list[i];
        const name = entry.getName();
        // Hide "default" session — same filter as session picker
        if (std.mem.eql(u8, name, "default")) continue;
        c.g_session_ids[out] = entry.id;
        const len = @min(name.len, 63);
        @memcpy(c.g_session_names[out][0..len], name[0..len]);
        c.g_session_names[out][len] = 0;
        if (current_id != null and entry.id == current_id.?) {
            active_idx = @intCast(out);
        }
        out += 1;
    }

    @atomicStore(i32, @as(*i32, @ptrCast(@volatileCast(&c.g_session_count))), @intCast(out), .seq_cst);
    @atomicStore(i32, @as(*i32, @ptrCast(@volatileCast(&c.g_active_session_idx))), active_idx, .seq_cst);
    @atomicStore(i32, @as(*i32, @ptrCast(@volatileCast(&c.g_sessions_active))), 1, .seq_cst);
    @atomicStore(i32, @as(*i32, @ptrCast(@volatileCast(&c.g_session_list_changed))), 1, .seq_cst);
}
