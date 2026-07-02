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
    var engine = try Engine.init(alloc, 2, 10, 100);
    defer engine.deinit();

    engine.feed("\x1b]8;;https://example.com\x1b\\");
    engine.feed("Hi");
    engine.feed("\x1b]8;;\x1b\\");
    engine.feed("No");

    const cell_h = engine.state.ring.getScreenCell(0, 0);
    const cell_i = engine.state.ring.getScreenCell(0, 1);
    const cell_n = engine.state.ring.getScreenCell(0, 2);

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
    var engine = try Engine.init(alloc, 2, 10, 100);
    defer engine.deinit();

    engine.feed("\x1b]8;;https://a.com\x1b\\A");
    engine.feed("\x1b]8;;\x1b\\");
    engine.feed("\x1b]8;;https://b.com\x1b\\B");
    engine.feed("\x1b]8;;\x1b\\");

    const cell_a = engine.state.ring.getScreenCell(0, 0);
    const cell_b = engine.state.ring.getScreenCell(0, 1);

    try std.testing.expect(cell_a.link_id != cell_b.link_id);
    try std.testing.expectEqualStrings("https://a.com", engine.state.getLinkUri(cell_a.link_id).?);
    try std.testing.expectEqualStrings("https://b.com", engine.state.getLinkUri(cell_b.link_id).?);
}

test "attr: OSC 8 with BEL terminator" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 10, 100);
    defer engine.deinit();

    engine.feed("\x1b]8;;https://bel.com\x07X");
    engine.feed("\x1b]8;;\x07");

    const cell = engine.state.ring.getScreenCell(0, 0);
    try std.testing.expect(cell.link_id != 0);
    try std.testing.expectEqualStrings("https://bel.com", engine.state.getLinkUri(cell.link_id).?);
}

test "attr: OSC 8 survives chunked input" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 10, 100);
    defer engine.deinit();

    engine.feed("\x1b]8;;https://examp");
    engine.feed("le.com\x1b");
    engine.feed("\\");
    engine.feed("X");
    engine.feed("\x1b]8;;\x1b\\");

    const cell = engine.state.ring.getScreenCell(0, 0);
    try std.testing.expect(cell.link_id != 0);
    try std.testing.expectEqualStrings("https://example.com", engine.state.getLinkUri(cell.link_id).?);
}

test "attr: OSC overflow is safely ignored" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 10, 100);
    defer engine.deinit();

    engine.feed("\x1b]8;;");
    var filler: [Parser.osc_buf_size + 100]u8 = undefined;
    @memset(&filler, 'x');
    engine.feed(&filler);
    engine.feed("\x07");
    engine.feed("A");

    try std.testing.expectEqual(@as(u21, 'A'), engine.state.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(@as(u32, 0), engine.state.ring.getScreenCell(0, 0).link_id);
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
    var engine = try Engine.init(alloc, 2, 10, 100);
    defer engine.deinit();

    engine.feed("\x1b]2;MyTitle\x07");
    try std.testing.expectEqualStrings("MyTitle", engine.state.title.?);
}

test "attr: OSC 0 also sets terminal title" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 10, 100);
    defer engine.deinit();

    engine.feed("\x1b]0;WindowTitle\x1b\\");
    try std.testing.expectEqualStrings("WindowTitle", engine.state.title.?);
}

test "attr: title is replaced on subsequent OSC 2" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 10, 100);
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
    var t = try TerminalState.init(alloc, 2, 4, 100);
    defer t.deinit();

    t.pen_link_id = 42;
    t.apply(.{ .print = 'L' });
    try std.testing.expectEqual(@as(u32, 42), t.ring.getScreenCell(0, 0).link_id);
}

test "startHyperlink allocates URI and sets pen_link_id" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4, 100);
    defer t.deinit();

    t.apply(.{ .hyperlink_start = "https://example.com" });
    try std.testing.expect(t.pen_link_id != 0);
    try std.testing.expectEqualStrings("https://example.com", t.getLinkUri(t.pen_link_id).?);
}

test "endHyperlink clears pen_link_id" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4, 100);
    defer t.deinit();

    t.apply(.{ .hyperlink_start = "https://example.com" });
    t.apply(.hyperlink_end);
    try std.testing.expectEqual(@as(u32, 0), t.pen_link_id);
}

test "getLinkUri returns null for id 0 and unknown ids" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4, 100);
    defer t.deinit();

    try std.testing.expect(t.getLinkUri(0) == null);
    try std.testing.expect(t.getLinkUri(9999) == null);
}

test "OSC 8 link spans multiple cells with same link_id" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 20, 100);
    defer engine.deinit();

    engine.feed("\x1b]8;;https://foo.bar\x1b\\");
    engine.feed("LINK");
    engine.feed("\x1b]8;;\x1b\\");
    engine.feed("X");

    const id_L = engine.state.ring.getScreenCell(0, 0).link_id;
    const id_I = engine.state.ring.getScreenCell(0, 1).link_id;
    const id_N = engine.state.ring.getScreenCell(0, 2).link_id;
    const id_K = engine.state.ring.getScreenCell(0, 3).link_id;
    const id_X = engine.state.ring.getScreenCell(0, 4).link_id;

    try std.testing.expect(id_L != 0);
    try std.testing.expectEqual(id_L, id_I);
    try std.testing.expectEqual(id_L, id_N);
    try std.testing.expectEqual(id_L, id_K);
    try std.testing.expectEqual(@as(u32, 0), id_X);
    try std.testing.expectEqualStrings("https://foo.bar", engine.state.getLinkUri(id_L).?);
}

test "setTitle stores and replaces title" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4, 100);
    defer t.deinit();

    t.apply(.{ .set_title = "Hello" });
    try std.testing.expectEqualStrings("Hello", t.title.?);

    t.apply(.{ .set_title = "World" });
    try std.testing.expectEqualStrings("World", t.title.?);
}

// ===========================================================================
// OSC 7337 — inject into main terminal
// ===========================================================================

test "parser: OSC 7337 write-main emits inject_into_main action" {
    var parser = Parser{};
    const seq = "\x1b]7337;write-main;ls -la\n\x07";
    var action: ?@import("../../term/actions.zig").Action = null;
    for (seq) |byte| {
        if (parser.next(byte)) |a| {
            action = a;
        }
    }
    try std.testing.expect(action != null);
    switch (action.?) {
        .inject_into_main => |payload| {
            try std.testing.expectEqualStrings("ls -la\n", payload);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: OSC 7337 unknown sub-command returns nop" {
    var parser = Parser{};
    const seq = "\x1b]7337;unknown-cmd;payload\x07";
    var action: ?@import("../../term/actions.zig").Action = null;
    for (seq) |byte| {
        if (parser.next(byte)) |a| {
            action = a;
        }
    }
    try std.testing.expect(action != null);
    try std.testing.expect(action.? == .nop);
}

test "state: inject buffer fills and drains correctly" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4, 100);
    defer t.deinit();

    // Initially empty
    try std.testing.expect(t.drainMainInject() == null);

    // Apply inject action
    t.apply(.{ .inject_into_main = "echo hello\n" });
    const drained = t.drainMainInject();
    try std.testing.expect(drained != null);
    try std.testing.expectEqualStrings("echo hello\n", drained.?);

    // Second drain returns null
    try std.testing.expect(t.drainMainInject() == null);
}

test "integration: OSC 7337 through engine produces drainMainInject payload" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 20, 100);
    defer engine.deinit();

    engine.feed("\x1b]7337;write-main;tmux attach -t 0\n\x07");

    const inject = engine.state.drainMainInject();
    try std.testing.expect(inject != null);
    try std.testing.expectEqualStrings("tmux attach -t 0\n", inject.?);
}

// ===========================================================================
// OSC 7337 — agent status
// ===========================================================================

const AgentStatus = @import("../../term/actions.zig").AgentStatus;

test "parser: OSC 7337 agent-status emits set_agent_status with state" {
    var parser = Parser{};
    const seq = "\x1b]7337;agent-status;claude;working\x07";
    var action: ?@import("../../term/actions.zig").Action = null;
    for (seq) |byte| {
        if (parser.next(byte)) |a| action = a;
    }
    try std.testing.expect(action != null);
    switch (action.?) {
        .set_agent_status => |u| {
            try std.testing.expectEqual(AgentStatus.working, u.status);
            try std.testing.expectEqualStrings("", u.message);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: OSC 7337 agent-status without agent name parses state" {
    var parser = Parser{};
    const seq = "\x1b]7337;agent-status;input\x07";
    var action: ?@import("../../term/actions.zig").Action = null;
    for (seq) |byte| {
        if (parser.next(byte)) |a| action = a;
    }
    try std.testing.expect(action != null);
    switch (action.?) {
        .set_agent_status => |u| try std.testing.expectEqual(AgentStatus.input, u.status),
        else => return error.TestUnexpectedResult,
    }
}

test "parser: OSC 7337 agent-status carries a message preview" {
    var parser = Parser{};
    const seq = "\x1b]7337;agent-status;claude;input;Allow Bash: ls -la?\x07";
    var action: ?@import("../../term/actions.zig").Action = null;
    for (seq) |byte| {
        if (parser.next(byte)) |a| action = a;
    }
    try std.testing.expect(action != null);
    switch (action.?) {
        .set_agent_status => |u| {
            try std.testing.expectEqual(AgentStatus.input, u.status);
            try std.testing.expectEqualStrings("Allow Bash: ls -la?", u.message);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: OSC 7337 agent-status with unknown state returns nop" {
    var parser = Parser{};
    const seq = "\x1b]7337;agent-status;claude;bogus\x07";
    var action: ?@import("../../term/actions.zig").Action = null;
    for (seq) |byte| {
        if (parser.next(byte)) |a| action = a;
    }
    try std.testing.expect(action != null);
    try std.testing.expect(action.? == .nop);
}

test "integration: agent-status transitions drive state.agent_status + changed flag" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 20, 100);
    defer engine.deinit();

    try std.testing.expectEqual(AgentStatus.none, engine.state.agent_status);

    engine.feed("\x1b]7337;agent-status;claude;working\x07");
    try std.testing.expectEqual(AgentStatus.working, engine.state.agent_status);
    try std.testing.expect(engine.state.agent_status_changed);

    // Consumer clears the flag; an identical status must not re-raise it.
    engine.state.agent_status_changed = false;
    engine.feed("\x1b]7337;agent-status;claude;working\x07");
    try std.testing.expect(!engine.state.agent_status_changed);

    // A real transition raises it again.
    engine.feed("\x1b]7337;agent-status;claude;input\x07");
    try std.testing.expectEqual(AgentStatus.input, engine.state.agent_status);
    try std.testing.expect(engine.state.agent_status_changed);

    engine.state.agent_status_changed = false;
    engine.feed("\x1b]7337;agent-status;claude;idle\x07");
    try std.testing.expectEqual(AgentStatus.idle, engine.state.agent_status);

    engine.feed("\x1b]7337;agent-status;claude;none\x07");
    try std.testing.expectEqual(AgentStatus.none, engine.state.agent_status);
}

test "parser: OSC 7337 agent-usage parses the KV set" {
    var parser = Parser{};
    const seq = "\x1b]7337;agent-usage;agent;in=1234;out=5678;cr=900000;cw=12000;ctx=82000;ctxmax=200000;cost=0.4213;model=opus-4.6;effort=high\x07";
    var action: ?@import("../../term/actions.zig").Action = null;
    for (seq) |byte| {
        if (parser.next(byte)) |a| action = a;
    }
    try std.testing.expect(action != null);
    switch (action.?) {
        .set_agent_usage => |u| {
            try std.testing.expectEqual(@as(?u64, 1234), u.input_tokens);
            try std.testing.expectEqual(@as(?u64, 5678), u.output_tokens);
            try std.testing.expectEqual(@as(?u64, 900000), u.cache_read_tokens);
            try std.testing.expectEqual(@as(?u64, 12000), u.cache_write_tokens);
            try std.testing.expectEqual(@as(?u64, 82000), u.context_used);
            try std.testing.expectEqual(@as(?u64, 200000), u.context_max);
            try std.testing.expectEqual(@as(?f64, 0.4213), u.cost_usd);
            try std.testing.expectEqualStrings("opus-4.6", u.model.?);
            try std.testing.expectEqualStrings("high", u.effort.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: OSC 7337 agent-usage tolerates malformed pairs" {
    var parser = Parser{};
    // missing '=', non-numeric, empty value, trailing ';' — all ignored; in= kept.
    const seq = "\x1b]7337;agent-usage;agent;in=42;garbage;out=abc;cr=;\x07";
    var action: ?@import("../../term/actions.zig").Action = null;
    for (seq) |byte| {
        if (parser.next(byte)) |a| action = a;
    }
    switch (action.?) {
        .set_agent_usage => |u| {
            try std.testing.expectEqual(@as(?u64, 42), u.input_tokens);
            try std.testing.expectEqual(@as(?u64, null), u.output_tokens);
            try std.testing.expectEqual(@as(?u64, null), u.cache_read_tokens);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "integration: agent-usage updates state usage without flipping status" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 20, 100);
    defer engine.deinit();

    engine.feed("\x1b]7337;agent-status;claude;working\x07");
    engine.state.agent_status_changed = false;
    engine.feed("\x1b]7337;agent-usage;agent;in=100;out=200;model=opus;effort=medium\x07");

    try std.testing.expectEqual(AgentStatus.working, engine.state.agent_status);
    try std.testing.expect(!engine.state.agent_status_changed); // usage never flips status
    try std.testing.expect(engine.state.agent_usage_changed);
    const u = engine.state.agentUsage();
    try std.testing.expectEqual(@as(?u64, 100), u.input_tokens);
    try std.testing.expectEqualStrings("opus", u.model.?);
    try std.testing.expectEqualStrings("medium", u.effort.?);

    // Session end clears usage.
    engine.feed("\x1b]7337;agent-status;claude;none\x07");
    try std.testing.expectEqual(@as(?u64, null), engine.state.agentUsage().input_tokens);
}
