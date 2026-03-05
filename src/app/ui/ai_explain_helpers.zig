const std = @import("std");
const attyx = @import("attyx");
const overlay_ai_explain = attyx.overlay_ai_explain;
const overlay_ai_stream = attyx.overlay_ai_stream;
const security_gateway = attyx.security_gateway;

const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const c = terminal.c;
const publish = @import("publish.zig");
const ai = @import("ai.zig");
const ai_edit = @import("ai_edit_helpers.zig");

// ---------------------------------------------------------------------------
// Explain mode helpers
// ---------------------------------------------------------------------------

pub fn startExplainInvocation(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;

    // Resolve target command (reuse existing logic)
    const target = ai_edit.resolveRewriteTarget(ctx) orelse {
        ai.showAiOverlayCard(ctx, &.{}, 0, 0, .{});
        return;
    };
    defer mgr.allocator.free(target);

    // Capture context and set invocation type
    ai.captureAiContext(ctx);
    if (ai.g_context_bundle) |*bundle| {
        bundle.invocation = .command_explain;
    }

    // Init ExplainContext
    if (ai.g_ai_explain == null) ai.g_ai_explain = overlay_ai_explain.ExplainContext.init(mgr.allocator);
    var explain = &(ai.g_ai_explain.?);
    explain.open(target) catch return;

    // Build request through security gateway
    if (ai.g_ai_prepared_request) |*old| old.deinit(mgr.allocator);
    ai.g_ai_prepared_request = security_gateway.prepareRequest(
        mgr.allocator,
        .{ .explain = .{ .command = target } },
    ) catch null;

    // Start auth + streaming
    ai.loadTokensAndStream(ctx);
}

pub fn handleExplainDoneResponse(ctx: *PtyThreadCtx, sse: *overlay_ai_stream.SseThread) void {
    var explain = &(ai.g_ai_explain orelse return);
    if (ai.g_ai_accumulator) |*acc| acc.reset();

    var drain_buf: [overlay_ai_stream.ring_size]u8 = undefined;
    const drained = sse.delta_ring.drain(&drain_buf);
    if (drained.len == 0) return;

    // Format: summary \0 breakdown_lines \0 notes
    const sep1 = std.mem.indexOfScalar(u8, drained, 0) orelse drained.len;
    const summary_text = drained[0..sep1];

    var items_list: [64][]const u8 = undefined;
    var item_count: usize = 0;
    var notes_text: ?[]const u8 = null;

    if (sep1 + 1 < drained.len) {
        const rest = drained[sep1 + 1 ..];
        const sep2 = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
        const breakdown = rest[0..sep2];

        // Parse breakdown lines
        var line_iter = std.mem.splitScalar(u8, breakdown, '\n');
        while (line_iter.next()) |line| {
            if (line.len > 0 and item_count < items_list.len) {
                items_list[item_count] = line;
                item_count += 1;
            }
        }

        if (sep2 + 1 < rest.len) {
            const n = rest[sep2 + 1 ..];
            if (n.len > 0) notes_text = n;
        }
    }

    explain.receiveResponse(summary_text, items_list[0..item_count], notes_text) catch return;
    renderExplainResultCard(ctx);
}

fn renderExplainResultCard(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    const explain = &(ai.g_ai_explain orelse return);
    const style = ai.contentStyleFromTheme(ctx);
    const result = overlay_ai_explain.layoutExplainResultCard(mgr.allocator, explain, 52, style) catch return;
    var bar = attyx.overlay_action.ActionBar{};
    bar.add(.copy, "Copy");
    bar.add(.dismiss, "Close");
    ai.showAiOverlayCard(ctx, result.cells, result.width, result.height, bar);
}

pub fn handleExplainCopyAction(_: *PtyThreadCtx) void {
    const explain = &(ai.g_ai_explain orelse return);
    const cmd = explain.target_command orelse return;
    c.attyx_clipboard_copy(cmd.ptr, @intCast(cmd.len));
}
