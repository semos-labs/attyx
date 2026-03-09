const std = @import("std");
const Engine = @import("../../term/engine.zig").Engine;
const Color = @import("../../term/grid.zig").Color;

// ===========================================================================
// Extended SGR — 256-color + truecolor + bright
// ===========================================================================

test "attr: 256-color foreground (38;5;n)" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 5, 100);
    defer engine.deinit();

    engine.feed("\x1b[38;5;196mA");
    const cell = engine.state.ring.getScreenCell(0, 0);
    try std.testing.expectEqual(@as(u21, 'A'), cell.char);
    try std.testing.expectEqual(Color{ .palette = 196 }, cell.style.fg);
}

test "attr: 256-color background (48;5;n)" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 5, 100);
    defer engine.deinit();

    engine.feed("\x1b[48;5;25mB");
    const cell = engine.state.ring.getScreenCell(0, 0);
    try std.testing.expectEqual(@as(u21, 'B'), cell.char);
    try std.testing.expectEqual(Color{ .palette = 25 }, cell.style.bg);
}

test "attr: truecolor foreground (38;2;r;g;b)" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 5, 100);
    defer engine.deinit();

    engine.feed("\x1b[38;2;1;2;3mC");
    const cell = engine.state.ring.getScreenCell(0, 0);
    try std.testing.expectEqual(@as(u21, 'C'), cell.char);
    try std.testing.expectEqual(Color{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, cell.style.fg);
}

test "attr: truecolor background (48;2;r;g;b)" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 5, 100);
    defer engine.deinit();

    engine.feed("\x1b[48;2;9;8;7mD");
    const cell = engine.state.ring.getScreenCell(0, 0);
    try std.testing.expectEqual(@as(u21, 'D'), cell.char);
    try std.testing.expectEqual(Color{ .rgb = .{ .r = 9, .g = 8, .b = 7 } }, cell.style.bg);
}

test "attr: SGR 39 resets truecolor fg to default" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 5, 100);
    defer engine.deinit();

    engine.feed("\x1b[38;2;1;2;3mX\x1b[39mY");
    try std.testing.expectEqual(
        Color{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
        engine.state.ring.getScreenCell(0, 0).style.fg,
    );
    try std.testing.expectEqual(Color.default, engine.state.ring.getScreenCell(0, 1).style.fg);
}

test "attr: SGR 0 resets 256-color bg and all flags" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 5, 100);
    defer engine.deinit();

    engine.feed("\x1b[1;48;5;25mX\x1b[0mY");
    const cell_x = engine.state.ring.getScreenCell(0, 0);
    try std.testing.expectEqual(Color{ .palette = 25 }, cell_x.style.bg);
    try std.testing.expect(cell_x.style.bold);

    const cell_y = engine.state.ring.getScreenCell(0, 1);
    try std.testing.expectEqual(Color.default, cell_y.style.fg);
    try std.testing.expectEqual(Color.default, cell_y.style.bg);
    try std.testing.expect(!cell_y.style.bold);
}

test "attr: combined 256-color fg + truecolor bg in one sequence" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 5, 100);
    defer engine.deinit();

    engine.feed("\x1b[38;5;196;48;2;10;20;30mZ");
    const cell = engine.state.ring.getScreenCell(0, 0);
    try std.testing.expectEqual(Color{ .palette = 196 }, cell.style.fg);
    try std.testing.expectEqual(Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } }, cell.style.bg);
}

test "attr: bright foreground colors (90–97)" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 5, 100);
    defer engine.deinit();

    engine.feed("\x1b[91mA\x1b[97mB");
    try std.testing.expectEqual(Color{ .ansi = 9 }, engine.state.ring.getScreenCell(0, 0).style.fg);
    try std.testing.expectEqual(Color{ .ansi = 15 }, engine.state.ring.getScreenCell(0, 1).style.fg);
}

test "attr: bright background colors (100–107)" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 5, 100);
    defer engine.deinit();

    engine.feed("\x1b[101mA\x1b[107mB");
    try std.testing.expectEqual(Color{ .ansi = 9 }, engine.state.ring.getScreenCell(0, 0).style.bg);
    try std.testing.expectEqual(Color{ .ansi = 15 }, engine.state.ring.getScreenCell(0, 1).style.bg);
}

test "attr: truncated 38;5 is gracefully ignored" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 5, 100);
    defer engine.deinit();

    engine.feed("\x1b[38;5mA");
    try std.testing.expectEqual(Color.default, engine.state.ring.getScreenCell(0, 0).style.fg);
}

test "attr: truncated 38;2;r;g is gracefully ignored" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 5, 100);
    defer engine.deinit();

    engine.feed("\x1b[38;2;1;2mA");
    try std.testing.expectEqual(Color.default, engine.state.ring.getScreenCell(0, 0).style.fg);
}

test "attr: truecolor fg survives chunked input" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 5, 100);
    defer engine.deinit();

    engine.feed("\x1b[38;2;1;");
    engine.feed("2;3mZ");
    const cell = engine.state.ring.getScreenCell(0, 0);
    try std.testing.expectEqual(@as(u21, 'Z'), cell.char);
    try std.testing.expectEqual(Color{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, cell.style.fg);
}

// ===========================================================================
// SGR 7 (reverse video) and attribute reset codes
// ===========================================================================

test "attr: SGR 7 sets reverse flag" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 5, 100);
    defer engine.deinit();

    engine.feed("\x1b[7mA");
    const cell = engine.state.ring.getScreenCell(0, 0);
    try std.testing.expect(cell.style.reverse);
}

test "attr: SGR 27 clears reverse flag" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 5, 100);
    defer engine.deinit();

    engine.feed("\x1b[7mA\x1b[27mB");
    try std.testing.expect(engine.state.ring.getScreenCell(0, 0).style.reverse);
    try std.testing.expect(!engine.state.ring.getScreenCell(0, 1).style.reverse);
}

test "attr: SGR 0 resets reverse flag" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 5, 100);
    defer engine.deinit();

    engine.feed("\x1b[7mA\x1b[0mB");
    try std.testing.expect(engine.state.ring.getScreenCell(0, 0).style.reverse);
    try std.testing.expect(!engine.state.ring.getScreenCell(0, 1).style.reverse);
}

test "attr: SGR 22 clears bold, SGR 24 clears underline" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 5, 100);
    defer engine.deinit();

    engine.feed("\x1b[1;4mA\x1b[22mB\x1b[24mC");
    const a = engine.state.ring.getScreenCell(0, 0);
    try std.testing.expect(a.style.bold);
    try std.testing.expect(a.style.underline);

    const b = engine.state.ring.getScreenCell(0, 1);
    try std.testing.expect(!b.style.bold);
    try std.testing.expect(b.style.underline);

    const cell_c = engine.state.ring.getScreenCell(0, 2);
    try std.testing.expect(!cell_c.style.bold);
    try std.testing.expect(!cell_c.style.underline);
}

test "attr: save/restore also captures scroll region" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 4, 100);
    defer engine.deinit();

    engine.feed("\x1b[2;4r");
    engine.feed("\x1b7");

    engine.feed("\x1b[r");
    try std.testing.expectEqual(@as(usize, 0), engine.state.scroll_top);
    try std.testing.expectEqual(@as(usize, 4), engine.state.scroll_bottom);

    engine.feed("\x1b8");
    try std.testing.expectEqual(@as(usize, 1), engine.state.scroll_top);
    try std.testing.expectEqual(@as(usize, 3), engine.state.scroll_bottom);
}
