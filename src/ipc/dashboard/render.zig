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
const mark_w: u16 = 2;
const session_w: u16 = 10;
const pane_w: u16 = 5;
const model_w: u16 = 16;
const state_w: u16 = 8;
const age_w: u16 = 6;
const in_w: u16 = 8;
const out_w: u16 = 8;
const ctx_w: u16 = 14;
const cost_w: u16 = 10;
// 10 body columns => 9 gutters.
pub const table_w: u16 = mark_w + session_w + pane_w + model_w + state_w + age_w + in_w + out_w + ctx_w + cost_w + gw * 9;

const ellipsis = "\xe2\x80\xa6"; // …

// ANSI
const reset = "\x1b[0m";
const dim = "\x1b[2m";
const bold = "\x1b[1m";
const rev = "\x1b[7m";
const c_idle = "\x1b[38;2;96;208;120m";
const c_working = "\x1b[38;2;255;170;64m";
const c_input = "\x1b[38;2;176;112;255m";

/// id→name lookup for the session column. Populated by run.zig from
/// `session_list`; the model stays id-based.
pub const NameCache = struct {
    ids: [64]u32 = undefined,
    names: [64][24]u8 = undefined,
    lens: [64]u8 = undefined,
    n: usize = 0,

    pub fn clear(self: *NameCache) void {
        self.n = 0;
    }
    pub fn set(self: *NameCache, id: u32, name: []const u8) void {
        for (0..self.n) |i| {
            if (self.ids[i] == id) {
                self.lens[i] = copyName(&self.names[i], name);
                return;
            }
        }
        if (self.n >= self.ids.len) return;
        self.ids[self.n] = id;
        self.lens[self.n] = copyName(&self.names[self.n], name);
        self.n += 1;
    }
    pub fn get(self: *const NameCache, id: u32) ?[]const u8 {
        for (0..self.n) |i| {
            if (self.ids[i] == id and self.lens[i] > 0) return self.names[i][0..self.lens[i]];
        }
        return null;
    }
};
fn copyName(buf: *[24]u8, s: []const u8) u8 {
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    return @intCast(n);
}

pub const Ctx = struct {
    now_ms: i64 = 0,
    names: ?*const NameCache = null,
    connected: bool = true,
    detail: bool = false,
    confirm_close: bool = false,
};

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

/// Human elapsed since `since_ms` (e.g. "5s", "1m12s", "2h3m"). "-" if unknown.
fn fmtAge(buf: []u8, now_ms: i64, since_ms: i64) []const u8 {
    if (since_ms == 0 or now_ms < since_ms) return "-";
    const secs: u64 = @intCast(@divTrunc(now_ms - since_ms, 1000));
    if (secs < 60) return std.fmt.bufPrint(buf, "{d}s", .{secs}) catch "-";
    if (secs < 3600) return std.fmt.bufPrint(buf, "{d}m{d}s", .{ secs / 60, secs % 60 }) catch "-";
    return std.fmt.bufPrint(buf, "{d}h{d}m", .{ secs / 3600, (secs % 3600) / 60 }) catch "-";
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

fn buildLine(a: std.mem.Allocator, cols: [10][]const u8, rights: [10]bool) ![]const u8 {
    const widths = [10]u16{ mark_w, session_w, pane_w, model_w, state_w, age_w, in_w, out_w, ctx_w, cost_w };
    var b = std.ArrayList(u8){};
    for (cols, widths, rights, 0..) |c, width, r, i| {
        try appendCol(&b, a, c, width, r);
        if (i + 1 < cols.len) try b.appendSlice(a, gutter);
    }
    return b.items;
}

fn rowLine(a: std.mem.Allocator, r: *const Row, marker: []const u8, ctx: Ctx) ![]const u8 {
    var sb: [24]u8 = undefined;
    var pb: [16]u8 = undefined;
    var ab: [16]u8 = undefined;
    var ib: [16]u8 = undefined;
    var ob: [16]u8 = undefined;
    var cb: [24]u8 = undefined;
    var kb: [24]u8 = undefined;
    const session = if (ctx.names != null and ctx.names.?.get(r.session) != null)
        ctx.names.?.get(r.session).?
    else
        std.fmt.bufPrint(&sb, "s{d}", .{r.session}) catch "s?";
    return buildLine(a, .{
        marker,
        session,
        std.fmt.bufPrint(&pb, "{d}", .{r.pane_id}) catch "?",
        if (r.model_len > 0) r.model() else "\xe2\x80\x94",
        stateLabel(r.state),
        fmtAge(&ab, ctx.now_ms, r.state_since_ms),
        fmt.tokensOpt(&ib, r.input_tokens),
        fmt.tokensOpt(&ob, r.output_tokens),
        fmt.ctx(&kb, r.context_used, r.context_max),
        fmt.cost(&cb, r.cost_usd, r.cost_is_estimate),
    }, .{ false, false, false, false, false, true, true, true, true, true });
}

fn headerLine(a: std.mem.Allocator) ![]const u8 {
    return buildLine(a, .{ " ", "session", "pane", "model", "state", "age", "in", "out", "ctx", "cost" }, .{ false, false, false, false, false, true, true, true, true, true });
}

fn totalsLine(a: std.mem.Allocator, m: *const Model) ![]const u8 {
    var ib: [16]u8 = undefined;
    var ob: [16]u8 = undefined;
    var cb: [24]u8 = undefined;
    const cost = std.fmt.bufPrint(&cb, "{s}${d:.2}", .{ if (m.any_estimate) "~" else "", m.total_cost }) catch "$?";
    return buildLine(a, .{ " ", "TOTAL", "", "", "", "", fmt.tokens(&ib, m.total_input), fmt.tokens(&ob, m.total_output), "", cost }, .{ false, false, false, false, false, true, true, true, true, true });
}

/// Plain-text table to `writer` (for `--once` / non-TTY). No ANSI.
pub fn snapshot(writer: anytype, a: std.mem.Allocator, m: *const Model, ctx: Ctx) !void {
    try writer.print("{d} agents \xc2\xb7 {d} working \xc2\xb7 {d} need input \xc2\xb7 ${d:.2}{s}\n", .{
        m.count, m.n_working, m.n_input, m.total_cost, if (m.any_estimate) " (incl. est)" else "",
    });
    try writer.print("{s}\n", .{try headerLine(a)});
    if (m.visibleCount() == 0) {
        try writer.writeAll("  (no agents)\n");
    } else {
        var i: usize = 0;
        while (i < m.visibleCount()) : (i += 1) try writer.print("{s}\n", .{try rowLine(a, m.rowAt(i), " ", ctx)});
    }
    try writer.print("{s}\n", .{try totalsLine(a, m)});
}

/// Full-screen ANSI frame into `buf` (for the interactive TUI).
pub fn frame(buf: *std.ArrayList(u8), a: std.mem.Allocator, m: *const Model, rows: u16, cols: u16, ctx: Ctx) !void {
    _ = cols;
    const w = buf.writer(a);
    try w.writeAll("\x1b[2J\x1b[H");
    var line: u16 = 1;
    try moveTo(w, line);
    try w.print("{s}Attyx \xe2\x80\x94 Agents{s}   {d} running \xc2\xb7 {s}{d} need input{s} \xc2\xb7 ${d:.2}{s}\x1b[K", .{
        bold,                    reset,
        m.n_working + m.n_input, if (m.n_input > 0) c_input else dim,
        m.n_input,               reset,
        m.total_cost,            if (m.any_estimate) " (~est)" else "",
    });
    line += 1;
    try moveTo(w, line);
    try w.print("{s}{s}{s}\x1b[K", .{ dim, try headerLine(a), reset });
    line += 1;

    // Reserve rows: 2 header + totals + help (+ up to 5 detail lines).
    const detail_rows: u16 = if (ctx.detail and m.selectedRow() != null) 5 else 0;
    const reserved: u16 = 4 + detail_rows;
    const body_rows = if (rows > reserved + 1) rows - reserved else 1;
    if (m.visibleCount() == 0) {
        try moveTo(w, line);
        try w.print("{s}  no agents \xe2\x80\x94 launch claude/codex/opencode/pi in any pane{s}\x1b[K", .{ dim, reset });
    } else {
        var i: usize = 0;
        while (i < m.visibleCount() and i < body_rows) : (i += 1) {
            const r = m.rowAt(i);
            try moveTo(w, line);
            if (i == m.selected) {
                try w.print("{s}{s}\x1b[K{s}", .{ rev, try rowLine(a, r, "\xe2\x96\xb6", ctx), reset });
            } else {
                try w.print("{s}{s}{s}\x1b[K", .{ stateColor(r.state), try rowLine(a, r, " ", ctx), reset });
            }
            line += 1;
        }
    }

    if (detail_rows > 0) try detailPanel(w, a, m.selectedRow().?, rows - reserved + 1, ctx);

    if (rows >= 2) {
        try moveTo(w, rows - 1);
        try w.print("{s}{s}{s}\x1b[K", .{ bold, try totalsLine(a, m), reset });
        try moveTo(w, rows);
        try helpLine(w, m, ctx);
    }
}

fn detailPanel(w: anytype, a: std.mem.Allocator, r: *const Row, at: u16, ctx: Ctx) !void {
    _ = a;
    var ab: [16]u8 = undefined;
    var ib: [16]u8 = undefined;
    var ob: [16]u8 = undefined;
    var kb: [24]u8 = undefined;
    var cb: [24]u8 = undefined;
    const name = if (ctx.names != null and ctx.names.?.get(r.session) != null) ctx.names.?.get(r.session).? else "";
    try moveTo(w, at);
    try w.print("{s}\xe2\x94\x80\xe2\x94\x80 detail \xe2\x94\x80\xe2\x94\x80{s}\x1b[K", .{ dim, reset });
    try moveTo(w, at + 1);
    try w.print("  session {d}{s}{s}{s} \xc2\xb7 pane {d} \xc2\xb7 {s}{s}{s} \xc2\xb7 {s}\x1b[K", .{
        r.session, if (name.len > 0) " (" else "", name, if (name.len > 0) ")" else "",
        r.pane_id, stateColor(r.state), stateLabel(r.state), reset, fmtAge(&ab, ctx.now_ms, r.state_since_ms),
    });
    try moveTo(w, at + 2);
    try w.print("  {s} \xc2\xb7 in {s} \xc2\xb7 out {s} \xc2\xb7 ctx {s} \xc2\xb7 {s}\x1b[K", .{
        if (r.model_len > 0) r.model() else "\xe2\x80\x94",
        fmt.tokensOpt(&ib, r.input_tokens), fmt.tokensOpt(&ob, r.output_tokens),
        fmt.ctx(&kb, r.context_used, r.context_max), fmt.cost(&cb, r.cost_usd, r.cost_is_estimate),
    });
    try moveTo(w, at + 3);
    const msg = if (r.msg_len > 0) r.message() else "\xe2\x80\x94";
    try w.print("  {s}{s}{s}\x1b[K", .{ dim, msg, reset });
}

fn helpLine(w: anytype, m: *const Model, ctx: Ctx) !void {
    if (ctx.confirm_close) {
        if (m.selectedRow()) |r| {
            try w.print("{s}close pane {d}? {s}y/N{s}\x1b[K", .{ c_input, r.pane_id, bold, reset });
            return;
        }
    }
    const q = m.searchQuery();
    if (q.len > 0) {
        try w.print("{s}  /{s}  \xc2\xb7  sort:{s} filter:{s}  \xc2\xb7  esc clear{s}\x1b[K", .{ dim, q, m.sort_mode.label(), m.filter_mode.label(), reset });
        return;
    }
    if (!ctx.connected) {
        try w.print("{s}  {s}disconnected{s}{s} \xc2\xb7 reconnecting \xc2\xb7 q quit{s}\x1b[K", .{ dim, c_input, reset, dim, reset });
        return;
    }
    try w.print("{s}  \xe2\x86\x91\xe2\x86\x93 sel  \xe2\x8f\x8e focus  z zoom  x close  s sort:{s}  f filter:{s}  / search  \xe2\x87\xa5 detail  q quit{s}\x1b[K", .{ dim, m.sort_mode.label(), m.filter_mode.label(), reset });
}

fn moveTo(w: anytype, row: u16) !void {
    try w.print("\x1b[{d};1H", .{row});
}

const testing = std.testing;

test "frame renders without overflow; view-based; age + detail" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Model{};
    var buf = std.ArrayList(u8){};
    try frame(&buf, a, &m, 24, 100, .{}); // empty
    buf.clearRetainingCapacity();
    m.applyLine(a, "{\"session\":1,\"pane_id\":3,\"state\":\"working\",\"usage\":{\"model\":\"opus-4.8\",\"input_tokens\":1200000}}", 5000);
    try frame(&buf, a, &m, 24, 100, .{ .now_ms = 65000, .detail = true });
    try testing.expect(std.mem.indexOf(u8, buf.items, "opus-4.8") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "1m0s") != null); // age 60s
    try testing.expect(std.mem.indexOf(u8, buf.items, "detail") != null);
}

test "name cache resolves the session column" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Model{};
    m.applyLine(a, "{\"session\":7,\"pane_id\":1,\"state\":\"idle\"}", 0);
    var names = NameCache{};
    names.set(7, "build");
    var buf = std.ArrayList(u8){};
    try frame(&buf, a, &m, 24, 100, .{ .names = &names });
    try testing.expect(std.mem.indexOf(u8, buf.items, "build") != null);
}
