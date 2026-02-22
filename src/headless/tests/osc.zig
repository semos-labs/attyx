const std = @import("std");
const helpers = @import("helpers.zig");
const Engine = @import("../../term/engine.zig").Engine;
const Parser = @import("../../term/parser.zig").Parser;
const TerminalState = @import("../../term/state.zig").TerminalState;
const Color = @import("../../term/grid.zig").Color;
const expectSnapshot = helpers.expectSnapshot;

// ===========================================================================
// OSC hyperlinks
// ===========================================================================

test "attr: OSC 8 hyperlink attaches link_id to cells" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 10);
    defer engine.deinit();

    engine.feed("\x1b]8;;https://example.com\x1b\\");
    engine.feed("Hi");
    engine.feed("\x1b]8;;\x1b\\");
    engine.feed("No");

    const cell_h = engine.state.grid.getCell(0, 0);
    const cell_i = engine.state.grid.getCell(0, 1);
    const cell_n = engine.state.grid.getCell(0, 2);

    try std.testing.expect(cell_h.link_id != 0);
    try std.testing.expect(cell_i.link_id != 0);
    try std.testing.expectEqual(cell_h.link_id, cell_i.link_id);
    try std.testing.expectEqual(@as(u32, 0), cell_n.link_id);
    try std.testing.expectEqualStrings(
        "https://example.com",
        engine.state.getLinkUri(cell_h.link_id).?,
    );
}

test "attr: multiple OSC 8 links get different IDs" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 10);
    defer engine.deinit();

    engine.feed("\x1b]8;;https://a.com\x1b\\A");
    engine.feed("\x1b]8;;\x1b\\");
    engine.feed("\x1b]8;;https://b.com\x1b\\B");
    engine.feed("\x1b]8;;\x1b\\");

    const cell_a = engine.state.grid.getCell(0, 0);
    const cell_b = engine.state.grid.getCell(0, 1);

    try std.testing.expect(cell_a.link_id != cell_b.link_id);
    try std.testing.expectEqualStrings("https://a.com", engine.state.getLinkUri(cell_a.link_id).?);
    try std.testing.expectEqualStrings("https://b.com", engine.state.getLinkUri(cell_b.link_id).?);
}

test "attr: OSC 8 with BEL terminator" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 10);
    defer engine.deinit();

    engine.feed("\x1b]8;;https://bel.com\x07X");
    engine.feed("\x1b]8;;\x07");

    const cell = engine.state.grid.getCell(0, 0);
    try std.testing.expect(cell.link_id != 0);
    try std.testing.expectEqualStrings("https://bel.com", engine.state.getLinkUri(cell.link_id).?);
}

test "attr: OSC 8 survives chunked input" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 10);
    defer engine.deinit();

    engine.feed("\x1b]8;;https://examp");
    engine.feed("le.com\x1b");
    engine.feed("\\");
    engine.feed("X");
    engine.feed("\x1b]8;;\x1b\\");

    const cell = engine.state.grid.getCell(0, 0);
    try std.testing.expect(cell.link_id != 0);
    try std.testing.expectEqualStrings("https://example.com", engine.state.getLinkUri(cell.link_id).?);
}

test "attr: OSC overflow is safely ignored" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 10);
    defer engine.deinit();

    engine.feed("\x1b]8;;");
    var filler: [Parser.osc_buf_size + 100]u8 = undefined;
    @memset(&filler, 'x');
    engine.feed(&filler);
    engine.feed("\x07");
    engine.feed("A");

    try std.testing.expectEqual(@as(u8, 'A'), engine.state.grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u32, 0), engine.state.grid.getCell(0, 0).link_id);
}

test "golden: OSC sequences don't affect character output" {
    try expectSnapshot(1, 6,
        "\x1b]8;;https://x.com\x07AB\x1b]8;;\x07CD",
        "ABCD  \n");
}

// ===========================================================================
// OSC title
// ===========================================================================

test "attr: OSC 2 sets terminal title" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 10);
    defer engine.deinit();

    engine.feed("\x1b]2;MyTitle\x07");
    try std.testing.expectEqualStrings("MyTitle", engine.state.title.?);
}

test "attr: OSC 0 also sets terminal title" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 10);
    defer engine.deinit();

    engine.feed("\x1b]0;WindowTitle\x1b\\");
    try std.testing.expectEqualStrings("WindowTitle", engine.state.title.?);
}

test "attr: title is replaced on subsequent OSC 2" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 10);
    defer engine.deinit();

    engine.feed("\x1b]2;First\x07");
    engine.feed("\x1b]2;Second\x07");
    try std.testing.expectEqualStrings("Second", engine.state.title.?);
}

// ===========================================================================
// State unit tests for hyperlinks and title
// ===========================================================================

test "printed cells carry pen_link_id" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.pen_link_id = 42;
    t.apply(.{ .print = 'L' });
    try std.testing.expectEqual(@as(u32, 42), t.grid.getCell(0, 0).link_id);
}

test "startHyperlink allocates URI and sets pen_link_id" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .hyperlink_start = "https://example.com" });
    try std.testing.expect(t.pen_link_id != 0);
    try std.testing.expectEqualStrings("https://example.com", t.getLinkUri(t.pen_link_id).?);
}

test "endHyperlink clears pen_link_id" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .hyperlink_start = "https://example.com" });
    t.apply(.hyperlink_end);
    try std.testing.expectEqual(@as(u32, 0), t.pen_link_id);
}

test "setTitle stores and replaces title" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .set_title = "Hello" });
    try std.testing.expectEqualStrings("Hello", t.title.?);

    t.apply(.{ .set_title = "World" });
    try std.testing.expectEqualStrings("World", t.title.?);
}
