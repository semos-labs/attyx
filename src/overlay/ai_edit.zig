const std = @import("std");
const diff_mod = @import("diff.zig");
const overlay = @import("overlay.zig");
const layout = @import("layout.zig");
const action_mod = @import("action.zig");
const content_mod = @import("content.zig");
const ai_safety = @import("ai_safety.zig");
const OverlayCell = overlay.OverlayCell;
const OverlayStyle = overlay.OverlayStyle;
const Rgb = overlay.Rgb;
const CardResult = layout.CardResult;

// ---------------------------------------------------------------------------
// Edit state machine
// ---------------------------------------------------------------------------

pub const EditState = enum(u8) { closed, prompt_input, streaming, proposal_ready };
pub const ViewMode = enum(u8) { diff, final_text };
pub const max_selection_bytes: usize = 65536; // 64KB cap

pub const PromptBuffer = struct {
    buf: [512]u8 = undefined,
    len: u16 = 0,
    cursor: u16 = 0,

    pub fn insertChar(self: *PromptBuffer, codepoint: u21) void {
        if (codepoint < 0x20) return;
        var enc_buf: [4]u8 = undefined;
        const enc_len = std.unicode.utf8Encode(codepoint, &enc_buf) catch return;
        if (self.len + enc_len > 512) return;
        const pos: usize = self.cursor;
        const qlen: usize = self.len;
        if (pos < qlen) {
            std.mem.copyBackwards(u8, self.buf[pos + enc_len .. qlen + enc_len], self.buf[pos..qlen]);
        }
        @memcpy(self.buf[pos .. pos + enc_len], enc_buf[0..enc_len]);
        self.len += @intCast(enc_len);
        self.cursor += @intCast(enc_len);
    }

    pub fn deleteBack(self: *PromptBuffer) void {
        if (self.cursor == 0) return;
        const prev = prevCharBoundary(self.buf[0..self.len], self.cursor);
        const del_len = self.cursor - prev;
        const qlen: usize = self.len;
        std.mem.copyForwards(u8, self.buf[prev .. qlen - del_len], self.buf[self.cursor..qlen]);
        self.len -= del_len;
        self.cursor = prev;
    }

    pub fn deleteFwd(self: *PromptBuffer) void {
        if (self.cursor >= self.len) return;
        const nxt = nextCharBoundary(self.buf[0..self.len], self.cursor);
        const del_len = nxt - self.cursor;
        const qlen: usize = self.len;
        std.mem.copyForwards(u8, self.buf[self.cursor .. qlen - del_len], self.buf[nxt..qlen]);
        self.len -= del_len;
    }

    pub fn cursorLeft(self: *PromptBuffer) void {
        if (self.cursor == 0) return;
        self.cursor = prevCharBoundary(self.buf[0..self.len], self.cursor);
    }

    pub fn cursorRight(self: *PromptBuffer) void {
        if (self.cursor >= self.len) return;
        self.cursor = nextCharBoundary(self.buf[0..self.len], self.cursor);
    }

    pub fn cursorHome(self: *PromptBuffer) void {
        self.cursor = 0;
    }

    pub fn cursorEnd(self: *PromptBuffer) void {
        self.cursor = self.len;
    }

    pub fn text(self: *const PromptBuffer) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn clear(self: *PromptBuffer) void {
        self.len = 0;
        self.cursor = 0;
    }
};

fn prevCharBoundary(buf: []const u8, pos: u16) u16 {
    var p = pos;
    if (p == 0) return 0;
    p -= 1;
    while (p > 0 and (buf[p] & 0xC0) == 0x80) p -= 1;
    return p;
}

fn nextCharBoundary(buf: []const u8, pos: u16) u16 {
    var p = pos;
    if (p >= buf.len) return @intCast(buf.len);
    p += 1;
    while (p < buf.len and (buf[p] & 0xC0) == 0x80) p += 1;
    return p;
}

// ---------------------------------------------------------------------------
// EditContext
// ---------------------------------------------------------------------------

pub const EditContext = struct {
    state: EditState = .closed,
    prompt: PromptBuffer = .{},
    original_text: ?[]u8 = null,
    replacement_text: ?[]u8 = null,
    explanation: ?[]u8 = null,
    diff_lines: ?[]diff_mod.DiffLine = null,
    view_mode: ViewMode = .diff,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) EditContext {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *EditContext) void {
        self.freeProposal();
        if (self.original_text) |t| self.allocator.free(t);
        self.original_text = null;
        self.state = .closed;
    }

    fn freeProposal(self: *EditContext) void {
        if (self.diff_lines) |dl| diff_mod.freeDiff(self.allocator, dl);
        self.diff_lines = null;
        if (self.replacement_text) |t| self.allocator.free(t);
        self.replacement_text = null;
        if (self.explanation) |e| self.allocator.free(e);
        self.explanation = null;
    }

    pub fn open(self: *EditContext, selection_text: []const u8) !void {
        if (selection_text.len > max_selection_bytes) return error.SelectionTooLarge;
        self.freeProposal();
        if (self.original_text) |t| self.allocator.free(t);
        self.original_text = try self.allocator.dupe(u8, selection_text);
        self.state = .prompt_input;
        self.view_mode = .diff;
    }

    pub fn submitPrompt(self: *EditContext) void {
        self.state = .streaming;
    }

    pub fn receiveResponse(self: *EditContext, replacement: []const u8, expl: []const u8) !void {
        self.freeProposal();
        self.replacement_text = try self.allocator.dupe(u8, replacement);
        if (expl.len > 0) {
            self.explanation = try self.allocator.dupe(u8, expl);
        }
        if (self.original_text) |orig| {
            self.diff_lines = diff_mod.computeDiff(self.allocator, orig, replacement) catch null;
        }
        self.state = .proposal_ready;
    }

    pub fn reject(self: *EditContext) void {
        self.freeProposal();
        self.state = .prompt_input;
    }

    pub fn close(self: *EditContext) void {
        self.deinit();
    }

    pub fn toggleView(self: *EditContext) void {
        self.view_mode = switch (self.view_mode) {
            .diff => .final_text,
            .final_text => .diff,
        };
    }
};

// ---------------------------------------------------------------------------
// RewriteContext — state machine for command rewrite mode
// ---------------------------------------------------------------------------

pub const RewriteState = enum(u8) { closed, prompt_input, streaming, result_ready };

pub const RewriteContext = struct {
    state: RewriteState = .closed,
    prompt: PromptBuffer = .{},
    target_command: ?[]u8 = null,
    rewritten_command: ?[]u8 = null,
    danger_confirmed: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RewriteContext {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RewriteContext) void {
        if (self.target_command) |t| self.allocator.free(t);
        self.target_command = null;
        if (self.rewritten_command) |r| self.allocator.free(r);
        self.rewritten_command = null;
        self.state = .closed;
    }

    pub fn open(self: *RewriteContext, command: []const u8) !void {
        if (self.target_command) |t| self.allocator.free(t);
        if (self.rewritten_command) |r| self.allocator.free(r);
        self.rewritten_command = null;
        self.danger_confirmed = false;
        self.target_command = try self.allocator.dupe(u8, command);
        self.prompt.clear();
        self.state = .prompt_input;
    }

    pub fn submitPrompt(self: *RewriteContext) void {
        self.state = .streaming;
    }

    pub fn receiveResponse(self: *RewriteContext, text: []const u8) !void {
        if (self.rewritten_command) |r| self.allocator.free(r);
        self.danger_confirmed = false;
        self.rewritten_command = try self.allocator.dupe(u8, text);
        self.state = .result_ready;
    }

    pub fn close(self: *RewriteContext) void {
        self.deinit();
    }
};

// ---------------------------------------------------------------------------
// Layout: Rewrite prompt card
// ---------------------------------------------------------------------------

pub fn layoutRewritePromptCard(
    allocator: std.mem.Allocator,
    rewrite: *const RewriteContext,
    max_width: u16,
    style: content_mod.ContentStyle,
) !CardResult {
    var blocks_buf: [4]content_mod.ContentBlock = undefined;
    var block_count: usize = 0;

    // Show target command
    if (rewrite.target_command) |cmd| {
        blocks_buf[block_count] = .{ .tag = .code_block, .text = cmd };
        block_count += 1;
    }

    // Prompt input display
    const prompt_text = if (rewrite.prompt.len > 0) rewrite.prompt.text() else "Type rewrite instructions...";
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
        "Rewrite Command",
        blocks_buf[0..block_count],
        max_width,
        style,
        bar,
    );
}

// ---------------------------------------------------------------------------
// Layout: Rewrite result card
// ---------------------------------------------------------------------------

pub fn layoutRewriteResultCard(
    allocator: std.mem.Allocator,
    rewrite: *const RewriteContext,
    max_width: u16,
    safety: ?ai_safety.SafetyResult,
    style: content_mod.ContentStyle,
) !CardResult {
    var blocks_buf: [4]content_mod.ContentBlock = undefined;
    var block_count: usize = 0;

    // Original command
    if (rewrite.target_command) |cmd| {
        blocks_buf[block_count] = .{ .tag = .code_block, .text = cmd };
        block_count += 1;
    }

    // Rewritten command
    if (rewrite.rewritten_command) |rw| {
        blocks_buf[block_count] = .{ .tag = .code_block, .text = rw };
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
    bar.add(.custom_0, "Replace");
    bar.add(.copy, "Copy");
    bar.add(.dismiss, "Close");

    return content_mod.layoutStructuredCard(
        allocator,
        "Rewrite Command",
        blocks_buf[0..block_count],
        max_width,
        style,
        bar,
    );
}

// ---------------------------------------------------------------------------
// Layout: Prompt card
// ---------------------------------------------------------------------------

pub fn layoutPromptCard(
    allocator: std.mem.Allocator,
    edit: *const EditContext,
    max_width: u16,
    style: content_mod.ContentStyle,
) !CardResult {
    // Build blocks for the card
    var blocks_buf: [4]content_mod.ContentBlock = undefined;
    var block_count: usize = 0;

    // Selection preview (first 3 lines, truncated)
    if (edit.original_text) |orig| {
        var preview_end: usize = 0;
        var line_count: usize = 0;
        for (orig, 0..) |ch, i| {
            if (ch == '\n') {
                line_count += 1;
                if (line_count >= 3) {
                    preview_end = i;
                    break;
                }
            }
            preview_end = i + 1;
        }
        const preview = orig[0..@min(preview_end, 200)];
        blocks_buf[block_count] = .{ .tag = .code_block, .text = preview };
        block_count += 1;
    }

    // Prompt input display
    const prompt_text = if (edit.prompt.len > 0) edit.prompt.text() else "Type your edit instruction...";
    blocks_buf[block_count] = .{ .tag = .paragraph, .text = prompt_text };
    block_count += 1;

    // Hint
    blocks_buf[block_count] = .{ .tag = .paragraph, .text = "Tip: be specific (tone, style, constraints)." };
    block_count += 1;

    // Action bar
    var bar = action_mod.ActionBar{};
    bar.add(.accept, "Submit");
    bar.add(.dismiss, "Cancel");

    return content_mod.layoutStructuredCard(
        allocator,
        "Edit Selection",
        blocks_buf[0..block_count],
        max_width,
        style,
        bar,
    );
}

// ---------------------------------------------------------------------------
// Layout: Proposal card
// ---------------------------------------------------------------------------

pub fn layoutProposalCard(
    allocator: std.mem.Allocator,
    edit: *const EditContext,
    max_width: u16,
    style: content_mod.ContentStyle,
) !CardResult {
    var blocks_buf: [64]content_mod.ContentBlock = undefined;
    var block_count: usize = 0;

    // View toggle indicator
    const toggle_text = switch (edit.view_mode) {
        .diff => "[Diff] Final",
        .final_text => "Diff [Final]",
    };
    blocks_buf[block_count] = .{ .tag = .paragraph, .text = toggle_text };
    block_count += 1;

    // Content based on view mode
    switch (edit.view_mode) {
        .diff => {
            if (edit.diff_lines) |dlines| {
                for (dlines) |dl| {
                    if (block_count >= blocks_buf.len) break;
                    blocks_buf[block_count] = .{
                        .tag = switch (dl.tag) {
                            .add => .diff_add,
                            .remove => .diff_remove,
                            .context => .diff_context,
                        },
                        .text = dl.text,
                    };
                    block_count += 1;
                }
            } else {
                blocks_buf[block_count] = .{ .tag = .paragraph, .text = "(no diff available)" };
                block_count += 1;
            }
        },
        .final_text => {
            if (edit.replacement_text) |repl| {
                blocks_buf[block_count] = .{ .tag = .code_block, .text = repl };
                block_count += 1;
            }
        },
    }

    // Explanation
    if (edit.explanation) |expl| {
        if (block_count < blocks_buf.len) {
            blocks_buf[block_count] = .{ .tag = .paragraph, .text = expl };
            block_count += 1;
        }
    }

    // Action bar
    var bar = action_mod.ActionBar{};
    bar.add(.accept, "Accept");
    bar.add(.reject, "Reject");
    bar.add(.copy, "Copy");
    bar.add(.insert, "Insert");

    return content_mod.layoutStructuredCard(
        allocator,
        "Edit Proposal",
        blocks_buf[0..block_count],
        max_width,
        style,
        bar,
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "EditContext: state transitions, reject, close" {
    const alloc = std.testing.allocator;
    var edit = EditContext.init(alloc);
    try std.testing.expectEqual(EditState.closed, edit.state);
    try edit.open("hello world");
    try std.testing.expectEqual(EditState.prompt_input, edit.state);
    try std.testing.expectEqualStrings("hello world", edit.original_text.?);
    edit.submitPrompt();
    try std.testing.expectEqual(EditState.streaming, edit.state);
    try edit.receiveResponse("HELLO WORLD", "Made uppercase");
    try std.testing.expectEqual(EditState.proposal_ready, edit.state);
    try std.testing.expectEqualStrings("HELLO WORLD", edit.replacement_text.?);
    // Reject returns to prompt_input
    edit.reject();
    try std.testing.expectEqual(EditState.prompt_input, edit.state);
    try std.testing.expectEqual(@as(?[]u8, null), edit.replacement_text);
    // Close frees all
    edit.close();
    try std.testing.expectEqual(EditState.closed, edit.state);
    try std.testing.expectEqual(@as(?[]u8, null), edit.original_text);
}

test "EditContext: selection cap enforcement" {
    const alloc = std.testing.allocator;
    var edit = EditContext.init(alloc);
    defer edit.deinit();
    var big: [max_selection_bytes + 1]u8 = undefined;
    @memset(&big, 'X');
    try std.testing.expectError(error.SelectionTooLarge, edit.open(&big));
    try std.testing.expectEqual(EditState.closed, edit.state);
}

test "PromptBuffer: insert and cursor movement" {
    var pb = PromptBuffer{};
    pb.insertChar('h');
    pb.insertChar('i');
    try std.testing.expectEqualStrings("hi", pb.text());
    try std.testing.expectEqual(@as(u16, 2), pb.cursor);

    pb.cursorLeft();
    try std.testing.expectEqual(@as(u16, 1), pb.cursor);

    pb.cursorHome();
    try std.testing.expectEqual(@as(u16, 0), pb.cursor);

    pb.cursorEnd();
    try std.testing.expectEqual(@as(u16, 2), pb.cursor);
}

test "PromptBuffer: deleteBack and deleteFwd" {
    var pb = PromptBuffer{};
    pb.insertChar('a');
    pb.insertChar('b');
    pb.insertChar('c');
    try std.testing.expectEqualStrings("abc", pb.text());

    pb.deleteBack();
    try std.testing.expectEqualStrings("ab", pb.text());

    pb.cursorHome();
    pb.deleteFwd();
    try std.testing.expectEqualStrings("b", pb.text());
}

test "PromptBuffer: clear" {
    var pb = PromptBuffer{};
    pb.insertChar('x');
    pb.clear();
    try std.testing.expectEqual(@as(u16, 0), pb.len);
    try std.testing.expectEqual(@as(u16, 0), pb.cursor);
}

test "EditContext: toggleView" {
    const alloc = std.testing.allocator;
    var edit = EditContext.init(alloc);
    defer edit.deinit();

    try std.testing.expectEqual(ViewMode.diff, edit.view_mode);
    edit.toggleView();
    try std.testing.expectEqual(ViewMode.final_text, edit.view_mode);
    edit.toggleView();
    try std.testing.expectEqual(ViewMode.diff, edit.view_mode);
}

test "layoutPromptCard: basic" {
    const alloc = std.testing.allocator;
    var edit = EditContext.init(alloc);
    defer edit.deinit();

    try edit.open("line1\nline2");
    const result = try layoutPromptCard(alloc, &edit, 48, .{});
    defer alloc.free(result.cells);

    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height > 0);
}

test "layoutProposalCard: diff view" {
    const alloc = std.testing.allocator;
    var edit = EditContext.init(alloc);
    defer edit.deinit();

    try edit.open("old line");
    try edit.receiveResponse("new line", "Changed content");
    const result = try layoutProposalCard(alloc, &edit, 48, .{});
    defer alloc.free(result.cells);

    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height > 0);
}

test "RewriteContext: state transitions and close" {
    const alloc = std.testing.allocator;
    var rw = RewriteContext.init(alloc);
    try std.testing.expectEqual(RewriteState.closed, rw.state);
    try rw.open("ls -la");
    try std.testing.expectEqual(RewriteState.prompt_input, rw.state);
    try std.testing.expectEqualStrings("ls -la", rw.target_command.?);
    rw.submitPrompt();
    try std.testing.expectEqual(RewriteState.streaming, rw.state);
    try rw.receiveResponse("ls -la --color=auto");
    try std.testing.expectEqual(RewriteState.result_ready, rw.state);
    try std.testing.expectEqualStrings("ls -la --color=auto", rw.rewritten_command.?);
    rw.close();
    try std.testing.expectEqual(RewriteState.closed, rw.state);
    try std.testing.expectEqual(@as(?[]u8, null), rw.target_command);
}

test "layoutRewritePromptCard and layoutRewriteResultCard" {
    const alloc = std.testing.allocator;
    var rw = RewriteContext.init(alloc);
    defer rw.deinit();
    try rw.open("git status");
    const p = try layoutRewritePromptCard(alloc, &rw, 48, .{});
    defer alloc.free(p.cells);
    try std.testing.expect(p.width > 0 and p.height > 0);
    try rw.receiveResponse("git status --short");
    const r = try layoutRewriteResultCard(alloc, &rw, 48, null, .{});
    defer alloc.free(r.cells);
    try std.testing.expect(r.width > 0 and r.height > 0);
}

test "layoutRewriteResultCard: with caution safety" {
    const alloc = std.testing.allocator;
    var rw = RewriteContext.init(alloc);
    defer rw.deinit();
    try rw.open("git status");
    try rw.receiveResponse("git reset --hard HEAD");
    const safety = ai_safety.analyzeCommand("git reset --hard HEAD");
    try std.testing.expectEqual(ai_safety.RiskLevel.caution, safety.risk_level);
    const r = try layoutRewriteResultCard(alloc, &rw, 48, safety, .{});
    defer alloc.free(r.cells);
    try std.testing.expect(r.width > 0 and r.height > 0);
}
