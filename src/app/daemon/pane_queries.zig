/// Terminal query interception for DaemonPane.
///
/// Scans PTY output for device queries (DA1, DA2, DSR, DECRQM, kitty graphics,
/// OSC color) and writes immediate responses. Extracted from pane.zig to keep
/// file sizes under the 600-line limit.
const std = @import("std");
const DaemonPane = @import("pane.zig").DaemonPane;

/// Scan PTY output for terminal queries and write immediate responses.
/// This eliminates round-trip latency through the client, preventing
/// shells from displaying stale responses as raw text.
pub fn interceptQueries(pane: *DaemonPane, data: []const u8) void {
    var i: usize = 0;
    while (i < data.len) {
        if (data[i] != '\x1b') {
            i += 1;
            continue;
        }
        if (i + 1 >= data.len) break;

        if (data[i + 1] == '[') {
            if (i + 2 >= data.len) break;
            const b2 = data[i + 2];

            // DA1: ESC [ c
            if (b2 == 'c') {
                pane.writeToPtyInput("\x1b[?62c");
                i += 3;
                continue;
            }
            // DA1: ESC [ 0 c
            if (b2 == '0' and i + 3 < data.len and data[i + 3] == 'c') {
                pane.writeToPtyInput("\x1b[?62c");
                i += 4;
                continue;
            }

            // DA2: ESC [ > c or ESC [ > 0 c
            if (b2 == '>') {
                if (i + 3 < data.len and data[i + 3] == 'c') {
                    pane.writeToPtyInput("\x1b[>0;10;1c");
                    i += 4;
                    continue;
                }
                if (i + 4 < data.len and data[i + 3] == '0' and data[i + 4] == 'c') {
                    pane.writeToPtyInput("\x1b[>0;10;1c");
                    i += 5;
                    continue;
                }
            }

            // DSR device status: ESC [ 5 n
            if (b2 == '5' and i + 3 < data.len and data[i + 3] == 'n') {
                pane.writeToPtyInput("\x1b[0n");
                i += 4;
                continue;
            }

            // CSI ? sequences: DECRQM or kitty keyboard query
            if (b2 == '?') {
                var j = i + 3;

                // Kitty keyboard query: ESC [ ? u
                if (j < data.len and data[j] == 'u') {
                    pane.writeToPtyInput("\x1b[?0u");
                    i = j + 1;
                    continue;
                }

                // DECRQM: ESC [ ? <digits> $ p
                var num: u32 = 0;
                var has_digits = false;
                while (j < data.len and data[j] >= '0' and data[j] <= '9') : (j += 1) {
                    num = num * 10 + (data[j] - '0');
                    has_digits = true;
                }
                if (has_digits and j + 1 < data.len and data[j] == '$' and data[j + 1] == 'p') {
                    respondDECRPM(pane, @intCast(num));
                    i = j + 2;
                    continue;
                }
            }
        }

        // APC kitty graphics query: ESC _ G ... ESC \
        if (data[i + 1] == '_') {
            if (i + 2 < data.len and data[i + 2] == 'G') {
                var j = i + 3;
                while (j + 1 < data.len) : (j += 1) {
                    if (data[j] == '\x1b' and data[j + 1] == '\\') break;
                }
                if (j + 1 < data.len) {
                    const params = data[i + 3 .. j];
                    if (isGraphicsQuery(params)) {
                        respondGraphicsOk(pane, parseGraphicsId(params));
                    }
                    i = j + 2;
                    continue;
                }
            }
        }

        // OSC sequences: ESC ] <num> ; ? <terminator>
        if (data[i + 1] == ']') {
            var j = i + 2;
            var osc_num: u16 = 0;
            var has_osc_digits = false;
            while (j < data.len and data[j] >= '0' and data[j] <= '9') : (j += 1) {
                osc_num = osc_num *% 10 +% @as(u16, data[j] - '0');
                has_osc_digits = true;
            }
            if (has_osc_digits and j < data.len and data[j] == ';') {
                j += 1;
                const payload_start = j;
                var term_end: usize = j;
                var found_term = false;
                while (term_end < data.len) : (term_end += 1) {
                    if (data[term_end] == 0x07) { found_term = true; break; }
                    if (data[term_end] == '\x1b' and term_end + 1 < data.len and data[term_end + 1] == '\\') {
                        found_term = true;
                        break;
                    }
                }
                if (found_term) {
                    const rest = data[payload_start..term_end];
                    const advanced = if (data[term_end] == 0x07) term_end + 1 else term_end + 2;
                    switch (osc_num) {
                        10 => if (std.mem.eql(u8, rest, "?")) {
                            respondOscColor(pane, 10, pane.theme_fg);
                            i = advanced;
                            continue;
                        },
                        11 => if (std.mem.eql(u8, rest, "?")) {
                            respondOscColor(pane, 11, pane.theme_bg);
                            i = advanced;
                            continue;
                        },
                        12 => if (std.mem.eql(u8, rest, "?")) {
                            const c = if (pane.theme_cursor_set) pane.theme_cursor else pane.theme_fg;
                            respondOscColor(pane, 12, c);
                            i = advanced;
                            continue;
                        },
                        4 => {
                            if (parseAndRespondPaletteQuery(pane, rest)) {
                                i = advanced;
                                continue;
                            }
                        },
                        else => {},
                    }
                }
            }
        }

        i += 1;
    }
}

fn isGraphicsQuery(params: []const u8) bool {
    const kv = if (std.mem.indexOfScalar(u8, params, ';')) |semi| params[0..semi] else params;
    var iter = std.mem.splitScalar(u8, kv, ',');
    while (iter.next()) |pair| {
        if (std.mem.eql(u8, pair, "a=q")) return true;
    }
    return false;
}

fn parseGraphicsId(params: []const u8) u32 {
    const kv = if (std.mem.indexOfScalar(u8, params, ';')) |semi| params[0..semi] else params;
    var iter = std.mem.splitScalar(u8, kv, ',');
    while (iter.next()) |pair| {
        if (pair.len > 2 and pair[0] == 'i' and pair[1] == '=') {
            return std.fmt.parseInt(u32, pair[2..], 10) catch 0;
        }
    }
    return 0;
}

fn respondGraphicsOk(pane: *DaemonPane, image_id: u32) void {
    var buf: [64]u8 = undefined;
    const resp = std.fmt.bufPrint(&buf, "\x1b_Gi={d};OK\x1b\\", .{image_id}) catch return;
    pane.writeToPtyInput(resp);
}

fn respondDECRPM(pane: *DaemonPane, mode: u16) void {
    const pm: u8 = switch (mode) {
        2026 => 2,
        else => 0,
    };
    var buf: [32]u8 = undefined;
    const resp = std.fmt.bufPrint(&buf, "\x1b[?{d};{d}$y", .{ mode, pm }) catch return;
    pane.writeToPtyInput(resp);
}

fn respondOscColor(pane: *DaemonPane, osc_num: u8, rgb: [3]u8) void {
    var buf: [64]u8 = undefined;
    const resp = std.fmt.bufPrint(&buf, "\x1b]{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x07", .{
        osc_num, rgb[0], rgb[0], rgb[1], rgb[1], rgb[2], rgb[2],
    }) catch return;
    pane.writeToPtyInput(resp);
}

fn parseAndRespondPaletteQuery(pane: *DaemonPane, rest: []const u8) bool {
    const semi = std.mem.indexOfScalar(u8, rest, ';') orelse return false;
    if (!std.mem.eql(u8, rest[semi + 1 ..], "?")) return false;
    const idx = std.fmt.parseInt(u8, rest[0..semi], 10) catch return false;
    const rgb = paletteRgb(idx);
    var buf: [64]u8 = undefined;
    const resp = std.fmt.bufPrint(&buf, "\x1b]4;{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x07", .{
        idx, rgb[0], rgb[0], rgb[1], rgb[1], rgb[2], rgb[2],
    }) catch return false;
    pane.writeToPtyInput(resp);
    return true;
}

fn paletteRgb(n: u8) [3]u8 {
    if (n < 16) return ansi16[n];
    if (n < 232) {
        const idx = n - 16;
        return .{ cubeComp(idx / 36), cubeComp((idx / 6) % 6), cubeComp(idx % 6) };
    }
    const g: u8 = @intCast(@as(u16, 8) + @as(u16, n - 232) * 10);
    return .{ g, g, g };
}

fn cubeComp(idx: u8) u8 {
    if (idx == 0) return 0;
    return @intCast(@as(u16, 55) + @as(u16, idx) * 40);
}

const ansi16 = [16][3]u8{
    .{ 0, 0, 0 },
    .{ 170, 0, 0 },
    .{ 0, 170, 0 },
    .{ 170, 85, 0 },
    .{ 0, 0, 170 },
    .{ 170, 0, 170 },
    .{ 0, 170, 170 },
    .{ 170, 170, 170 },
    .{ 85, 85, 85 },
    .{ 255, 85, 85 },
    .{ 85, 255, 85 },
    .{ 255, 255, 85 },
    .{ 85, 85, 255 },
    .{ 255, 85, 255 },
    .{ 85, 255, 255 },
    .{ 255, 255, 255 },
};
