const std = @import("std");
const attyx = @import("attyx");
const overlay_mod = attyx.overlay_mod;
const overlay_ai_edit = attyx.overlay_ai_edit;
const overlay_ai_stream = attyx.overlay_ai_stream;
const overlay_ai_content = attyx.overlay_ai_content;
const overlay_ai_config = attyx.overlay_ai_config;
const overlay_ai_safety = attyx.overlay_ai_safety;
const overlay_context = attyx.overlay_context;

const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const c = terminal.c;
const publish = @import("publish.zig");
const input = @import("input.zig");
const ai = @import("ai.zig");
const ai_gen = @import("ai_generate_helpers.zig");
const ai_menu_helpers = @import("ai_menu_helpers.zig");
const ai_explain = @import("ai_explain_helpers.zig");
const cmd_capture_mod = @import("../cmd_capture.zig");

pub fn renderEditPromptCard(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    const edit = &(ai.g_ai_edit orelse return);
    const style = ai.contentStyleFromTheme(ctx);
    const result = overlay_ai_edit.layoutPromptCard(mgr.allocator, edit, 52, style) catch return;

    var bar = attyx.overlay_action.ActionBar{};
    bar.add(.accept, "Submit");
    bar.add(.dismiss, "Cancel");

    if (ai.g_streaming) |*so| {
        if (so.state != .idle) {
            so.replaceContent(result.cells, result.width, result.height);
            mgr.layers[@intFromEnum(overlay_mod.OverlayId.ai_demo)].action_bar = bar;
            ai.publishAiStreamingFrame(ctx);
            return;
        }
    }

    ai.showAiOverlayCard(ctx, result.cells, result.width, result.height, bar);
}

fn renderEditProposalCard(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    const edit = &(ai.g_ai_edit orelse return);
    const style = ai.contentStyleFromTheme(ctx);
    const result = overlay_ai_edit.layoutProposalCard(mgr.allocator, edit, 52, style) catch return;
    var bar = attyx.overlay_action.ActionBar{};
    bar.add(.accept, "Accept");
    bar.add(.reject, "Reject");
    bar.add(.copy, "Copy");
    bar.add(.insert, "Insert");
    ai.showAiOverlayCard(ctx, result.cells, result.width, result.height, bar);
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
    // Set final action bar BEFORE relayout so publishOverlays sees the correct bar
    var bar = attyx.overlay_action.ActionBar{};
    bar.add(.dismiss, "Dismiss");
    bar.add(.insert, "Insert");
    bar.add(.copy, "Copy");
    bar.add(.context, "Context");
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.ai_demo)].action_bar = bar;
    if (ai.g_ai_accumulator) |*acc| {
        const blocks = acc.reparse() catch &.{};
        if (blocks.len > 0) {
            ai.relayoutAiStreamContent(ctx, blocks);
        }
    }
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
    if (ai.g_ai_rewrite) |*rw| {
        rw.deinit();
        ai.g_ai_rewrite = null;
    }
    if (ai.g_ai_explain) |*ex| {
        ex.deinit();
        ai.g_ai_explain = null;
    }
    if (ai.g_ai_generate) |*gen| {
        gen.deinit();
        ai.g_ai_generate = null;
    }
    if (ai.g_ai_menu) |_| {
        ai.g_ai_menu = null;
    }
    terminal.g_ai_prompt_active = 0;
}

fn startRewriteFromMenu(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;

    ai.captureAiContext(ctx);

    if (resolveRewriteTarget(ctx)) |target| {
        if (ai.g_ai_rewrite == null) ai.g_ai_rewrite = overlay_ai_edit.RewriteContext.init(mgr.allocator);
        var rw = &(ai.g_ai_rewrite.?);
        rw.open(target) catch {
            mgr.allocator.free(target);
            return;
        };
        mgr.allocator.free(target);
        terminal.g_ai_prompt_active = 1;
        renderRewritePromptCard(ctx);
    }
}

/// Resolve a rewrite target command from CmdCapture state.
/// Returns an owned slice (caller must free) or null if no command available.
///
/// For current input: only read grid text when the cursor is on the SAME
/// row as prompt_row. Multi-line/async prompts can render in stages,
/// causing prompt_row/col to be captured mid-prompt; text on subsequent
/// rows would be prompt decoration, not user input.
pub fn resolveRewriteTarget(ctx: *PtyThreadCtx) ?[]const u8 {
    const pane = ctx.tab_mgr.activePane();
    const cap = pane.cmd_capture orelse return null;
    const alloc = (ctx.overlay_mgr orelse return null).allocator;

    // 1. Current input: same row, cursor past prompt end
    if (cap.state == .at_prompt) {
        const cursor = pane.engine.state.cursor;
        if (cursor.row == cap.prompt_row and cursor.col > cap.prompt_col) {
            if (cmd_capture_mod.readGridText(
                alloc,
                &pane.engine.state.grid,
                cap.prompt_row,
                cap.prompt_col,
                cursor.row,
                cursor.col,
            )) |text| {
                if (std.mem.trim(u8, text, " \t").len > 0) return text;
                alloc.free(text);
            }
        }
    }
    // 2. Last executed command
    if (cap.blockCount() > 0) {
        if (cap.getBlock(cap.blockCount() - 1)) |blk| {
            if (blk.command.len > 0)
                return alloc.dupe(u8, blk.command) catch null;
        }
    }
    return null;
}

pub fn renderRewritePromptCard(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    const rw = &(ai.g_ai_rewrite orelse return);
    const style = ai.contentStyleFromTheme(ctx);
    const result = overlay_ai_edit.layoutRewritePromptCard(mgr.allocator, rw, 52, style) catch return;

    var bar = attyx.overlay_action.ActionBar{};
    bar.add(.accept, "Submit");
    bar.add(.dismiss, "Cancel");

    if (ai.g_streaming) |*so| {
        if (so.state != .idle) {
            so.replaceContent(result.cells, result.width, result.height);
            mgr.layers[@intFromEnum(overlay_mod.OverlayId.ai_demo)].action_bar = bar;
            ai.publishAiStreamingFrame(ctx);
            return;
        }
    }

    ai.showAiOverlayCard(ctx, result.cells, result.width, result.height, bar);
}

fn renderRewriteResultCard(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    const rw = &(ai.g_ai_rewrite orelse return);

    // Compute safety for the rewritten command
    const safety: ?overlay_ai_safety.SafetyResult = if (rw.rewritten_command) |cmd|
        overlay_ai_safety.analyzeCommand(cmd)
    else
        null;

    const style = ai.contentStyleFromTheme(ctx);
    const result = overlay_ai_edit.layoutRewriteResultCard(mgr.allocator, rw, 52, safety, style) catch return;
    var bar = attyx.overlay_action.ActionBar{};

    // Danger commands need confirmation before replace
    if (safety) |s| {
        if (s.risk_level == .danger and !rw.danger_confirmed) {
            bar.add(.custom_0, "Confirm Replace");
        } else {
            bar.add(.custom_0, "Replace");
        }
    } else {
        bar.add(.custom_0, "Replace");
    }
    bar.add(.copy, "Copy");
    bar.add(.dismiss, "Close");
    ai.showAiOverlayCard(ctx, result.cells, result.width, result.height, bar);
}

pub fn consumeRewritePromptInput(ctx: *PtyThreadCtx) bool {
    var rw = &(ai.g_ai_rewrite orelse return false);
    var changed = false;

    // Drain char ring
    while (true) {
        const w = @atomicLoad(u32, &input.g_ai_prompt_char_write, .seq_cst);
        const r = @atomicLoad(u32, &input.g_ai_prompt_char_read, .seq_cst);
        if (w == r) break;
        const cp = input.g_ai_prompt_char_ring[r % 32];
        @atomicStore(u32, &input.g_ai_prompt_char_read, r +% 1, .seq_cst);
        rw.prompt.insertChar(@intCast(cp));
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
            1 => rw.prompt.deleteBack(),
            2 => rw.prompt.deleteFwd(),
            3 => rw.prompt.cursorLeft(),
            4 => rw.prompt.cursorRight(),
            5 => rw.prompt.cursorHome(),
            6 => rw.prompt.cursorEnd(),
            7 => { // cancel
                rw.close();
                ai.g_ai_rewrite = null;
                terminal.g_ai_prompt_active = 0;
                cancelAi(ctx);
                return true;
            },
            8 => { // submit
                submitRewritePrompt(ctx);
                return true;
            },
            else => {},
        }
        changed = true;
    }

    return changed;
}

fn submitRewritePrompt(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    var rw = &(ai.g_ai_rewrite orelse return);

    const prompt_text = rw.prompt.text();
    if (prompt_text.len == 0) return;
    const command = rw.target_command orelse return;

    // Build rewrite-specific request body
    if (ai.g_ai_request_body) |old| mgr.allocator.free(old);
    ai.g_ai_request_body = overlay_ai_config.serializeRewriteRequest(
        mgr.allocator,
        command,
        prompt_text,
    ) catch null;

    // Set context bundle invocation type
    if (ai.g_context_bundle) |*bundle| {
        bundle.invocation = .command_rewrite;
    }

    rw.submitPrompt();
    terminal.g_ai_prompt_active = 0;

    ai.loadTokensAndStream(ctx);
}

pub fn handleRewriteDoneResponse(ctx: *PtyThreadCtx, sse: *overlay_ai_stream.SseThread) void {
    var rw = &(ai.g_ai_rewrite orelse return);
    if (ai.g_ai_accumulator) |*acc| acc.reset();
    var drain_buf: [overlay_ai_stream.ring_size]u8 = undefined;
    const drained = sse.delta_ring.drain(&drain_buf);
    if (drained.len > 0) {
        // Same format as edit: replacement + \0 + summary
        const sep = std.mem.indexOfScalar(u8, drained, 0);
        const rewritten = if (sep) |s| drained[0..s] else drained;
        rw.receiveResponse(rewritten) catch {};
    }
    renderRewriteResultCard(ctx);
}

pub fn handleRewriteReplaceAction(ctx: *PtyThreadCtx) void {
    var rw = &(ai.g_ai_rewrite orelse return);
    const rewritten = rw.rewritten_command orelse return;

    // Safety gate: danger commands require confirmation step
    const safety = overlay_ai_safety.analyzeCommand(rewritten);
    if (safety.risk_level == .danger and !rw.danger_confirmed) {
        rw.danger_confirmed = true;
        renderRewriteResultCard(ctx);
        return;
    }

    // Clear current input: Ctrl-A (home) + Ctrl-K (kill to end of line)
    c.attyx_send_input("\x01", 1); // Ctrl-A
    c.attyx_send_input("\x0B", 1); // Ctrl-K

    // Insert via bracketed paste (does NOT auto-execute)
    if (publish.ctxEngine(ctx).state.bracketed_paste) {
        c.attyx_send_input("\x1b[200~", 6);
    }
    c.attyx_send_input(rewritten.ptr, @intCast(rewritten.len));
    if (publish.ctxEngine(ctx).state.bracketed_paste) {
        c.attyx_send_input("\x1b[201~", 6);
    }

    // Close rewrite and overlay
    cancelAi(ctx);
    publish.publishOverlays(ctx);
}

pub fn handleRewriteCopyAction(_: *PtyThreadCtx) void {
    const rw = &(ai.g_ai_rewrite orelse return);
    const rewritten = rw.rewritten_command orelse return;
    c.attyx_clipboard_copy(rewritten.ptr, @intCast(rewritten.len));
}

pub fn handleOverlayEsc(ctx: *PtyThreadCtx) void {
    if (ai.g_ai_menu) |_| {
        ai.g_ai_menu = null;
        terminal.g_ai_prompt_active = 0;
        cancelAi(ctx);
        publish.publishOverlays(ctx);
        return;
    }
    if (ai.g_ai_generate) |*gen| {
        switch (gen.state) {
            .result_ready => { cancelAi(ctx); publish.publishOverlays(ctx); },
            .prompt_input => {
                gen.close();
                ai.g_ai_generate = null;
                terminal.g_ai_prompt_active = 0;
                cancelAi(ctx);
                publish.publishOverlays(ctx);
            },
            else => {},
        }
        return;
    }
    if (ai.g_ai_explain) |_| {
        cancelAi(ctx);
        publish.publishOverlays(ctx);
        return;
    }
    if (ai.g_ai_rewrite) |*rw| {
        switch (rw.state) {
            .result_ready => { cancelAi(ctx); publish.publishOverlays(ctx); },
            .prompt_input => {
                rw.close();
                ai.g_ai_rewrite = null;
                terminal.g_ai_prompt_active = 0;
                cancelAi(ctx);
                publish.publishOverlays(ctx);
            },
            else => {},
        }
        return;
    }
    if (ai.g_ai_edit) |*edit| {
        switch (edit.state) {
            .proposal_ready => {
                handleEditRejectAction(ctx);
            },
            .prompt_input => {
                edit.close();
                ai.g_ai_edit = null;
                terminal.g_ai_prompt_active = 0;
                cancelAi(ctx);
                publish.publishOverlays(ctx);
            },
            else => {},
        }
        return;
    }

    // General overlay dismiss
    if (ctx.overlay_mgr) |mgr| {
        const was_ai_visible = mgr.isVisible(.ai_demo);
        const was_ctx_visible = mgr.isVisible(.context_preview);
        if (mgr.dismissActive()) {
            if (was_ctx_visible and !mgr.isVisible(.context_preview)) {
                mgr.show(.ai_demo);
            }
            if (was_ai_visible and !mgr.isVisible(.ai_demo)) {
                cancelAi(ctx);
            }
            publish.publishOverlays(ctx);
        }
    }
}

pub fn pollPromptInput(ctx: *PtyThreadCtx) void {
    if (ai.g_ai_menu) |*menu| {
        if (menu.state == .open) {
            if (ai_menu_helpers.consumeMenuInput(ctx)) |sel| {
                menu.close();
                ai.g_ai_menu = null;
                terminal.g_ai_prompt_active = 0;
                switch (sel) {
                    .rewrite_command => startRewriteFromMenu(ctx),
                    .explain_command => ai_explain.startExplainInvocation(ctx),
                    .generate_command => ai_gen.startGenerateInvocation(ctx),
                }
            } else if (ai.g_ai_menu != null) {
                ai_menu_helpers.renderMenuCard(ctx);
            }
            return;
        }
    }
    if (ai.g_ai_generate) |*gen| {
        if (gen.state == .prompt_input) {
            if (ai_gen.consumeGeneratePromptInput(ctx)) {
                if (ai.g_ai_generate) |*g2| if (g2.state == .prompt_input) ai_gen.renderGeneratePromptCard(ctx);
            }
            return;
        }
    }
    if (ai.g_ai_rewrite) |*rw| {
        if (rw.state == .prompt_input) {
            if (consumeRewritePromptInput(ctx)) {
                if (ai.g_ai_rewrite) |*rw2| {
                    if (rw2.state == .prompt_input) {
                        renderRewritePromptCard(ctx);
                    }
                }
            }
            return;
        }
    }

    // Edit prompt polling
    if (ai.g_ai_edit) |*edit| {
        if (edit.state == .prompt_input) {
            if (consumeAiPromptInput(ctx)) {
                if (ai.g_ai_edit) |*e2| {
                    if (e2.state == .prompt_input) {
                        renderEditPromptCard(ctx);
                    }
                }
            }
        }
    }
}
