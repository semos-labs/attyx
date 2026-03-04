/// Overlay interaction handlers: dismiss, focus cycle, activate, mouse click, scroll.
/// Extracted from event_loop.zig to keep files under 600 lines.
const std = @import("std");

const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const publish = @import("publish.zig");
const input = @import("input.zig");
const ai = @import("ai.zig");

/// Process all overlay interactions (dismiss, focus cycling, activate, clicks, scroll).
pub fn processOverlayInteractions(ctx: *PtyThreadCtx) void {
    processDismiss(ctx);
    processCycleFocus(ctx);
    processActivate(ctx);
    processMouseClick(ctx);
    processMouseScroll(ctx);
}

fn processDismiss(ctx: *PtyThreadCtx) void {
    if (@atomicRmw(i32, &input.g_overlay_dismiss, .Xchg, 0, .seq_cst) == 0) return;

    if (ai.g_ai_edit) |*edit| {
        switch (edit.state) {
            .proposal_ready => ai.handleEditRejectAction(ctx),
            .prompt_input => {
                edit.close();
                ai.g_ai_edit = null;
                terminal.g_ai_prompt_active = 0;
                ai.cancelAi(ctx);
                publish.publishOverlays(ctx);
            },
            else => {},
        }
    } else if (ctx.overlay_mgr) |mgr| {
        const was_ai_visible = mgr.isVisible(.ai_demo);
        const was_ctx_visible = mgr.isVisible(.context_preview);
        if (mgr.dismissActive()) {
            if (was_ctx_visible and !mgr.isVisible(.context_preview)) mgr.show(.ai_demo);
            if (was_ai_visible and !mgr.isVisible(.ai_demo)) ai.cancelAi(ctx);
            publish.publishOverlays(ctx);
        }
    }
}

fn processCycleFocus(ctx: *PtyThreadCtx) void {
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
}

fn processActivate(ctx: *PtyThreadCtx) void {
    if (@atomicRmw(i32, &input.g_overlay_activate, .Xchg, 0, .seq_cst) == 0) return;
    const mgr = ctx.overlay_mgr orelse return;

    const was_ai_visible = mgr.isVisible(.ai_demo);
    const was_ctx_visible = mgr.isVisible(.context_preview);
    if (mgr.activateFocused()) |action_id| {
        switch (action_id) {
            .dismiss => {
                _ = mgr.dismissActive();
                if (was_ctx_visible and !mgr.isVisible(.context_preview)) mgr.show(.ai_demo);
                if (was_ai_visible and !mgr.isVisible(.ai_demo)) ai.cancelAi(ctx);
            },
            .context => ai.toggleContextPreview(ctx),
            .insert => if (ai.g_ai_edit != null) ai.handleEditInsertAction(ctx) else ai.handleInsertAction(ctx),
            .copy => ai.handleCopyAction(ctx),
            .retry => ai.handleRetryAction(ctx),
            .accept => ai.handleEditAcceptAction(ctx),
            .reject => ai.handleEditRejectAction(ctx),
            else => {},
        }
        publish.publishOverlays(ctx);
    }
}

fn processMouseClick(ctx: *PtyThreadCtx) void {
    if (@atomicRmw(i32, &input.g_overlay_click_pending, .Xchg, 0, .seq_cst) == 0) return;
    const mgr = ctx.overlay_mgr orelse return;

    const click_col: u16 = @intCast(@max(0, @atomicLoad(i32, &input.g_overlay_click_col, .seq_cst)));
    const click_row: u16 = @intCast(@max(0, @atomicLoad(i32, &input.g_overlay_click_row, .seq_cst)));
    if (mgr.hitTest(click_col, click_row)) |hit| {
        const was_ai_visible = mgr.isVisible(.ai_demo);
        const was_ctx_visible = mgr.isVisible(.context_preview);
        if (mgr.clickAction(hit)) |action_id| {
            switch (action_id) {
                .dismiss => {
                    _ = mgr.dismissActive();
                    if (was_ctx_visible and !mgr.isVisible(.context_preview)) mgr.show(.ai_demo);
                    if (was_ai_visible and !mgr.isVisible(.ai_demo)) ai.cancelAi(ctx);
                },
                .context => ai.toggleContextPreview(ctx),
                .insert => ai.handleInsertAction(ctx),
                .copy => ai.handleCopyAction(ctx),
                .retry => ai.handleRetryAction(ctx),
                else => {},
            }
        }
        publish.publishOverlays(ctx);
    }
}

fn processMouseScroll(ctx: *PtyThreadCtx) void {
    if (@atomicRmw(i32, &input.g_overlay_scroll_pending, .Xchg, 0, .seq_cst) == 0) return;
    const delta = @atomicRmw(i32, &input.g_overlay_scroll_delta, .Xchg, 0, .seq_cst);
    if (ai.g_streaming) |*so| {
        const d: i16 = @intCast(std.math.clamp(delta, -100, 100));
        if (so.scroll(d)) {
            ai.publishAiStreamingFrame(ctx);
        }
    }
}
