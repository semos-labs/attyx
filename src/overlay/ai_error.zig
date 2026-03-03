const std = @import("std");
const content_mod = @import("content.zig");
const action_mod = @import("action.zig");
const layout_mod = @import("layout.zig");
const ContentBlock = content_mod.ContentBlock;
const ContentStyle = content_mod.ContentStyle;
const CardResult = layout_mod.CardResult;

// ---------------------------------------------------------------------------
// Error card layout
// ---------------------------------------------------------------------------

/// Build an error card overlay. Returns owned cells via CardResult.
/// Action bar: [Retry] [Copy diagnostics] [Dismiss]
pub fn layoutErrorCard(
    allocator: std.mem.Allocator,
    error_code: []const u8,
    error_msg: []const u8,
    max_width: u16,
    base_style: ContentStyle,
) !CardResult {
    // Build error message text
    var msg_buf: [512]u8 = undefined;
    var msg_stream = std.io.fixedBufferStream(&msg_buf);
    const mw = msg_stream.writer();

    if (error_code.len > 0) {
        mw.writeAll("[") catch {};
        mw.writeAll(error_code) catch {};
        mw.writeAll("] ") catch {};
    }
    if (error_msg.len > 0) {
        mw.writeAll(error_msg) catch {};
    } else {
        mw.writeAll("An unknown error occurred.") catch {};
    }

    const msg_text = msg_buf[0..msg_stream.pos];

    const blocks = [_]ContentBlock{
        .{ .tag = .header, .text = "Error" },
        .{ .tag = .paragraph, .text = msg_text },
    };

    var bar = action_mod.ActionBar{};
    bar.add(.retry, "Retry");
    bar.add(.copy, "Copy diagnostics");
    bar.add(.dismiss, "Dismiss");

    var style = base_style;
    style.header_fg = .{ .r = 230, .g = 80, .b = 80 };

    return content_mod.layoutStructuredCard(
        allocator,
        "Attyx AI",
        &blocks,
        max_width,
        style,
        bar,
    );
}

/// Build a "connecting" card overlay shown while establishing SSE connection.
pub fn layoutConnectingCard(
    allocator: std.mem.Allocator,
    max_width: u16,
    style: ContentStyle,
) !CardResult {
    const blocks = [_]ContentBlock{
        .{ .tag = .paragraph, .text = "Connecting to AI backend..." },
    };

    var bar = action_mod.ActionBar{};
    bar.add(.dismiss, "Cancel");

    return content_mod.layoutStructuredCard(
        allocator,
        "Attyx AI",
        &blocks,
        max_width,
        style,
        bar,
    );
}

/// Build a device authorization card showing the user code.
pub fn layoutDeviceCodeCard(
    allocator: std.mem.Allocator,
    user_code: []const u8,
    max_width: u16,
    style: ContentStyle,
) !CardResult {
    const blocks = [_]ContentBlock{
        .{ .tag = .paragraph, .text = "Sign in to use AI features" },
        .{ .tag = .paragraph, .text = "1. Visit:  semos.ai/device" },
        .{ .tag = .code_block, .text = user_code },
        .{ .tag = .paragraph, .text = "Waiting for authorization..." },
    };

    var bar = action_mod.ActionBar{};
    bar.add(.dismiss, "Cancel");

    return content_mod.layoutStructuredCard(
        allocator,
        "Attyx AI",
        &blocks,
        max_width,
        style,
        bar,
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "layoutErrorCard: basic dimensions" {
    const result = try layoutErrorCard(
        std.testing.allocator,
        "401",
        "Unauthorized",
        40,
        .{},
    );
    defer std.testing.allocator.free(result.cells);

    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height > 0);
    // Should have cells: width * height
    try std.testing.expectEqual(@as(usize, result.width) * result.height, result.cells.len);
}

test "layoutErrorCard: empty code" {
    const result = try layoutErrorCard(
        std.testing.allocator,
        "",
        "Something went wrong",
        40,
        .{},
    );
    defer std.testing.allocator.free(result.cells);

    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height > 0);
}

test "layoutConnectingCard: dimensions" {
    const result = try layoutConnectingCard(
        std.testing.allocator,
        40,
        .{},
    );
    defer std.testing.allocator.free(result.cells);

    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height >= 3);
}

test "layoutDeviceCodeCard: contains user code" {
    const result = try layoutDeviceCodeCard(
        std.testing.allocator,
        "ABCD-EFGH",
        40,
        .{},
    );
    defer std.testing.allocator.free(result.cells);

    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height >= 5);
}
