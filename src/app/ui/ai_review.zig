const std = @import("std");
const attyx = @import("attyx");
const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const c = terminal.c;
const ai = @import("ai.zig");

const content_mod = attyx.overlay_content;
const action_mod = attyx.overlay_action;
const PayloadReport = attyx.security_payload.PayloadReport;

// ---------------------------------------------------------------------------
// Review card — shown before sending output-aware AI requests
// ---------------------------------------------------------------------------

/// Show a review card before sending an output-aware AI request.
/// The card displays redaction findings and truncation status.
pub fn showReviewCard(ctx: *PtyThreadCtx, report: *const PayloadReport) void {
    const mgr = ctx.overlay_mgr orelse return;

    var summary_buf: [256]u8 = undefined;
    var summary_stream = std.io.fixedBufferStream(&summary_buf);
    const sw = summary_stream.writer();

    sw.print("Redacted: {d} finding(s)", .{report.finding_count}) catch {};
    if (report.truncated) {
        sw.writeAll(" · Truncated: yes") catch {};
    }
    if (report.bytes_before > 0) {
        sw.print(" · {d}B -> {d}B", .{ report.bytes_before, report.bytes_after }) catch {};
    }

    const summary_text = summary_buf[0..summary_stream.pos];

    const blocks = [_]content_mod.ContentBlock{
        .{ .tag = .header, .text = "Review Before Sending" },
        .{ .tag = .paragraph, .text = "Sensitive content was detected and redacted." },
        .{ .tag = .code_block, .text = summary_text },
    };

    var bar = action_mod.ActionBar{};
    bar.add(.accept, "Send");
    bar.add(.copy, "Copy redacted");
    bar.add(.dismiss, "Cancel");

    var style = ai.contentStyleFromTheme(ctx);
    style.header_fg = .{ .r = 220, .g = 180, .b = 50 };

    const result = content_mod.layoutStructuredCard(
        mgr.allocator,
        "Attyx AI",
        &blocks,
        48,
        style,
        bar,
    ) catch return;

    ai.showAiOverlayCard(ctx, result.cells, result.width, result.height, bar);
}

/// Confirm and send a pending review request.
pub fn confirmReviewSend(ctx: *PtyThreadCtx) void {
    ai.g_ai_review_pending = false;
    ai.loadTokensAndStream(ctx);
}

/// Copy the redacted payload body to clipboard.
pub fn copyRedactedPayload(_: *PtyThreadCtx) void {
    if (ai.g_ai_prepared_request) |*req| {
        const body = req.bodySlice();
        c.attyx_clipboard_copy(body.ptr, @intCast(body.len));
    }
}
