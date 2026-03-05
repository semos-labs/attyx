const std = @import("std");
const Engine = @import("../../term/engine.zig").Engine;
const Parser = @import("../../term/parser.zig").Parser;
const GraphicsCommand = @import("../../term/graphics_cmd.zig").GraphicsCommand;

// ===========================================================================
// APC capture tests
// ===========================================================================

test "parser: APC graphics command is captured" {
    var p = Parser{};

    // ESC _ G a=q,i=1; ESC \   — query with no payload
    const seq = "\x1b_Ga=q,i=1;\x1b\\";
    var result: ?@import("../../term/actions.zig").Action = null;
    for (seq) |byte| {
        if (p.next(byte)) |action| {
            result = action;
        }
    }

    try std.testing.expect(result != null);
    switch (result.?) {
        .graphics_command => |payload| {
            try std.testing.expectEqualStrings("a=q,i=1;", payload);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: APC non-graphics falls through to str_ignore" {
    var p = Parser{};

    // ESC _ X ... ESC \ — first byte not 'G', should be ignored.
    const seq = "\x1b_Xhello\x1b\\";
    var result: ?@import("../../term/actions.zig").Action = null;
    for (seq) |byte| {
        if (p.next(byte)) |action| {
            result = action;
        }
    }

    // Should produce a nop (from str_ignore termination), not graphics_command.
    try std.testing.expect(result != null);
    switch (result.?) {
        .graphics_command => return error.TestUnexpectedResult,
        else => {},
    }
}

test "parser: APC with C1 ST terminator" {
    var p = Parser{};

    // ESC _ G a=t 0x9C (C1 ST)
    const seq = "\x1b_Ga=t\x9c";
    var result: ?@import("../../term/actions.zig").Action = null;
    for (seq) |byte| {
        if (p.next(byte)) |action| {
            result = action;
        }
    }

    try std.testing.expect(result != null);
    switch (result.?) {
        .graphics_command => |payload| {
            try std.testing.expectEqualStrings("a=t", payload);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: APC graphics across feed boundaries" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 10, 100);
    defer engine.deinit();

    // Split the sequence across feeds.
    engine.feed("\x1b_Ga=q,i=");
    engine.feed("1;\x1b\\");

    // The graphics command should have been processed. With responses enabled,
    // a query (a=q) generates an OK response.
    const resp = engine.state.drainResponse();
    try std.testing.expect(resp != null);
}

test "parser: APC overflow produces nop" {
    var p = Parser{};

    // Start a graphics APC.
    _ = p.next(0x1B);
    _ = p.next('_');
    _ = p.next('G');

    // Feed more than apc_buf_size bytes to trigger overflow.
    var i: usize = 0;
    while (i < Parser.apc_buf_size + 100) : (i += 1) {
        _ = p.next('x');
    }

    // Terminate with ST.
    _ = p.next(0x1B);
    const result = p.next('\\');

    // Overflow should produce nop.
    try std.testing.expect(result != null);
    switch (result.?) {
        .graphics_command => return error.TestUnexpectedResult,
        .nop => {},
        else => return error.TestUnexpectedResult,
    }
}

// ===========================================================================
// GraphicsCommand parsing tests
// ===========================================================================

test "graphics_cmd: parse basic query" {
    const cmd = GraphicsCommand.parse("a=q,i=42,f=100,s=1,v=1;iVBORw0KGgo=");
    try std.testing.expectEqual(cmd.action, .query);
    try std.testing.expectEqual(cmd.image_id, 42);
    try std.testing.expectEqual(cmd.format, .png);
    try std.testing.expectEqual(cmd.src_width, 1);
    try std.testing.expectEqual(cmd.src_height, 1);
    try std.testing.expect(cmd.payload_len > 0);
}

test "graphics_cmd: parse transmit with defaults" {
    const cmd = GraphicsCommand.parse("i=1,s=2,v=2;AAAA");
    // Default action is transmit_and_display.
    try std.testing.expectEqual(cmd.action, .transmit_and_display);
    try std.testing.expectEqual(cmd.image_id, 1);
    try std.testing.expectEqual(cmd.src_width, 2);
    try std.testing.expectEqual(cmd.src_height, 2);
    try std.testing.expectEqual(cmd.format, .rgba32);
}

test "graphics_cmd: parse delete" {
    const cmd = GraphicsCommand.parse("a=d,d=a");
    try std.testing.expectEqual(cmd.action, .delete);
    try std.testing.expectEqual(cmd.delete_target, .all);
}

test "graphics_cmd: parse chunked" {
    const cmd = GraphicsCommand.parse("m=1,i=5;AAAA");
    try std.testing.expect(cmd.more_chunks);
    try std.testing.expectEqual(cmd.image_id, 5);
}

test "graphics_cmd: parse quiet mode" {
    const cmd = GraphicsCommand.parse("a=t,q=2,i=1;AA");
    try std.testing.expectEqual(cmd.quiet, 2);
}

test "graphics_cmd: parse z-index negative" {
    const cmd = GraphicsCommand.parse("a=p,i=1,z=-5");
    try std.testing.expectEqual(cmd.z_index, -5);
}

test "graphics_cmd: no payload" {
    const cmd = GraphicsCommand.parse("a=d,d=i,i=3");
    try std.testing.expectEqual(cmd.payload_len, 0);
    try std.testing.expectEqual(cmd.payload_offset, 0);
}

test "graphics_cmd: empty input" {
    const cmd = GraphicsCommand.parse("");
    try std.testing.expectEqual(cmd.action, .transmit_and_display);
    try std.testing.expectEqual(cmd.image_id, 0);
}
