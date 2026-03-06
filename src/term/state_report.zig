const std = @import("std");
const state_mod = @import("state.zig");
const TerminalState = state_mod.TerminalState;
const actions_mod = @import("actions.zig");
const grid_mod = @import("grid.zig");

pub fn appendResponse(self: *TerminalState, data: []const u8) void {
    const avail = self.response_buf.len - self.response_len;
    const n = @min(data.len, avail);
    @memcpy(self.response_buf[self.response_len .. self.response_len + n], data[0..n]);
    self.response_len += n;
}

pub fn respondDeviceStatus(self: *TerminalState) void {
    self.appendResponse("\x1b[0n");
}

pub fn respondCursorPosition(self: *TerminalState) void {
    var buf: [32]u8 = undefined;
    const row = self.cursor.row + 1;
    const col = self.cursor.col + 1;
    const len = std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{ row, col }) catch return;
    self.appendResponse(len);
}

pub fn respondDeviceAttributes(self: *TerminalState) void {
    self.appendResponse("\x1b[?62c");
}

pub fn respondSecondaryDeviceAttributes(self: *TerminalState) void {
    // VT220-like: type 0, version 10, ROM version 1
    self.appendResponse("\x1b[>0;10;1c");
}

pub fn respondKittyFlags(self: *TerminalState) void {
    const flags = self.kittyFlags();
    var buf: [32]u8 = undefined;
    const resp = std.fmt.bufPrint(&buf, "\x1b[?{d}u", .{flags}) catch return;
    self.appendResponse(resp);
}

/// Format an 8-bit color component as a 4-digit hex value (scaled to 16-bit).
/// E.g. 0xFF → "ffff", 0x1e → "1e1e".
fn fmtColorComponent(buf: *[4]u8, val: u8) []const u8 {
    return std.fmt.bufPrint(buf, "{x:0>2}{x:0>2}", .{ val, val }) catch buf;
}

/// Respond to OSC 10 (fg), 11 (bg), or 12 (cursor) color query.
pub fn respondColorQuery(self: *TerminalState, target: actions_mod.ColorQueryType) void {
    const rgb: grid_mod.Color.Rgb = switch (target) {
        .foreground => self.theme_colors.fg,
        .background => self.theme_colors.bg,
        .cursor => self.theme_colors.cursor orelse self.theme_colors.fg,
    };
    const osc_num: u8 = switch (target) {
        .foreground => 10,
        .background => 11,
        .cursor => 12,
    };
    var rb: [4]u8 = undefined;
    var gb: [4]u8 = undefined;
    var bb: [4]u8 = undefined;
    var buf: [64]u8 = undefined;
    const resp = std.fmt.bufPrint(&buf, "\x1b]{d};rgb:{s}/{s}/{s}\x07", .{
        osc_num,
        fmtColorComponent(&rb, rgb.r),
        fmtColorComponent(&gb, rgb.g),
        fmtColorComponent(&bb, rgb.b),
    }) catch return;
    self.appendResponse(resp);
}

/// Respond to OSC 4;N;? palette color query.
pub fn respondPaletteColorQuery(self: *TerminalState, idx: u8) void {
    const rgb = resolvePaletteColor(self, idx);
    var rb: [4]u8 = undefined;
    var gb: [4]u8 = undefined;
    var bb: [4]u8 = undefined;
    var buf: [64]u8 = undefined;
    const resp = std.fmt.bufPrint(&buf, "\x1b]4;{d};rgb:{s}/{s}/{s}\x07", .{
        idx,
        fmtColorComponent(&rb, rgb.r),
        fmtColorComponent(&gb, rgb.g),
        fmtColorComponent(&bb, rgb.b),
    }) catch return;
    self.appendResponse(resp);
}

/// Resolve a 256-color palette index to RGB, using theme overrides for 0-15.
fn resolvePaletteColor(self: *TerminalState, idx: u8) grid_mod.Color.Rgb {
    // Theme palette overrides for ANSI 0-15
    if (idx < 16) {
        if (self.theme_colors.palette[idx]) |p| return p;
    }
    // Fall back to standard 256-color palette
    return resolve256(idx);
}

const ansi16 = [16]grid_mod.Color.Rgb{
    .{ .r = 0, .g = 0, .b = 0 },
    .{ .r = 170, .g = 0, .b = 0 },
    .{ .r = 0, .g = 170, .b = 0 },
    .{ .r = 170, .g = 85, .b = 0 },
    .{ .r = 0, .g = 0, .b = 170 },
    .{ .r = 170, .g = 0, .b = 170 },
    .{ .r = 0, .g = 170, .b = 170 },
    .{ .r = 170, .g = 170, .b = 170 },
    .{ .r = 85, .g = 85, .b = 85 },
    .{ .r = 255, .g = 85, .b = 85 },
    .{ .r = 85, .g = 255, .b = 85 },
    .{ .r = 255, .g = 255, .b = 85 },
    .{ .r = 85, .g = 85, .b = 255 },
    .{ .r = 255, .g = 85, .b = 255 },
    .{ .r = 85, .g = 255, .b = 255 },
    .{ .r = 255, .g = 255, .b = 255 },
};

fn cubeComponent(idx: u8) u8 {
    if (idx == 0) return 0;
    return @intCast(@as(u16, 55) + @as(u16, idx) * 40);
}

fn resolve256(n: u8) grid_mod.Color.Rgb {
    if (n < 16) return ansi16[n];
    if (n < 232) {
        const i = n - 16;
        return .{
            .r = cubeComponent(i / 36),
            .g = cubeComponent((i / 6) % 6),
            .b = cubeComponent(i % 6),
        };
    }
    const g: u8 = @intCast(@as(u16, 8) + @as(u16, n - 232) * 10);
    return .{ .r = g, .g = g, .b = g };
}

test "respondColorQuery foreground" {
    const t = std.testing;
    var s = try TerminalState.init(t.allocator, 24, 80, 1);
    defer s.deinit();
    s.theme_colors.fg = .{ .r = 0xdc, .g = 0xdc, .b = 0xdc };
    s.respondColorQuery(.foreground);
    const resp = s.drainResponse().?;
    try t.expectEqualStrings("\x1b]10;rgb:dcdc/dcdc/dcdc\x07", resp);
}

test "respondColorQuery background" {
    const t = std.testing;
    var s = try TerminalState.init(t.allocator, 24, 80, 1);
    defer s.deinit();
    s.theme_colors.bg = .{ .r = 0x1e, .g = 0x1e, .b = 0x24 };
    s.respondColorQuery(.background);
    const resp = s.drainResponse().?;
    try t.expectEqualStrings("\x1b]11;rgb:1e1e/1e1e/2424\x07", resp);
}

test "respondColorQuery cursor fallback to fg" {
    const t = std.testing;
    var s = try TerminalState.init(t.allocator, 24, 80, 1);
    defer s.deinit();
    s.theme_colors.fg = .{ .r = 0xff, .g = 0x00, .b = 0xaa };
    s.theme_colors.cursor = null;
    s.respondColorQuery(.cursor);
    const resp = s.drainResponse().?;
    try t.expectEqualStrings("\x1b]12;rgb:ffff/0000/aaaa\x07", resp);
}

test "respondPaletteColorQuery with theme override" {
    const t = std.testing;
    var s = try TerminalState.init(t.allocator, 24, 80, 1);
    defer s.deinit();
    s.theme_colors.palette[1] = .{ .r = 0xcc, .g = 0x00, .b = 0x33 };
    s.respondPaletteColorQuery(1);
    const resp = s.drainResponse().?;
    try t.expectEqualStrings("\x1b]4;1;rgb:cccc/0000/3333\x07", resp);
}

test "respondPaletteColorQuery standard fallback" {
    const t = std.testing;
    var s = try TerminalState.init(t.allocator, 24, 80, 1);
    defer s.deinit();
    // Index 0 with no theme override = standard black
    s.respondPaletteColorQuery(0);
    const resp = s.drainResponse().?;
    try t.expectEqualStrings("\x1b]4;0;rgb:0000/0000/0000\x07", resp);
}

test "OSC 10 query via parser round-trip" {
    const t = std.testing;
    var s = try TerminalState.init(t.allocator, 24, 80, 1);
    defer s.deinit();
    s.theme_colors.fg = .{ .r = 0xab, .g = 0xcd, .b = 0xef };
    // Feed OSC 10;? sequence: ESC ] 1 0 ; ? BEL
    const seq = "\x1b]10;?\x07";
    var p = @import("parser.zig").Parser{};
    for (seq) |byte| {
        if (p.next(byte)) |action| {
            s.apply(action);
        }
    }
    const resp = s.drainResponse().?;
    try t.expectEqualStrings("\x1b]10;rgb:abab/cdcd/efef\x07", resp);
}

pub fn respondDecRequestMode(self: *TerminalState, mode: u16) void {
    // DECRQM response: ESC[?Ps;Pm$y  where Pm = 0 not recognized, 1 set, 2 reset
    const pm: u8 = switch (mode) {
        2026 => if (self.synchronized_output) 1 else 2,
        else => 0,
    };
    var buf: [32]u8 = undefined;
    const resp = std.fmt.bufPrint(&buf, "\x1b[?{d};{d}$y", .{ mode, pm }) catch return;
    self.appendResponse(resp);
}
