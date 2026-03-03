const std = @import("std");
const attyx = @import("attyx");
const overlay_mod = attyx.overlay_mod;
const overlay_ai_generate = attyx.overlay_ai_generate;
const overlay_ai_stream = attyx.overlay_ai_stream;
const overlay_ai_config = attyx.overlay_ai_config;
const overlay_ai_safety = attyx.overlay_ai_safety;

const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const c = terminal.c;
const publish = @import("publish.zig");
const input = @import("input.zig");
const ai = @import("ai.zig");
const ai_edit = @import("ai_edit_helpers.zig");

// ---------------------------------------------------------------------------
// Generate mode helpers
// ---------------------------------------------------------------------------

pub fn startGenerateInvocation(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;

    // Capture context
    ai.captureAiContext(ctx);
    if (ai.g_context_bundle) |*bundle| {
        bundle.invocation = .command_generate;
    }

    // Init GenerateContext
    if (ai.g_ai_generate == null) ai.g_ai_generate = overlay_ai_generate.GenerateContext.init(mgr.allocator);
    var gen = &(ai.g_ai_generate.?);
    gen.open();

    terminal.g_ai_prompt_active = 1;
    renderGeneratePromptCard(ctx);
}

pub fn consumeGeneratePromptInput(ctx: *PtyThreadCtx) bool {
    var gen = &(ai.g_ai_generate orelse return false);
    var changed = false;

    // Drain char ring
    while (true) {
        const w = @atomicLoad(u32, &input.g_ai_prompt_char_write, .seq_cst);
        const r = @atomicLoad(u32, &input.g_ai_prompt_char_read, .seq_cst);
        if (w == r) break;
        const cp = input.g_ai_prompt_char_ring[r % 32];
        @atomicStore(u32, &input.g_ai_prompt_char_read, r +% 1, .seq_cst);
        gen.prompt.insertChar(@intCast(cp));
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
            1 => gen.prompt.deleteBack(),
            2 => gen.prompt.deleteFwd(),
            3 => gen.prompt.cursorLeft(),
            4 => gen.prompt.cursorRight(),
            5 => gen.prompt.cursorHome(),
            6 => gen.prompt.cursorEnd(),
            7 => { // cancel
                gen.close();
                ai.g_ai_generate = null;
                terminal.g_ai_prompt_active = 0;
                ai_edit.cancelAi(ctx);
                return true;
            },
            8 => { // submit
                submitGeneratePrompt(ctx);
                return true;
            },
            else => {},
        }
        changed = true;
    }

    return changed;
}

pub fn submitGeneratePrompt(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    var gen = &(ai.g_ai_generate orelse return);

    const prompt_text = gen.prompt.text();
    if (prompt_text.len == 0) return;

    // Get shell name from context bundle title
    const shell: ?[]const u8 = if (ai.g_context_bundle) |*bundle| bundle.title else null;

    // Build generate-specific request body
    if (ai.g_ai_request_body) |old| mgr.allocator.free(old);
    ai.g_ai_request_body = overlay_ai_config.serializeGenerateRequest(
        mgr.allocator,
        prompt_text,
        shell,
    ) catch null;

    // Set context bundle invocation type
    if (ai.g_context_bundle) |*bundle| {
        bundle.invocation = .command_generate;
    }

    gen.submitPrompt();
    terminal.g_ai_prompt_active = 0;

    ai.loadTokensAndStream(ctx);
}

pub fn handleGenerateDoneResponse(ctx: *PtyThreadCtx, sse: *overlay_ai_stream.SseThread) void {
    var gen = &(ai.g_ai_generate orelse return);
    if (ai.g_ai_accumulator) |*acc| acc.reset();

    var drain_buf: [overlay_ai_stream.ring_size]u8 = undefined;
    const drained = sse.delta_ring.drain(&drain_buf);
    if (drained.len == 0) return;

    // Format: command \0 notes
    const sep = std.mem.indexOfScalar(u8, drained, 0) orelse drained.len;
    const command = drained[0..sep];
    const notes_text: ?[]const u8 = if (sep + 1 < drained.len) drained[sep + 1 ..] else null;

    gen.receiveResponse(command, notes_text) catch return;
    renderGenerateResultCard(ctx);
}

pub fn renderGeneratePromptCard(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    const gen = &(ai.g_ai_generate orelse return);
    const style = ai.contentStyleFromTheme(ctx);
    const result = overlay_ai_generate.layoutGeneratePromptCard(mgr.allocator, gen, 52, style) catch return;

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

fn renderGenerateResultCard(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    const gen = &(ai.g_ai_generate orelse return);

    // Compute safety for the generated command
    const safety: ?overlay_ai_safety.SafetyResult = if (gen.generated_command) |cmd|
        overlay_ai_safety.analyzeCommand(cmd)
    else
        null;

    const style = ai.contentStyleFromTheme(ctx);
    const result = overlay_ai_generate.layoutGenerateResultCard(mgr.allocator, gen, 52, safety, style) catch return;
    var bar = attyx.overlay_action.ActionBar{};

    // Danger commands need confirmation before insert
    if (safety) |s| {
        if (s.risk_level == .danger and !gen.danger_confirmed) {
            bar.add(.insert, "Confirm Insert");
        } else {
            bar.add(.insert, "Insert");
        }
    } else {
        bar.add(.insert, "Insert");
    }
    bar.add(.copy, "Copy");
    bar.add(.dismiss, "Close");
    ai.showAiOverlayCard(ctx, result.cells, result.width, result.height, bar);
}

pub fn handleGenerateInsertAction(ctx: *PtyThreadCtx) void {
    var gen = &(ai.g_ai_generate orelse return);
    const command = gen.generated_command orelse return;

    // Safety gate: danger commands require confirmation step
    const safety = overlay_ai_safety.analyzeCommand(command);
    if (safety.risk_level == .danger and !gen.danger_confirmed) {
        gen.danger_confirmed = true;
        renderGenerateResultCard(ctx);
        return;
    }

    // Clear current input: Ctrl-A (home) + Ctrl-K (kill to end of line)
    c.attyx_send_input("\x01", 1); // Ctrl-A
    c.attyx_send_input("\x0B", 1); // Ctrl-K

    // Insert via bracketed paste (does NOT auto-execute)
    if (publish.ctxEngine(ctx).state.bracketed_paste) {
        c.attyx_send_input("\x1b[200~", 6);
    }
    c.attyx_send_input(command.ptr, @intCast(command.len));
    if (publish.ctxEngine(ctx).state.bracketed_paste) {
        c.attyx_send_input("\x1b[201~", 6);
    }

    // Close generate and overlay
    ai_edit.cancelAi(ctx);
    publish.publishOverlays(ctx);
}

pub fn handleGenerateCopyAction(_: *PtyThreadCtx) void {
    const gen = &(ai.g_ai_generate orelse return);
    const command = gen.generated_command orelse return;
    c.attyx_clipboard_copy(command.ptr, @intCast(command.len));
}
