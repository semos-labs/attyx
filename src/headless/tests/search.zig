const std = @import("std");
const Engine = @import("../../term/engine.zig").Engine;
const SearchState = @import("../../term/search.zig").SearchState;

test "search: find text in engine grid" {
    var eng = try Engine.init(std.testing.allocator, 5, 80);
    defer eng.deinit();

    eng.feed("hello world\r\n");
    eng.feed("foo bar hello\r\n");

    var s = SearchState.init(std.testing.allocator);
    defer s.deinit();

    s.update("hello", &eng.state.scrollback, &eng.state.grid);
    try std.testing.expectEqual(@as(usize, 2), s.matchCount());
}

test "search: find text pushed into scrollback" {
    var eng = try Engine.init(std.testing.allocator, 3, 20);
    defer eng.deinit();

    eng.feed("error one\r\n");
    eng.feed("line two\r\n");
    eng.feed("error three\r\n");
    eng.feed("line four\r\n");
    eng.feed("error five\r\n");

    var s = SearchState.init(std.testing.allocator);
    defer s.deinit();

    s.update("error", &eng.state.scrollback, &eng.state.grid);
    try std.testing.expect(s.matchCount() >= 2);
}

test "search: navigation scrolls through matches" {
    var eng = try Engine.init(std.testing.allocator, 4, 40);
    defer eng.deinit();

    eng.feed("aaa\r\n");
    eng.feed("bbb\r\n");
    eng.feed("aaa\r\n");

    var s = SearchState.init(std.testing.allocator);
    defer s.deinit();

    s.update("aaa", &eng.state.scrollback, &eng.state.grid);
    try std.testing.expectEqual(@as(usize, 2), s.matchCount());

    const m0 = s.currentMatch().?;
    _ = s.next();
    const m1 = s.currentMatch().?;
    try std.testing.expect(m1.abs_row != m0.abs_row);

    _ = s.next();
    const m2 = s.currentMatch().?;
    try std.testing.expectEqual(m0.abs_row, m2.abs_row);
}

test "search: viewport offset for current match" {
    var eng = try Engine.init(std.testing.allocator, 3, 20);
    defer eng.deinit();

    // Push many lines to build scrollback
    for (0..10) |_| eng.feed("padding\r\n");
    eng.feed("target\r\n");
    for (0..5) |_| eng.feed("more\r\n");

    var s = SearchState.init(std.testing.allocator);
    defer s.deinit();

    s.update("target", &eng.state.scrollback, &eng.state.grid);
    try std.testing.expect(s.matchCount() >= 1);

    const vp = s.viewportForCurrent(eng.state.scrollback.count, eng.state.grid.rows);
    try std.testing.expect(vp != null);
}

test "search: clear resets state" {
    var eng = try Engine.init(std.testing.allocator, 4, 40);
    defer eng.deinit();

    eng.feed("hello\r\n");

    var s = SearchState.init(std.testing.allocator);
    defer s.deinit();

    s.update("hello", &eng.state.scrollback, &eng.state.grid);
    try std.testing.expect(s.matchCount() > 0);

    s.clear();
    try std.testing.expectEqual(@as(usize, 0), s.matchCount());
    try std.testing.expect(s.currentMatch() == null);
}
