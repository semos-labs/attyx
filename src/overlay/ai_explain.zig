const std = @import("std");
const content_mod = @import("content.zig");
const action_mod = @import("action.zig");
const layout = @import("layout.zig");

const CardResult = layout.CardResult;

// ---------------------------------------------------------------------------
// Explain state machine
// ---------------------------------------------------------------------------

pub const ExplainState = enum {
    closed,
    streaming,
    result_ready,
};

pub const ExplainContext = struct {
    state: ExplainState = .closed,
    target_command: ?[]u8 = null,
    summary: ?[]u8 = null,
    breakdown_items: ?[][]u8 = null,
    notes: ?[]u8 = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ExplainContext {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ExplainContext) void {
        if (self.target_command) |t| self.allocator.free(t);
        self.target_command = null;
        self.freeResponse();
        self.state = .closed;
    }

    fn freeResponse(self: *ExplainContext) void {
        if (self.summary) |s| self.allocator.free(s);
        self.summary = null;
        if (self.breakdown_items) |items| {
            for (items) |item| self.allocator.free(item);
            self.allocator.free(items);
        }
        self.breakdown_items = null;
        if (self.notes) |n| self.allocator.free(n);
        self.notes = null;
    }

    pub fn open(self: *ExplainContext, command: []const u8) !void {
        if (self.target_command) |t| self.allocator.free(t);
        self.freeResponse();
        self.target_command = try self.allocator.dupe(u8, command);
        self.state = .streaming;
    }

    pub fn receiveResponse(
        self: *ExplainContext,
        summary_text: []const u8,
        items: []const []const u8,
        notes_text: ?[]const u8,
    ) !void {
        self.freeResponse();
        self.summary = try self.allocator.dupe(u8, summary_text);
        const duped = try self.allocator.alloc([]u8, items.len);
        errdefer self.allocator.free(duped);
        for (items, 0..) |item, i| {
            duped[i] = try self.allocator.dupe(u8, item);
        }
        self.breakdown_items = duped;
        if (notes_text) |n| {
            self.notes = try self.allocator.dupe(u8, n);
        }
        self.state = .result_ready;
    }

    pub fn close(self: *ExplainContext) void {
        self.deinit();
    }
};

// ---------------------------------------------------------------------------
// Layout: Explain result card
// ---------------------------------------------------------------------------

pub fn layoutExplainResultCard(
    allocator: std.mem.Allocator,
    explain: *const ExplainContext,
    max_width: u16,
) !CardResult {
    var blocks_buf: [4]content_mod.ContentBlock = undefined;
    var block_count: usize = 0;

    // Target command as code block
    if (explain.target_command) |cmd| {
        blocks_buf[block_count] = .{ .tag = .code_block, .text = cmd };
        block_count += 1;
    }

    // Summary paragraph
    if (explain.summary) |s| {
        blocks_buf[block_count] = .{ .tag = .paragraph, .text = s };
        block_count += 1;
    }

    // Breakdown as bullet list
    if (explain.breakdown_items) |items| {
        blocks_buf[block_count] = .{ .tag = .bullet_list, .text = "", .items = items };
        block_count += 1;
    }

    // Notes paragraph
    if (explain.notes) |n| {
        blocks_buf[block_count] = .{ .tag = .paragraph, .text = n };
        block_count += 1;
    }

    var bar = action_mod.ActionBar{};
    bar.add(.copy, "Copy");
    bar.add(.dismiss, "Close");

    return content_mod.layoutStructuredCard(
        allocator,
        "Explain Command",
        blocks_buf[0..block_count],
        max_width,
        .{},
        bar,
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ExplainContext: state transitions" {
    const allocator = std.testing.allocator;
    var ctx = ExplainContext.init(allocator);
    defer ctx.deinit();

    try std.testing.expectEqual(ExplainState.closed, ctx.state);

    try ctx.open("ls -la");
    try std.testing.expectEqual(ExplainState.streaming, ctx.state);
    try std.testing.expectEqualStrings("ls -la", ctx.target_command.?);

    const items = [_][]const u8{ "ls \u{2014} list directory", "-la \u{2014} long format, all files" };
    try ctx.receiveResponse("Lists files in detail", &items, "Commonly used for inspecting directories");
    try std.testing.expectEqual(ExplainState.result_ready, ctx.state);
    try std.testing.expectEqualStrings("Lists files in detail", ctx.summary.?);
    try std.testing.expectEqual(@as(usize, 2), ctx.breakdown_items.?.len);
    try std.testing.expectEqualStrings("Commonly used for inspecting directories", ctx.notes.?);

    ctx.close();
    try std.testing.expectEqual(ExplainState.closed, ctx.state);
    try std.testing.expect(ctx.target_command == null);
    try std.testing.expect(ctx.summary == null);
}

test "ExplainContext: receiveResponse with null notes" {
    const allocator = std.testing.allocator;
    var ctx = ExplainContext.init(allocator);
    defer ctx.deinit();

    try ctx.open("echo hello");

    const items = [_][]const u8{"echo \u{2014} print text"};
    try ctx.receiveResponse("Prints hello", &items, null);
    try std.testing.expectEqual(ExplainState.result_ready, ctx.state);
    try std.testing.expect(ctx.notes == null);
}

test "layoutExplainResultCard: produces card" {
    const allocator = std.testing.allocator;
    var ctx = ExplainContext.init(allocator);
    defer ctx.deinit();

    try ctx.open("pwd");
    const items = [_][]const u8{"pwd \u{2014} print working directory"};
    try ctx.receiveResponse("Shows current directory", &items, null);

    const result = try layoutExplainResultCard(allocator, &ctx, 60);
    defer allocator.free(result.cells);

    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height > 0);
}
