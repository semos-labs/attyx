//! Parse an agent's on-screen prompt into a structured choice — pure, TTY-free,
//! unit-testable. Input is the pane's visible screen text (plain grid rows, no
//! ANSI) as returned by `get_text`. Agents that pause for input (Claude/Codex
//! permission and menu prompts) draw a numbered option list; we find the bottom
//! contiguous `N. label` block and the question line above it. Agents that don't
//! (opencode/pi freeform) yield null, and the dashboard falls back to a reply box.
//!
//! Also defines `Interact`, the dashboard's transient input state, here (not in
//! run.zig) so render.zig can read it without importing run.zig.
const std = @import("std");

pub const max_options = 9;

pub const Option = struct {
    num: u8 = 0,
    buf: [96]u8 = undefined,
    len: u8 = 0,

    pub fn label(self: *const Option) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Prompt = struct {
    q_buf: [160]u8 = undefined,
    q_len: u8 = 0,
    options: [max_options]Option = undefined,
    n: u8 = 0,

    pub fn question(self: *const Prompt) []const u8 {
        return self.q_buf[0..self.q_len];
    }

    /// Parse `screen` (visible rows, newline-separated, plain text). Returns a
    /// Prompt when a numbered option block (≥2 options starting at 1, consecutive)
    /// sits at the bottom of the screen, else null.
    pub fn parse(screen: []const u8) ?Prompt {
        // Collect non-blank trimmed lines (drop trailing blanks).
        var lines: [256][]const u8 = undefined;
        var nlines: usize = 0;
        var it = std.mem.splitScalar(u8, screen, '\n');
        while (it.next()) |raw| {
            if (nlines >= lines.len) break;
            lines[nlines] = raw;
            nlines += 1;
        }
        // Trim trailing lines that hold no option/text (blank or box-only).
        while (nlines > 0 and strip(lines[nlines - 1]).len == 0) nlines -= 1;
        if (nlines == 0) return null;

        // Walk up from the bottom collecting consecutive option lines.
        var p = Prompt{};
        var tmp: [max_options]Option = undefined;
        var got: usize = 0;
        var i: usize = nlines;
        var block_top: usize = nlines;
        while (i > 0) {
            i -= 1;
            if (asOption(strip(lines[i]))) |opt| {
                if (got < max_options) {
                    tmp[got] = opt;
                    got += 1;
                    block_top = i;
                    continue;
                }
            }
            // First non-option after we've started the block ends it.
            if (got > 0) break;
        }
        if (got < 2) return null;

        // tmp is bottom-up; reverse into options[] and validate 1,2,3… order.
        p.n = @intCast(got);
        var k: usize = 0;
        while (k < got) : (k += 1) {
            const src = tmp[got - 1 - k];
            if (src.num != k + 1) return null; // not a clean 1..N menu → reject
            p.options[k] = src;
        }

        // Question: nearest non-blank text line above the block that isn't itself
        // an option. Strip box noise; empty is fine (some prompts have none).
        var q: []const u8 = "";
        var j: usize = block_top;
        while (j > 0) {
            j -= 1;
            const s = strip(lines[j]);
            if (s.len == 0) continue;
            if (asOption(s) != null) continue;
            q = s;
            break;
        }
        p.q_len = copy(&p.q_buf, q);
        return p;
    }
};

/// Dashboard interaction state. `.reply` types a freeform message; `.options`
/// shows the parsed picker. The expanded panel under the row also shows `msg`
/// (the agent's last message, scrollable). Owned by run.zig, read by render.zig.
pub const Interact = struct {
    mode: enum { none, reply, options } = .none,
    session: u32 = 0,
    pane_id: u32 = 0,
    reply_buf: [512]u8 = undefined,
    reply_len: usize = 0,
    prompt: Prompt = .{},
    sel: u8 = 0,
    msg_buf: [4096]u8 = undefined,
    msg_len: usize = 0,
    msg_scroll: usize = 0, // first wrapped line shown in the message area

    pub fn reply(self: *const Interact) []const u8 {
        return self.reply_buf[0..self.reply_len];
    }
    pub fn msg(self: *const Interact) []const u8 {
        return self.msg_buf[0..self.msg_len];
    }
    pub fn setMsg(self: *Interact, s: []const u8) void {
        self.msg_len = @min(s.len, self.msg_buf.len);
        @memcpy(self.msg_buf[0..self.msg_len], s[0..self.msg_len]);
    }
    pub fn reset(self: *Interact) void {
        self.* = .{};
    }
};

// --- helpers ---------------------------------------------------------------

const caret_box = [_][]const u8{ "│", "┃", "║", "❯", "▶", "›", "*", ">", "|" };

/// Strip leading whitespace and box/caret glyphs (repeatedly), then trailing
/// whitespace and box verticals.
fn strip(line: []const u8) []const u8 {
    var s = std.mem.trim(u8, line, " \t\r");
    outer: while (s.len > 0) {
        for (caret_box) |g| {
            if (std.mem.startsWith(u8, s, g)) {
                s = std.mem.trimLeft(u8, s[g.len..], " \t");
                continue :outer;
            }
        }
        break;
    }
    // Trailing box verticals (right border of a panel) + spaces.
    while (s.len > 0) {
        var trimmed = false;
        s = std.mem.trimRight(u8, s, " \t\r");
        for (caret_box) |g| {
            if (std.mem.endsWith(u8, s, g)) {
                s = s[0 .. s.len - g.len];
                trimmed = true;
            }
        }
        if (!trimmed) break;
    }
    return s;
}

/// `N. label` / `N) label` / `N: label` / `N label`, N in 1..9. Returns the
/// option or null. `s` is assumed already stripped of leading box/caret.
fn asOption(s: []const u8) ?Option {
    if (s.len < 2) return null;
    if (s[0] < '1' or s[0] > '9') return null;
    const sep = s[1];
    if (sep != '.' and sep != ')' and sep != ':' and sep != ' ') return null;
    const label = std.mem.trim(u8, s[2..], " \t");
    if (label.len == 0) return null;
    var o = Option{ .num = s[0] - '0' };
    o.len = copy(&o.buf, label);
    return o;
}

fn copy(buf: []u8, s: []const u8) u8 {
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    return @intCast(n);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "parses a Claude-style permission box" {
    const screen =
        \\╭─────────────────────────────────────╮
        \\│ Bash command                        │
        \\│ rm -rf build                        │
        \\│ Do you want to proceed?             │
        \\│ ❯ 1. Yes                            │
        \\│   2. Yes, and don't ask again       │
        \\│   3. No, and tell Claude what to do │
        \\╰─────────────────────────────────────╯
    ;
    const p = Prompt.parse(screen) orelse return error.NoPrompt;
    try testing.expectEqual(@as(u8, 3), p.n);
    try testing.expectEqualStrings("Yes", p.options[0].label());
    try testing.expectEqual(@as(u8, 2), p.options[1].num);
    try testing.expectEqualStrings("No, and tell Claude what to do", p.options[2].label());
    try testing.expectEqualStrings("Do you want to proceed?", p.question());
}

test "parses a bare numbered menu (no box)" {
    const screen =
        \\Select an option:
        \\1) Continue
        \\2) Cancel
        \\
    ;
    const p = Prompt.parse(screen) orelse return error.NoPrompt;
    try testing.expectEqual(@as(u8, 2), p.n);
    try testing.expectEqualStrings("Continue", p.options[0].label());
    try testing.expectEqualStrings("Select an option:", p.question());
}

test "no numbered block → null (freeform)" {
    try testing.expect(Prompt.parse("Tell me what to build next.\n> ") == null);
    try testing.expect(Prompt.parse("") == null);
    try testing.expect(Prompt.parse("step 1. done\nstep 3. later") == null); // not 1..N consecutive
}

test "interact tracks session and pane until reset" {
    var it = Interact{ .session = 7, .pane_id = 42, .mode = .reply };
    try testing.expectEqual(@as(u32, 7), it.session);
    try testing.expectEqual(@as(u32, 42), it.pane_id);
    it.reset();
    try testing.expectEqual(@as(u32, 0), it.session);
    try testing.expectEqual(@as(u32, 0), it.pane_id);
}

test "ignores prose above; only bottom block counts" {
    const screen =
        \\I considered 3 approaches earlier.
        \\Now choose:
        \\1. Approach A
        \\2. Approach B
    ;
    const p = Prompt.parse(screen) orelse return error.NoPrompt;
    try testing.expectEqual(@as(u8, 2), p.n);
    try testing.expectEqualStrings("Now choose:", p.question());
}
