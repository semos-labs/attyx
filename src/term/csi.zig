const std = @import("std");
const actions_mod = @import("actions.zig");

pub const Action = actions_mod.Action;

/// Intermediate result of parsing CSI parameter bytes (e.g. "31;1" → [31, 1]).
pub const CsiParams = struct {
    params: [16]u16 = undefined,
    len: u8 = 0,
};

/// Parse a CSI parameter buffer like "31;1" into a list of u16 values.
/// Semicolons delimit params. Missing digits default to 0.
/// Non-digit/non-semicolon bytes (like '?' in DEC private mode) are ignored.
pub fn parseCsiParams(buf: []const u8) CsiParams {
    var result = CsiParams{};
    if (buf.len == 0) return result;

    var current: u32 = 0;

    for (buf) |byte| {
        if (byte >= '0' and byte <= '9') {
            current = @min(current * 10 + (byte - '0'), 65535);
        } else if (byte == ';') {
            if (result.len < 16) {
                result.params[result.len] = @intCast(current);
                result.len += 1;
            }
            current = 0;
        }
    }
    if (result.len < 16) {
        result.params[result.len] = @intCast(current);
        result.len += 1;
    }

    return result;
}

// ---------------------------------------------------------------------------
// Action constructors
// ---------------------------------------------------------------------------

/// CUP (ESC[row;colH) — default row=1, col=1, converted to 0-based.
pub fn makeCursorAbs(params: CsiParams) Action {
    const raw_row: u16 = if (params.len > 0) params.params[0] else 0;
    const raw_col: u16 = if (params.len > 1) params.params[1] else 0;
    return .{ .cursor_abs = .{
        .row = if (raw_row == 0) 0 else raw_row - 1,
        .col = if (raw_col == 0) 0 else raw_col - 1,
    } };
}

/// CUU/CUD/CUF/CUB — default n=1.
pub fn makeCursorRel(params: CsiParams, dir: actions_mod.Direction) Action {
    const raw: u16 = if (params.len > 0) params.params[0] else 0;
    return .{ .cursor_rel = .{
        .dir = dir,
        .n = if (raw == 0) 1 else raw,
    } };
}

/// ED (ESC[nJ) — default n=0 (clear to end).
pub fn makeEraseDisplay(params: CsiParams) Action {
    const mode: u16 = if (params.len > 0) params.params[0] else 0;
    return switch (mode) {
        0 => .{ .erase_display = .to_end },
        1 => .{ .erase_display = .to_start },
        2 => .{ .erase_display = .all },
        3 => .{ .erase_display = .scrollback },
        else => .nop,
    };
}

/// EL (ESC[nK) — default n=0 (clear to end of line).
pub fn makeEraseLine(params: CsiParams) Action {
    const mode: u16 = if (params.len > 0) params.params[0] else 0;
    return switch (mode) {
        0 => .{ .erase_line = .to_end },
        1 => .{ .erase_line = .to_start },
        2 => .{ .erase_line = .all },
        else => .nop,
    };
}

/// SGR (ESC[...m) — if no params, defaults to [0] (reset).
pub fn makeSgr(params: CsiParams) Action {
    var sgr = actions_mod.Sgr{};
    if (params.len == 0) {
        sgr.params[0] = 0;
        sgr.len = 1;
        return .{ .sgr = sgr };
    }
    const count: u8 = @intCast(@min(params.len, @as(u8, 16)));
    for (0..count) |i| {
        sgr.params[i] = @intCast(@min(params.params[i], 255));
    }
    sgr.len = count;
    return .{ .sgr = sgr };
}

/// DECSTBM (ESC[top;bottom r) — carries raw 1-based values (0 = default).
pub fn makeSetScrollRegion(params: CsiParams) Action {
    const top: u16 = if (params.len > 0) params.params[0] else 0;
    const bottom: u16 = if (params.len > 1) params.params[1] else 0;
    return .{ .set_scroll_region = .{ .top = top, .bottom = bottom } };
}

/// CSI G — Cursor Character Absolute. Default col=1, converted to 0-based.
pub fn makeCursorColAbs(params: CsiParams) Action {
    const raw: u16 = if (params.len > 0) params.params[0] else 0;
    return .{ .cursor_col_abs = if (raw == 0) 0 else raw - 1 };
}

/// CSI d — Line Position Absolute. Default row=1, converted to 0-based.
pub fn makeCursorRowAbs(params: CsiParams) Action {
    const raw: u16 = if (params.len > 0) params.params[0] else 0;
    return .{ .cursor_row_abs = if (raw == 0) 0 else raw - 1 };
}

/// CSI E — Cursor Next Line (move down n, set col=0).
pub fn makeCursorNextLine(params: CsiParams) Action {
    const raw: u16 = if (params.len > 0) params.params[0] else 0;
    return .{ .cursor_next_line = if (raw == 0) 1 else raw };
}

/// CSI F — Cursor Previous Line (move up n, set col=0).
pub fn makeCursorPrevLine(params: CsiParams) Action {
    const raw: u16 = if (params.len > 0) params.params[0] else 0;
    return .{ .cursor_prev_line = if (raw == 0) 1 else raw };
}

/// Generic constructor for actions that take a single count param (default 1).
pub fn makeCountAction(params: CsiParams, comptime tag: std.meta.Tag(Action)) Action {
    const raw: u16 = if (params.len > 0) params.params[0] else 0;
    return @unionInit(Action, @tagName(tag), if (raw == 0) 1 else raw);
}

/// CSI n — Device Status Report.
pub fn makeDeviceStatusReport(params: CsiParams) Action {
    const code: u16 = if (params.len > 0) params.params[0] else 0;
    return switch (code) {
        5 => .device_status,
        6 => .cursor_position_report,
        else => .nop,
    };
}

/// CSI c / CSI 0 c — Primary Device Attributes (DA1).
pub fn makeDeviceAttributes(params: CsiParams) Action {
    const code: u16 = if (params.len > 0) params.params[0] else 0;
    if (code == 0) return .device_attributes;
    return .nop;
}

/// CSI Ps SP q — DECSCUSR (set cursor shape).
pub fn makeCursorShape(params: CsiParams) Action {
    const ps: u16 = if (params.len > 0) params.params[0] else 0;
    const shape: actions_mod.CursorShape = switch (ps) {
        0, 1 => .blinking_block,
        2 => .steady_block,
        3 => .blinking_underline,
        4 => .steady_underline,
        5 => .blinking_bar,
        6 => .steady_bar,
        else => return .nop,
    };
    return .{ .set_cursor_shape = shape };
}

/// CSI > c / CSI > 0 c — Secondary Device Attributes (DA2).
pub fn dispatchSecondaryDA(final: u8, param_buf: []const u8) Action {
    if (final != 'c') return .nop;
    const params = parseCsiParams(param_buf);
    const code: u16 = if (params.len > 0) params.params[0] else 0;
    if (code == 0) return .secondary_device_attributes;
    return .nop;
}

/// DEC private mode dispatch (ESC[?...h / ESC[?...l).
/// Packs all mode params into a single compound action so multi-param
/// sequences like ESC[?1000;1006h are applied atomically by the state.
pub fn dispatchDecPrivate(final: u8, param_buf: []const u8) Action {
    const params = parseCsiParams(param_buf);
    if (params.len == 0) return .nop;
    return switch (final) {
        'h' => makeDecPrivateMode(params, true),
        'l' => makeDecPrivateMode(params, false),
        'p' => blk: {
            // DECRQM: ESC[?Ps$p — '$' is accumulated as a param byte before final 'p'.
            if (param_buf.len > 0 and param_buf[param_buf.len - 1] == '$')
                break :blk .{ .query_dec_private_mode = params.params[0] };
            break :blk .nop;
        },
        else => .nop,
    };
}

fn makeDecPrivateMode(params: CsiParams, set: bool) Action {
    var dm = actions_mod.DecPrivateModes{ .set = set };
    const count = @min(params.len, 8);
    for (params.params[0..count]) |p| {
        dm.params[dm.len] = p;
        dm.len += 1;
    }
    return .{ .dec_private_mode = dm };
}

/// CSI > N u — Kitty keyboard protocol: push flags.
pub fn dispatchKittyPush(param_buf: []const u8) Action {
    const params = parseCsiParams(param_buf);
    const flags: u16 = if (params.len > 0) params.params[0] else 0;
    if (flags > 31) return .nop;
    return .{ .kitty_push_flags = @intCast(flags) };
}

/// CSI < N u — Kitty keyboard protocol: pop N entries.
pub fn dispatchKittyPop(param_buf: []const u8) Action {
    const params = parseCsiParams(param_buf);
    const n: u16 = if (params.len > 0) params.params[0] else 1;
    return .{ .kitty_pop_flags = @intCast(@min(n, 255)) };
}

/// CSI ? u — Kitty keyboard protocol: query current flags.
pub fn dispatchKittyQuery(param_buf: []const u8) Action {
    _ = param_buf;
    return .kitty_query_flags;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "parseCsiParams: empty buffer" {
    const p = parseCsiParams("");
    try testing.expectEqual(@as(u8, 0), p.len);
}

test "parseCsiParams: single param" {
    const p = parseCsiParams("42");
    try testing.expectEqual(@as(u8, 1), p.len);
    try testing.expectEqual(@as(u16, 42), p.params[0]);
}

test "parseCsiParams: multiple params" {
    const p = parseCsiParams("3;14;159");
    try testing.expectEqual(@as(u8, 3), p.len);
    try testing.expectEqual(@as(u16, 3), p.params[0]);
    try testing.expectEqual(@as(u16, 14), p.params[1]);
    try testing.expectEqual(@as(u16, 159), p.params[2]);
}

test "parseCsiParams: missing param defaults to 0" {
    const p = parseCsiParams(";5;");
    try testing.expectEqual(@as(u8, 3), p.len);
    try testing.expectEqual(@as(u16, 0), p.params[0]);
    try testing.expectEqual(@as(u16, 5), p.params[1]);
    try testing.expectEqual(@as(u16, 0), p.params[2]);
}

test "parseCsiParams: overflow >16 params capped" {
    const p = parseCsiParams("1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17;18");
    try testing.expectEqual(@as(u8, 16), p.len);
    try testing.expectEqual(@as(u16, 16), p.params[15]);
}

test "parseCsiParams: u16 cap at 65535" {
    const p = parseCsiParams("99999");
    try testing.expectEqual(@as(u16, 65535), p.params[0]);
}

test "parseCsiParams: non-digit bytes skipped" {
    const p = parseCsiParams("?25");
    try testing.expectEqual(@as(u8, 1), p.len);
    try testing.expectEqual(@as(u16, 25), p.params[0]);
}

test "makeCursorAbs: default to origin" {
    const a = makeCursorAbs(.{});
    try testing.expectEqual(@as(u16, 0), a.cursor_abs.row);
    try testing.expectEqual(@as(u16, 0), a.cursor_abs.col);
}

test "makeCursorAbs: 1-based to 0-based" {
    var p = CsiParams{};
    p.params[0] = 5;
    p.params[1] = 10;
    p.len = 2;
    const a = makeCursorAbs(p);
    try testing.expectEqual(@as(u16, 4), a.cursor_abs.row);
    try testing.expectEqual(@as(u16, 9), a.cursor_abs.col);
}

test "makeEraseDisplay: modes 0-3" {
    const ed0 = makeEraseDisplay(.{});
    try testing.expectEqual(actions_mod.EraseMode.to_end, ed0.erase_display);

    var p1 = CsiParams{};
    p1.params[0] = 1;
    p1.len = 1;
    try testing.expectEqual(actions_mod.EraseMode.to_start, makeEraseDisplay(p1).erase_display);

    p1.params[0] = 2;
    try testing.expectEqual(actions_mod.EraseMode.all, makeEraseDisplay(p1).erase_display);

    p1.params[0] = 3;
    try testing.expectEqual(actions_mod.EraseMode.scrollback, makeEraseDisplay(p1).erase_display);
}

test "makeEraseDisplay: unknown mode is nop" {
    var p = CsiParams{};
    p.params[0] = 99;
    p.len = 1;
    try testing.expectEqual(Action.nop, makeEraseDisplay(p));
}

test "makeEraseLine: modes 0-2 and unknown" {
    const el0 = makeEraseLine(.{});
    try testing.expectEqual(actions_mod.EraseMode.to_end, el0.erase_line);

    var p = CsiParams{};
    p.params[0] = 1;
    p.len = 1;
    try testing.expectEqual(actions_mod.EraseMode.to_start, makeEraseLine(p).erase_line);

    p.params[0] = 2;
    try testing.expectEqual(actions_mod.EraseMode.all, makeEraseLine(p).erase_line);

    p.params[0] = 99;
    try testing.expectEqual(Action.nop, makeEraseLine(p));
}

test "makeSgr: no params defaults to reset" {
    const a = makeSgr(.{});
    try testing.expectEqual(@as(u8, 1), a.sgr.len);
    try testing.expectEqual(@as(u8, 0), a.sgr.params[0]);
}

test "makeSgr: multiple params forwarded with u8 clamping" {
    var p = CsiParams{};
    p.params[0] = 1;
    p.params[1] = 31;
    p.params[2] = 300; // exceeds u8, clamped to 255
    p.len = 3;
    const a = makeSgr(p);
    try testing.expectEqual(@as(u8, 3), a.sgr.len);
    try testing.expectEqual(@as(u8, 1), a.sgr.params[0]);
    try testing.expectEqual(@as(u8, 31), a.sgr.params[1]);
    try testing.expectEqual(@as(u8, 255), a.sgr.params[2]);
}

test "makeCursorShape: all shapes" {
    var p = CsiParams{};
    p.len = 1;

    const expected = [_]actions_mod.CursorShape{
        .blinking_block,   // 0
        .blinking_block,   // 1
        .steady_block,     // 2
        .blinking_underline, // 3
        .steady_underline, // 4
        .blinking_bar,     // 5
        .steady_bar,       // 6
    };
    for (expected, 0..) |shape, i| {
        p.params[0] = @intCast(i);
        const a = makeCursorShape(p);
        try testing.expectEqual(shape, a.set_cursor_shape);
    }
}

test "makeCursorShape: unknown is nop" {
    var p = CsiParams{};
    p.params[0] = 99;
    p.len = 1;
    try testing.expectEqual(Action.nop, makeCursorShape(p));
}

/// Parse the rest of an OSC 8 payload after the "8;".
/// Format: "params;URI" — params are ignored, URI determines start/end.
pub fn makeOscHyperlink(rest: []const u8) Action {
    var i: usize = 0;
    while (i < rest.len and rest[i] != ';') : (i += 1) {}
    if (i >= rest.len) return .hyperlink_end;
    const uri = rest[i + 1 ..];
    if (uri.len == 0) return .hyperlink_end;
    return .{ .hyperlink_start = uri };
}
