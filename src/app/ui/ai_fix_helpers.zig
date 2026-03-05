const std = @import("std");
const attyx = @import("attyx");
const overlay_ai_fix = attyx.overlay_ai_fix;
const overlay_ai_stream = attyx.overlay_ai_stream;
const overlay_ai_config = attyx.overlay_ai_config;
const overlay_ai_safety = attyx.overlay_ai_safety;
const overlay_ai_redact = attyx.overlay_ai_redact;

const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const c = terminal.c;
const publish = @import("publish.zig");
const ai = @import("ai.zig");
const ai_edit = @import("ai_edit_helpers.zig");

// ---------------------------------------------------------------------------
// Fix mode helpers
// ---------------------------------------------------------------------------

/// Start the "Fix Last Command" flow.
/// Finds the last command block, validates it failed, redacts output,
/// builds the fix request, and starts streaming.
pub fn startFixInvocation(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;

    // Get CmdCapture from active pane
    const pane = ctx.tab_mgr.activePane();
    const cap = pane.cmd_capture orelse {
        showFixError(ctx, "No command history available");
        return;
    };

    // Get last command block
    if (cap.blockCount() == 0) {
        showFixError(ctx, "No previous command found");
        return;
    }

    const block = cap.getBlock(cap.blockCount() - 1) orelse {
        showFixError(ctx, "No previous command found");
        return;
    };

    // Validate command failed
    if (block.exit_code) |code| {
        if (code == 0) {
            showFixError(ctx, "Last command succeeded (exit 0)");
            return;
        }
    } else {
        showFixError(ctx, "Exit code unavailable for last command");
        return;
    }

    const exit_code = block.exit_code.?;

    // Capture AI context
    ai.captureAiContext(ctx);
    if (ai.g_context_bundle) |*bundle| {
        bundle.invocation = .command_fix;
    }

    // Init FixContext
    if (ai.g_ai_fix == null) ai.g_ai_fix = overlay_ai_fix.FixContext.init(mgr.allocator);
    var fix = &(ai.g_ai_fix.?);
    fix.open(block.command) catch return;

    // Extract last 50 lines of output and redact
    const output_tail = extractOutputTail(mgr.allocator, block.output, 50) catch "";
    defer if (output_tail.len > 0 and output_tail.ptr != block.output.ptr)
        mgr.allocator.free(output_tail);

    const redacted = overlay_ai_redact.redactSensitive(mgr.allocator, output_tail) catch output_tail;
    defer if (redacted.ptr != output_tail.ptr) mgr.allocator.free(redacted);

    // Get shell name from context bundle
    const shell: ?[]const u8 = if (ai.g_context_bundle) |*bundle| bundle.title else null;

    // Build fix request body
    if (ai.g_ai_request_body) |old| mgr.allocator.free(old);
    ai.g_ai_request_body = overlay_ai_config.serializeFixRequest(
        mgr.allocator,
        block.command,
        exit_code,
        redacted,
        shell,
    ) catch null;

    // Start auth + streaming
    ai.loadTokensAndStream(ctx);
}

pub fn handleFixDoneResponse(ctx: *PtyThreadCtx, sse: *overlay_ai_stream.SseThread) void {
    var fix = &(ai.g_ai_fix orelse return);
    if (ai.g_ai_accumulator) |*acc| acc.reset();

    var drain_buf: [overlay_ai_stream.ring_size]u8 = undefined;
    const drained = sse.delta_ring.drain(&drain_buf);
    if (drained.len == 0) return;

    // Format: rewritten_command \0 reason
    const sep = std.mem.indexOfScalar(u8, drained, 0) orelse drained.len;
    const rewritten = drained[0..sep];
    const reason_text = if (sep + 1 < drained.len) drained[sep + 1 ..] else "Command fixed";

    fix.receiveResponse(rewritten, reason_text) catch return;
    renderFixResultCard(ctx);
}

pub fn renderFixResultCard(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    const fix = &(ai.g_ai_fix orelse return);

    // Compute safety for the rewritten command
    const safety: overlay_ai_safety.SafetyResult = if (fix.rewritten_command) |cmd|
        overlay_ai_safety.analyzeCommand(cmd)
    else
        .{};

    const style = ai.contentStyleFromTheme(ctx);
    const result = overlay_ai_fix.layoutFixResultCard(mgr.allocator, fix, 52, safety, style) catch return;
    var bar = attyx.overlay_action.ActionBar{};

    // Danger commands need confirmation before insert
    if (safety.risk_level == .danger and !fix.danger_confirmed) {
        bar.add(.insert, "Confirm Replace");
    } else {
        bar.add(.insert, "Replace");
    }
    bar.add(.copy, "Copy");
    bar.add(.dismiss, "Close");
    ai.showAiOverlayCard(ctx, result.cells, result.width, result.height, bar);
}

pub fn handleFixReplaceAction(ctx: *PtyThreadCtx) void {
    var fix = &(ai.g_ai_fix orelse return);
    const command = fix.rewritten_command orelse return;

    // Safety gate
    const safety = overlay_ai_safety.analyzeCommand(command);
    if (safety.risk_level == .danger and !fix.danger_confirmed) {
        fix.danger_confirmed = true;
        renderFixResultCard(ctx);
        return;
    }

    // Clear current input: Ctrl-A (home) + Ctrl-K (kill to end of line)
    c.attyx_send_input("\x01", 1); // Ctrl-A
    c.attyx_send_input("\x0B", 1); // Ctrl-K

    // Insert via bracketed paste
    if (publish.ctxEngine(ctx).state.bracketed_paste) {
        c.attyx_send_input("\x1b[200~", 6);
    }
    c.attyx_send_input(command.ptr, @intCast(command.len));
    if (publish.ctxEngine(ctx).state.bracketed_paste) {
        c.attyx_send_input("\x1b[201~", 6);
    }

    // Close fix and overlay
    ai_edit.cancelAi(ctx);
    publish.publishOverlays(ctx);
}

pub fn handleFixCopyAction(_: *PtyThreadCtx) void {
    const fix = &(ai.g_ai_fix orelse return);
    const command = fix.rewritten_command orelse return;
    c.attyx_clipboard_copy(command.ptr, @intCast(command.len));
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn showFixError(ctx: *PtyThreadCtx, msg: []const u8) void {
    const mgr = ctx.overlay_mgr orelse return;
    const overlay_ai_error = attyx.overlay_ai_error;
    const style = ai.contentStyleFromTheme(ctx);
    const result = overlay_ai_error.layoutErrorCard(mgr.allocator, "fix", msg, 48, style) catch return;
    var bar = attyx.overlay_action.ActionBar{};
    bar.add(.dismiss, "Close");
    ai.showAiOverlayCard(ctx, result.cells, result.width, result.height, bar);
}

/// Extract the last N lines from output.
fn extractOutputTail(allocator: std.mem.Allocator, output: []const u8, max_lines: usize) ![]const u8 {
    if (output.len == 0) return "";

    // Count newlines from the end
    var count: usize = 0;
    var pos = output.len;
    while (pos > 0) {
        pos -= 1;
        if (output[pos] == '\n') {
            count += 1;
            if (count >= max_lines) {
                return try allocator.dupe(u8, output[pos + 1 ..]);
            }
        }
    }

    // Fewer than max_lines — return all
    return try allocator.dupe(u8, output);
}
