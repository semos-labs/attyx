const std = @import("std");
const Engine = @import("../../term/engine.zig").Engine;
const input_mod = @import("../../term/input.zig");
const MouseTrackingMode = @import("../../term/actions.zig").MouseTrackingMode;

// ===========================================================================
// Bracketed paste toggling
// ===========================================================================

test "attr: CSI ?2004h enables bracketed paste" {
    var engine = try Engine.init(std.testing.allocator, 2, 4);
    defer engine.deinit();
    try std.testing.expect(!engine.state.bracketed_paste);
    engine.feed("\x1b[?2004h");
    try std.testing.expect(engine.state.bracketed_paste);
}

test "attr: CSI ?2004l disables bracketed paste" {
    var engine = try Engine.init(std.testing.allocator, 2, 4);
    defer engine.deinit();
    engine.feed("\x1b[?2004h");
    try std.testing.expect(engine.state.bracketed_paste);
    engine.feed("\x1b[?2004l");
    try std.testing.expect(!engine.state.bracketed_paste);
}

// ===========================================================================
// Mouse tracking mode toggling
// ===========================================================================

test "attr: CSI ?1000h sets x10 mouse tracking" {
    var engine = try Engine.init(std.testing.allocator, 2, 4);
    defer engine.deinit();
    try std.testing.expectEqual(MouseTrackingMode.off, engine.state.mouse_tracking);
    engine.feed("\x1b[?1000h");
    try std.testing.expectEqual(MouseTrackingMode.x10, engine.state.mouse_tracking);
}

test "attr: CSI ?1002h sets button_event tracking" {
    var engine = try Engine.init(std.testing.allocator, 2, 4);
    defer engine.deinit();
    engine.feed("\x1b[?1002h");
    try std.testing.expectEqual(MouseTrackingMode.button_event, engine.state.mouse_tracking);
}

test "attr: CSI ?1003h sets any_event tracking" {
    var engine = try Engine.init(std.testing.allocator, 2, 4);
    defer engine.deinit();
    engine.feed("\x1b[?1003h");
    try std.testing.expectEqual(MouseTrackingMode.any_event, engine.state.mouse_tracking);
}

test "attr: disabling active mouse mode falls back to off" {
    var engine = try Engine.init(std.testing.allocator, 2, 4);
    defer engine.deinit();
    engine.feed("\x1b[?1003h");
    try std.testing.expectEqual(MouseTrackingMode.any_event, engine.state.mouse_tracking);
    engine.feed("\x1b[?1003l");
    try std.testing.expectEqual(MouseTrackingMode.off, engine.state.mouse_tracking);
}

test "attr: disabling inactive mouse mode is a no-op" {
    var engine = try Engine.init(std.testing.allocator, 2, 4);
    defer engine.deinit();
    engine.feed("\x1b[?1003h");
    engine.feed("\x1b[?1000l");
    try std.testing.expectEqual(MouseTrackingMode.any_event, engine.state.mouse_tracking);
}

test "attr: enabling new mouse mode overrides previous" {
    var engine = try Engine.init(std.testing.allocator, 2, 4);
    defer engine.deinit();
    engine.feed("\x1b[?1000h");
    try std.testing.expectEqual(MouseTrackingMode.x10, engine.state.mouse_tracking);
    engine.feed("\x1b[?1003h");
    try std.testing.expectEqual(MouseTrackingMode.any_event, engine.state.mouse_tracking);
}

// ===========================================================================
// Mouse SGR toggle
// ===========================================================================

test "attr: CSI ?1006h enables SGR mouse" {
    var engine = try Engine.init(std.testing.allocator, 2, 4);
    defer engine.deinit();
    try std.testing.expect(!engine.state.mouse_sgr);
    engine.feed("\x1b[?1006h");
    try std.testing.expect(engine.state.mouse_sgr);
}

test "attr: CSI ?1006l disables SGR mouse" {
    var engine = try Engine.init(std.testing.allocator, 2, 4);
    defer engine.deinit();
    engine.feed("\x1b[?1006h");
    engine.feed("\x1b[?1006l");
    try std.testing.expect(!engine.state.mouse_sgr);
}

// ===========================================================================
// Compound DEC private mode sequence
// ===========================================================================

test "attr: compound CSI ?1000;1006h enables both" {
    var engine = try Engine.init(std.testing.allocator, 2, 4);
    defer engine.deinit();
    engine.feed("\x1b[?1000;1006h");
    try std.testing.expectEqual(MouseTrackingMode.x10, engine.state.mouse_tracking);
    try std.testing.expect(engine.state.mouse_sgr);
}

test "attr: compound CSI ?1000;1006l disables both" {
    var engine = try Engine.init(std.testing.allocator, 2, 4);
    defer engine.deinit();
    engine.feed("\x1b[?1000;1006h");
    engine.feed("\x1b[?1000;1006l");
    try std.testing.expectEqual(MouseTrackingMode.off, engine.state.mouse_tracking);
    try std.testing.expect(!engine.state.mouse_sgr);
}

// ===========================================================================
// Modes survive alt screen
// ===========================================================================

test "attr: mouse modes persist across alt screen switch" {
    var engine = try Engine.init(std.testing.allocator, 2, 4);
    defer engine.deinit();
    engine.feed("\x1b[?1003h");
    engine.feed("\x1b[?1006h");
    engine.feed("\x1b[?2004h");
    engine.feed("\x1b[?1049h");
    try std.testing.expectEqual(MouseTrackingMode.any_event, engine.state.mouse_tracking);
    try std.testing.expect(engine.state.mouse_sgr);
    try std.testing.expect(engine.state.bracketed_paste);
    engine.feed("\x1b[?1049l");
    try std.testing.expectEqual(MouseTrackingMode.any_event, engine.state.mouse_tracking);
    try std.testing.expect(engine.state.mouse_sgr);
    try std.testing.expect(engine.state.bracketed_paste);
}

// ===========================================================================
// Paste wrapper output
// ===========================================================================

test "attr: wrapPaste with bracketed paste enabled" {
    var buf: [64]u8 = undefined;
    const result = try input_mod.wrapPaste(true, "abc", &buf);
    try std.testing.expectEqualStrings("\x1b[200~abc\x1b[201~", result);
}

test "attr: wrapPaste with bracketed paste disabled" {
    var buf: [64]u8 = undefined;
    const result = try input_mod.wrapPaste(false, "abc", &buf);
    try std.testing.expectEqualStrings("abc", result);
}

// ===========================================================================
// Mouse encoding output (SGR)
// ===========================================================================

test "attr: encodeMouse left press SGR" {
    var buf: [64]u8 = undefined;
    const result = input_mod.encodeMouse(.x10, true, .{
        .kind = .press,
        .button = .left,
        .x = 10,
        .y = 5,
    }, &buf);
    try std.testing.expectEqualStrings("\x1b[<0;10;5M", result);
}

test "attr: encodeMouse left release SGR" {
    var buf: [64]u8 = undefined;
    const result = input_mod.encodeMouse(.x10, true, .{
        .kind = .release,
        .button = .left,
        .x = 10,
        .y = 5,
    }, &buf);
    try std.testing.expectEqualStrings("\x1b[<0;10;5m", result);
}

test "attr: encodeMouse scroll up SGR" {
    var buf: [64]u8 = undefined;
    const result = input_mod.encodeMouse(.x10, true, .{
        .kind = .scroll_up,
        .x = 3,
        .y = 4,
    }, &buf);
    try std.testing.expectEqualStrings("\x1b[<64;3;4M", result);
}

test "attr: encodeMouse ctrl+left press" {
    var buf: [64]u8 = undefined;
    const result = input_mod.encodeMouse(.x10, true, .{
        .kind = .press,
        .button = .left,
        .x = 10,
        .y = 5,
        .ctrl = true,
    }, &buf);
    try std.testing.expectEqualStrings("\x1b[<16;10;5M", result);
}

test "attr: encodeMouse off returns empty" {
    var buf: [64]u8 = undefined;
    const result = input_mod.encodeMouse(.off, true, .{
        .kind = .press,
        .button = .left,
    }, &buf);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

// ===========================================================================
// Incremental parsing for DEC private modes
// ===========================================================================

test "attr: CSI ?2004h split across chunks" {
    var engine = try Engine.init(std.testing.allocator, 2, 4);
    defer engine.deinit();
    engine.feed("\x1b[?20");
    engine.feed("04h");
    try std.testing.expect(engine.state.bracketed_paste);
}

test "attr: CSI ?1003h split across chunks" {
    var engine = try Engine.init(std.testing.allocator, 2, 4);
    defer engine.deinit();
    engine.feed("\x1b");
    engine.feed("[");
    engine.feed("?1003h");
    try std.testing.expectEqual(MouseTrackingMode.any_event, engine.state.mouse_tracking);
}
