const std = @import("std");
const Engine = @import("../../term/engine.zig").Engine;
const CursorShape = @import("../../term/actions.zig").CursorShape;

// ===========================================================================
// Device Status Report (DSR) / Device Attributes (DA)
// ===========================================================================

test "CSI 6 n: cursor position report" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 10, 20, 100);
    defer engine.deinit();

    engine.feed("\x1b[5;12H");
    engine.feed("\x1b[6n");

    const resp = engine.state.drainResponse();
    try std.testing.expect(resp != null);
    try std.testing.expectEqualStrings("\x1b[5;12R", resp.?);
}

test "CSI 6 n: cursor at origin" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 5, 100);
    defer engine.deinit();

    engine.feed("\x1b[6n");

    const resp = engine.state.drainResponse();
    try std.testing.expect(resp != null);
    try std.testing.expectEqualStrings("\x1b[1;1R", resp.?);
}

test "CSI 5 n: device status OK" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 5, 100);
    defer engine.deinit();

    engine.feed("\x1b[5n");

    const resp = engine.state.drainResponse();
    try std.testing.expect(resp != null);
    try std.testing.expectEqualStrings("\x1b[0n", resp.?);
}

test "CSI c: primary device attributes" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 5, 100);
    defer engine.deinit();

    engine.feed("\x1b[c");

    const resp = engine.state.drainResponse();
    try std.testing.expect(resp != null);
    try std.testing.expectEqualStrings("\x1b[?62c", resp.?);
}

test "CSI 0 c: primary device attributes explicit param" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 5, 100);
    defer engine.deinit();

    engine.feed("\x1b[0c");

    const resp = engine.state.drainResponse();
    try std.testing.expect(resp != null);
    try std.testing.expectEqualStrings("\x1b[?62c", resp.?);
}

test "CSI > c: secondary device attributes" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 5, 100);
    defer engine.deinit();

    engine.feed("\x1b[>c");

    const resp = engine.state.drainResponse();
    try std.testing.expect(resp != null);
    try std.testing.expectEqualStrings("\x1b[>0;10;1c", resp.?);
}

test "CSI > 0 c: secondary device attributes explicit param" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 5, 100);
    defer engine.deinit();

    engine.feed("\x1b[>0c");

    const resp = engine.state.drainResponse();
    try std.testing.expect(resp != null);
    try std.testing.expectEqualStrings("\x1b[>0;10;1c", resp.?);
}

test "drainResponse clears buffer" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 5, 100);
    defer engine.deinit();

    engine.feed("\x1b[6n");
    _ = engine.state.drainResponse();

    try std.testing.expectEqual(@as(?[]const u8, null), engine.state.drainResponse());
}

test "multiple DSR responses accumulate" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 5, 100);
    defer engine.deinit();

    engine.feed("\x1b[5n\x1b[6n");

    const resp = engine.state.drainResponse();
    try std.testing.expect(resp != null);
    try std.testing.expectEqualStrings("\x1b[0n\x1b[1;1R", resp.?);
}

test "tmux passthrough with inner OSC hyperlink is silently consumed" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 40, 100);
    defer engine.deinit();

    // Simulate: "AB" then tmux passthrough wrapping OSC 8 hyperlink
    // (inner ESCs doubled, inner OSC terminated by BEL), then "CD".
    // Only "ABCD" should appear on screen — the passthrough must be
    // fully consumed without leaking "Ptmux;", "]", URL bytes, etc.
    engine.feed("AB" ++
        "\x1bPtmux;\x1b\x1b]8;;https://example.com\x07\x1b\\" ++
        "CD");

    try std.testing.expectEqual(@as(u21, 'A'), engine.state.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), engine.state.ring.getScreenCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'C'), engine.state.ring.getScreenCell(0, 2).char);
    try std.testing.expectEqual(@as(u21, 'D'), engine.state.ring.getScreenCell(0, 3).char);
    try std.testing.expectEqual(@as(u21, ' '), engine.state.ring.getScreenCell(0, 4).char);
}

test "C1 DCS (0x90) payload is silently consumed" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 20, 100);
    defer engine.deinit();

    // 8-bit DCS: \x90 payload \x9C (C1 ST).  Nothing should print.
    engine.feed("X" ++ "\x90" ++ "qpayload" ++ "\x9C" ++ "Y");

    try std.testing.expectEqual(@as(u21, 'X'), engine.state.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'Y'), engine.state.ring.getScreenCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, ' '), engine.state.ring.getScreenCell(0, 2).char);
}

test "APC Kitty graphics payload is silently consumed" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 40, 100);
    defer engine.deinit();

    // ESC _ G ... ESC \  (Kitty graphics protocol)
    engine.feed("A" ++ "\x1b_Ga=T,f=24,s=1,v=1;AAAA\x1b\\" ++ "B");

    try std.testing.expectEqual(@as(u21, 'A'), engine.state.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), engine.state.ring.getScreenCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, ' '), engine.state.ring.getScreenCell(0, 2).char);
}

// ===========================================================================
// DECSCUSR — cursor shape
// ===========================================================================

test "DECSCUSR: CSI 2 SP q sets steady block" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 10, 100);
    defer engine.deinit();

    try std.testing.expectEqual(CursorShape.blinking_block, engine.state.cursor_shape);
    engine.feed("\x1b[2 q");
    try std.testing.expectEqual(CursorShape.steady_block, engine.state.cursor_shape);
}

test "DECSCUSR: CSI 5 SP q sets blinking bar" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 10, 100);
    defer engine.deinit();

    engine.feed("\x1b[5 q");
    try std.testing.expectEqual(CursorShape.blinking_bar, engine.state.cursor_shape);
}

test "DECSCUSR: CSI 0 SP q resets to blinking block" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 10, 100);
    defer engine.deinit();

    engine.feed("\x1b[6 q");
    try std.testing.expectEqual(CursorShape.steady_bar, engine.state.cursor_shape);
    engine.feed("\x1b[0 q");
    try std.testing.expectEqual(CursorShape.blinking_block, engine.state.cursor_shape);
}

test "DECSCUSR: CSI 3 SP q sets blinking underline" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 10, 100);
    defer engine.deinit();

    engine.feed("\x1b[3 q");
    try std.testing.expectEqual(CursorShape.blinking_underline, engine.state.cursor_shape);
}

test "DECSCUSR: CSI 4 SP q sets steady underline" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 10, 100);
    defer engine.deinit();

    engine.feed("\x1b[4 q");
    try std.testing.expectEqual(CursorShape.steady_underline, engine.state.cursor_shape);
}

// ===========================================================================
// DEC mode 25 — cursor visibility
// ===========================================================================

test "DEC mode 25: CSI ?25l hides cursor" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 10, 100);
    defer engine.deinit();

    try std.testing.expect(engine.state.cursor_visible);
    engine.feed("\x1b[?25l");
    try std.testing.expect(!engine.state.cursor_visible);
}

test "DEC mode 25: CSI ?25h shows cursor" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 10, 100);
    defer engine.deinit();

    engine.feed("\x1b[?25l");
    try std.testing.expect(!engine.state.cursor_visible);
    engine.feed("\x1b[?25h");
    try std.testing.expect(engine.state.cursor_visible);
}

// ===========================================================================
// Combined: DECSCUSR + mode 25
// ===========================================================================

test "cursor shape + visibility combined" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 10, 100);
    defer engine.deinit();

    engine.feed("\x1b[5 q");
    try std.testing.expectEqual(CursorShape.blinking_bar, engine.state.cursor_shape);
    try std.testing.expect(engine.state.cursor_visible);

    engine.feed("\x1b[?25l");
    try std.testing.expect(!engine.state.cursor_visible);
    try std.testing.expectEqual(CursorShape.blinking_bar, engine.state.cursor_shape);

    engine.feed("\x1b[2 q");
    try std.testing.expectEqual(CursorShape.steady_block, engine.state.cursor_shape);
    try std.testing.expect(!engine.state.cursor_visible);

    engine.feed("\x1b[?25h");
    try std.testing.expect(engine.state.cursor_visible);
    try std.testing.expectEqual(CursorShape.steady_block, engine.state.cursor_shape);
}

test "cursor shape persists across alt screen switch" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 10, 100);
    defer engine.deinit();

    engine.feed("\x1b[4 q");
    try std.testing.expectEqual(CursorShape.steady_underline, engine.state.cursor_shape);

    engine.feed("\x1b[?1049h");
    try std.testing.expectEqual(CursorShape.steady_underline, engine.state.cursor_shape);

    engine.feed("\x1b[6 q");
    try std.testing.expectEqual(CursorShape.steady_bar, engine.state.cursor_shape);

    engine.feed("\x1b[?1049l");
    try std.testing.expectEqual(CursorShape.steady_bar, engine.state.cursor_shape);
}
