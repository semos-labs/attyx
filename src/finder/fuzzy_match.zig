/// Fuzzy matching and scoring for path-aware search.
/// Pure, no allocations, no dependencies beyond std.
const std = @import("std");

pub const max_positions = 64;

pub const Score = struct {
    value: i32,
    matched: bool,
    positions: [max_positions]u8,
    match_count: u8,
};

// Scoring constants (fzf-inspired, path-aware)
const bonus_sequential: i32 = 16;
const bonus_separator: i32 = 24;
const bonus_first_char: i32 = 16;
const penalty_gap: i32 = -3;
const penalty_leading: i32 = -1;

fn toLower(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

fn isSeparator(ch: u8) bool {
    return ch == '/' or ch == '-' or ch == '_' or ch == '.';
}

/// Full scoring with match positions.
pub fn score(candidate: []const u8, query: []const u8) Score {
    var result = Score{
        .value = 0,
        .matched = false,
        .positions = undefined,
        .match_count = 0,
    };

    if (query.len == 0) {
        result.matched = true;
        return result;
    }
    if (candidate.len == 0 or query.len > candidate.len) return result;
    if (query.len > max_positions) return result;

    // Try to find the best match using a greedy forward scan
    var qi: usize = 0;
    var positions: [max_positions]u8 = undefined;

    for (candidate, 0..) |ch, ci| {
        if (qi < query.len and toLower(ch) == toLower(query[qi])) {
            if (ci <= std.math.maxInt(u8)) {
                positions[qi] = @intCast(ci);
            }
            qi += 1;
        }
    }

    if (qi < query.len) return result; // Not all query chars matched

    result.matched = true;
    result.match_count = @intCast(query.len);
    @memcpy(result.positions[0..query.len], positions[0..query.len]);

    // Calculate score
    var s: i32 = 0;

    // Leading gap penalty
    s += @as(i32, @intCast(positions[0])) * penalty_leading;

    for (0..query.len) |i| {
        const pos = positions[i];

        // First char bonus
        if (pos == 0) {
            s += bonus_first_char;
        }

        // Separator bonus: match right after a separator
        if (pos > 0 and isSeparator(candidate[pos - 1])) {
            s += bonus_separator;
        }

        // Sequential bonus
        if (i > 0) {
            const prev_pos = positions[i - 1];
            if (pos == prev_pos + 1) {
                s += bonus_sequential;
            } else {
                // Gap penalty between matches
                const gap: i32 = @as(i32, @intCast(pos)) - @as(i32, @intCast(prev_pos)) - 1;
                s += gap * penalty_gap;
            }
        }
    }

    result.value = s;
    return result;
}

/// Simplified scoring: returns just the score or null if no match.
pub fn matchScore(candidate: []const u8, query: []const u8) ?i32 {
    const result = score(candidate, query);
    if (!result.matched) return null;
    return result.value;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "empty query matches everything" {
    const result = score("anything", "");
    try std.testing.expect(result.matched);
    try std.testing.expectEqual(@as(u8, 0), result.match_count);
}

test "exact match" {
    const result = score("hello", "hello");
    try std.testing.expect(result.matched);
    try std.testing.expectEqual(@as(u8, 5), result.match_count);
    try std.testing.expect(result.value > 0);
}

test "prefix match scores higher than gap match" {
    const prefix = score("project", "pro");
    const gap = score("parador", "pro");
    try std.testing.expect(prefix.matched);
    try std.testing.expect(gap.matched);
    try std.testing.expect(prefix.value > gap.value);
}

test "path boundary bonus" {
    const boundary = score("src/finder", "finder");
    const middle = score("pathfinder", "finder");
    try std.testing.expect(boundary.matched);
    try std.testing.expect(middle.matched);
    try std.testing.expect(boundary.value > middle.value);
}

test "gap penalty" {
    const tight = score("abc", "abc");
    const gapped = score("axxbxxc", "abc");
    try std.testing.expect(tight.matched);
    try std.testing.expect(gapped.matched);
    try std.testing.expect(tight.value > gapped.value);
}

test "no match returns false" {
    const result = score("hello", "xyz");
    try std.testing.expect(!result.matched);
}

test "case insensitive" {
    const result = score("HelloWorld", "helloworld");
    try std.testing.expect(result.matched);
    try std.testing.expectEqual(@as(u8, 10), result.match_count);
}

test "query longer than candidate" {
    const result = score("ab", "abc");
    try std.testing.expect(!result.matched);
}

test "matchScore convenience" {
    try std.testing.expect(matchScore("hello", "hel") != null);
    try std.testing.expect(matchScore("hello", "xyz") == null);
}

test "separator chars all work" {
    // All separator types should give bonus
    const slash = score("a/b", "b");
    const dash = score("a-b", "b");
    const under = score("a_b", "b");
    const dot = score("a.b", "b");
    const none = score("axb", "b");

    try std.testing.expect(slash.value > none.value);
    try std.testing.expect(dash.value > none.value);
    try std.testing.expect(under.value > none.value);
    try std.testing.expect(dot.value > none.value);
}
