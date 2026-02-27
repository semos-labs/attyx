const std = @import("std");
const content_mod = @import("content.zig");
const ContentBlock = content_mod.ContentBlock;
const BlockTag = content_mod.BlockTag;

// ---------------------------------------------------------------------------
// Incremental text accumulator → ContentBlock parser
// ---------------------------------------------------------------------------

const max_blocks = 32;
const max_block_texts = 32;

pub const AiContentAccumulator = struct {
    allocator: std.mem.Allocator,
    text_buf: std.ArrayList(u8),
    blocks: [max_blocks]ContentBlock = undefined,
    block_count: u8 = 0,
    // Owned text slices for blocks that need allocated copies
    block_texts: [max_block_texts][]u8 = undefined,
    block_text_count: u8 = 0,

    pub fn init(allocator: std.mem.Allocator) AiContentAccumulator {
        return .{
            .allocator = allocator,
            .text_buf = .{},
        };
    }

    pub fn deinit(self: *AiContentAccumulator) void {
        self.freeBlockTexts();
        self.text_buf.deinit(self.allocator);
    }

    /// Append a delta chunk to the accumulated text.
    pub fn appendDelta(self: *AiContentAccumulator, delta: []const u8) !void {
        try self.text_buf.appendSlice(self.allocator, delta);
    }

    /// Reparse the full accumulated text into ContentBlocks.
    /// Returns a slice of blocks valid until the next reparse or reset.
    pub fn reparse(self: *AiContentAccumulator) ![]const ContentBlock {
        self.freeBlockTexts();
        self.block_count = 0;
        self.block_text_count = 0;

        const text = self.text_buf.items;
        if (text.len == 0) return self.blocks[0..0];

        var pos: usize = 0;
        var in_code_block = false;
        var code_start: usize = 0;

        while (pos < text.len and self.block_count < max_blocks) {
            // Skip blank lines between blocks
            if (!in_code_block) {
                while (pos < text.len and text[pos] == '\n') pos += 1;
                if (pos >= text.len) break;
            }

            if (in_code_block) {
                // Look for closing fence
                if (isCodeFence(text, pos)) {
                    // End of code block
                    const code_end = pos;
                    // Skip the closing fence line
                    pos = skipLine(text, pos);

                    const code_text = text[code_start..code_end];
                    // Trim trailing newline
                    const trimmed = if (code_text.len > 0 and code_text[code_text.len - 1] == '\n')
                        code_text[0 .. code_text.len - 1]
                    else
                        code_text;
                    self.addBlock(.code_block, trimmed);
                    in_code_block = false;
                } else {
                    pos = skipLine(text, pos);
                }
                continue;
            }

            // Check for code fence opening
            if (isCodeFence(text, pos)) {
                pos = skipLine(text, pos); // skip the fence line itself
                code_start = pos;
                in_code_block = true;
                continue;
            }

            // Check for header (# or ##)
            if (isHeader(text, pos)) {
                const level_end = skipHashes(text, pos);
                // Skip space after #
                const header_start = if (level_end < text.len and text[level_end] == ' ') level_end + 1 else level_end;
                const line_end = findLineEnd(text, header_start);
                self.addBlock(.header, text[header_start..line_end]);
                pos = if (line_end < text.len) line_end + 1 else line_end;
                continue;
            }

            // Check for bullet
            if (isBulletLine(text, pos)) {
                // Collect consecutive bullet lines
                const bullet_start = pos;
                var bullet_end = pos;
                while (bullet_end < text.len and isBulletLine(text, bullet_end)) {
                    bullet_end = skipLine(text, bullet_end);
                }
                // For simplicity, store as a single paragraph-like block with bullet tag
                // We'll split into items at render time
                const bullet_text = text[bullet_start..bullet_end];
                const trimmed = if (bullet_text.len > 0 and bullet_text[bullet_text.len - 1] == '\n')
                    bullet_text[0 .. bullet_text.len - 1]
                else
                    bullet_text;
                self.addBulletBlock(trimmed);
                pos = bullet_end;
                continue;
            }

            // Regular paragraph: collect lines until blank line or special line
            const para_start = pos;
            while (pos < text.len) {
                if (text[pos] == '\n') {
                    const next = pos + 1;
                    if (next >= text.len or text[next] == '\n' or
                        isCodeFence(text, next) or isHeader(text, next) or
                        isBulletLine(text, next))
                    {
                        break;
                    }
                }
                pos += 1;
            }
            // Include current char if not newline
            const para_end = if (pos < text.len and text[pos] == '\n') pos else pos;
            if (para_end > para_start) {
                self.addBlock(.paragraph, text[para_start..para_end]);
            }
            if (pos < text.len and text[pos] == '\n') pos += 1;
        }

        // Handle unclosed code block: emit what we have so far
        if (in_code_block and code_start < text.len) {
            const code_text = text[code_start..];
            const trimmed = if (code_text.len > 0 and code_text[code_text.len - 1] == '\n')
                code_text[0 .. code_text.len - 1]
            else
                code_text;
            if (trimmed.len > 0) {
                self.addBlock(.code_block, trimmed);
            }
        }

        return self.blocks[0..self.block_count];
    }

    /// Get the full accumulated text.
    pub fn fullText(self: *const AiContentAccumulator) []const u8 {
        return self.text_buf.items;
    }

    /// Reset all state for a new streaming session.
    pub fn reset(self: *AiContentAccumulator) void {
        self.freeBlockTexts();
        self.text_buf.clearRetainingCapacity();
        self.block_count = 0;
        self.block_text_count = 0;
    }

    fn addBlock(self: *AiContentAccumulator, tag: BlockTag, text: []const u8) void {
        if (self.block_count >= max_blocks) return;
        self.blocks[self.block_count] = .{ .tag = tag, .text = text };
        self.block_count += 1;
    }

    fn addBulletBlock(self: *AiContentAccumulator, text: []const u8) void {
        if (self.block_count >= max_blocks) return;
        // Parse bullet items from text
        // Each line starting with "- " or "* " is an item
        var items: [16][]const u8 = undefined;
        var item_count: usize = 0;
        var pos: usize = 0;

        while (pos < text.len and item_count < 16) {
            // Skip bullet prefix
            if (pos < text.len and (text[pos] == '-' or text[pos] == '*')) {
                pos += 1;
                if (pos < text.len and text[pos] == ' ') pos += 1;
            }
            const item_start = pos;
            while (pos < text.len and text[pos] != '\n') pos += 1;
            if (pos > item_start) {
                items[item_count] = text[item_start..pos];
                item_count += 1;
            }
            if (pos < text.len) pos += 1; // skip newline
        }

        if (item_count == 0) return;

        // Allocate items slice
        if (self.block_text_count < max_block_texts) {
            // Store the items as a block. We can't easily store []const []const u8
            // without allocation, so we store as individual paragraph lines in a
            // bullet_list block. The items field points to stack data, but since
            // reparse is called each time and blocks are consumed before next reparse,
            // we can use a static buffer approach.
            // Actually — just store as paragraph with bullet tag. The layout engine
            // reads .items for bullet_list, so let's convert to paragraphs instead.
            for (items[0..item_count]) |item| {
                if (self.block_count >= max_blocks) break;
                self.blocks[self.block_count] = .{ .tag = .paragraph, .text = item };
                self.block_count += 1;
            }
        }
    }

    fn freeBlockTexts(self: *AiContentAccumulator) void {
        for (self.block_texts[0..self.block_text_count]) |t| {
            self.allocator.free(t);
        }
        self.block_text_count = 0;
    }
};

// ---------------------------------------------------------------------------
// Line-level helpers
// ---------------------------------------------------------------------------

fn isCodeFence(text: []const u8, pos: usize) bool {
    if (pos + 3 > text.len) return false;
    return (std.mem.eql(u8, text[pos..][0..3], "```") or
        std.mem.eql(u8, text[pos..][0..3], "~~~"));
}

fn isHeader(text: []const u8, pos: usize) bool {
    if (pos >= text.len) return false;
    if (text[pos] != '#') return false;
    var p = pos + 1;
    while (p < text.len and text[p] == '#') p += 1;
    return p < text.len and text[p] == ' ';
}

fn skipHashes(text: []const u8, pos: usize) usize {
    var p = pos;
    while (p < text.len and text[p] == '#') p += 1;
    return p;
}

fn isBulletLine(text: []const u8, pos: usize) bool {
    if (pos + 2 > text.len) return false;
    return (text[pos] == '-' or text[pos] == '*') and text[pos + 1] == ' ';
}

fn findLineEnd(text: []const u8, pos: usize) usize {
    var p = pos;
    while (p < text.len and text[p] != '\n') p += 1;
    return p;
}

fn skipLine(text: []const u8, pos: usize) usize {
    var p = pos;
    while (p < text.len and text[p] != '\n') p += 1;
    if (p < text.len) p += 1;
    return p;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "AiContentAccumulator: basic paragraph" {
    var acc = AiContentAccumulator.init(std.testing.allocator);
    defer acc.deinit();

    try acc.appendDelta("Hello world.");
    const blocks = try acc.reparse();

    try std.testing.expectEqual(@as(u8, 1), @as(u8, @intCast(blocks.len)));
    try std.testing.expectEqual(BlockTag.paragraph, blocks[0].tag);
    try std.testing.expectEqualStrings("Hello world.", blocks[0].text);
}

test "AiContentAccumulator: header and paragraph" {
    var acc = AiContentAccumulator.init(std.testing.allocator);
    defer acc.deinit();

    try acc.appendDelta("# Title\n\nSome text here.");
    const blocks = try acc.reparse();

    try std.testing.expectEqual(@as(u8, 2), @as(u8, @intCast(blocks.len)));
    try std.testing.expectEqual(BlockTag.header, blocks[0].tag);
    try std.testing.expectEqualStrings("Title", blocks[0].text);
    try std.testing.expectEqual(BlockTag.paragraph, blocks[1].tag);
    try std.testing.expectEqualStrings("Some text here.", blocks[1].text);
}

test "AiContentAccumulator: code block" {
    var acc = AiContentAccumulator.init(std.testing.allocator);
    defer acc.deinit();

    try acc.appendDelta("Before\n\n```\nfn foo() void {}\n```\n\nAfter");
    const blocks = try acc.reparse();

    try std.testing.expect(blocks.len >= 3);
    try std.testing.expectEqual(BlockTag.paragraph, blocks[0].tag);
    try std.testing.expectEqual(BlockTag.code_block, blocks[1].tag);
    try std.testing.expectEqualStrings("fn foo() void {}", blocks[1].text);
    try std.testing.expectEqual(BlockTag.paragraph, blocks[2].tag);
}

test "AiContentAccumulator: unclosed code block" {
    var acc = AiContentAccumulator.init(std.testing.allocator);
    defer acc.deinit();

    try acc.appendDelta("```\npartial code");
    const blocks = try acc.reparse();

    try std.testing.expect(blocks.len >= 1);
    // Should emit partial code block
    var found_code = false;
    for (blocks) |b| {
        if (b.tag == .code_block) {
            found_code = true;
            try std.testing.expectEqualStrings("partial code", b.text);
        }
    }
    try std.testing.expect(found_code);
}

test "AiContentAccumulator: incremental deltas" {
    var acc = AiContentAccumulator.init(std.testing.allocator);
    defer acc.deinit();

    try acc.appendDelta("# Ti");
    var blocks = try acc.reparse();
    try std.testing.expect(blocks.len >= 1);

    try acc.appendDelta("tle\n\nBody text.");
    blocks = try acc.reparse();
    try std.testing.expectEqual(@as(u8, 2), @as(u8, @intCast(blocks.len)));
    try std.testing.expectEqual(BlockTag.header, blocks[0].tag);
    try std.testing.expectEqualStrings("Title", blocks[0].text);
}

test "AiContentAccumulator: bullet list" {
    var acc = AiContentAccumulator.init(std.testing.allocator);
    defer acc.deinit();

    try acc.appendDelta("- First item\n- Second item\n- Third item");
    const blocks = try acc.reparse();

    // Bullets are expanded to individual paragraph blocks
    try std.testing.expect(blocks.len >= 3);
    try std.testing.expectEqualStrings("First item", blocks[0].text);
    try std.testing.expectEqualStrings("Second item", blocks[1].text);
    try std.testing.expectEqualStrings("Third item", blocks[2].text);
}

test "AiContentAccumulator: reset clears state" {
    var acc = AiContentAccumulator.init(std.testing.allocator);
    defer acc.deinit();

    try acc.appendDelta("Some text");
    _ = try acc.reparse();

    acc.reset();
    try std.testing.expectEqual(@as(usize, 0), acc.fullText().len);
    try std.testing.expectEqual(@as(u8, 0), acc.block_count);
}

test "AiContentAccumulator: fullText returns accumulated" {
    var acc = AiContentAccumulator.init(std.testing.allocator);
    defer acc.deinit();

    try acc.appendDelta("hello ");
    try acc.appendDelta("world");
    try std.testing.expectEqualStrings("hello world", acc.fullText());
}
