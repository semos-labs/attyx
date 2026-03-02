const std = @import("std");

// ---------------------------------------------------------------------------
// Line-level diff computation (O(n) prefix/suffix matching)
// ---------------------------------------------------------------------------

pub const DiffTag = enum { context, add, remove };

pub const DiffLine = struct {
    tag: DiffTag,
    text: []const u8,
};

pub const max_diff_lines: usize = 500;
const max_context_lines: usize = 3;

/// Split text into lines. Returns a slice of slices referencing the original text.
/// Caller owns the returned array.
fn splitLines(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    if (text.len == 0) return try allocator.alloc([]const u8, 0);

    var count: usize = 1;
    for (text) |ch| {
        if (ch == '\n') count += 1;
    }

    const lines = try allocator.alloc([]const u8, count);
    var idx: usize = 0;
    var start: usize = 0;
    for (text, 0..) |ch, i| {
        if (ch == '\n') {
            lines[idx] = text[start..i];
            idx += 1;
            start = i + 1;
        }
    }
    lines[idx] = text[start..];
    return lines;
}

/// Compute a line-level diff between original and replacement text.
///
/// Algorithm:
/// 1. Split both texts into lines
/// 2. Match common prefix lines
/// 3. Match common suffix lines
/// 4. Middle section: all original lines as .remove, all replacement lines as .add
/// 5. Include up to 3 context lines at boundaries
/// 6. If total lines > max_diff_lines: return simple remove-all + add-all
///
/// Caller must free the result with `freeDiff`.
pub fn computeDiff(allocator: std.mem.Allocator, original: []const u8, replacement: []const u8) ![]DiffLine {
    const orig_lines = try splitLines(allocator, original);
    defer allocator.free(orig_lines);
    const repl_lines = try splitLines(allocator, replacement);
    defer allocator.free(repl_lines);

    // If total lines would be too large, return simple remove-all + add-all
    if (orig_lines.len + repl_lines.len > max_diff_lines) {
        return simpleDiff(allocator, orig_lines, repl_lines);
    }

    // Match common prefix
    const min_len = @min(orig_lines.len, repl_lines.len);
    var prefix: usize = 0;
    while (prefix < min_len and std.mem.eql(u8, orig_lines[prefix], repl_lines[prefix])) {
        prefix += 1;
    }

    // If everything matches, return empty diff
    if (prefix == orig_lines.len and prefix == repl_lines.len) {
        return try allocator.alloc(DiffLine, 0);
    }

    // Match common suffix (from end, not overlapping prefix)
    var suffix: usize = 0;
    while (suffix < min_len - prefix and
        std.mem.eql(u8, orig_lines[orig_lines.len - 1 - suffix], repl_lines[repl_lines.len - 1 - suffix]))
    {
        suffix += 1;
    }

    // Calculate context bounds
    const ctx_before = @min(prefix, max_context_lines);
    const ctx_after = @min(suffix, max_context_lines);

    // Middle ranges
    const orig_mid_start = prefix;
    const orig_mid_end = orig_lines.len - suffix;
    const repl_mid_start = prefix;
    const repl_mid_end = repl_lines.len - suffix;

    const orig_mid_count = orig_mid_end - orig_mid_start;
    const repl_mid_count = repl_mid_end - repl_mid_start;

    // Total output lines
    const total = ctx_before + orig_mid_count + repl_mid_count + ctx_after;
    if (total == 0) return try allocator.alloc(DiffLine, 0);

    var result = try allocator.alloc(DiffLine, total);
    var out: usize = 0;

    // Context before
    for (0..ctx_before) |i| {
        result[out] = .{ .tag = .context, .text = orig_lines[prefix - ctx_before + i] };
        out += 1;
    }

    // Removed lines
    for (orig_mid_start..orig_mid_end) |i| {
        result[out] = .{ .tag = .remove, .text = orig_lines[i] };
        out += 1;
    }

    // Added lines
    for (repl_mid_start..repl_mid_end) |i| {
        result[out] = .{ .tag = .add, .text = repl_lines[i] };
        out += 1;
    }

    // Context after
    for (0..ctx_after) |i| {
        result[out] = .{ .tag = .context, .text = orig_lines[orig_mid_end + i] };
        out += 1;
    }

    return result[0..out];
}

fn simpleDiff(allocator: std.mem.Allocator, orig_lines: []const []const u8, repl_lines: []const []const u8) ![]DiffLine {
    const total = orig_lines.len + repl_lines.len;
    var result = try allocator.alloc(DiffLine, total);
    var out: usize = 0;
    for (orig_lines) |line| {
        result[out] = .{ .tag = .remove, .text = line };
        out += 1;
    }
    for (repl_lines) |line| {
        result[out] = .{ .tag = .add, .text = line };
        out += 1;
    }
    return result[0..out];
}

pub fn freeDiff(allocator: std.mem.Allocator, lines: []DiffLine) void {
    allocator.free(lines);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "computeDiff: identical texts" {
    const alloc = std.testing.allocator;
    const result = try computeDiff(alloc, "hello\nworld", "hello\nworld");
    defer freeDiff(alloc, result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "computeDiff: empty inputs" {
    const alloc = std.testing.allocator;
    const result = try computeDiff(alloc, "", "");
    defer freeDiff(alloc, result);
    // Both empty → single empty line match → empty diff
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "computeDiff: completely different" {
    const alloc = std.testing.allocator;
    const result = try computeDiff(alloc, "aaa\nbbb", "ccc\nddd");
    defer freeDiff(alloc, result);
    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqual(DiffTag.remove, result[0].tag);
    try std.testing.expectEqualStrings("aaa", result[0].text);
    try std.testing.expectEqual(DiffTag.remove, result[1].tag);
    try std.testing.expectEqualStrings("bbb", result[1].text);
    try std.testing.expectEqual(DiffTag.add, result[2].tag);
    try std.testing.expectEqualStrings("ccc", result[2].text);
    try std.testing.expectEqual(DiffTag.add, result[3].tag);
    try std.testing.expectEqualStrings("ddd", result[3].text);
}

test "computeDiff: prefix change only" {
    const alloc = std.testing.allocator;
    const result = try computeDiff(alloc, "changed\nkeep1\nkeep2", "new_line\nkeep1\nkeep2");
    defer freeDiff(alloc, result);
    // Should have: remove "changed", add "new_line", context "keep1" (up to 3 context after)
    var has_remove = false;
    var has_add = false;
    for (result) |line| {
        if (line.tag == .remove) has_remove = true;
        if (line.tag == .add) has_add = true;
    }
    try std.testing.expect(has_remove);
    try std.testing.expect(has_add);
}

test "computeDiff: suffix change only" {
    const alloc = std.testing.allocator;
    const result = try computeDiff(alloc, "keep1\nkeep2\nold_end", "keep1\nkeep2\nnew_end");
    defer freeDiff(alloc, result);
    var has_remove = false;
    var has_add = false;
    for (result) |line| {
        if (line.tag == .remove) has_remove = true;
        if (line.tag == .add) has_add = true;
    }
    try std.testing.expect(has_remove);
    try std.testing.expect(has_add);
}

test "computeDiff: middle change with context" {
    const alloc = std.testing.allocator;
    const orig = "line1\nline2\nline3\nOLD\nline5\nline6\nline7";
    const repl = "line1\nline2\nline3\nNEW\nline5\nline6\nline7";
    const result = try computeDiff(alloc, orig, repl);
    defer freeDiff(alloc, result);

    // Context before (up to 3): line1, line2, line3
    // Remove: OLD
    // Add: NEW
    // Context after (up to 3): line5, line6, line7
    try std.testing.expectEqual(@as(usize, 8), result.len);
    try std.testing.expectEqual(DiffTag.context, result[0].tag);
    try std.testing.expectEqualStrings("line1", result[0].text);
    try std.testing.expectEqual(DiffTag.context, result[1].tag);
    try std.testing.expectEqual(DiffTag.context, result[2].tag);
    try std.testing.expectEqual(DiffTag.remove, result[3].tag);
    try std.testing.expectEqualStrings("OLD", result[3].text);
    try std.testing.expectEqual(DiffTag.add, result[4].tag);
    try std.testing.expectEqualStrings("NEW", result[4].text);
    try std.testing.expectEqual(DiffTag.context, result[5].tag);
    try std.testing.expectEqual(DiffTag.context, result[6].tag);
    try std.testing.expectEqual(DiffTag.context, result[7].tag);
}

test "computeDiff: large input fallback" {
    const alloc = std.testing.allocator;
    // Generate >500 lines total
    var orig_buf: [300 * 6]u8 = undefined;
    var repl_buf: [300 * 6]u8 = undefined;
    var opos: usize = 0;
    var rpos: usize = 0;
    for (0..300) |i| {
        const olen = std.fmt.bufPrint(orig_buf[opos..], "aaa{d}\n", .{i}) catch break;
        opos += olen.len;
        const rlen = std.fmt.bufPrint(repl_buf[rpos..], "bbb{d}\n", .{i}) catch break;
        rpos += rlen.len;
    }
    const result = try computeDiff(alloc, orig_buf[0..opos], repl_buf[0..rpos]);
    defer freeDiff(alloc, result);
    // Should have used simpleDiff fallback: all remove + all add
    try std.testing.expect(result.len > 0);
    try std.testing.expectEqual(DiffTag.remove, result[0].tag);
}

test "computeDiff: add lines to empty" {
    const alloc = std.testing.allocator;
    const result = try computeDiff(alloc, "", "new line");
    defer freeDiff(alloc, result);
    // "" splits to [""], "new line" splits to ["new line"]
    // They differ: remove "" + add "new line"
    try std.testing.expect(result.len >= 1);
}
