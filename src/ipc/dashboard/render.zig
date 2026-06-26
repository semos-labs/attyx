//! Dashboard rendering: a width-correct agent table, in two flavors —
//! `snapshot` (plain text for `--once`/non-TTY) and `frame` (full-screen ANSI
//! for the interactive TUI). Column widths are measured in display columns via
//! the engine's `ui_cell` helpers so multibyte/wide chars never misalign.
const std = @import("std");
const model = @import("model.zig");
const fmt = @import("format.zig");
const ui_cell = @import("attyx").overlay_ui_cell;

const Model = model.Model;
const Row = model.Row;
const State = model.State;

// Column display widths and the 2-col gutter between them.
const gutter = "  ";
const gw: u16 = 2;
const mark_w: u16 = 2; // selection marker + space
const session_w: u16 = 8;
const pane_w: u16 = 5;
const model_w: u16 = 18;
const state_w: u16 = 8;
const in_w: u16 = 8;
const out_w: u16 = 8;
const ctx_w: u16 = 14;
const cost_w: u16 = 10;
// 8 body columns => 7 gutters.
pub const table_w: u16 = mark_w + session_w + pane_w + model_w + state_w + in_w + out_w + ctx_w + cost_w + gw * 7;

const ellipsis = "\xe2\x80\xa6"; // …

// ANSI
const reset = "\x1b[0m";
const dim = "\x1b[2m";
const bold = "\x1b[1m";
const rev = "\x1b[7m";
const c_idle = "\x1b[38;2;96;208;120m";
const c_working = "\x1b[38;2;255;170;64m";
const c_input = "\x1b[38;2;176;112;255m";

fn stateColor(s: State) []const u8 {
    return switch (s) {
        .idle => c_idle,
        .working => c_working,
        .input => c_input,
        .none => dim,
    };
}
fn stateLabel(s: State) []const u8 {
    return switch (s) {
        .idle => "idle",
        .working => "working",
        .input => "input",
        .none => "none",
    };
}

fn appendCol(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8, width: u16, right: bool) !void {
    const full = ui_cell.utf8Count(s);
    if (full <= width) {
        const pad: usize = width - full;
        if (right) try buf.appendNTimes(a, ' ', pad);
        try buf.appendSlice(a, s);
        if (!right) try buf.appendNTimes(a, ' ', pad);
        return;
    }
    const off = ui_cell.utf8ByteOffset(s, width - 1);
    const shown = s[0..off];
    const used: usize = ui_cell.utf8Count(shown) + 1;
    const pad: usize = if (width > used) width - used else 0;
    if (right) try buf.appendNTimes(a, ' ', pad);
    try buf.appendSlice(a, shown);
    try buf.appendSlice(a, ellipsis);
    if (!right) try buf.appendNTimes(a, ' ', pad);
}

/// Build one table line (no ANSI): marker + session/pane/model/state/in/out/ctx/cost.
fn buildLine(a: std.mem.Allocator, marker: []const u8, session: []const u8, pane: []const u8, model_s: []const u8, state_s: []const u8, in: []const u8, out: []const u8, ctx: []const u8, cost: []const u8) ![]const u8 {
    var b = std.ArrayList(u8){};
    try appendCol(&b, a, marker, mark_w, false);
    try appendCol(&b, a, session, session_w, false);
    try b.appendSlice(a, gutter);
    try appendCol(&b, a, pane, pane_w, false);
    try b.appendSlice(a, gutter);
    try appendCol(&b, a, model_s, model_w, false);
    try b.appendSlice(a, gutter);
    try appendCol(&b, a, state_s, state_w, false);
    try b.appendSlice(a, gutter);
    try appendCol(&b, a, in, in_w, true);
    try b.appendSlice(a, gutter);
    try appendCol(&b, a, out, out_w, true);
    try b.appendSlice(a, gutter);
    try appendCol(&b, a, ctx, ctx_w, true);
    try b.appendSlice(a, gutter);
    try appendCol(&b, a, cost, cost_w, true);
    return b.items;
}

fn rowLine(a: std.mem.Allocator, r: *const Row, marker: []const u8) ![]const u8 {
    var sb: [16]u8 = undefined;
    var pb: [16]u8 = undefined;
    var ib: [16]u8 = undefined;
    var ob: [16]u8 = undefined;
    var cb: [24]u8 = undefined;
    var kb: [24]u8 = undefined;
    const session = std.fmt.bufPrint(&sb, "s{d}", .{r.session}) catch "s?";
    const pane = std.fmt.bufPrint(&pb, "{d}", .{r.pane_id}) catch "?";
    return buildLine(
        a,
        marker,
        session,
        pane,
        if (r.model_len > 0) r.model() else "\xe2\x80\x94",
        stateLabel(r.state),
        fmt.tokensOpt(&ib, r.input_tokens),
        fmt.tokensOpt(&ob, r.output_tokens),
        fmt.ctx(&kb, r.context_used, r.context_max),
        fmt.cost(&cb, r.cost_usd, r.cost_is_estimate),
    );
}

fn headerLine(a: std.mem.Allocator) ![]const u8 {
    return buildLine(a, " ", "session", "pane", "model", "state", "in", "out", "ctx", "cost");
}

fn totalsLine(a: std.mem.Allocator, m: *const Model) ![]const u8 {
    var ib: [16]u8 = undefined;
    var ob: [16]u8 = undefined;
    var cb: [24]u8 = undefined;
    const cost = std.fmt.bufPrint(&cb, "{s}${d:.2}", .{ if (m.any_estimate) "~" else "", m.total_cost }) catch "$?";
    return buildLine(a, " ", "TOTAL", "", "", "", fmt.tokens(&ib, m.total_input), fmt.tokens(&ob, m.total_output), "", cost);
}

/// Plain-text table to `writer` (for `--once` / non-TTY). No ANSI.
pub fn snapshot(writer: anytype, a: std.mem.Allocator, m: *const Model) !void {
    try writer.print("{d} agents \xc2\xb7 {d} working \xc2\xb7 {d} need input \xc2\xb7 ${d:.2}{s}\n", .{
        m.count, m.n_working, m.n_input, m.total_cost, if (m.any_estimate) " (incl. est)" else "",
    });
    try writer.print("{s}\n", .{try headerLine(a)});
    if (m.count == 0) {
        try writer.writeAll("  (no agents running)\n");
    } else {
        for (m.rows[0..m.count]) |*r| try writer.print("{s}\n", .{try rowLine(a, r, " ")});
    }
    try writer.print("{s}\n", .{try totalsLine(a, m)});
}

/// Full-screen ANSI frame into `buf` (for the interactive TUI). Rows are colored
/// by state; the selected row is reverse-video. Lines are clipped to `cols`.
pub fn frame(buf: *std.ArrayList(u8), a: std.mem.Allocator, m: *const Model, rows: u16, cols: u16, connected: bool) !void {
    _ = cols;
    const w = buf.writer(a);
    try w.writeAll("\x1b[2J\x1b[H"); // clear + home
    var line: u16 = 1;
    // Header bar.
    try moveTo(w, line);
    try w.print("{s}Attyx \xe2\x80\x94 Agents{s}   {d} running \xc2\xb7 {s}{d} need input{s} \xc2\xb7 ${d:.2}{s}\x1b[K", .{
        bold,                            reset,
        m.n_working + m.n_input,         if (m.n_input > 0) c_input else dim,
        m.n_input,                       reset,
        m.total_cost,                    if (m.any_estimate) " (~est)" else "",
    });
    line += 1;
    // Column header.
    try moveTo(w, line);
    try w.print("{s}{s}{s}\x1b[K", .{ dim, try headerLine(a), reset });
    line += 1;

    const body_rows = if (rows > 5) rows - 4 else 1; // header(2) + totals + help
    if (m.count == 0) {
        try moveTo(w, line);
        try w.print("{s}  no agents running \xe2\x80\x94 launch claude/codex/opencode/pi in any pane{s}\x1b[K", .{ dim, reset });
    } else {
        var i: usize = 0;
        while (i < m.count and i < body_rows) : (i += 1) {
            const r = &m.rows[i];
            try moveTo(w, line);
            if (i == m.selected) {
                try w.print("{s}{s}\x1b[K{s}", .{ rev, try rowLine(a, r, "\xe2\x96\xb6"), reset });
            } else {
                try w.print("{s}{s}{s}\x1b[K", .{ stateColor(r.state), try rowLine(a, r, " "), reset });
            }
            line += 1;
        }
    }
    // Totals + help on the last two rows.
    if (rows >= 2) {
        try moveTo(w, rows - 1);
        try w.print("{s}{s}{s}\x1b[K", .{ bold, try totalsLine(a, m), reset });
        try moveTo(w, rows);
        if (connected) {
            try w.print("{s}  \xe2\x86\x91\xe2\x86\x93 select  \xe2\x8f\x8e focus pane  r refresh  q quit{s}\x1b[K", .{ dim, reset });
        } else {
            try w.print("{s}  {s}disconnected{s}{s} \xc2\xb7 q quit{s}\x1b[K", .{ dim, c_input, reset, dim, reset });
        }
    }
}

fn moveTo(w: anytype, row: u16) !void {
    try w.print("\x1b[{d};1H", .{row});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "snapshot renders a header, rows, and totals" {
    const ally = testing.allocator;
    var m = Model{};
    m.applyLine(ally, "{\"session\":1,\"pane_id\":3,\"state\":\"working\",\"usage\":{\"input_tokens\":1200000,\"output_tokens\":842000,\"context_used\":82000,\"context_max\":200000,\"cost_usd\":0.42,\"model\":\"opus-4.8\"}}");
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    var out = std.ArrayList(u8){};
    try snapshot(out.writer(arena.allocator()), arena.allocator(), &m);
    const s = out.items;
    try testing.expect(std.mem.indexOf(u8, s, "session") != null);
    try testing.expect(std.mem.indexOf(u8, s, "s1") != null);
    try testing.expect(std.mem.indexOf(u8, s, "opus-4.8") != null);
    try testing.expect(std.mem.indexOf(u8, s, "1.2M") != null);
    try testing.expect(std.mem.indexOf(u8, s, "$0.42") != null);
    try testing.expect(std.mem.indexOf(u8, s, "TOTAL") != null);
}

test "frame produces ANSI and is non-empty for empty + populated models" {
    const ally = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Model{};
    var buf = std.ArrayList(u8){};
    try frame(&buf, a, &m, 24, 100, true); // empty
    try testing.expect(std.mem.indexOf(u8, buf.items, "\x1b[2J") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "no agents") != null);
    buf.clearRetainingCapacity();
    m.applyLine(ally, "{\"session\":2,\"pane_id\":5,\"state\":\"input\"}");
    try frame(&buf, a, &m, 24, 100, true);
    try testing.expect(std.mem.indexOf(u8, buf.items, "input") != null);
}
