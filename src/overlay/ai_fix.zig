const std = @import("std");
const content_mod = @import("content.zig");
const action_mod = @import("action.zig");
const safety_mod = @import("ai_safety.zig");
const layout = @import("layout.zig");

const CardResult = layout.CardResult;
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Fix state machine
// ---------------------------------------------------------------------------

pub const FixState = enum(u8) {
    closed,
    streaming,
    result_ready,
};

pub const FixContext = struct {
    state: FixState = .closed,
    original_command: ?[]u8 = null,
    rewritten_command: ?[]u8 = null,
    reason: ?[]u8 = null,
    danger_confirmed: bool = false,
    allocator: Allocator,

    pub fn init(allocator: Allocator) FixContext {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FixContext) void {
        if (self.original_command) |c| self.allocator.free(c);
        self.original_command = null;
        self.freeResponse();
        self.state = .closed;
    }

    fn freeResponse(self: *FixContext) void {
        if (self.rewritten_command) |c| self.allocator.free(c);
        self.rewritten_command = null;
        if (self.reason) |r| self.allocator.free(r);
        self.reason = null;
        self.danger_confirmed = false;
    }

    pub fn open(self: *FixContext, command: []const u8) !void {
        if (self.original_command) |c| self.allocator.free(c);
        self.freeResponse();
        self.original_command = try self.allocator.dupe(u8, command);
        self.state = .streaming;
    }

    pub fn receiveResponse(
        self: *FixContext,
        rewritten: []const u8,
        reason_text: []const u8,
    ) !void {
        self.freeResponse();
        self.rewritten_command = try self.allocator.dupe(u8, rewritten);
        self.reason = try self.allocator.dupe(u8, reason_text);
        self.state = .result_ready;
    }

    pub fn close(self: *FixContext) void {
        self.deinit();
    }
};

// ---------------------------------------------------------------------------
// Layout: Fix result card
// ---------------------------------------------------------------------------

pub fn layoutFixResultCard(
    allocator: Allocator,
    fix: *const FixContext,
    max_width: u16,
    safety: safety_mod.SafetyResult,
    style: content_mod.ContentStyle,
) !CardResult {
    var blocks_buf: [5]content_mod.ContentBlock = undefined;
    var block_count: usize = 0;

    // Original command as code block
    if (fix.original_command) |cmd| {
        blocks_buf[block_count] = .{ .tag = .code_block, .text = cmd };
        block_count += 1;
    }

    // Reason paragraph
    if (fix.reason) |r| {
        blocks_buf[block_count] = .{ .tag = .paragraph, .text = r };
        block_count += 1;
    }

    // Proposed fix as code block
    if (fix.rewritten_command) |cmd| {
        blocks_buf[block_count] = .{ .tag = .code_block, .text = cmd };
        block_count += 1;
    }

    // Safety badge if not safe
    if (safety.risk_level != .safe and safety.reason_count > 0) {
        blocks_buf[block_count] = .{ .tag = .paragraph, .text = safety.reasons[0] };
        block_count += 1;
    }

    var bar = action_mod.ActionBar{};
    bar.add(.insert, "Replace");
    bar.add(.copy, "Copy");
    bar.add(.dismiss, "Close");

    return content_mod.layoutStructuredCard(
        allocator,
        "Fix Failed Command",
        blocks_buf[0..block_count],
        max_width,
        style,
        bar,
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "FixContext: state transitions" {
    const allocator = std.testing.allocator;
    var ctx = FixContext.init(allocator);
    defer ctx.deinit();

    try std.testing.expectEqual(FixState.closed, ctx.state);

    try ctx.open("gcc -o main main.c");
    try std.testing.expectEqual(FixState.streaming, ctx.state);
    try std.testing.expectEqualStrings("gcc -o main main.c", ctx.original_command.?);

    try ctx.receiveResponse("gcc -Wall -o main main.c", "Added -Wall to show all warnings");
    try std.testing.expectEqual(FixState.result_ready, ctx.state);
    try std.testing.expectEqualStrings("gcc -Wall -o main main.c", ctx.rewritten_command.?);
    try std.testing.expectEqualStrings("Added -Wall to show all warnings", ctx.reason.?);

    ctx.close();
    try std.testing.expectEqual(FixState.closed, ctx.state);
    try std.testing.expect(ctx.original_command == null);
    try std.testing.expect(ctx.rewritten_command == null);
    try std.testing.expect(ctx.reason == null);
}

test "FixContext: re-open clears previous" {
    const allocator = std.testing.allocator;
    var ctx = FixContext.init(allocator);
    defer ctx.deinit();

    try ctx.open("first");
    try ctx.receiveResponse("first-fix", "reason1");
    try ctx.open("second");

    try std.testing.expectEqual(FixState.streaming, ctx.state);
    try std.testing.expectEqualStrings("second", ctx.original_command.?);
    try std.testing.expect(ctx.rewritten_command == null);
}

test "layoutFixResultCard: produces card" {
    const allocator = std.testing.allocator;
    var ctx = FixContext.init(allocator);
    defer ctx.deinit();

    try ctx.open("npm test");
    try ctx.receiveResponse("npm run test", "Use 'run test' instead of 'test'");

    const safety = safety_mod.SafetyResult{};
    const result = try layoutFixResultCard(allocator, &ctx, 60, safety, .{});
    defer allocator.free(result.cells);

    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height > 0);
}
