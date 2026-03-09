const std = @import("std");
const TerminalState = @import("../../term/state.zig").TerminalState;

// ===========================================================================
// Styled text reflow
// ===========================================================================

test "resize: styled text reflows correctly on shrink" {
    const alloc = std.testing.allocator;
    const Grid = @import("../../term/grid.zig");
    const Style = Grid.Style;
    var t = try TerminalState.init(alloc, 4, 10, 100);
    defer t.deinit();

    const cyan = Style{ .fg = .{ .ansi = 6 } };

    // Simulate colored prompt: "ABCDEF" in cyan (6 chars at 10 cols)
    t.pen = cyan;
    t.apply(.{ .print = 'A' });
    t.apply(.{ .print = 'B' });
    t.apply(.{ .print = 'C' });
    t.apply(.{ .print = 'D' });
    t.apply(.{ .print = 'E' });
    t.apply(.{ .print = 'F' });
    t.pen = .{};

    // Cursor below content (prompt position)
    t.cursor.row = 1;
    t.cursor.col = 0;

    try t.resize(4, 4);

    // "ABCDEF" reflows: row 0 = "ABCD" (wrapped), row 1 = "EF"
    try std.testing.expectEqual(@as(u21, 'A'), t.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(cyan, t.ring.getScreenCell(0, 0).style);
    try std.testing.expectEqual(@as(u21, 'D'), t.ring.getScreenCell(0, 3).char);
    try std.testing.expect(t.ring.getScreenWrapped(0));
    try std.testing.expectEqual(@as(u21, 'E'), t.ring.getScreenCell(1, 0).char);
    try std.testing.expectEqual(cyan, t.ring.getScreenCell(1, 0).style);
    try std.testing.expectEqual(@as(u21, 'F'), t.ring.getScreenCell(1, 1).char);
}

test "resize: fg-only styled trailing spaces are ignored for content_len" {
    // Spaces with only foreground styling (default bg) are invisible
    // and must NOT inflate content_len — otherwise prompts like
    // Starship cascade rightward on repeated shrinks.
    const alloc = std.testing.allocator;
    const Grid = @import("../../term/grid.zig");
    const Style = Grid.Style;
    var t = try TerminalState.init(alloc, 4, 10, 100);
    defer t.deinit();

    const magenta_fg = Style{ .fg = .{ .ansi = 5 } };

    // "AB" at cols 0-1, then fg-only styled spaces at cols 2-5
    t.apply(.{ .print = 'A' });
    t.apply(.{ .print = 'B' });
    t.pen = magenta_fg;
    t.apply(.{ .print = ' ' });
    t.apply(.{ .print = ' ' });
    t.apply(.{ .print = ' ' });
    t.apply(.{ .print = ' ' });
    t.pen = .{};

    // Cursor below content
    t.cursor.row = 1;
    t.cursor.col = 0;

    try t.resize(4, 3);

    // content_len = 2 (only "AB" counts; fg-only spaces are ignored).
    // At 3 cols: 2 chars → 1 row, no wrapping.
    try std.testing.expectEqual(@as(u21, 'A'), t.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), t.ring.getScreenCell(0, 1).char);
    try std.testing.expect(!t.ring.getScreenWrapped(0));
    try std.testing.expectEqual(@as(u21, ' '), t.ring.getScreenCell(1, 0).char);
}

test "resize: bg-styled trailing spaces ARE counted for content_len" {
    // Spaces with a non-default background are visible (colored block)
    // and must count as content.
    const alloc = std.testing.allocator;
    const Grid = @import("../../term/grid.zig");
    const Style = Grid.Style;
    var t = try TerminalState.init(alloc, 4, 10, 100);
    defer t.deinit();

    const red_bg = Style{ .bg = .{ .ansi = 1 } };

    // "AB" at cols 0-1, then bg-styled spaces at cols 2-5
    t.apply(.{ .print = 'A' });
    t.apply(.{ .print = 'B' });
    t.pen = red_bg;
    t.apply(.{ .print = ' ' });
    t.apply(.{ .print = ' ' });
    t.apply(.{ .print = ' ' });
    t.apply(.{ .print = ' ' });
    t.pen = .{};

    // Cursor below content
    t.cursor.row = 1;
    t.cursor.col = 0;

    try t.resize(4, 3);

    // content_len = 6 (bg-styled spaces are visible content).
    // At 3 cols: ceil(6/3) = 2 rows.
    try std.testing.expectEqual(@as(u21, 'A'), t.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), t.ring.getScreenCell(0, 1).char);
    try std.testing.expect(t.ring.getScreenWrapped(0));
    try std.testing.expectEqual(red_bg, t.ring.getScreenCell(1, 0).style);
}

test "resize: right-aligned content stripped on shrink (RPROMPT)" {
    // Simulates right-aligned prompt: left text (cols 0-2), gap (3-6 default),
    // right text (cols 7-9 styled). RPROMPT stripping removes the right content
    // so it doesn't garble the display on shrink.
    const alloc = std.testing.allocator;
    const Grid = @import("../../term/grid.zig");
    const Style = Grid.Style;
    var t = try TerminalState.init(alloc, 4, 10, 100);
    defer t.deinit();

    const cyan = Style{ .fg = .{ .ansi = 6 } };
    const magenta = Style{ .fg = .{ .ansi = 5 } };

    // Left: "DIR" in cyan
    t.pen = cyan;
    t.apply(.{ .print = 'D' });
    t.apply(.{ .print = 'I' });
    t.apply(.{ .print = 'R' });
    t.pen = .{};
    // Gap: cols 3-6 are default (simulates cursor jump)
    t.cursor.col = 7;
    // Right: "git" in magenta (right-aligned at edge)
    t.pen = magenta;
    t.apply(.{ .print = 'g' });
    t.apply(.{ .print = 'i' });
    t.apply(.{ .print = 't' });
    t.pen = .{};

    // Cursor below content
    t.cursor.row = 1;
    t.cursor.col = 0;

    try t.resize(4, 5);

    // RPROMPT stripped: only "DIR" remains (3 chars fits in 5 cols, no wrap)
    try std.testing.expectEqual(@as(u21, 'D'), t.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(cyan, t.ring.getScreenCell(0, 0).style);
    try std.testing.expect(!t.ring.getScreenWrapped(0));
    // Right content gone
    try std.testing.expectEqual(@as(u21, ' '), t.ring.getScreenCell(0, 3).char);
}

test "resize: rapid shrink cycles with styled prompt don't cascade" {
    // Simulates the real-world scenario: colored prompt text, multiple
    // shrink cycles.  Counts non-default cells after each resize to
    // verify that content doesn't duplicate (the cascading bug creates
    // extra copies of the prompt text, inflating the cell count).
    const alloc = std.testing.allocator;
    const Grid = @import("../../term/grid.zig");
    const Style = Grid.Style;
    var t = try TerminalState.init(alloc, 24, 40, 100);
    defer t.deinit();

    const cyan = Style{ .fg = .{ .ansi = 6 } };
    const magenta = Style{ .fg = .{ .ansi = 5 } };

    // Row 0: output line "output_line_here" (16 chars, default style)
    for ("output_line_here") |ch| {
        t.apply(.{ .print = ch });
    }
    t.apply(.{ .control = .lf });
    t.apply(.{ .control = .cr });

    // Row 1: colored prompt "~/proj" (cyan) + " main" (magenta) = 11 chars
    t.pen = cyan;
    for ("~/proj") |ch| {
        t.apply(.{ .print = ch });
    }
    t.pen = magenta;
    for (" main") |ch| {
        t.apply(.{ .print = ch });
    }
    t.pen = .{};
    t.apply(.{ .control = .lf });
    t.apply(.{ .control = .cr });

    // Row 2: input line "> " (cursor here at col 2)
    t.apply(.{ .print = '>' });
    t.apply(.{ .print = ' ' });
    try std.testing.expectEqual(@as(usize, 2), t.cursor.row);

    // Total meaningful content: 16 + 11 + 2 = 29 non-default cells.
    // After any resize, the count should stay <= 29 (content is never
    // duplicated — it can only shrink if trailing cells are trimmed).
    const max_content = 29;

    // Helper: count non-default cells in the ring's screen area
    const RingBuffer = @import("../../term/ring.zig").RingBuffer;
    const countNonDefault = struct {
        fn f(ring: *const RingBuffer) usize {
            const grid_mod = @import("../../term/grid.zig");
            var n: usize = 0;
            for (0..ring.screen_rows) |r| {
                const row = ring.getScreenRow(r);
                for (row) |cell| {
                    if (!grid_mod.isDefaultCell(cell)) n += 1;
                }
            }
            return n;
        }
    }.f;

    // --- Cycle 1: 40 → 20 ---
    try t.resize(24, 20);
    try std.testing.expect(countNonDefault(&t.ring) <= max_content);

    // --- Cycle 2: 20 → 10 ---
    try t.resize(24, 10);
    try std.testing.expect(countNonDefault(&t.ring) <= max_content);

    // --- Cycle 3: 10 → 5 ---
    try t.resize(24, 5);
    try std.testing.expect(countNonDefault(&t.ring) <= max_content);

    // --- Cycle 4: 5 → 3 ---
    try t.resize(24, 3);
    try std.testing.expect(countNonDefault(&t.ring) <= max_content);

    // --- Grow back: 3 → 40 ---
    try t.resize(24, 40);
    try std.testing.expect(countNonDefault(&t.ring) <= max_content);
}

test "resize: right-aligned prompt with styled gap — shrink cycles" {
    // Simulates a prompt like: "~/proj" (cyan, cols 0-5) + gap + "main" (magenta, cols 36-39)
    // This is the right-alignment pattern used by starship/powerline.
    // The default cells in the gap are "invisible" but the content_len
    // spans the full row (last non-default at col 39 = 40).
    // On shrink, this 40-char logical line wraps massively.
    const alloc = std.testing.allocator;
    const Grid = @import("../../term/grid.zig");
    const Style = Grid.Style;
    var t = try TerminalState.init(alloc, 24, 40, 100);
    defer t.deinit();

    const cyan = Style{ .fg = .{ .ansi = 6 } };
    const magenta = Style{ .fg = .{ .ansi = 5 } };

    // Simulate prompt with cursor-positioning gap:
    // Left part: "~/proj" in cyan
    t.pen = cyan;
    for ("~/proj") |ch| {
        t.apply(.{ .print = ch });
    }
    t.pen = .{};

    // Jump cursor to column 36 (simulating ESC[37G)
    t.cursor.col = 36;

    // Right part: "main" in magenta
    t.pen = magenta;
    for ("main") |ch| {
        t.apply(.{ .print = ch });
    }
    t.pen = .{};

    // New line for input
    t.apply(.{ .control = .lf });
    t.apply(.{ .control = .cr });
    t.apply(.{ .print = '>' });
    t.apply(.{ .print = ' ' });

    // Cursor at row 1. Row 0 has styled content at cols 0-5 and 36-39
    // with default gap at cols 6-35.
    try std.testing.expectEqual(@as(usize, 1), t.cursor.row);

    // content_len for row 0 = 40 (last non-default at col 39).
    // This is the key issue: the 30-cell default gap inflates the line.

    const RingBuffer = @import("../../term/ring.zig").RingBuffer;
    const countNonDefault = struct {
        fn f(ring: *const RingBuffer) usize {
            const grid_mod = @import("../../term/grid.zig");
            var n: usize = 0;
            for (0..ring.screen_rows) |r| {
                const row = ring.getScreenRow(r);
                for (row) |cell| {
                    if (!grid_mod.isDefaultCell(cell)) n += 1;
                }
            }
            return n;
        }
    }.f;

    const initial_count = countNonDefault(&t.ring);

    // --- Shrink cycles ---
    try t.resize(24, 20);
    var count = countNonDefault(&t.ring);
    try std.testing.expect(count <= initial_count);

    try t.resize(24, 10);
    count = countNonDefault(&t.ring);
    try std.testing.expect(count <= initial_count);

    try t.resize(24, 5);
    count = countNonDefault(&t.ring);
    try std.testing.expect(count <= initial_count);

    // Grow back
    try t.resize(24, 40);
    count = countNonDefault(&t.ring);
    try std.testing.expect(count <= initial_count);
}

test "resize: right-aligned content stripped before reflow on shrink" {
    // Simulates Starship RPROMPT: left text at cols 0-5, gap of default
    // cells, right text at cols 36-39.  On shrink to 20 cols the right
    // content exceeds new_cols and must be stripped before the reflow so
    // it doesn't wrap into garbled fragment rows.
    const alloc = std.testing.allocator;
    const Grid = @import("../../term/grid.zig");
    const Style = Grid.Style;
    var t = try TerminalState.init(alloc, 4, 40, 100);
    defer t.deinit();

    const cyan = Style{ .fg = .{ .ansi = 6 } };
    const magenta = Style{ .fg = .{ .ansi = 5 } };

    // Left: "~/proj" in cyan
    t.pen = cyan;
    for ("~/proj") |ch| {
        t.apply(.{ .print = ch });
    }
    t.pen = .{};

    // Jump to column 36 (simulating cursor-absolute positioning)
    t.cursor.col = 36;

    // Right: "main" in magenta
    t.pen = magenta;
    for ("main") |ch| {
        t.apply(.{ .print = ch });
    }
    t.pen = .{};

    // Newline + input prompt
    t.apply(.{ .control = .lf });
    t.apply(.{ .control = .cr });
    t.apply(.{ .print = '>' });
    t.apply(.{ .print = ' ' });
    try std.testing.expectEqual(@as(usize, 1), t.cursor.row);

    // Shrink to 20 cols — right content (cols 36-39) exceeds 20.
    // The pre-processing should strip it; the left text (6 chars) fits.
    try t.resize(4, 20);

    // Left text preserved
    try std.testing.expectEqual(@as(u21, '~'), t.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(cyan, t.ring.getScreenCell(0, 0).style);
    try std.testing.expectEqual(@as(u21, 'j'), t.ring.getScreenCell(0, 5).char);

    // No wrapping on the prompt row — line fits after stripping
    try std.testing.expect(!t.ring.getScreenWrapped(0));

    // Right-aligned "main" text should be gone (cells cleared)
    try std.testing.expectEqual(@as(u21, ' '), t.ring.getScreenCell(0, 6).char);
    try std.testing.expectEqual(Grid.Style{}, t.ring.getScreenCell(0, 6).style);
}

test "resize: auto-wrapped line rejoins on grow and re-wraps on shrink" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 4, 4, 100);
    defer t.deinit();

    // Print 5 chars to trigger auto-wrap: "ABCD" on row 0, "E" on row 1
    t.apply(.{ .print = 'A' });
    t.apply(.{ .print = 'B' });
    t.apply(.{ .print = 'C' });
    t.apply(.{ .print = 'D' });
    t.apply(.{ .print = 'E' });
    try std.testing.expect(t.ring.getScreenWrapped(0));
    try std.testing.expectEqual(@as(u21, 'E'), t.ring.getScreenCell(1, 0).char);

    // Grow to 8 cols — auto-wrapped "ABCDE" rejoins into one row.
    try t.resize(4, 8);
    try std.testing.expectEqual(@as(u21, 'A'), t.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), t.ring.getScreenCell(0, 3).char);
    try std.testing.expectEqual(@as(u21, 'E'), t.ring.getScreenCell(0, 4).char);
    try std.testing.expect(!t.ring.getScreenWrapped(0));

    // Shrink to 2 cols — "ABCDE" wraps into 3 rows (one logical line)
    try t.resize(4, 2);
    try std.testing.expectEqual(@as(u21, 'A'), t.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), t.ring.getScreenCell(0, 1).char);
    try std.testing.expect(t.ring.getScreenWrapped(0));
    try std.testing.expectEqual(@as(u21, 'C'), t.ring.getScreenCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), t.ring.getScreenCell(1, 1).char);
    try std.testing.expectEqual(@as(u21, 'E'), t.ring.getScreenCell(2, 0).char);
}

// ===========================================================================
// Starship / RPROMPT-style prompt reflow tests
// ===========================================================================

test "resize: starship prompt RPROMPT stripped on shrink" {
    // Simulates: ~/Projects/attyx on ⎇ main      ⊙ v22.15.1
    // Left prompt ~30 chars, gap ~15, right prompt ~10, total = 55 at 60 cols
    const alloc = std.testing.allocator;
    const Grid = @import("../../term/grid.zig");
    const Style = Grid.Style;
    var t = try TerminalState.init(alloc, 24, 60, 200);
    defer t.deinit();

    const cyan = Style{ .fg = .{ .ansi = 6 } };
    const green = Style{ .fg = .{ .ansi = 2 } };

    // Left: "~/proj on main" in cyan (14 chars)
    t.pen = cyan;
    for ("~/proj on main") |ch| t.apply(.{ .print = ch });
    t.pen = .{};

    // Jump to right side (col 50) — simulates cursor positioning
    t.cursor.col = 50;

    // Right: "v22.15.1" in green (8 chars, ending at col 57)
    t.pen = green;
    for ("v22.15.1") |ch| t.apply(.{ .print = ch });
    t.pen = .{};

    // New line + input prompt
    t.apply(.{ .control = .lf });
    t.apply(.{ .control = .cr });
    t.apply(.{ .print = '>' });
    t.apply(.{ .print = ' ' });
    try std.testing.expectEqual(@as(usize, 1), t.cursor.row);

    // Shrink to 30 cols — right content should be stripped
    try t.resize(24, 30);

    // Left prompt preserved
    try std.testing.expectEqual(@as(u21, '~'), t.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(cyan, t.ring.getScreenCell(0, 0).style);
    // "n" at end of "main" at col 13
    try std.testing.expectEqual(@as(u21, 'n'), t.ring.getScreenCell(0, 13).char);
    // No wrapping — left content (14 chars) fits in 30 cols
    try std.testing.expect(!t.ring.getScreenWrapped(0));
    // Right content gone (col 14+ should be blank)
    try std.testing.expectEqual(@as(u21, ' '), t.ring.getScreenCell(0, 14).char);
}

test "resize: starship prompt survives multiple shrink cycles" {
    // Simulates rapid resize: 80 → 40 → 20 → 40 → 80
    // Left prompt should be preserved, RPROMPT stripped, no garbled content
    const alloc = std.testing.allocator;
    const Grid = @import("../../term/grid.zig");
    const Style = Grid.Style;
    const RingBuffer = @import("../../term/ring.zig").RingBuffer;
    var t = try TerminalState.init(alloc, 24, 80, 200);
    defer t.deinit();

    const cyan = Style{ .fg = .{ .ansi = 6 } };
    const magenta = Style{ .fg = .{ .ansi = 5 } };

    // Row 0: starship prompt
    // Left: "~/Projects/attyx on main" (24 chars)
    t.pen = cyan;
    for ("~/Projects/attyx on main") |ch| t.apply(.{ .print = ch });
    t.pen = .{};

    // Jump to right side
    t.cursor.col = 70;
    t.pen = magenta;
    for ("v22.15.1") |ch| t.apply(.{ .print = ch });
    t.pen = .{};

    // Row 1: input
    t.apply(.{ .control = .lf });
    t.apply(.{ .control = .cr });
    t.apply(.{ .print = '>' });
    t.apply(.{ .print = ' ' });

    // Count non-default cells to verify no duplication
    const countNonDefault = struct {
        fn f(ring: *const RingBuffer) usize {
            const gm = @import("../../term/grid.zig");
            var n: usize = 0;
            for (0..ring.screen_rows) |r| {
                for (ring.getScreenRow(r)) |cell| {
                    if (!gm.isDefaultCell(cell)) n += 1;
                }
            }
            return n;
        }
    }.f;

    const initial_count = countNonDefault(&t.ring);

    // Shrink cycles
    try t.resize(24, 40);
    try std.testing.expect(countNonDefault(&t.ring) <= initial_count);

    try t.resize(24, 20);
    try std.testing.expect(countNonDefault(&t.ring) <= initial_count);

    // Grow back
    try t.resize(24, 40);
    try std.testing.expect(countNonDefault(&t.ring) <= initial_count);

    try t.resize(24, 80);
    try std.testing.expect(countNonDefault(&t.ring) <= initial_count);

    // Left prompt should still be intact at row 0
    try std.testing.expectEqual(@as(u21, '~'), t.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(cyan, t.ring.getScreenCell(0, 0).style);
}

test "resize: RPROMPT stripped even after previous wrap" {
    // Simulates: prompt rendered at 60 cols, resized to 40, then to 20.
    // After first resize the RPROMPT wraps. Second resize must still strip it
    // by scanning the logical line (wrapped rows).
    const alloc = std.testing.allocator;
    const Grid = @import("../../term/grid.zig");
    const Style = Grid.Style;
    var t = try TerminalState.init(alloc, 24, 60, 200);
    defer t.deinit();

    const cyan = Style{ .fg = .{ .ansi = 6 } };
    const green = Style{ .fg = .{ .ansi = 2 } };

    // Left: 20 chars
    t.pen = cyan;
    for ("~/proj on feat-xyz") |_ch| t.apply(.{ .print = _ch });
    t.pen = .{};

    // Jump to col 50, write right prompt (10 chars to col 59)
    t.cursor.col = 50;
    t.pen = green;
    for ("git:main *") |_ch| t.apply(.{ .print = _ch });
    t.pen = .{};

    // Input line below
    t.apply(.{ .control = .lf });
    t.apply(.{ .control = .cr });
    t.apply(.{ .print = '>' });
    t.apply(.{ .print = ' ' });

    // First shrink: 60→30. RPROMPT stripped (gap=32 > threshold).
    try t.resize(24, 30);
    // Left prompt preserved, no wrapping (18 chars < 30)
    try std.testing.expectEqual(@as(u21, '~'), t.ring.getScreenCell(0, 0).char);
    try std.testing.expect(!t.ring.getScreenWrapped(0));

    // Simulate shell redraw at 30 cols: new prompt with small gap
    // (This is what starship would do after SIGWINCH)
    // Clear row 0 and rewrite
    {
        const row = t.ring.getScreenRowMut(0);
        @memset(row, Grid.Cell{});
    }
    t.cursor.row = 0;
    t.cursor.col = 0;
    t.pen = cyan;
    for ("~/proj on feat-xyz") |_ch| t.apply(.{ .print = _ch });
    t.pen = .{};
    t.cursor.col = 22; // small gap of 4 cells
    t.pen = green;
    for ("main *") |_ch| t.apply(.{ .print = _ch });
    t.pen = .{};
    t.cursor.row = 1;
    t.cursor.col = 2;

    // Second shrink: 30→15. The redrawn prompt has content at 0-17 + gap + 22-27.
    // RPROMPT should be stripped.
    try t.resize(24, 15);

    // Left content wraps at 15 cols (18 chars → 2 rows)
    try std.testing.expectEqual(@as(u21, '~'), t.ring.getScreenCell(0, 0).char);
    // Right content should be gone
    // Check that no green-styled content appears on the screen
    var found_green = false;
    for (0..t.ring.screen_rows) |r| {
        for (t.ring.getScreenRow(r)) |cell| {
            if (std.meta.eql(cell.style, green) and cell.char != ' ') {
                found_green = true;
            }
        }
    }
    try std.testing.expect(!found_green);
}

test "resize: powerline two-line prompt reflow" {
    // Simulates a two-line powerline prompt:
    //   Line 1: "user@host ~/project          main" (RPROMPT at right edge)
    //   Line 2: "> " (input line)
    // On shrink, line 1's RPROMPT should be stripped, line 2 preserved.
    const alloc = std.testing.allocator;
    const Grid = @import("../../term/grid.zig");
    const Style = Grid.Style;
    var t = try TerminalState.init(alloc, 24, 80, 200);
    defer t.deinit();

    const blue = Style{ .fg = .{ .ansi = 4 } };
    const yellow = Style{ .fg = .{ .ansi = 3 } };

    // Line 1: left part
    t.pen = blue;
    for ("user@host ~/project") |ch| t.apply(.{ .print = ch });
    t.pen = .{};

    // Jump to right edge (col 76, so "main" fills cols 76-79)
    t.cursor.col = 76;
    t.pen = yellow;
    for ("main") |ch| t.apply(.{ .print = ch });
    t.pen = .{};

    // Line 2: prompt char
    t.apply(.{ .control = .lf });
    t.apply(.{ .control = .cr });
    t.apply(.{ .print = '>' });
    t.apply(.{ .print = ' ' });

    // Shrink to 30
    try t.resize(24, 30);

    // Left part of line 1 should be intact
    try std.testing.expectEqual(@as(u21, 'u'), t.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(blue, t.ring.getScreenCell(0, 0).style);
    // Right part should be stripped
    try std.testing.expectEqual(@as(u21, ' '), t.ring.getScreenCell(0, 19).char);
    // Input prompt still accessible
    try std.testing.expectEqual(@as(u21, '>'), t.ring.getScreenCell(1, 0).char);
}

test "resize: rapid resize with starship prompt — no content duplication" {
    // Simulates rapid window dragging: multiple resizes in quick succession,
    // with the shell re-rendering the prompt at each intermediate size.
    // At narrow widths starship truncates the left prompt so there's always
    // a gap before the right-aligned content.
    // Verifies that:
    //   1. Screen content doesn't grow unboundedly after resize cycles
    //   2. Left prompt is always recoverable
    const alloc = std.testing.allocator;
    const Grid = @import("../../term/grid.zig");
    const Style = Grid.Style;
    const RingBuffer = @import("../../term/ring.zig").RingBuffer;
    var t = try TerminalState.init(alloc, 24, 100, 500);
    defer t.deinit();

    const cyan = Style{ .fg = .{ .ansi = 6 } };
    const green = Style{ .fg = .{ .ansi = 2 } };

    // Helper: write a starship-like prompt at current width.
    // Truncates left prompt and ensures a gap before right content.
    const writePrompt = struct {
        fn f(state: *@import("../../term/state.zig").TerminalState, left: []const u8, right: []const u8, c: Style, g: Style) void {
            const row_cells = state.ring.getScreenRowMut(state.cursor.row);
            @memset(row_cells, Grid.Cell{});

            const w = state.ring.cols;
            // Ensure gap of at least 4 cells between left and right
            const right_len = @min(right.len, w);
            const max_left = if (w > right_len + 4) w - right_len - 4 else 0;
            const left_len = @min(left.len, max_left);

            state.cursor.col = 0;
            state.pen = c;
            for (left[0..left_len]) |ch| state.apply(.{ .print = ch });
            state.pen = .{};

            if (right_len > 0 and w > right_len) {
                state.cursor.col = w - right_len;
                state.pen = g;
                for (right[0..right_len]) |ch| state.apply(.{ .print = ch });
                state.pen = .{};
            }
        }
    }.f;

    // Helper: count non-default cells on screen only
    const countScreenNonDefault = struct {
        fn f(ring: *const RingBuffer) usize {
            const gm = @import("../../term/grid.zig");
            var n: usize = 0;
            for (0..ring.screen_rows) |r| {
                for (ring.getScreenRow(r)) |cell| {
                    if (!gm.isDefaultCell(cell)) n += 1;
                }
            }
            return n;
        }
    }.f;

    const left_prompt = "~/Projects/attyx on main";
    const right_prompt = "v22.15.1";

    // Initial prompt at 100 cols
    writePrompt(&t, left_prompt, right_prompt, cyan, green);
    t.apply(.{ .control = .lf });
    t.apply(.{ .control = .cr });
    t.apply(.{ .print = '>' });
    t.apply(.{ .print = ' ' });

    // Rapid shrink: 100 → 80 → 60 → 40
    const widths = [_]usize{ 80, 60, 40 };
    for (widths) |w| {
        try t.resize(24, w);
        writePrompt(&t, left_prompt, right_prompt, cyan, green);
    }

    // Measure after all shrinks
    const after_shrink = countScreenNonDefault(&t.ring);

    // Rapid grow: 40 → 60 → 80 → 100
    const grow_widths = [_]usize{ 60, 80, 100 };
    for (grow_widths) |w| {
        try t.resize(24, w);
        writePrompt(&t, left_prompt, right_prompt, cyan, green);
    }

    const after_grow = countScreenNonDefault(&t.ring);

    // Content should not have exploded: growth is reasonable (not 10x)
    try std.testing.expect(after_grow <= after_shrink * 3);

    // Left prompt text is intact on current screen row
    try std.testing.expectEqual(@as(u21, '~'), t.ring.getScreenCell(t.cursor.row, 0).char);
    try std.testing.expectEqual(cyan, t.ring.getScreenCell(t.cursor.row, 0).style);
}

test "resize: rapid horizontal oscillation doesn't accumulate garbage" {
    // Simulates dragging the window edge back and forth rapidly:
    // 80 → 40 → 80 → 40 → 80 (5 cycles)
    // Each resize should cleanly strip RPROMPT and reflow.
    // Non-default cell count should never increase.
    const alloc = std.testing.allocator;
    const Grid = @import("../../term/grid.zig");
    const Style = Grid.Style;
    const RingBuffer = @import("../../term/ring.zig").RingBuffer;
    var t = try TerminalState.init(alloc, 24, 80, 200);
    defer t.deinit();

    const cyan = Style{ .fg = .{ .ansi = 6 } };
    const green = Style{ .fg = .{ .ansi = 2 } };

    // Fill 5 prompt lines (simulates scrollback with multiple prompts)
    for (0..5) |_| {
        t.pen = cyan;
        for ("~/attyx on main") |ch| t.apply(.{ .print = ch });
        t.pen = .{};
        t.cursor.col = 70;
        t.pen = green;
        for ("v22.15.1") |ch| t.apply(.{ .print = ch });
        t.pen = .{};
        t.apply(.{ .control = .lf });
        t.apply(.{ .control = .cr });
        t.apply(.{ .print = '>' });
        t.apply(.{ .print = ' ' });
        t.apply(.{ .control = .lf });
        t.apply(.{ .control = .cr });
    }

    const countNonDefault = struct {
        fn f(ring: *const RingBuffer) usize {
            const gm = @import("../../term/grid.zig");
            var n: usize = 0;
            for (0..ring.count) |r| {
                for (ring.getRow(r)) |cell| {
                    if (!gm.isDefaultCell(cell)) n += 1;
                }
            }
            return n;
        }
    }.f;

    const baseline = countNonDefault(&t.ring);

    // Oscillate 5 times
    for (0..5) |_| {
        try t.resize(24, 40);
        const c1 = countNonDefault(&t.ring);
        try std.testing.expect(c1 <= baseline);

        try t.resize(24, 80);
        const c2 = countNonDefault(&t.ring);
        try std.testing.expect(c2 <= baseline);
    }

    // Content should still be readable
    try std.testing.expectEqual(@as(u21, '~'), t.ring.getScreenCell(0, 0).char);
}
