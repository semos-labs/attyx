const std = @import("std");
const attyx = @import("attyx");
const overlay_mod = attyx.overlay_mod;
const overlay_ai_edit = attyx.overlay_ai_edit;
const overlay_ai_stream = attyx.overlay_ai_stream;
const overlay_ai_content = attyx.overlay_ai_content;

const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const c = terminal.c;
const publish = @import("publish.zig");
const input = @import("input.zig");
const ai = @import("ai.zig");

// ---------------------------------------------------------------------------
// Edit mode helpers
// ---------------------------------------------------------------------------

pub fn renderEditPromptCard(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    const edit = &(ai.g_ai_edit orelse return);
    const result = overlay_ai_edit.layoutPromptCard(mgr.allocator, edit, 52) catch return;

    if (ai.g_streaming) |*so| {
        if (so.state != .idle) {
            so.replaceContent(result.cells, result.width, result.height);
            mgr.layers[@intFromEnum(overlay_mod.OverlayId.ai_demo)].action_bar = blk: {
                var bar = attyx.overlay_action.ActionBar{};
                bar.add(.accept, "Submit");
                bar.add(.dismiss, "Cancel");
                break :blk bar;
            };
            ai.publishAiStreamingFrame(ctx);
            return;
        }
    }

    ai.showAiOverlayCard(ctx, result.cells, result.width, result.height, .{});
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.ai_demo)].action_bar = blk: {
        var bar = attyx.overlay_action.ActionBar{};
        bar.add(.accept, "Submit");
        bar.add(.dismiss, "Cancel");
        break :blk bar;
    };
    publish.publishOverlays(ctx);
}

fn renderEditProposalCard(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    const edit = &(ai.g_ai_edit orelse return);
    const result = overlay_ai_edit.layoutProposalCard(mgr.allocator, edit, 52) catch return;
    ai.showAiOverlayCard(ctx, result.cells, result.width, result.height, .{});
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.ai_demo)].action_bar = blk: {
        var bar = attyx.overlay_action.ActionBar{};
        bar.add(.accept, "Accept");
        bar.add(.reject, "Reject");
        bar.add(.copy, "Copy");
        bar.add(.insert, "Insert");
        break :blk bar;
    };
    publish.publishOverlays(ctx);
}

fn submitEditPrompt(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    var edit = &(ai.g_ai_edit orelse return);
    var bundle = &(ai.g_context_bundle orelse return);

    const prompt_text = edit.prompt.text();
    std.debug.print("[ai-edit] submitEditPrompt: prompt=\"{s}\" len={d}\n", .{ prompt_text, prompt_text.len });
    if (prompt_text.len == 0) return;
    if (bundle.edit_prompt) |ep| bundle.allocator.free(ep);
    bundle.edit_prompt = mgr.allocator.dupe(u8, prompt_text) catch null;
    bundle.invocation = .edit_selection;

    std.debug.print("[ai-edit] set invocation=edit_selection, calling loadTokensAndStream\n", .{});
    edit.submitPrompt();
    terminal.g_ai_prompt_active = 0;

    ai.loadTokensAndStream(ctx);
}

pub fn consumeAiPromptInput(ctx: *PtyThreadCtx) bool {
    var edit = &(ai.g_ai_edit orelse return false);
    var changed = false;

    // Drain char ring
    while (true) {
        const w = @atomicLoad(u32, &input.g_ai_prompt_char_write, .seq_cst);
        const r = @atomicLoad(u32, &input.g_ai_prompt_char_read, .seq_cst);
        if (w == r) break;
        const cp = input.g_ai_prompt_char_ring[r % 32];
        @atomicStore(u32, &input.g_ai_prompt_char_read, r +% 1, .seq_cst);
        edit.prompt.insertChar(@intCast(cp));
        changed = true;
    }

    // Drain cmd ring
    while (true) {
        const w = @atomicLoad(u32, &input.g_ai_prompt_cmd_write, .seq_cst);
        const r = @atomicLoad(u32, &input.g_ai_prompt_cmd_read, .seq_cst);
        if (w == r) break;
        const cmd = input.g_ai_prompt_cmd_ring[r % 16];
        @atomicStore(u32, &input.g_ai_prompt_cmd_read, r +% 1, .seq_cst);
        switch (cmd) {
            1 => edit.prompt.deleteBack(),
            2 => edit.prompt.deleteFwd(),
            3 => edit.prompt.cursorLeft(),
            4 => edit.prompt.cursorRight(),
            5 => edit.prompt.cursorHome(),
            6 => edit.prompt.cursorEnd(),
            7 => { // cancel
                edit.close();
                ai.g_ai_edit = null;
                terminal.g_ai_prompt_active = 0;
                cancelAi(ctx);
                return true;
            },
            8 => { // submit
                submitEditPrompt(ctx);
                return true;
            },
            else => {},
        }
        changed = true;
    }

    return changed;
}

pub fn handleEditAcceptAction(ctx: *PtyThreadCtx) void {
    const edit = &(ai.g_ai_edit orelse return);
    switch (edit.state) {
        .prompt_input => submitEditPrompt(ctx),
        .proposal_ready => {
            if (edit.replacement_text) |repl| {
                c.attyx_clipboard_copy(repl.ptr, @intCast(repl.len));
            }
        },
        else => {},
    }
}

pub fn handleEditInsertAction(ctx: *PtyThreadCtx) void {
    const edit = &(ai.g_ai_edit orelse return);
    const repl = edit.replacement_text orelse return;
    if (publish.ctxEngine(ctx).state.bracketed_paste) {
        c.attyx_send_input("\x1b[200~", 6);
    }
    c.attyx_send_input(repl.ptr, @intCast(repl.len));
    if (publish.ctxEngine(ctx).state.bracketed_paste) {
        c.attyx_send_input("\x1b[201~", 6);
    }
}

pub fn handleEditDoneResponse(ctx: *PtyThreadCtx, sse: *overlay_ai_stream.SseThread) void {
    var edit = &(ai.g_ai_edit orelse return);
    if (ai.g_ai_accumulator) |*acc| acc.reset();
    var drain_buf: [overlay_ai_stream.ring_size]u8 = undefined;
    const drained = sse.delta_ring.drain(&drain_buf);
    if (drained.len > 0) {
        const sep = std.mem.indexOfScalar(u8, drained, 0);
        if (sep) |s| {
            const replacement = drained[0..s];
            const explanation = if (s + 1 < drained.len) drained[s + 1 ..] else "";
            edit.receiveResponse(replacement, explanation) catch {};
        } else {
            edit.receiveResponse(drained, "") catch {};
        }
    }
    renderEditProposalCard(ctx);
}

pub fn handleNormalDoneResponse(ctx: *PtyThreadCtx, sse: *overlay_ai_stream.SseThread, mgr: *overlay_mod.OverlayManager) void {
    if (ai.g_ai_accumulator) |*acc| acc.reset();
    {
        var drain_buf: [overlay_ai_stream.ring_size]u8 = undefined;
        const drained = sse.delta_ring.drain(&drain_buf);
        if (drained.len > 0) {
            if (ai.g_ai_accumulator) |*acc| {
                acc.appendDelta(drained) catch {};
            }
        }
    }
    if (ai.g_ai_accumulator) |*acc| {
        const blocks = acc.reparse() catch &.{};
        if (blocks.len > 0) {
            ai.relayoutAiStreamContent(ctx, blocks);
        }
    }
    var bar = attyx.overlay_action.ActionBar{};
    bar.add(.dismiss, "Dismiss");
    bar.add(.insert, "Insert");
    bar.add(.copy, "Copy");
    bar.add(.context, "Context");
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.ai_demo)].action_bar = bar;
    publish.publishOverlays(ctx);
}

pub fn handleEditRejectAction(ctx: *PtyThreadCtx) void {
    var edit = &(ai.g_ai_edit orelse return);
    edit.reject();
    terminal.g_ai_prompt_active = 1;
    renderEditPromptCard(ctx);
}

pub fn handleRetryAction(ctx: *PtyThreadCtx) void {
    if (ai.g_sse_thread) |*sse| {
        sse.requestCancel();
        _ = sse.tryJoin();
    }
    if (ai.g_auth_thread) |*auth| {
        auth.requestCancel();
        _ = auth.tryJoin();
    }
    if (ai.g_streaming) |*so| so.cancel();
    if (ai.g_ai_accumulator) |*acc| acc.reset();

    ai.startAiInvocation(ctx);
}

pub fn cancelAi(ctx: *PtyThreadCtx) void {
    if (ai.g_sse_thread) |*sse| {
        sse.requestCancel();
        _ = sse.tryJoin();
    }
    if (ai.g_auth_thread) |*auth| {
        auth.requestCancel();
        _ = auth.tryJoin();
    }
    if (ai.g_streaming) |*so| {
        so.cancel();
    }
    if (ctx.overlay_mgr) |mgr| {
        mgr.hide(.ai_demo);
        mgr.hide(.context_preview);
    }
    if (ai.g_ai_request_body) |body| {
        if (ctx.overlay_mgr) |mgr| mgr.allocator.free(body);
        ai.g_ai_request_body = null;
    }
    if (ai.g_ai_accumulator) |*acc| {
        acc.deinit();
        ai.g_ai_accumulator = null;
    }
    if (ai.g_context_bundle) |*bundle| {
        bundle.deinit();
        ai.g_context_bundle = null;
    }
    if (ai.g_ai_edit) |*edit| {
        edit.deinit();
        ai.g_ai_edit = null;
    }
    terminal.g_ai_prompt_active = 0;
}
