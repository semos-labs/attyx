/// Windows popup terminal lifecycle — spawn/drain/exit/publish.
/// Mirrors the POSIX popup handling in actions.zig but uses WinCtx
/// and Windows PTY APIs instead of POSIX poll/read.
const std = @import("std");
const attyx = @import("attyx");
const logging = @import("../../logging/log.zig");
const popup_mod = @import("../popup.zig");
const publish = @import("publish.zig");
const c = publish.c;
const ws = @import("../windows_stubs.zig");
const event_loop = @import("event_loop_windows.zig");
const WinCtx = event_loop.WinCtx;

/// Check popup toggle requests and spawn/close popups.
pub fn processPopupToggle(ctx: *WinCtx) void {
    for (0..ctx.popup_config_count) |i| {
        if (@atomicRmw(i32, &ws.popup_toggle_request[i], .Xchg, 0, .seq_cst) != 0) {
            logging.info("popup", "processing toggle for index {d}", .{i});
            if (ctx.popup_state) |ps| {
                const same = (ps.config_index == i);
                closePopup(ctx);
                if (same) return;
            }
            const cfg = ctx.popup_configs[i];
            logging.info("popup", "spawning: cmd={s} w={d}% h={d}%", .{ cfg.command, cfg.width_pct, cfg.height_pct });
            var ps = ctx.allocator.create(popup_mod.PopupState) catch return;
            ps.* = popup_mod.PopupState.spawn(
                ctx.allocator, cfg, ctx.grid_cols, ctx.grid_rows, null, null,
            ) catch |err| {
                logging.err("popup", "spawn failed: {}", .{err});
                ctx.allocator.destroy(ps);
                return;
            };
            ps.pane.engine.state.theme_colors = publish.themeToEngineColors(ctx.theme);
            ps.config_index = @intCast(i);
            ctx.popup_state = ps;
            ws.g_popup_pty_handle = ps.pane.pty.pipe_in_write;
            ws.g_popup_engine = &ps.pane.engine;
            @atomicStore(i32, @as(*i32, @ptrCast(@volatileCast(&c.g_popup_active))), 1, .seq_cst);
            ps.publishCells(ctx.theme, cfg);
            return;
        }
    }
}

/// Drain popup PTY data via PeekNamedPipe + ReadFile.
pub fn drainPopupPty(ctx: *WinCtx, buf: []u8) void {
    const ps = ctx.popup_state orelse return;
    if (ps.child_exited) return;

    var got_data = false;
    while (true) {
        const avail = ps.pane.pty.peekAvail();
        if (avail == 0) break;
        const n = ps.pane.pty.read(buf) catch break;
        if (n == 0) break;
        got_data = true;
        ps.feed(buf[0..n]);
    }

    // Keep async read pending to trigger ConPTY output flush.
    if (!got_data) {
        if (ps.pane.pty.checkAsyncRead()) |data| {
            got_data = true;
            ps.feed(data);
        }
        ps.pane.pty.startAsyncRead();
    }

    if (got_data) {
        const cfg = ctx.popup_configs[ps.config_index];
        ps.publishCells(ctx.theme, cfg);
        c.g_popup_mouse_tracking = @intFromEnum(ps.pane.engine.state.mouse_tracking);
        c.g_popup_mouse_sgr = @intFromBool(ps.pane.engine.state.mouse_sgr);
    }
}

/// Check if popup child has exited and handle cleanup.
pub fn checkPopupExit(ctx: *WinCtx) void {
    const ps = ctx.popup_state orelse return;
    if (ps.child_exited) return;
    if (!ps.pane.childExited()) return;

    ps.pane.pty.waitForExit();
    const code = ps.pane.pty.exitCode() orelse 1;
    logging.info("popup", "exit code={d}", .{code});

    // Drain any remaining output
    var drain_buf: [4096]u8 = undefined;
    while (true) {
        const avail = ps.pane.pty.peekAvail();
        if (avail == 0) break;
        const n = ps.pane.pty.read(&drain_buf) catch break;
        if (n == 0) break;
        ps.feed(drain_buf[0..n]);
    }

    // Close on success or user cancellation
    if (code == 0 or code == 1 or code == 130) {
        closePopup(ctx);
    } else {
        ps.child_exited = true;
    }
}

/// Close popup and reset bridge state.
pub fn closePopup(ctx: *WinCtx) void {
    const ps = ctx.popup_state orelse return;
    ws.g_popup_pty_handle = null;
    ws.g_popup_engine = null;
    @atomicStore(i32, &ws.popup_dead, 0, .seq_cst);
    ps.deinit();
    ctx.allocator.destroy(ps);
    ctx.popup_state = null;
    popup_mod.clearBridgeState();
}
