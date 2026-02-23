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
