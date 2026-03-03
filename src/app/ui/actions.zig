const std = @import("std");
const logging = @import("../../logging/log.zig");
const reload = @import("../../config/reload.zig");
const config_mod = @import("../../config/config.zig");
const keybinds_mod = @import("../../config/keybinds.zig");
const platform = @import("../../platform/platform.zig");
const popup_mod = @import("../popup.zig");
const split_layout_mod = @import("../split_layout.zig");
const SplitLayout = split_layout_mod.SplitLayout;
const split_render = @import("../split_render.zig");

const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const c = terminal.c;
const publish = @import("publish.zig");
const input = @import("input.zig");
const session_actions = @import("session_actions.zig");

/// Set by switchActiveTab to force mark_all_dirty on next main-loop render.
pub var g_force_full_redraw: bool = false;

/// Re-exports from session_actions (consumed by other modules).
pub const saveSessionLayout = session_actions.saveSessionLayout;
pub const sendActiveFocusPanes = session_actions.sendActiveFocusPanes;

// ---------------------------------------------------------------------------
// Tab lifecycle helpers
// ---------------------------------------------------------------------------

pub fn processTabActions(ctx: *PtyThreadCtx) void {
    const action_raw = @atomicRmw(i32, &input.g_tab_action_request, .Xchg, 0, .seq_cst);
    if (action_raw == 0) return;

    const Action = keybinds_mod.Action;
    const action: Action = @enumFromInt(@as(u8, @intCast(action_raw)));

    switch (action) {
        .tab_new => {
            const eng = publish.ctxEngine(ctx);
            const rows: u16 = @intCast(eng.state.grid.rows);
            const cols: u16 = @intCast(eng.state.grid.cols);
            const fg_cwd = platform.getForegroundCwd(ctx.allocator, publish.ctxPty(ctx).master);
            defer if (fg_cwd) |cwd| ctx.allocator.free(cwd);
            const cwd_z: ?[:0]u8 = if (fg_cwd) |d| ctx.allocator.dupeZ(u8, d) catch null else null;
            defer if (cwd_z) |z| ctx.allocator.free(z);
            ctx.tab_mgr.addTab(rows, cols, if (cwd_z) |z| z.ptr else null) catch |err| {
                logging.err("tabs", "addTab failed: {}", .{err});
                return;
            };
            // In session mode, create a daemon pane for the new tab.
            if (ctx.sessions_enabled) {
                if (ctx.session_client) |sc| {
                    sc.sendCreatePane(rows, cols) catch {
                        logging.err("tabs", "send create_pane failed", .{});
                        publish.updateGridTopOffset(ctx);
                        switchActiveTab(ctx);
                        return;
                    };
                    const pane_id = sc.waitForPaneCreated(5000) catch |err| {
                        logging.err("tabs", "create daemon pane failed: {}", .{err});
                        publish.updateGridTopOffset(ctx);
                        switchActiveTab(ctx);
                        return;
                    };
                    const new_pane = ctx.tab_mgr.activePane();
                    new_pane.daemon_pane_id = pane_id;
                    logging.info("tabs", "new tab: daemon pane {d}", .{pane_id});
                }
            }
            publish.updateGridTopOffset(ctx);
            switchActiveTab(ctx);
            saveSessionLayout(ctx);
            logging.info("tabs", "new tab {d}/{d}", .{ ctx.tab_mgr.active + 1, ctx.tab_mgr.count });
        },
        .tab_close => {
            if (ctx.tab_mgr.count <= 1) {
                c.attyx_request_quit();
                return;
            }
            // Tell daemon to close all panes in this tab
            if (ctx.session_client) |sc| {
                if (ctx.tab_mgr.tabs[ctx.tab_mgr.active]) |*lay| {
                    var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
                    const lc = lay.collectLeaves(&leaves);
                    for (leaves[0..lc]) |leaf| {
                        if (leaf.pane.daemon_pane_id) |dpid| {
                            sc.sendClosePane(dpid) catch {};
                        }
                    }
                }
            }
            ctx.tab_mgr.closeTab(ctx.tab_mgr.active);
            publish.updateGridTopOffset(ctx);
            switchActiveTab(ctx);
            saveSessionLayout(ctx);
            logging.info("tabs", "closed tab, now {d}", .{ctx.tab_mgr.count});
        },
        .tab_next => {
            if (ctx.tab_mgr.count <= 1) return;
            ctx.tab_mgr.nextTab();
            switchActiveTab(ctx);
            logging.info("tabs", "switched to tab {d}", .{ctx.tab_mgr.active + 1});
        },
        .tab_prev => {
            if (ctx.tab_mgr.count <= 1) return;
            ctx.tab_mgr.prevTab();
            switchActiveTab(ctx);
            logging.info("tabs", "switched to tab {d}", .{ctx.tab_mgr.active + 1});
        },
        .tab_select_1, .tab_select_2, .tab_select_3,
        .tab_select_4, .tab_select_5, .tab_select_6,
        .tab_select_7, .tab_select_8, .tab_select_9,
        => {
            const idx = @intFromEnum(action) - @intFromEnum(Action.tab_select_1);
            if (idx < ctx.tab_mgr.count and idx != ctx.tab_mgr.active) {
                ctx.tab_mgr.switchTo(idx);
                switchActiveTab(ctx);
                logging.info("tabs", "switched to tab {d}", .{idx + 1});
            }
        },
        else => {},
    }
}

pub fn processSplitActions(ctx: *PtyThreadCtx) void {
    const action_raw = @atomicRmw(i32, &input.g_split_action_request, .Xchg, 0, .seq_cst);
    if (action_raw == 0) return;

    const Action = keybinds_mod.Action;
    const action: Action = @enumFromInt(@as(u8, @intCast(action_raw)));
    const layout = ctx.tab_mgr.activeLayout();

    switch (action) {
        .split_vertical => {
            doSplit(ctx, layout, .vertical);
        },
        .split_horizontal => {
            doSplit(ctx, layout, .horizontal);
        },
        .pane_close => {
            if (ctx.session_client) |sc|
                if (layout.focusedPane().daemon_pane_id) |dpid| sc.sendClosePane(dpid) catch {};
            const result = layout.closePane(ctx.allocator);
            if (result == .last_pane) {
                if (ctx.tab_mgr.count <= 1) { c.attyx_request_quit(); return; }
                ctx.tab_mgr.closeTab(ctx.tab_mgr.active);
                publish.updateGridTopOffset(ctx);
            } else {
                const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
                layout.layout(pty_rows, ctx.grid_cols);
                updateSplitActive(ctx);
            }
            switchActiveTab(ctx);
            saveSessionLayout(ctx);
        },
        .pane_focus_up => { layout.navigate(.up); switchActiveTab(ctx); },
        .pane_focus_down => { layout.navigate(.down); switchActiveTab(ctx); },
        .pane_focus_left => { layout.navigate(.left); switchActiveTab(ctx); },
        .pane_focus_right => { layout.navigate(.right); switchActiveTab(ctx); },
        .pane_resize_left, .pane_resize_right => {
            const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
            if (layout.findResizeTarget(.vertical)) |target| {
                const delta: f32 = if (action == .pane_resize_left) -0.05 else 0.05;
                if (layout.resizeNode(target, delta, pty_rows, ctx.grid_cols)) {
                    switchActiveTab(ctx);
                }
            }
        },
        .pane_resize_up, .pane_resize_down => {
            const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
            if (layout.findResizeTarget(.horizontal)) |target| {
                const delta: f32 = if (action == .pane_resize_up) -0.05 else 0.05;
                if (layout.resizeNode(target, delta, pty_rows, ctx.grid_cols)) {
                    switchActiveTab(ctx);
                }
            }
        },
        else => {},
    }
}

pub fn processSplitDrag(ctx: *PtyThreadCtx) void {
    const layout = ctx.tab_mgr.activeLayout();
    const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));

    if (@atomicRmw(i32, &input.g_split_drag_start_pending, .Xchg, 0, .seq_cst) != 0) {
        const col: u16 = @intCast(@max(0, @atomicLoad(i32, &input.g_split_drag_start_col, .seq_cst)));
        const row_raw = @atomicLoad(i32, &input.g_split_drag_start_row, .seq_cst);
        const row: u16 = @intCast(@max(0, row_raw - terminal.g_grid_top_offset));
        if (layout.separatorAt(row, col)) |branch_idx| {
            input.g_split_drag_branch = branch_idx;
            @atomicStore(i32, &terminal.g_split_drag_active, 1, .seq_cst);
            @atomicStore(i32, &terminal.g_split_drag_direction, switch (layout.pool[branch_idx].direction) {
                .vertical => @as(i32, 0),
                .horizontal => @as(i32, 1),
            }, .seq_cst);
        }
    }

    if (@atomicRmw(i32, &input.g_split_drag_cur_pending, .Xchg, 0, .seq_cst) != 0) {
        const branch_idx = input.g_split_drag_branch;
        if (branch_idx != 0xFF and layout.pool[branch_idx].tag == .branch) {
            const col: u16 = @intCast(@max(0, @atomicLoad(i32, &input.g_split_drag_cur_col, .seq_cst)));
            const row_raw = @atomicLoad(i32, &input.g_split_drag_cur_row, .seq_cst);
            const row: u16 = @intCast(@max(0, row_raw - terminal.g_grid_top_offset));
            const rect = layout.pool[branch_idx].rect;

            const new_ratio: f32 = switch (layout.pool[branch_idx].direction) {
                .vertical => blk: {
                    const available = rect.cols -| layout.gap_h;
                    if (available == 0) break :blk @as(f32, 0.5);
                    const offset: f32 = @floatFromInt(@as(i32, col) - @as(i32, rect.col));
                    break :blk @max(0.05, @min(0.95, offset / @as(f32, @floatFromInt(available))));
                },
                .horizontal => blk: {
                    const available = rect.rows -| layout.gap_v;
                    if (available == 0) break :blk @as(f32, 0.5);
                    const offset: f32 = @floatFromInt(@as(i32, row) - @as(i32, rect.row));
                    break :blk @max(0.05, @min(0.95, offset / @as(f32, @floatFromInt(available))));
                },
            };

            layout.pool[branch_idx].ratio = new_ratio;
            layout.layout(pty_rows, ctx.grid_cols);
            switchActiveTab(ctx);
        }
    }

    if (@atomicRmw(i32, &input.g_split_drag_end_pending, .Xchg, 0, .seq_cst) != 0) {
        input.g_split_drag_branch = 0xFF;
        @atomicStore(i32, &terminal.g_split_drag_active, 0, .seq_cst);
    }
}

/// Compute split gap sizes from window padding and cell dimensions.
pub fn computeSplitGaps() struct { h: u16, v: u16 } {
    const cell_w: f32 = c.g_cell_w_pts;
    const cell_h: f32 = c.g_cell_h_pts;
    if (cell_w <= 0 or cell_h <= 0) return .{ .h = 1, .v = 1 };
    const pad_h: f32 = @floatFromInt(c.g_padding_left + c.g_padding_right);
    const pad_v: f32 = @floatFromInt(c.g_padding_top + c.g_padding_bottom);
    return .{
        .h = @max(1, @as(u16, @intFromFloat(@round(pad_h / cell_w)))),
        .v = @max(1, @as(u16, @intFromFloat(@round(pad_v / cell_h)))),
    };
}

/// Update g_split_active flag based on active tab's pane count.
pub fn updateSplitActive(ctx: *PtyThreadCtx) void {
    const layout = ctx.tab_mgr.activeLayout();
    @atomicStore(i32, &terminal.g_split_active, if (layout.pane_count > 1) @as(i32, 1) else @as(i32, 0), .seq_cst);
}

fn doSplit(ctx: *PtyThreadCtx, layout: *SplitLayout, dir: split_layout_mod.Direction) void {
    const Pane = @import("../pane.zig").Pane;

    if (ctx.sessions_enabled) {
        const sc = ctx.session_client orelse return;
        const sz = layout.splitChildSize(dir, layout.pool[layout.focused].rect) orelse return;
        sc.sendCreatePane(sz.rows, sz.cols) catch return;
        const pane_id = sc.waitForPaneCreated(5000) catch return;
        const new_pane = ctx.allocator.create(Pane) catch return;
        new_pane.* = Pane.initDaemonBacked(ctx.allocator, sz.rows, sz.cols) catch {
            ctx.allocator.destroy(new_pane);
            return;
        };
        new_pane.daemon_pane_id = pane_id;
        layout.splitPaneWith(dir, new_pane) catch {
            new_pane.deinit();
            ctx.allocator.destroy(new_pane);
            return;
        };
    } else {
        layout.splitPane(dir, ctx.allocator, publish.ctxPty(ctx).master) catch return;
    }

    const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
    layout.layout(pty_rows, ctx.grid_cols);
    updateSplitActive(ctx);
    switchActiveTab(ctx);
    saveSessionLayout(ctx);
}

/// Update global routing pointers and refresh the cell buffer after a tab switch.
pub fn switchActiveTab(ctx: *PtyThreadCtx) void {
    const pane = ctx.tab_mgr.activePane();
    terminal.g_pty_master = pane.pty.master;
    terminal.g_engine = &pane.engine;

    // Update active daemon pane ID for input routing
    if (pane.daemon_pane_id) |dpid| {
        terminal.g_active_daemon_pane_id = dpid;
    }

    // In session mode, tell daemon which panes are now visible
    if (ctx.sessions_enabled) {
        sendActiveFocusPanes(ctx);
    }

    updateSplitActive(ctx);

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
        const eng = &pane.engine;
        const vp_cur = @min(eng.state.viewport_offset, eng.state.scrollback.count);
        c.attyx_set_cursor(
            @intCast(eng.state.cursor.row + vp_cur + rect.row + @as(usize, @intCast(terminal.g_grid_top_offset))),
            @intCast(eng.state.cursor.col + rect.col),
        );
        c.attyx_mark_all_dirty();
    } else {
        const buf_total: usize = @as(usize, ctx.grid_rows) * @as(usize, ctx.grid_cols);
        const bg = ctx.active_theme.background;
        for (0..buf_total) |i| {
            ctx.cells[i] = .{
                .character = ' ',
                .combining = .{ 0, 0 },
                .fg_r = bg.r,
                .fg_g = bg.g,
                .fg_b = bg.b,
                .bg_r = bg.r,
                .bg_g = bg.g,
                .bg_b = bg.b,
                .flags = 4,
                .link_id = 0,
            };
        }
        const eng = &pane.engine;
        const total = eng.state.grid.rows * eng.state.grid.cols;
        publish.fillCells(ctx.cells[0..total], eng, total, &ctx.active_theme);
        const vp_cur = @min(eng.state.viewport_offset, eng.state.scrollback.count);
        c.attyx_set_cursor(
            @intCast(eng.state.cursor.row + vp_cur + @as(usize, @intCast(terminal.g_grid_top_offset))),
            @intCast(eng.state.cursor.col),
        );
        c.attyx_mark_all_dirty();
        eng.state.dirty.clear();
    }
    publish.publishImagePlacements(ctx);
    publish.publishState(ctx);
    publish.generateTabBar(ctx);
    publish.generateStatusbar(ctx);
    publish.publishNativeTabTitles(ctx);
    publish.publishOverlays(ctx);
    c.attyx_end_cell_update();
    c.attyx_mark_all_dirty();
    g_force_full_redraw = true;
}

// ---------------------------------------------------------------------------
// Popup lifecycle helpers
// ---------------------------------------------------------------------------

pub fn processPopupToggle(ctx: *PtyThreadCtx) void {
    for (0..ctx.popup_config_count) |i| {
        if (@atomicRmw(i32, &input.g_popup_toggle_request[i], .Xchg, 0, .seq_cst) != 0) {
            logging.info("popup", "processing toggle for index {d}", .{i});
            if (ctx.popup_state) |ps| {
                const same = (ps.config_index == i);
                closePopup(ctx);
                if (same) return;
            }
            const cfg = ctx.popup_configs[i];
            logging.info("popup", "spawning: cmd={s} w={d}% h={d}%", .{ cfg.command, cfg.width_pct, cfg.height_pct });
            const grid_cols: u16 = ctx.grid_cols;
            const grid_rows: u16 = ctx.grid_rows;
            const fg_cwd = platform.getForegroundCwd(ctx.allocator, publish.ctxPty(ctx).master);
            defer if (fg_cwd) |cwd| ctx.allocator.free(cwd);
            var ps = ctx.allocator.create(popup_mod.PopupState) catch return;
            ps.* = popup_mod.PopupState.spawn(ctx.allocator, cfg, grid_cols, grid_rows, fg_cwd) catch |err| {
                logging.err("popup", "spawn failed: {}", .{err});
                ctx.allocator.destroy(ps);
                return;
            };
            ps.config_index = @intCast(i);
            ctx.popup_state = ps;
            terminal.g_popup_pty_master = ps.pane.pty.master;
            terminal.g_popup_engine = &ps.pane.engine;
            @atomicStore(i32, @as(*i32, @ptrCast(@volatileCast(&c.g_popup_active))), 1, .seq_cst);
            ps.publishCells(&ctx.active_theme, cfg);
            ps.publishImagePlacements(cfg);
            return;
        }
    }
}

pub fn closePopup(ctx: *PtyThreadCtx) void {
    const ps = ctx.popup_state orelse return;
    terminal.g_popup_pty_master = -1;
    terminal.g_popup_engine = null;
    @atomicStore(i32, &input.g_popup_dead, 0, .seq_cst);
    ps.deinit();
    ctx.allocator.destroy(ps);
    ctx.popup_state = null;
    popup_mod.clearBridgeState();
}

pub fn handlePopupExit(ctx: *PtyThreadCtx, ps: *popup_mod.PopupState) void {
    ps.pane.pty.waitForExit();
    const code = ps.pane.pty.exitCode() orelse 1;

    var drain_buf: [4096]u8 = undefined;
    while (true) {
        const n = ps.pane.pty.read(&drain_buf) catch break;
        if (n == 0) break;
        ps.feed(drain_buf[0..n]);
        if (ps.pane.engine.state.drainMainInject()) |inject| {
            _ = publish.ctxPty(ctx).writeToPty(inject) catch {};
        }
    }

    logging.info("popup", "exit code={d} stdout_fd={d} alt_active={}", .{
        code, ps.pane.pty.stdout_read_fd, publish.ctxEngine(ctx).state.alt_active,
    });

    // Session picker: intercept exit and handle captured stdout
    if (ctx.session_picker_active) {
        if (code == 0) {
            const captured = popup_mod.readCapturedStdout(ctx.allocator, ps.pane.pty.stdout_read_fd);
            if (captured) |text| {
                defer ctx.allocator.free(text);
                session_actions.handleSessionPickerResult(ctx, text);
            }
        }
        ctx.session_picker_active = false;
        closePopup(ctx);
        return;
    }

    if (code == 0) {
        const pcfg = ctx.popup_configs[ps.config_index];
        if (pcfg.on_return_cmd) |cmd| {
            const captured = popup_mod.readCapturedStdout(ctx.allocator, ps.pane.pty.stdout_read_fd);
            if (captured) |text| {
                logging.info("popup", "on_return_cmd: cmd=\"{s}\" value=\"{s}\" alt={}", .{
                    cmd, text, publish.ctxEngine(ctx).state.alt_active,
                });
                defer ctx.allocator.free(text);
                if (publish.ctxEngine(ctx).state.alt_active and !pcfg.inject_alt) {
                    popup_mod.execDetached(ctx.allocator, cmd, text);
                } else {
                    const full = std.fmt.allocPrint(ctx.allocator, "{s} {s}\r", .{ cmd, text }) catch return;
                    defer ctx.allocator.free(full);
                    publish.ctxEngine(ctx).state.suppress_echo = true;
                    _ = publish.ctxPty(ctx).writeToPty(full) catch {};
                }
            } else {
                logging.info("popup", "on_return_cmd: no captured stdout", .{});
            }
        }
        closePopup(ctx);
        return;
    }
    ps.child_exited = true;
    terminal.g_popup_pty_master = -1;
    terminal.g_popup_engine = null;
    @atomicStore(i32, &input.g_popup_dead, 1, .seq_cst);
    const pcfg = ctx.popup_configs[ps.config_index];
    ps.publishCells(&ctx.active_theme, pcfg);
    ps.publishImagePlacements(pcfg);
    logging.info("popup", "command exited with code {d}, keeping popup open (Ctrl-C to close)", .{code});
}

pub fn doReloadConfig(ctx: *PtyThreadCtx) void {
    var new_cfg = reload.loadReloadedConfig(
        ctx.allocator,
        ctx.no_config,
        ctx.config_path,
        ctx.args,
    ) catch |err| {
        logging.err("config", "reload failed: {}", .{err});
        return;
    };
    defer new_cfg.deinit();

    // Cursor (hot)
    if (new_cfg.cursor_shape != ctx.applied_cursor_shape or
        new_cfg.cursor_blink != ctx.applied_cursor_blink)
    {
        publish.ctxEngine(ctx).state.cursor_shape = publish.cursorShapeFromConfig(new_cfg.cursor_shape, new_cfg.cursor_blink);
        ctx.applied_cursor_shape = new_cfg.cursor_shape;
        ctx.applied_cursor_blink = new_cfg.cursor_blink;
    }
    if (new_cfg.cursor_trail != ctx.applied_cursor_trail) {
        c.g_cursor_trail = @intFromBool(new_cfg.cursor_trail);
        ctx.applied_cursor_trail = new_cfg.cursor_trail;
    }

    // Scrollback
    if (new_cfg.scrollback_lines != ctx.applied_scrollback_lines) {
        publish.ctxEngine(ctx).state.scrollback.reallocate(new_cfg.scrollback_lines) catch |err| {
            logging.err("config", "scrollback resize failed: {}", .{err});
        };
        ctx.applied_scrollback_lines = @intCast(publish.ctxEngine(ctx).state.scrollback.max_lines);
        if (publish.ctxEngine(ctx).state.viewport_offset > publish.ctxEngine(ctx).state.scrollback.count) {
            publish.ctxEngine(ctx).state.viewport_offset = publish.ctxEngine(ctx).state.scrollback.count;
            c.g_viewport_offset = @intCast(publish.ctxEngine(ctx).state.viewport_offset);
        }
        c.g_scrollback_count = @intCast(publish.ctxEngine(ctx).state.scrollback.count);
    }

    // Font
    const current_font_size: u16 = @intCast(c.g_font_size);
    const current_family_len: usize = @intCast(c.g_font_family_len);
    const current_family = c.g_font_family[0..current_family_len];
    const font_changed = new_cfg.font_size != current_font_size or
        !std.mem.eql(u8, new_cfg.font_family, current_family) or
        new_cfg.cell_width.encode() != c.g_cell_width or
        new_cfg.cell_height.encode() != c.g_cell_height;
    if (font_changed) {
        publish.publishFontConfig(&new_cfg);
        c.g_needs_font_rebuild = 1;
    }

    // Theme
    ctx.active_theme = ctx.theme_registry.resolve(new_cfg.theme_name);
    if (new_cfg.theme_background) |bg| ctx.active_theme.background = bg;
    publish.publishTheme(&ctx.active_theme);

    // Window properties
    {
        var needs_window_update = false;

        if (new_cfg.background_opacity != c.g_background_opacity) {
            c.g_background_opacity = new_cfg.background_opacity;
            needs_window_update = true;
        }
        const new_blur: i32 = @intCast(new_cfg.background_blur);
        if (new_blur != c.g_background_blur) {
            c.g_background_blur = new_blur;
            needs_window_update = true;
        }
        const new_deco: i32 = if (new_cfg.window_decorations) 1 else 0;
        if (new_deco != c.g_window_decorations) {
            c.g_window_decorations = new_deco;
            needs_window_update = true;
        }
        const new_pl: i32 = @intCast(new_cfg.window_padding_left);
        const new_pr: i32 = @intCast(new_cfg.window_padding_right);
        const new_pt: i32 = @intCast(new_cfg.window_padding_top);
        const new_pb: i32 = @intCast(new_cfg.window_padding_bottom);
        if (new_pl != c.g_padding_left or new_pr != c.g_padding_right or
            new_pt != c.g_padding_top or new_pb != c.g_padding_bottom)
        {
            c.g_padding_left = new_pl;
            c.g_padding_right = new_pr;
            c.g_padding_top = new_pt;
            c.g_padding_bottom = new_pb;
            needs_window_update = true;
        }
        if (needs_window_update) {
            c.g_needs_window_update = 1;
            const gaps = computeSplitGaps();
            ctx.tab_mgr.updateGaps(gaps.h, gaps.v);
        }
    }

    // Tab always_show
    const new_always: i32 = if (new_cfg.tab_always_show) 1 else 0;
    if (new_always != terminal.g_tab_always_show) {
        terminal.g_tab_always_show = new_always;
        publish.updateGridOffsets(ctx);
    }
    publish.ctxEngine(ctx).state.reflow_on_resize = new_cfg.reflow_enabled;
    {
        var ph: [4]keybinds_mod.PopupHotkey = undefined;
        var ph_count: u8 = 0;
        if (new_cfg.popup_configs) |entries| {
            for (entries) |entry| {
                if (ph_count >= 4) break;
                ph[ph_count] = .{ .index = ph_count, .hotkey = entry.hotkey };
                ph_count += 1;
            }
        }
        const new_table = keybinds_mod.buildTable(
            new_cfg.keybind_overrides,
            new_cfg.sequence_entries,
            ph[0..ph_count],
        );
        keybinds_mod.installTable(&new_table);
    }
    c.attyx_mark_all_dirty();
    logging.info("config", "reloaded", .{});
}

