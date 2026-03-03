const std = @import("std");
const posix = std.posix;
const attyx = @import("attyx");
const Engine = attyx.Engine;
const SearchState = attyx.SearchState;
const state_hash = attyx.hash;
const logging = @import("../../logging/log.zig");
const diag = @import("../../logging/diag.zig");
const reload = @import("../../config/reload.zig");
const config_mod = @import("../../config/config.zig");
const keybinds_mod = @import("../../config/keybinds.zig");
const platform = @import("../../platform/platform.zig");
const Pty = @import("../pty.zig").Pty;
const popup_mod = @import("../popup.zig");
const split_layout_mod = @import("../split_layout.zig");
const SplitLayout = split_layout_mod.SplitLayout;
const split_render = @import("../split_render.zig");

const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const c = terminal.c;
const publish = @import("publish.zig");
const input = @import("input.zig");
const search = @import("search.zig");
const ai = @import("ai.zig");
const actions = @import("actions.zig");

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

    search.g_search = SearchState.init(publish.ctxEngine(ctx).state.grid.allocator);
    defer {
        if (search.g_search) |*s| s.deinit();
        search.g_search = null;
    }

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

    while (c.attyx_should_quit() == 0) {
        // Config reload check (atomic read-and-reset)
        if (@atomicRmw(i32, &terminal.g_needs_reload_config, .Xchg, 0, .seq_cst) != 0) {
            actions.doReloadConfig(ctx);
        }

        // Tick statusbar widgets
        if (ctx.statusbar) |sb| if (sb.config.enabled) {
            // Resolve theme palette into statusbar ANSI colors
            for (ctx.active_theme.palette, 0..) |opt_color, i| {
                if (opt_color) |p| sb.ansi_palette[i] = .{ .r = p.r, .g = p.g, .b = p.b };
            }
            sb.tick(std.time.timestamp(), publish.ctxPty(ctx).master, publish.ctxEngine(ctx).state.working_directory);
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

        // AI explain toggle check
        if (@atomicRmw(i32, &terminal.g_toggle_ai_explain, .Xchg, 0, .seq_cst) != 0) {
            if (ctx.overlay_mgr) |mgr| {
                if (mgr.isVisible(.ai_demo)) {
                    ai.cancelAi(ctx);
                } else {
                    mgr.show(.ai_demo);
                    ai.startExplainInvocation(ctx);
                }
                publish.publishOverlays(ctx);
            }
        }

        // Tick AI (auth/SSE state + streaming reveal)
        ai.tickAi(ctx);

        // AI prompt input polling (edit + rewrite)
        ai.pollPromptInput(ctx);

        // Tick update check notification
        ai.tickUpdateCheck(ctx);

        // Overlay interaction: dismiss (Esc)
        if (@atomicRmw(i32, &input.g_overlay_dismiss, .Xchg, 0, .seq_cst) != 0) {
            ai.handleOverlayEsc(ctx);
        }

        // Overlay interaction: cycle focus (Tab / Shift-Tab)
        if (@atomicRmw(i32, &input.g_overlay_cycle_focus, .Xchg, 0, .seq_cst) != 0) {
            if (ctx.overlay_mgr) |mgr| {
                if (mgr.cycleFocus()) {
                    mgr.repaintActiveActionBar();
                    publish.generateDebugCard(ctx);
                    publish.publishOverlays(ctx);
                }
            }
        }
        if (@atomicRmw(i32, &input.g_overlay_cycle_focus_rev, .Xchg, 0, .seq_cst) != 0) {
            if (ctx.overlay_mgr) |mgr| {
                if (mgr.cycleFocusReverse()) {
                    mgr.repaintActiveActionBar();
                    publish.generateDebugCard(ctx);
                    publish.publishOverlays(ctx);
                }
            }
        }

        // Overlay interaction: activate focused action (Enter)
        if (@atomicRmw(i32, &input.g_overlay_activate, .Xchg, 0, .seq_cst) != 0) {
            if (ctx.overlay_mgr) |mgr| {
                const was_ai_visible = mgr.isVisible(.ai_demo);
                const was_ctx_visible = mgr.isVisible(.context_preview);
                if (mgr.activateFocused()) |action_id| {
                    switch (action_id) {
                        .dismiss => {
                            _ = mgr.dismissActive();
                            if (was_ctx_visible and !mgr.isVisible(.context_preview)) {
                                mgr.show(.ai_demo);
                            }
                            if (was_ai_visible and !mgr.isVisible(.ai_demo)) {
                                ai.cancelAi(ctx);
                            }
                        },
                        .context => ai.toggleContextPreview(ctx),
                        .insert => if (ai.g_ai_edit != null) ai.handleEditInsertAction(ctx) else ai.handleInsertAction(ctx),
                        .copy => if (ai.g_ai_explain != null) ai.handleExplainCopyAction(ctx) else if (ai.g_ai_rewrite != null) ai.handleRewriteCopyAction(ctx) else ai.handleCopyAction(ctx),
                        .retry => ai.handleRetryAction(ctx),
                        .accept => ai.handleEditAcceptAction(ctx),
                        .reject => ai.handleEditRejectAction(ctx),
                        .custom_0 => ai.handleRewriteReplaceAction(ctx),
                        else => {},
                    }
                    publish.publishOverlays(ctx);
                }
            }
        }

        // Overlay interaction: mouse click
        if (@atomicRmw(i32, &input.g_overlay_click_pending, .Xchg, 0, .seq_cst) != 0) {
            if (ctx.overlay_mgr) |mgr| {
                const click_col: u16 = @intCast(@max(0, @atomicLoad(i32, &input.g_overlay_click_col, .seq_cst)));
                const click_row: u16 = @intCast(@max(0, @atomicLoad(i32, &input.g_overlay_click_row, .seq_cst)));
                if (mgr.hitTest(click_col, click_row)) |hit| {
                    const was_ai_visible = mgr.isVisible(.ai_demo);
                    const was_ctx_visible = mgr.isVisible(.context_preview);
                    if (mgr.clickAction(hit)) |action_id| {
                        switch (action_id) {
                            .dismiss => {
                                _ = mgr.dismissActive();
                                if (was_ctx_visible and !mgr.isVisible(.context_preview)) {
                                    mgr.show(.ai_demo);
                                }
                                if (was_ai_visible and !mgr.isVisible(.ai_demo)) {
                                    ai.cancelAi(ctx);
                                }
                            },
                            .context => ai.toggleContextPreview(ctx),
                            .insert => ai.handleInsertAction(ctx),
                            .copy => if (ai.g_ai_explain != null) ai.handleExplainCopyAction(ctx) else if (ai.g_ai_rewrite != null) ai.handleRewriteCopyAction(ctx) else ai.handleCopyAction(ctx),
                            .retry => ai.handleRetryAction(ctx),
                            .custom_0 => ai.handleRewriteReplaceAction(ctx),
                            else => {},
                        }
                    }
                    publish.publishOverlays(ctx);
                }
            }
        }

        // Overlay interaction: mouse scroll
        if (@atomicRmw(i32, &input.g_overlay_scroll_pending, .Xchg, 0, .seq_cst) != 0) {
            const delta = @atomicRmw(i32, &input.g_overlay_scroll_delta, .Xchg, 0, .seq_cst);
            if (ai.g_streaming) |*so| {
                const d: i16 = @intCast(std.math.clamp(delta, -100, 100));
                if (so.scroll(d)) {
                    ai.publishAiStreamingFrame(ctx);
                }
            }
        }

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

        // Popup toggle handling
        actions.processPopupToggle(ctx);

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

        {
            var rr: c_int = 0;
            var rc: c_int = 0;
            if (c.attyx_check_resize(&rr, &rc) != 0) {
                const nr: usize = @intCast(rr);
                const nc: usize = @intCast(rc);

                ctx.grid_rows = @intCast(rr);
                ctx.grid_cols = @intCast(rc);

                const gaps = actions.computeSplitGaps();
                ctx.tab_mgr.updateGaps(gaps.h, gaps.v);

                const pty_rows: u16 = @intCast(@max(1, rr - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
                ctx.tab_mgr.resizeAll(pty_rows, @intCast(rc));

                posix.nanosleep(0, 1_000_000);
                while (true) {
                    const n = publish.ctxPty(ctx).read(&buf) catch break;
                    if (n == 0) break;
                    ctx.session.appendOutput(buf[0..n]);
                    ctx.tab_mgr.activePane().feed(buf[0..n]);
                }

                c.attyx_begin_cell_update();
                const resize_layout = ctx.tab_mgr.activeLayout();
                if (resize_layout.pane_count > 1) {
                    split_render.fillCellsSplit(
                        @ptrCast(ctx.cells),
                        resize_layout,
                        pty_rows,
                        @intCast(rc),
                        &ctx.active_theme,
                    );
                    const resize_rect = resize_layout.pool[resize_layout.focused].rect;
                    const vp_cur = @min(publish.ctxEngine(ctx).state.viewport_offset, publish.ctxEngine(ctx).state.scrollback.count);
                    c.attyx_set_cursor(
                        @intCast(publish.ctxEngine(ctx).state.cursor.row + vp_cur + resize_rect.row + @as(usize, @intCast(terminal.g_grid_top_offset))),
                        @intCast(publish.ctxEngine(ctx).state.cursor.col + resize_rect.col),
                    );
                    c.attyx_mark_all_dirty();
                } else {
                    const new_total = nr * nc;
                    publish.fillCells(ctx.cells[0..new_total], publish.ctxEngine(ctx), new_total, &ctx.active_theme);
                    const vp_cur = @min(publish.ctxEngine(ctx).state.viewport_offset, publish.ctxEngine(ctx).state.scrollback.count);
                    c.attyx_set_cursor(
                        @intCast(publish.ctxEngine(ctx).state.cursor.row + vp_cur + @as(usize, @intCast(terminal.g_grid_top_offset))),
                        @intCast(publish.ctxEngine(ctx).state.cursor.col),
                    );
                    c.attyx_set_dirty(&publish.ctxEngine(ctx).state.dirty.bits);
                }
                publish.ctxEngine(ctx).state.dirty.clear();
                c.attyx_set_grid_size(rc, rr);
                publish.publishImagePlacements(ctx);
                if (ctx.overlay_mgr) |mgr| {
                    mgr.relayoutAnchored(publish.viewportInfoFromCtx(ctx));
                    publish.generateDebugCard(ctx);
                    publish.generateAnchorDemo(ctx);
                    ai.relayoutAiDemo(ctx);
                    ai.relayoutContextPreview(ctx);
                }
                publish.generateTabBar(ctx);
                publish.generateStatusbar(ctx);
                publish.publishOverlays(ctx);
                if (ctx.popup_state) |ps| {
                    const cfg = ctx.popup_configs[ps.config_index];
                    ps.resize(cfg, @intCast(nc), @intCast(nr));
                    ps.publishCells(&ctx.active_theme, cfg);
                    ps.publishImagePlacements(cfg);
                }
                c.attyx_end_cell_update();
                publish.publishState(ctx);
                last_published_vp = publish.ctxEngine(ctx).state.viewport_offset;
            }
        }

        // Build poll fd array
        const tab_max = @import("../tab_manager.zig").max_tabs;
        const max_fds = tab_max * split_layout_mod.max_panes + 1;
        var fds: [max_fds]posix.pollfd = undefined;
        var fd_panes: [max_fds]*@import("../pane.zig").Pane = undefined;
        var fd_tab_idx: [max_fds]u8 = undefined;
        var nfds: usize = 0;

        for (ctx.tab_mgr.tabs[0..ctx.tab_mgr.count], 0..) |*maybe_layout, tab_i| {
            if (maybe_layout.*) |*lay| {
                var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
                const lc = lay.collectLeaves(&leaves);
                for (leaves[0..lc]) |leaf| {
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

        _ = posix.poll(fds[0..nfds], 16) catch break;

        var got_data = false;
        const active_focused_pane = ctx.tab_mgr.activePane();
        for (0..nfds) |i| {
            if (i == popup_fd_idx) continue;
            if (fd_tab_idx[i] == 0xFF) continue;
            if (fds[i].revents & POLLIN != 0) {
                const p = fd_panes[i];
                while (true) {
                    const n = p.pty.read(&buf) catch break;
                    if (n == 0) break;
                    if (p == active_focused_pane) {
                        ctx.session.appendOutput(buf[0..n]);
                        ctx.throughput.add(n);
                    }
                    if (fd_tab_idx[i] == ctx.tab_mgr.active) {
                        got_data = true;
                    }
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
        const need_update_final = need_update or search_vp_changed;        // Tick command capture
        if (active_focused_pane.cmd_capture) |cap| {
            const st = &active_focused_pane.engine.state;
            const cr = @atomicRmw(i32, &terminal.g_cmd_cr_pending, .Xchg, 0, .seq_cst) != 0;
            const ts = std.time.nanoTimestamp();
            cap.tick(&st.grid, st.cursor, st.alt_active, cr, if (ts < 0) 0 else @intCast(ts));
        }
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
            if (layout.pane_count > 1) {
                const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
                split_render.fillCellsSplit(
                    @ptrCast(ctx.cells),
                    layout,
                    pty_rows,
                    ctx.grid_cols,
                    &ctx.active_theme,
                );
                const rect = layout.pool[layout.focused].rect;
                const eng = publish.ctxEngine(ctx);
                const vp_cur = @min(eng.state.viewport_offset, eng.state.scrollback.count);
                c.attyx_set_cursor(
                    @intCast(eng.state.cursor.row + vp_cur + rect.row + @as(usize, @intCast(terminal.g_grid_top_offset))),
                    @intCast(eng.state.cursor.col + rect.col),
                );
                c.attyx_mark_all_dirty();
                actions.g_force_full_redraw = false;
            } else {
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
            publish.publishOverlays(ctx);
            c.attyx_end_cell_update();
            publish.publishState(ctx);
            last_published_vp = publish.ctxEngine(ctx).state.viewport_offset;

            if (got_data) {
                const h = state_hash.hash(&publish.ctxEngine(ctx).state);
                ctx.session.appendFrame(h, publish.ctxEngine(ctx).state.alt_active);
            }
        }

        // Check active focused pane for POLLHUP
        for (0..nfds) |fi| {
            if (fi == popup_fd_idx) continue;
            if (fd_panes[fi] != active_focused_pane or fds[fi].revents & POLLHUP == 0) continue;
            if (!active_focused_pane.childExited()) break;
            const lay = ctx.tab_mgr.activeLayout();
            if (lay.pane_count <= 1) {
                ctx.tab_mgr.closeTab(ctx.tab_mgr.active);
                if (ctx.tab_mgr.count == 0) { c.attyx_request_quit(); break; }
                publish.updateGridTopOffset(ctx);
            } else if (lay.closePane(ctx.allocator) == .last_pane) {
                ctx.tab_mgr.closeTab(ctx.tab_mgr.active);
                if (ctx.tab_mgr.count == 0) { c.attyx_request_quit(); break; }
                publish.updateGridTopOffset(ctx);
            } else {
                const pr: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
                lay.layout(pr, ctx.grid_cols);
                actions.updateSplitActive(ctx);
            }
            actions.switchActiveTab(ctx);
            break;
        }
    }
}
