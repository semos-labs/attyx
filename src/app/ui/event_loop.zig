const std = @import("std");
const posix = std.posix;
const attyx = @import("attyx");
const SearchState = attyx.SearchState;
const state_hash = attyx.hash;
const logging = @import("../../logging/log.zig");
const split_layout_mod = @import("../split_layout.zig");
const split_render = @import("../split_render.zig");

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
const copy_mode = @import("copy_mode.zig");

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

    // Save layout to daemon on clean shutdown (before terminal.zig closes the socket).
    defer {
        if (ctx.session_client) |sc| {
            var save_buf: [4096]u8 = undefined;
            const save_len = ctx.tab_mgr.serializeLayout(&save_buf) catch 0;
            if (save_len > 0) {
                sc.sendSaveLayout(save_buf[0..save_len]) catch {};
            }
        }
    }

    search.g_search = SearchState.init(publish.ctxEngine(ctx).state.grid.allocator);
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
        if (ai.g_update_checker) |*uc| uc.tryJoin();
        ai.g_update_checker = null;
    }

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

        // Direct session create (Ctrl+Shift+N without picker)
        if (@atomicRmw(i32, &terminal.g_create_session_direct, .Xchg, 0, .seq_cst) != 0) {
            session_actions.createSessionDirect(ctx);
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
            session_picker_ui.tickFinder(ctx);
        }

        // Command palette input polling
        if (terminal.g_command_palette_active != 0) {
            _ = command_palette_ui.consumePaletteInput(ctx);
        }

        // Tick update check notification
        ai.tickUpdateCheck(ctx);

        // Overlay interactions: dismiss, focus cycle, activate, mouse click/scroll
        overlay_input.processOverlayInteractions(ctx);

        actions.processTabActions(ctx);
        actions.processSplitActions(ctx);
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

        // Popup toggle handling
        actions.processPopupToggle(ctx);

        // Clear screen + scrollback (Cmd+K / Ctrl+Shift+K)
        if (@atomicRmw(i32, &input.g_clear_screen_pending, .Xchg, 0, .seq_cst) != 0) {
            const eng = publish.ctxEngine(ctx);
            const grid = &eng.state.grid;
            // Clear scrollback
            eng.state.scrollback.clear();
            eng.state.viewport_offset = 0;
            // Clear screen
            @memset(grid.cells, attyx.grid.Cell{});
            @memset(grid.row_wrapped[0..grid.rows], false);
            // Move cursor home
            eng.state.cursor.row = 0;
            eng.state.cursor.col = 0;
            eng.state.dirty.markAll(grid.rows);
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
                        const result = lay.closePaneAt(exited_idx, ctx.allocator);
                        if (result == .last_pane) {
                            ctx.tab_mgr.closeTab(ti);
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

        resize_mod.handleResize(ctx, &buf);
        // Update viewport tracking after potential resize
        if (publish.ctxEngine(ctx).state.viewport_offset != last_published_vp) {
            last_published_vp = publish.ctxEngine(ctx).state.viewport_offset;
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

        // Drain any buffered paste data before polling — this interleaves
        // writing paste input with reading shell output, preventing deadlock
        // when the kernel PTY buffer fills in both directions.
        input.drainPasteBuffer();

        // Shorten poll timeout when there's still pending paste data so we
        // drain it promptly instead of waiting the full 16ms.
        const poll_timeout: i32 = if (input.hasPendingPaste()) 1 else 16;
        _ = posix.poll(fds[0..nfds], poll_timeout) catch break;

        var got_data = false;
        const active_focused_pane = ctx.tab_mgr.activePane();

        // Drain session socket — route pane_output by daemon_pane_id
        if (session_fd_idx) |si| {
            if (fds[si].revents & (POLLIN | POLLHUP) != 0) {
                if (ctx.session_client) |sc| {
                    if (!sc.recvData()) {
                        // Daemon disconnected — reset to fresh local PTY
                        handleDaemonDeath(ctx);
                        got_data = true;
                    } else {
                        while (sc.readMessage()) |msg| {
                            switch (msg) {
                                .pane_output => |out| {
                                    if (findPaneByDaemonId(ctx, out.pane_id)) |result| {
                                        // Deferred engine reinit: if the daemon is replaying
                                        // scrollback for a newly-focused pane, reinit the
                                        // engine NOW (right before feeding data) to prevent
                                        // blank-screen gap and duplicate content.
                                        if (result.pane.needs_engine_reinit) {
                                            const rows: u16 = @intCast(result.pane.engine.state.grid.rows);
                                            const cols: u16 = @intCast(result.pane.engine.state.grid.cols);
                                            const new_engine = @import("attyx").Engine.init(
                                                result.pane.allocator,
                                                rows,
                                                cols,
                                                ctx.applied_scrollback_lines,
                                            ) catch continue;
                                            result.pane.engine.deinit();
                                            result.pane.engine = new_engine;
                                            result.pane.needs_engine_reinit = false;
                                        }
                                        if (result.pane == active_focused_pane) {
                                            ctx.session.appendOutput(out.data);
                                            ctx.throughput.add(out.data.len);
                                        }
                                        if (result.tab_idx == ctx.tab_mgr.active) got_data = true;
                                        result.pane.engine.feed(out.data);
                                        // Discard engine responses — the daemon intercepts
                                        // common queries (DA1, DECRPM, kitty keyboard, etc.)
                                        // and responds directly to avoid round-trip latency
                                        // that causes shells to echo stale responses as text.
                                        _ = result.pane.engine.state.drainResponse();
                                    }
                                },
                                .pane_died => |died| {
                                    if (findPaneByDaemonId(ctx, died.pane_id)) |result| {
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
                                            // Re-layout and resize surviving daemon panes
                                            const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
                                            if (ctx.tab_mgr.tabs[result.tab_idx]) |*l| {
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
                                },
                                .pane_proc_name => |pn| {
                                    if (findPaneByDaemonId(ctx, pn.pane_id)) |result| {
                                        const len: u8 = @intCast(@min(pn.name.len, 64));
                                        @memcpy(result.pane.daemon_proc_name[0..len], pn.name[0..len]);
                                        result.pane.daemon_proc_name_len = len;
                                        if (result.tab_idx == ctx.tab_mgr.active) got_data = true;
                                    }
                                },
                                .replay_end => {},
                                .layout_sync => |sync| {
                                    session_actions.handleLayoutSync(ctx, sync.layout);
                                    got_data = true;
                                },
                                else => {},
                            }
                        }
                    }
                }
            }
        }

        // Drain local PTY data from non-session panes
        {
            const local_start = if (session_fd_idx != null) @as(usize, 1) else @as(usize, 0);
            for (local_start..nfds) |i| {
                if (fd_tab_idx[i] == 0xFF) continue; // popup handled separately
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
            }
        }

        publish.syncViewportFromC(&publish.ctxEngine(ctx).state);

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

        if (need_update_final) {
            c.attyx_begin_cell_update();
            const layout = ctx.tab_mgr.activeLayout();
            if (layout.pane_count > 1 and !layout.isZoomed()) {
                const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
                split_render.fillCellsSplit(
                    @ptrCast(ctx.cells),
                    layout,
                    pty_rows,
                    ctx.grid_cols,
                    &ctx.active_theme,
                );
                const rect = layout.pool[layout.focused].rect;
                terminal.g_pane_rect_row = @intCast(rect.row);
                terminal.g_pane_rect_col = @intCast(rect.col);
                terminal.g_pane_rect_rows = @intCast(rect.rows);
                terminal.g_pane_rect_cols = @intCast(rect.cols);
                const eng = publish.ctxEngine(ctx);
                const vp_cur = @min(eng.state.viewport_offset, eng.state.scrollback.count);
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
                const total = publish.ctxEngine(ctx).state.grid.rows * publish.ctxEngine(ctx).state.grid.cols;
                publish.fillCells(ctx.cells[0..total], publish.ctxEngine(ctx), total, &ctx.active_theme);
                const vp_cur = @min(publish.ctxEngine(ctx).state.viewport_offset, publish.ctxEngine(ctx).state.scrollback.count);
                c.attyx_set_cursor(
                    @intCast(publish.ctxEngine(ctx).state.cursor.row + vp_cur + @as(usize, @intCast(terminal.g_grid_top_offset))),
                    @intCast(publish.ctxEngine(ctx).state.cursor.col),
                );
                if (viewport_changed or search_vp_changed or actions.g_force_full_redraw) {
                    c.attyx_mark_all_dirty();
                    actions.g_force_full_redraw = false;
                } else {
                    c.attyx_set_dirty(&publish.ctxEngine(ctx).state.dirty.bits);
                }
            }
            publish.ctxEngine(ctx).state.dirty.clear();
            publish.publishImagePlacements(ctx);
            publish.generateDebugCard(ctx);
            publish.generateAnchorDemo(ctx);
            publish.generateTabBar(ctx);
            publish.generateStatusbar(ctx);
            publish.publishNativeTabTitles(ctx);
            publish.publishOverlays(ctx);
            c.attyx_end_cell_update();
            publish.publishState(ctx);
            last_published_vp = publish.ctxEngine(ctx).state.viewport_offset;

            if (got_data) {
                const h = state_hash.hash(&publish.ctxEngine(ctx).state);
                ctx.session.appendFrame(h, publish.ctxEngine(ctx).state.alt_active);
            }
        }

        // Statusbar widgets may have refreshed outside the cell-update path
        // (e.g. after session switch when engine is idle). Re-generate overlay.
        const copy_search_dirty = (@atomicRmw(i32, &copy_mode.g_copy_search_dirty, .Xchg, 0, .seq_cst) != 0);
        if ((statusbar_refreshed or copy_search_dirty) and !need_update_final) {
            publish.generateStatusbar(ctx);
            publish.publishOverlays(ctx);
        }

        hup_mod.handleActiveHup(ctx, fds[0..nfds], fd_panes[0..nfds], nfds, popup_fd_idx);
    }
}

fn handleDaemonDeath(ctx: *PtyThreadCtx) void {
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
