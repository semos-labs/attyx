const std = @import("std");
const content_mod = @import("content.zig");
const action_mod = @import("action.zig");
const layout = @import("layout.zig");
const ai_edit = @import("ai_edit.zig");
const ai_safety = @import("ai_safety.zig");

const CardResult = layout.CardResult;

// ---------------------------------------------------------------------------
// Generate state machine
// ---------------------------------------------------------------------------

pub const GenerateState = enum(u8) {
    closed,
    prompt_input,
    streaming,
    result_ready,
};

pub const GenerateContext = struct {
    state: GenerateState = .closed,
    prompt: ai_edit.PromptBuffer = .{},
    generated_command: ?[]u8 = null,
    notes: ?[]u8 = null,
    danger_confirmed: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GenerateContext {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *GenerateContext) void {
        if (self.generated_command) |cmd| self.allocator.free(cmd);
        self.generated_command = null;
        if (self.notes) |n| self.allocator.free(n);
        self.notes = null;
        self.state = .closed;
    }

    pub fn open(self: *GenerateContext) void {
        if (self.generated_command) |cmd| self.allocator.free(cmd);
        self.generated_command = null;
        if (self.notes) |n| self.allocator.free(n);
        self.notes = null;
        self.danger_confirmed = false;
        self.prompt.clear();
        self.state = .prompt_input;
    }

    pub fn submitPrompt(self: *GenerateContext) void {
        self.state = .streaming;
    }

    pub fn receiveResponse(self: *GenerateContext, command: []const u8, notes_text: ?[]const u8) !void {
        if (self.generated_command) |cmd| self.allocator.free(cmd);
        if (self.notes) |n| self.allocator.free(n);
        self.notes = null;
        self.danger_confirmed = false;
        self.generated_command = try self.allocator.dupe(u8, command);
        if (notes_text) |n| {
            if (n.len > 0) {
                self.notes = try self.allocator.dupe(u8, n);
            }
        }
        self.state = .result_ready;
    }

    pub fn close(self: *GenerateContext) void {
        self.deinit();
    }
};

// ---------------------------------------------------------------------------
// Layout: Generate prompt card
// ---------------------------------------------------------------------------

pub fn layoutGeneratePromptCard(
    allocator: std.mem.Allocator,
    gen: *const GenerateContext,
    max_width: u16,
    style: content_mod.ContentStyle,
) !CardResult {
    var blocks_buf: [3]content_mod.ContentBlock = undefined;
    var block_count: usize = 0;

    // Prompt input display
    const prompt_text = if (gen.prompt.len > 0) gen.prompt.text() else "Describe what you want to do...";
    blocks_buf[block_count] = .{ .tag = .paragraph, .text = prompt_text };
    block_count += 1;

    // Hint
    blocks_buf[block_count] = .{ .tag = .paragraph, .text = "Enter to submit \xc2\xb7 Esc to cancel" };
    block_count += 1;

    var bar = action_mod.ActionBar{};
    bar.add(.accept, "Submit");
    bar.add(.dismiss, "Cancel");

    return content_mod.layoutStructuredCard(
        allocator,
        "Generate Command",
        blocks_buf[0..block_count],
        max_width,
        style,
        bar,
    );
}

// ---------------------------------------------------------------------------
// Layout: Generate result card
// ---------------------------------------------------------------------------

pub fn layoutGenerateResultCard(
    allocator: std.mem.Allocator,
    gen: *const GenerateContext,
    max_width: u16,
    safety: ?ai_safety.SafetyResult,
    style: content_mod.ContentStyle,
) !CardResult {
    var blocks_buf: [4]content_mod.ContentBlock = undefined;
    var block_count: usize = 0;

    // Generated command as code block
    if (gen.generated_command) |cmd| {
        blocks_buf[block_count] = .{ .tag = .code_block, .text = cmd };
        block_count += 1;
    }

    // Notes paragraph
    if (gen.notes) |n| {
        blocks_buf[block_count] = .{ .tag = .paragraph, .text = n };
        block_count += 1;
    }

    // Safety section (skip for safe)
    if (safety) |s| {
        if (s.risk_level != .safe) {
            const warn_tag: content_mod.BlockTag = switch (s.risk_level) {
                .caution => .warning_caution,
                .danger => .warning_danger,
                .safe => unreachable,
            };
            blocks_buf[block_count] = .{ .tag = warn_tag, .text = s.badge(), .items = s.reasons[0..s.reason_count] };
            block_count += 1;
        }
    }

    var bar = action_mod.ActionBar{};
    bar.add(.insert, "Insert");
    bar.add(.copy, "Copy");
    bar.add(.dismiss, "Close");

    return content_mod.layoutStructuredCard(
        allocator,
        "Generate Command",
        blocks_buf[0..block_count],
        max_width,
        style,
        bar,
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "GenerateContext: state transitions" {
    const allocator = std.testing.allocator;
    var ctx = GenerateContext.init(allocator);
    defer ctx.deinit();

    try std.testing.expectEqual(GenerateState.closed, ctx.state);

    ctx.open();
    try std.testing.expectEqual(GenerateState.prompt_input, ctx.state);

    ctx.submitPrompt();
    try std.testing.expectEqual(GenerateState.streaming, ctx.state);

    try ctx.receiveResponse("docker ps -a", "Lists all containers");
    try std.testing.expectEqual(GenerateState.result_ready, ctx.state);
    try std.testing.expectEqualStrings("docker ps -a", ctx.generated_command.?);
    try std.testing.expectEqualStrings("Lists all containers", ctx.notes.?);

    ctx.close();
    try std.testing.expectEqual(GenerateState.closed, ctx.state);
    try std.testing.expect(ctx.generated_command == null);
    try std.testing.expect(ctx.notes == null);
}

test "GenerateContext: receiveResponse with null notes" {
    const allocator = std.testing.allocator;
    var ctx = GenerateContext.init(allocator);
    defer ctx.deinit();

    ctx.open();
    try ctx.receiveResponse("ls -la", null);
    try std.testing.expectEqual(GenerateState.result_ready, ctx.state);
    try std.testing.expectEqualStrings("ls -la", ctx.generated_command.?);
    try std.testing.expect(ctx.notes == null);
}

test "GenerateContext: open resets previous state" {
    const allocator = std.testing.allocator;
    var ctx = GenerateContext.init(allocator);
    defer ctx.deinit();

    ctx.open();
    try ctx.receiveResponse("first cmd", "first notes");
    try std.testing.expectEqual(GenerateState.result_ready, ctx.state);

    ctx.open();
    try std.testing.expectEqual(GenerateState.prompt_input, ctx.state);
    try std.testing.expect(ctx.generated_command == null);
    try std.testing.expect(ctx.notes == null);
}

test "layoutGeneratePromptCard: basic" {
    const allocator = std.testing.allocator;
    var ctx = GenerateContext.init(allocator);
    defer ctx.deinit();

    ctx.open();
    const result = try layoutGeneratePromptCard(allocator, &ctx, 48, .{});
    defer allocator.free(result.cells);

    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height > 0);
}

test "layoutGenerateResultCard: basic" {
    const allocator = std.testing.allocator;
    var ctx = GenerateContext.init(allocator);
    defer ctx.deinit();

    ctx.open();
    try ctx.receiveResponse("find . -name '*.zig'", "Finds all Zig files");
    const result = try layoutGenerateResultCard(allocator, &ctx, 48, null, .{});
    defer allocator.free(result.cells);

    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height > 0);
}

test "layoutGenerateResultCard: with danger safety" {
    const allocator = std.testing.allocator;
    var ctx = GenerateContext.init(allocator);
    defer ctx.deinit();

    ctx.open();
    try ctx.receiveResponse("rm -rf /", null);
    const safety = ai_safety.analyzeCommand("rm -rf /");
    try std.testing.expectEqual(ai_safety.RiskLevel.danger, safety.risk_level);
    const result = try layoutGenerateResultCard(allocator, &ctx, 48, safety, .{});
    defer allocator.free(result.cells);

    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height > 0);
}
