const std = @import("std");
const helpers = @import("helpers.zig");
const Engine = @import("../../term/engine.zig").Engine;
const TerminalState = @import("../../term/state.zig").TerminalState;
const Color = @import("../../term/grid.zig").Color;
const expectSnapshot = helpers.expectSnapshot;

// ===========================================================================
// Alternate screen
// ===========================================================================

test "golden: alt screen preserves main buffer" {
    try expectSnapshot(2, 5,
        "MAIN" ++
        "\x1b[?1049h" ++
        "ALT" ++
        "\x1b[?1049l",
        "MAIN \n" ++
        "     \n");
}

test "golden: alt screen is cleared on each entry" {
    try expectSnapshot(2, 5,
        "\x1b[?1049h" ++
        "ALT" ++
        "\x1b[?1049l" ++
        "\x1b[?1049h",
        "     \n" ++
        "     \n");
}

test "golden: alt screen with ?47h variant" {
    try expectSnapshot(2, 5,
        "MAIN" ++
        "\x1b[?47h" ++
        "ALT" ++
        "\x1b[?47l",
        "MAIN \n" ++
        "     \n");
}

test "golden: alt screen with ?1047h variant" {
    try expectSnapshot(2, 5,
        "MAIN" ++
        "\x1b[?1047h" ++
        "ALT" ++
        "\x1b[?1047l",
        "MAIN \n" ++
        "     \n");
}

test "golden: entering alt twice is idempotent" {
    try expectSnapshot(2, 5,
        "MAIN" ++
        "\x1b[?1049h" ++
        "\x1b[?1049h" ++
        "ALT" ++
        "\x1b[?1049l",
        "MAIN \n" ++
        "     \n");
}

test "attr: cursor restored when leaving alt screen" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 3, 5);
    defer engine.deinit();

    engine.feed("\x1b[2;3H");
    try std.testing.expectEqual(@as(usize, 1), engine.state.cursor.row);
    try std.testing.expectEqual(@as(usize, 2), engine.state.cursor.col);

    engine.feed("\x1b[?1049h");
    try std.testing.expectEqual(@as(usize, 0), engine.state.cursor.row);
    try std.testing.expectEqual(@as(usize, 0), engine.state.cursor.col);

    engine.feed("\x1b[?1049l");
    try std.testing.expectEqual(@as(usize, 1), engine.state.cursor.row);
    try std.testing.expectEqual(@as(usize, 2), engine.state.cursor.col);
}

// ===========================================================================
// Cursor save / restore
// ===========================================================================

test "golden: DECSC/DECRC save and restore cursor" {
    try expectSnapshot(2, 5,
        "AB" ++
        "\x1b7" ++
        "\x1b[2;4H" ++
        "X" ++
        "\x1b8" ++
        "C",
        "ABC  \n" ++
        "   X \n");
}

test "golden: CSI s/u save and restore cursor" {
    try expectSnapshot(2, 5,
        "AB" ++
        "\x1b[s" ++
        "\x1b[2;4H" ++
        "X" ++
        "\x1b[u" ++
        "C",
        "ABC  \n" ++
        "   X \n");
}

test "attr: save/restore preserves pen attributes" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 5);
    defer engine.deinit();

    engine.feed("\x1b[31m");
    engine.feed("\x1b7");
    engine.feed("\x1b[0m");
    engine.feed("\x1b8");
    engine.feed("X");

    try std.testing.expectEqual(Color.red, engine.state.grid.getCell(0, 0).style.fg);
}

test "attr: saved cursor is per-buffer" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 3, 5);
    defer engine.deinit();

    engine.feed("\x1b[2;3H");
    engine.feed("\x1b7");

    engine.feed("\x1b[?1049h");
    engine.feed("\x1b[1;5H");
    engine.feed("\x1b7");

    engine.feed("\x1b[?1049l");
    engine.feed("\x1b8");

    try std.testing.expectEqual(@as(usize, 1), engine.state.cursor.row);
    try std.testing.expectEqual(@as(usize, 2), engine.state.cursor.col);
}

// ===========================================================================
// State unit tests for alt screen
// ===========================================================================

test "enter alt screen clears grid and resets cursor" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .print = 'X' });
    t.apply(.enter_alt_screen);

    try std.testing.expect(t.alt_active);
    try std.testing.expectEqual(@as(usize, 0), t.cursor.row);
    try std.testing.expectEqual(@as(usize, 0), t.cursor.col);
    try std.testing.expectEqual(@as(u21, ' '), t.grid.getCell(0, 0).char);
}

test "leave alt screen restores main buffer" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .print = 'M' });
    const saved_col = t.cursor.col;
    t.apply(.enter_alt_screen);
    t.apply(.{ .print = 'A' });
    t.apply(.leave_alt_screen);

    try std.testing.expect(!t.alt_active);
    try std.testing.expectEqual(@as(u21, 'M'), t.grid.getCell(0, 0).char);
    try std.testing.expectEqual(saved_col, t.cursor.col);
}

test "save and restore cursor" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 3, 4);
    defer t.deinit();

    t.cursor = .{ .row = 1, .col = 2 };
    t.pen = .{ .fg = Color.red };
    t.apply(.save_cursor);

    t.cursor = .{ .row = 0, .col = 0 };
    t.pen = .{};
    t.apply(.restore_cursor);

    try std.testing.expectEqual(@as(usize, 1), t.cursor.row);
    try std.testing.expectEqual(@as(usize, 2), t.cursor.col);
    try std.testing.expectEqual(Color.red, t.pen.fg);
}

// ===========================================================================
// Resize (with reflow)
// ===========================================================================

test "resize: grow preserves content" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .print = 'A' });
    t.apply(.{ .print = 'B' });

    try t.resize(4, 8);

    try std.testing.expectEqual(@as(usize, 4), t.grid.rows);
    try std.testing.expectEqual(@as(usize, 8), t.grid.cols);
    try std.testing.expectEqual(@as(u21, 'A'), t.grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), t.grid.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, ' '), t.grid.getCell(0, 4).char);
    try std.testing.expectEqual(@as(u21, ' '), t.grid.getCell(3, 0).char);
}

test "resize: shrink reflows content" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 4, 8);
    defer t.deinit();

    // Print "ABCD" — 4 chars at 8-col width, NOT a wrapped line
    t.apply(.{ .print = 'A' });
    t.apply(.{ .print = 'B' });
    t.apply(.{ .print = 'C' });
    t.apply(.{ .print = 'D' });

    // Move cursor below content (simulates prompt position in real usage)
    t.cursor.row = 1;
    t.cursor.col = 0;

    try t.resize(4, 3);

    try std.testing.expectEqual(@as(usize, 4), t.grid.rows);
    try std.testing.expectEqual(@as(usize, 3), t.grid.cols);
    // "ABCD" reflows: row 0 = "ABC" (wrapped), row 1 = "D"
    try std.testing.expectEqual(@as(u21, 'A'), t.grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), t.grid.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'C'), t.grid.getCell(0, 2).char);
    try std.testing.expect(t.grid.row_wrapped[0]);
    try std.testing.expectEqual(@as(u21, 'D'), t.grid.getCell(1, 0).char);
    try std.testing.expect(!t.grid.row_wrapped[1]);
}

test "resize: shrink then grow restores content" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 4, 8);
    defer t.deinit();

    t.apply(.{ .print = 'A' });
    t.apply(.{ .print = 'B' });
    t.apply(.{ .print = 'C' });
    t.apply(.{ .print = 'D' });
    t.apply(.{ .print = 'E' });
    t.apply(.{ .print = 'F' });

    // Move cursor below content (simulates prompt position)
    t.cursor.row = 1;
    t.cursor.col = 0;

    try t.resize(4, 3);
    try std.testing.expectEqual(@as(u21, 'D'), t.grid.getCell(1, 0).char);

    try t.resize(4, 8);
    try std.testing.expectEqual(@as(u21, 'A'), t.grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'F'), t.grid.getCell(0, 5).char);
    try std.testing.expectEqual(@as(u21, ' '), t.grid.getCell(1, 0).char);
}

test "resize: cursor mapped through reflow" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 4, 8);
    defer t.deinit();

    // Print 6 chars, cursor ends at (0, 6)
    t.apply(.{ .print = 'A' });
    t.apply(.{ .print = 'B' });
    t.apply(.{ .print = 'C' });
    t.apply(.{ .print = 'D' });
    t.apply(.{ .print = 'E' });
    t.apply(.{ .print = 'F' });
    try std.testing.expectEqual(@as(usize, 0), t.cursor.row);
    try std.testing.expectEqual(@as(usize, 6), t.cursor.col);

    try t.resize(4, 3);

    // Cursor was at offset 6 in logical line → row 2, col 0
    try std.testing.expectEqual(@as(usize, 2), t.cursor.row);
    try std.testing.expectEqual(@as(usize, 0), t.cursor.col);
}

test "resize: cursor clamped to new bounds" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 10, 20);
    defer t.deinit();

    t.cursor = .{ .row = 8, .col = 15 };

    try t.resize(5, 10);

    try std.testing.expect(t.cursor.row <= 4);
    try std.testing.expect(t.cursor.col <= 9);
}

test "resize: scroll region reset when invalid" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 10, 20);
    defer t.deinit();

    t.scroll_top = 2;
    t.scroll_bottom = 8;

    try t.resize(3, 20);

    try std.testing.expectEqual(@as(usize, 0), t.scroll_top);
    try std.testing.expectEqual(@as(usize, 2), t.scroll_bottom);
}

test "resize: saved cursor clamped" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 10, 20);
    defer t.deinit();

    t.cursor = .{ .row = 7, .col = 15 };
    t.apply(.save_cursor);

    try t.resize(5, 10);

    const saved = t.saved_cursor.?;
    try std.testing.expect(saved.cursor.row <= 4);
    try std.testing.expect(saved.cursor.col <= 9);
}

test "resize: both buffers resized" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 4, 8);
    defer t.deinit();

    t.apply(.{ .print = 'M' });
    t.apply(.enter_alt_screen);
    t.apply(.{ .print = 'A' });

    try t.resize(6, 12);

    try std.testing.expectEqual(@as(usize, 6), t.grid.rows);
    try std.testing.expectEqual(@as(usize, 12), t.grid.cols);
    try std.testing.expectEqual(@as(u21, 'A'), t.grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(usize, 6), t.inactive_grid.rows);
    try std.testing.expectEqual(@as(usize, 12), t.inactive_grid.cols);
    try std.testing.expectEqual(@as(u21, 'M'), t.inactive_grid.getCell(0, 0).char);
}

test "resize: wrap_next cleared" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .print = 'A' });
    t.apply(.{ .print = 'B' });
    t.apply(.{ .print = 'C' });
    t.apply(.{ .print = 'D' });
    try std.testing.expect(t.wrap_next);

    try t.resize(2, 8);

    try std.testing.expect(!t.wrap_next);
}

test "resize: same size is no-op" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 4, 8);
    defer t.deinit();

    t.apply(.{ .print = 'X' });
    const ptr_before = t.grid.cells.ptr;

    try t.resize(4, 8);

    try std.testing.expectEqual(ptr_before, t.grid.cells.ptr);
    try std.testing.expectEqual(@as(u21, 'X'), t.grid.getCell(0, 0).char);
}

test "resize: marks all rows dirty" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 4, 8);
    defer t.deinit();

    t.dirty.clear();

    try t.resize(6, 10);

    for (0..6) |row| {
        try std.testing.expect(t.dirty.isDirty(row));
    }
}

// ===========================================================================
// Styled text reflow
// ===========================================================================

test "resize: styled text reflows correctly on shrink" {
    const alloc = std.testing.allocator;
    const Grid = @import("../../term/grid.zig");
    const Style = Grid.Style;
    var t = try TerminalState.init(alloc, 4, 10);
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
    try std.testing.expectEqual(@as(u21, 'A'), t.grid.getCell(0, 0).char);
    try std.testing.expectEqual(cyan, t.grid.getCell(0, 0).style);
    try std.testing.expectEqual(@as(u21, 'D'), t.grid.getCell(0, 3).char);
    try std.testing.expect(t.grid.row_wrapped[0]);
    try std.testing.expectEqual(@as(u21, 'E'), t.grid.getCell(1, 0).char);
    try std.testing.expectEqual(cyan, t.grid.getCell(1, 0).style);
    try std.testing.expectEqual(@as(u21, 'F'), t.grid.getCell(1, 1).char);
}

test "resize: fg-only styled trailing spaces are ignored for content_len" {
    // Spaces with only foreground styling (default bg) are invisible
    // and must NOT inflate content_len — otherwise prompts like
    // Starship cascade rightward on repeated shrinks.
    const alloc = std.testing.allocator;
    const Grid = @import("../../term/grid.zig");
    const Style = Grid.Style;
    var g = try Grid.Grid.init(alloc, 4, 10);
    defer g.deinit();

    const magenta_fg = Style{ .fg = .{ .ansi = 5 } };

    // "AB" at cols 0-1, then fg-only styled spaces at cols 2-5
    g.setCell(0, 0, .{ .char = 'A' });
    g.setCell(0, 1, .{ .char = 'B' });
    g.setCell(0, 2, .{ .char = ' ', .style = magenta_fg });
    g.setCell(0, 3, .{ .char = ' ', .style = magenta_fg });
    g.setCell(0, 4, .{ .char = ' ', .style = magenta_fg });
    g.setCell(0, 5, .{ .char = ' ', .style = magenta_fg });

    try g.resize(4, 3, null, null, null);

    // content_len = 2 (only "AB" counts; fg-only spaces are ignored).
    // At 3 cols: 2 chars → 1 row, no wrapping.
    try std.testing.expectEqual(@as(u21, 'A'), g.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), g.getCell(0, 1).char);
    try std.testing.expect(!g.row_wrapped[0]);
    try std.testing.expectEqual(@as(u21, ' '), g.getCell(1, 0).char);
}

test "resize: bg-styled trailing spaces ARE counted for content_len" {
    // Spaces with a non-default background are visible (colored block)
    // and must count as content.
    const alloc = std.testing.allocator;
    const Grid = @import("../../term/grid.zig");
    const Style = Grid.Style;
    var g = try Grid.Grid.init(alloc, 4, 10);
    defer g.deinit();

    const red_bg = Style{ .bg = .{ .ansi = 1 } };

    // "AB" at cols 0-1, then bg-styled spaces at cols 2-5
    g.setCell(0, 0, .{ .char = 'A' });
    g.setCell(0, 1, .{ .char = 'B' });
    g.setCell(0, 2, .{ .char = ' ', .style = red_bg });
    g.setCell(0, 3, .{ .char = ' ', .style = red_bg });
    g.setCell(0, 4, .{ .char = ' ', .style = red_bg });
    g.setCell(0, 5, .{ .char = ' ', .style = red_bg });

    try g.resize(4, 3, null, null, null);

    // content_len = 6 (bg-styled spaces are visible content).
    // At 3 cols: ceil(6/3) = 2 rows.
    try std.testing.expectEqual(@as(u21, 'A'), g.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), g.getCell(0, 1).char);
    try std.testing.expect(g.row_wrapped[0]);
    try std.testing.expectEqual(red_bg, g.getCell(1, 0).style);
}

test "resize: prompt-like styled gap inflates content_len" {
    // Simulates right-aligned prompt: left text (cols 0-3), gap (4-6 default),
    // right text (cols 7-9 styled). content_len = 10 (full row).
    const alloc = std.testing.allocator;
    const Grid = @import("../../term/grid.zig");
    const Style = Grid.Style;
    var g = try Grid.Grid.init(alloc, 4, 10);
    defer g.deinit();

    const cyan = Style{ .fg = .{ .ansi = 6 } };
    const magenta = Style{ .fg = .{ .ansi = 5 } };

    // Left: "DIR" in cyan
    g.setCell(0, 0, .{ .char = 'D', .style = cyan });
    g.setCell(0, 1, .{ .char = 'I', .style = cyan });
    g.setCell(0, 2, .{ .char = 'R', .style = cyan });
    // Gap: cols 3-6 are default (unwritten, simulates cursor jump)
    // Right: "git" in magenta
    g.setCell(0, 7, .{ .char = 'g', .style = magenta });
    g.setCell(0, 8, .{ .char = 'i', .style = magenta });
    g.setCell(0, 9, .{ .char = 't', .style = magenta });

    try g.resize(4, 5, null, null, null);

    // content_len = 10 (last non-default at col 9).
    // At 5 cols: 10/5 = 2 rows
    try std.testing.expectEqual(@as(u21, 'D'), g.getCell(0, 0).char);
    try std.testing.expectEqual(cyan, g.getCell(0, 0).style);
    try std.testing.expect(g.row_wrapped[0]);
    // Row 1: cols 5-9 of original → default spaces + "git"
    try std.testing.expectEqual(@as(u21, ' '), g.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), g.getCell(1, 1).char);
    try std.testing.expectEqual(@as(u21, 'g'), g.getCell(1, 2).char);
    try std.testing.expectEqual(magenta, g.getCell(1, 2).style);
}

test "resize: rapid shrink cycles with styled prompt don't cascade" {
    // Simulates the real-world scenario: colored prompt text, multiple
    // shrink cycles.  Counts non-default cells after each resize to
    // verify that content doesn't duplicate (the cascading bug creates
    // extra copies of the prompt text, inflating the cell count).
    const alloc = std.testing.allocator;
    const Grid = @import("../../term/grid.zig");
    const Style = Grid.Style;
    var t = try TerminalState.init(alloc, 24, 40);
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

    // Helper: count non-default cells in the grid
    const countNonDefault = struct {
        fn f(grid: *Grid.Grid) usize {
            var n: usize = 0;
            for (0..grid.rows * grid.cols) |i| {
                if (!Grid.isDefaultCell(grid.cells[i])) n += 1;
            }
            return n;
        }
    }.f;

    // --- Cycle 1: 40 → 20 ---
    try t.resize(24, 20);
    try std.testing.expect(countNonDefault(&t.grid) <= max_content);

    // --- Cycle 2: 20 → 10 ---
    try t.resize(24, 10);
    try std.testing.expect(countNonDefault(&t.grid) <= max_content);

    // --- Cycle 3: 10 → 5 ---
    try t.resize(24, 5);
    try std.testing.expect(countNonDefault(&t.grid) <= max_content);

    // --- Cycle 4: 5 → 3 ---
    try t.resize(24, 3);
    try std.testing.expect(countNonDefault(&t.grid) <= max_content);

    // --- Grow back: 3 → 40 ---
    try t.resize(24, 40);
    try std.testing.expect(countNonDefault(&t.grid) <= max_content);
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
    var t = try TerminalState.init(alloc, 24, 40);
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

    const countNonDefault = struct {
        fn f(grid: *Grid.Grid) usize {
            var n: usize = 0;
            for (0..grid.rows * grid.cols) |i| {
                if (!Grid.isDefaultCell(grid.cells[i])) n += 1;
            }
            return n;
        }
    }.f;

    const initial_count = countNonDefault(&t.grid);

    // --- Shrink cycles ---
    try t.resize(24, 20);
    var count = countNonDefault(&t.grid);
    try std.testing.expect(count <= initial_count);

    try t.resize(24, 10);
    count = countNonDefault(&t.grid);
    try std.testing.expect(count <= initial_count);

    try t.resize(24, 5);
    count = countNonDefault(&t.grid);
    try std.testing.expect(count <= initial_count);

    // Grow back
    try t.resize(24, 40);
    count = countNonDefault(&t.grid);
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
    var t = try TerminalState.init(alloc, 4, 40);
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
    try std.testing.expectEqual(@as(u21, '~'), t.grid.getCell(0, 0).char);
    try std.testing.expectEqual(cyan, t.grid.getCell(0, 0).style);
    try std.testing.expectEqual(@as(u21, 'j'), t.grid.getCell(0, 5).char);

    // No wrapping on the prompt row — line fits after stripping
    try std.testing.expect(!t.grid.row_wrapped[0]);

    // Right-aligned "main" text should be gone (cells cleared)
    try std.testing.expectEqual(@as(u21, ' '), t.grid.getCell(0, 6).char);
    try std.testing.expectEqual(Grid.Style{}, t.grid.getCell(0, 6).style);
}

test "resize: auto-wrapped line rejoins on grow and re-wraps on shrink" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 4, 4);
    defer t.deinit();

    // Print 5 chars to trigger auto-wrap: "ABCD" on row 0, "E" on row 1
    t.apply(.{ .print = 'A' });
    t.apply(.{ .print = 'B' });
    t.apply(.{ .print = 'C' });
    t.apply(.{ .print = 'D' });
    t.apply(.{ .print = 'E' });
    try std.testing.expect(t.grid.row_wrapped[0]);
    try std.testing.expectEqual(@as(u21, 'E'), t.grid.getCell(1, 0).char);

    // Grow to 8 cols — auto-wrapped "ABCDE" rejoins into one row.
    try t.resize(4, 8);
    try std.testing.expectEqual(@as(u21, 'A'), t.grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), t.grid.getCell(0, 3).char);
    try std.testing.expectEqual(@as(u21, 'E'), t.grid.getCell(0, 4).char);
    try std.testing.expect(!t.grid.row_wrapped[0]);

    // Shrink to 2 cols — "ABCDE" wraps into 3 rows (one logical line)
    try t.resize(4, 2);
    try std.testing.expectEqual(@as(u21, 'A'), t.grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), t.grid.getCell(0, 1).char);
    try std.testing.expect(t.grid.row_wrapped[0]);
    try std.testing.expectEqual(@as(u21, 'C'), t.grid.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), t.grid.getCell(1, 1).char);
    try std.testing.expectEqual(@as(u21, 'E'), t.grid.getCell(2, 0).char);
}
