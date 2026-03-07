const std = @import("std");
const posix = std.posix;
const attyx = @import("attyx");
const split_layout_mod = @import("../split_layout.zig");
const split_render = @import("../split_render.zig");

const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const c = terminal.c;
const publish = @import("publish.zig");
const actions = @import("actions.zig");
const ai = @import("ai.zig");
const session_picker_ui = @import("session_picker_ui.zig");
const command_palette_ui = @import("command_palette_ui.zig");
const theme_picker_ui = @import("theme_picker_ui.zig");
const popup_mod = @import("../popup.zig");

/// Handle a window resize event. Drains old-size data, resizes all tabs,
/// forwards resize to daemon-backed panes, republishes cells, and updates
/// all overlays/popups.
pub fn handleResize(ctx: *PtyThreadCtx, buf: []u8) void {
    var rr: c_int = 0;
    var rc: c_int = 0;
    if (c.attyx_check_resize(&rr, &rc) == 0) return;

    const nr: usize = @intCast(rr);
    const nc: usize = @intCast(rc);

    ctx.grid_rows = @intCast(rr);
    ctx.grid_cols = @intCast(rc);

    const gaps = actions.computeSplitGaps();
    ctx.tab_mgr.updateGaps(gaps.h, gaps.v);

    const pty_rows: u16 = @intCast(@max(1, rr - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));

    // Drain in-flight daemon data at the OLD grid size for the active
    // pane BEFORE resizing.  Old-size output must be processed
    // against old dimensions to avoid cursor/wrapping corruption.
    if (ctx.session_client) |sc| {
        _ = sc.recvData();
        while (sc.readMessage()) |msg| {
            switch (msg) {
                .pane_output => |out| {
                    const rpane = ctx.tab_mgr.activePane();
                    if (rpane.daemon_pane_id) |dpid| {
                        if (dpid == out.pane_id) {
                            ctx.session.appendOutput(out.data);
                            rpane.engine.feed(out.data);
                            _ = rpane.engine.state.drainResponse();
                        }
                    }
                },
                else => {},
            }
        }
    }

    ctx.tab_mgr.resizeAll(pty_rows, @intCast(rc));

    // Forward resize to each session-backed pane on the daemon.
    // Use each pane's actual split rect dimensions, not the full terminal size.
    if (ctx.session_client) |sc| {
        for (ctx.tab_mgr.tabs[0..ctx.tab_mgr.count]) |*maybe_layout| {
            if (maybe_layout.*) |*lay| {
                var rleaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
                const rlc = lay.collectLeaves(&rleaves);
                for (rleaves[0..rlc]) |rleaf| {
                    if (rleaf.pane.daemon_pane_id) |dpid| {
                        sc.sendPaneResize(dpid, rleaf.rect.rows, rleaf.rect.cols) catch {};
                    }
                }
            }
        }
    }

    posix.nanosleep(0, 1_000_000);
    // Drain local PTY data for the active pane (non-session mode)
    {
        const rpane = ctx.tab_mgr.activePane();
        if (rpane.daemon_pane_id == null) {
            while (true) {
                const n = rpane.pty.read(buf) catch break;
                if (n == 0) break;
                ctx.session.appendOutput(buf[0..n]);
                rpane.feed(buf[0..n]);
            }
        }
    }

    c.attyx_begin_cell_update();
    const resize_layout = ctx.tab_mgr.activeLayout();
    if (resize_layout.pane_count > 1 and !resize_layout.isZoomed()) {
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
        publish.fillCells(ctx.cells[0..new_total], publish.ctxEngine(ctx), new_total, &ctx.active_theme, null);
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
        session_picker_ui.relayout(ctx);
        command_palette_ui.relayout(ctx);
        theme_picker_ui.relayout(ctx);
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
}
