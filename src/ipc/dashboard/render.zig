//! Dashboard rendering: a width-correct agent table, in two flavors —
//! `snapshot` (plain text for `--once`/non-TTY) and `frame` (full-screen ANSI
//! for the interactive TUI). Column widths are measured in display columns via
//! the engine's `ui_cell` helpers so multibyte/wide chars never misalign.
const std = @import("std");
const model = @import("model.zig");
const fmt = @import("format.zig");
const prompt = @import("prompt.zig");
const ui_cell = @import("attyx").overlay_ui_cell;

const Model = model.Model;
const Row = model.Row;
const State = model.State;

// Column display widths and the 2-col gutter between them. Column 0 is the
// status dot; a 2-col selection marker (▶) is prepended outside buildLine.
const gutter = "  ";
const gw: u16 = 2;
const dot_w: u16 = 2;
const session_w: u16 = 10;
const tab_w: u16 = 14;
const pane_w: u16 = 5;
const model_w: u16 = 16;
const state_w: u16 = 8;
const elapsed_w: u16 = 7;
const in_w: u16 = 8;
const out_w: u16 = 8;
const ctx_w: u16 = 14;
const cost_w: u16 = 10;
const n_cols = 11;
const col_widths = [n_cols]u16{ dot_w, session_w, tab_w, pane_w, model_w, state_w, elapsed_w, in_w, out_w, ctx_w, cost_w };
const col_right = [n_cols]bool{ false, false, false, false, false, false, true, true, true, true, true };
const dot = "\xe2\x97\x8f"; // ●
const marker_sel = "\xe2\x96\xb6 "; // ▶ + space
const marker_none = "  ";

const ellipsis = "\xe2\x80\xa6"; // …

// ANSI
const reset = "\x1b[0m";
const fg_reset = "\x1b[39m"; // reset foreground only (keeps a selection background)
const dim = "\x1b[2m";
const bold = "\x1b[1m";
const sel_bg = "\x1b[48;2;48;48;54m"; // subtle highlight for the selected row
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
    interact: ?*const prompt.Interact = null,
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

/// Append `s` in exactly `width` display columns. `color` (empty = none) wraps
/// only the text; padding stays uncolored and we reset foreground only
/// (`fg_reset`) so a selection background survives the cell.
fn appendColC(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8, width: u16, right: bool, color: []const u8) !void {
    const full = ui_cell.utf8Count(s);
    var shown = s;
    var content_w = full;
    if (full > width) {
        const off = ui_cell.utf8ByteOffset(s, width - 1);
        shown = s[0..off];
        content_w = ui_cell.utf8Count(shown) + 1;
    }
    const pad: usize = if (width > content_w) width - content_w else 0;
    if (right) try buf.appendNTimes(a, ' ', pad);
    if (color.len > 0) try buf.appendSlice(a, color);
    try buf.appendSlice(a, shown);
    if (full > width) try buf.appendSlice(a, ellipsis);
    if (color.len > 0) try buf.appendSlice(a, fg_reset);
    if (!right) try buf.appendNTimes(a, ' ', pad);
}

/// Build a table line (10 columns) with optional per-column color.
fn buildLine(a: std.mem.Allocator, cols: [n_cols][]const u8, colors: [n_cols][]const u8) ![]const u8 {
    var b = std.ArrayList(u8){};
    for (cols, col_widths, col_right, colors, 0..) |c, width, r, color, i| {
        try appendColC(&b, a, c, width, r, color);
        if (i + 1 < cols.len) try b.appendSlice(a, gutter);
    }
    return b.items;
}

const no_colors = [_][]const u8{""} ** n_cols;

fn rowLine(a: std.mem.Allocator, r: *const Row, ctx: Ctx, color: bool) ![]const u8 {
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
    var colors = no_colors;
    if (color) {
        colors[0] = stateColor(r.state); // dot
        colors[5] = stateColor(r.state); // state
    }
    return buildLine(a, .{
        dot,
        session,
        if (r.tab_len > 0) r.tabName() else "\xe2\x80\x94",
        std.fmt.bufPrint(&pb, "{d}", .{r.pane_id}) catch "?",
        if (r.model_len > 0) r.model() else "\xe2\x80\x94",
        stateLabel(r.state),
        fmtAge(&ab, ctx.now_ms, r.state_since_ms),
        fmt.tokensOpt(&ib, r.input_tokens),
        fmt.tokensOpt(&ob, r.output_tokens),
        fmt.ctx(&kb, r.context_used, r.context_max),
        fmt.cost(&cb, r.cost_usd, r.cost_is_estimate),
    }, colors);
}

fn headerLine(a: std.mem.Allocator) ![]const u8 {
    return buildLine(a, .{ " ", "SESSION", "TAB", "PANE", "MODEL", "STATE", "ELAPSED", "IN", "OUT", "CTX", "COST" }, no_colors);
}

fn totalsLine(a: std.mem.Allocator, m: *const Model) ![]const u8 {
    var ib: [16]u8 = undefined;
    var ob: [16]u8 = undefined;
    var cb: [24]u8 = undefined;
    const cost = std.fmt.bufPrint(&cb, "{s}${d:.2}", .{ if (m.any_estimate) "~" else "", m.total_cost }) catch "$?";
    return buildLine(a, .{ " ", "TOTAL", "", "", "", "", "", fmt.tokens(&ib, m.total_input), fmt.tokens(&ob, m.total_output), "", cost }, no_colors);
}

/// Plain-text table to `writer` (for `--once` / non-TTY). No ANSI.
pub fn snapshot(writer: anytype, a: std.mem.Allocator, m: *const Model, ctx: Ctx) !void {
    try writer.print("{d} agents \xc2\xb7 {d} working \xc2\xb7 {d} need input \xc2\xb7 ${d:.2}{s}\n", .{
        m.count, m.n_working, m.n_input, m.total_cost, if (m.any_estimate) " (incl. est)" else "",
    });
    try writer.print("  {s}\n", .{try headerLine(a)});
    if (m.visibleCount() == 0) {
        try writer.writeAll("  (no agents)\n");
    } else {
        var i: usize = 0;
        while (i < m.visibleCount()) : (i += 1) try writer.print("  {s}\n", .{try rowLine(a, m.rowAt(i), ctx, false)});
    }
    try writer.print("  {s}\n", .{try totalsLine(a, m)});
}

const interact_msg_rows: u16 = 5; // message scroll-area height inside the panel

/// Rows the inline interaction panel occupies: a label, the message area, a hint,
/// plus the input row (reply) or question+buttons rows (options).
fn interactRows(it: *const prompt.Interact) u16 {
    return interact_msg_rows + 2 + (if (it.mode == .options) @as(u16, 2) else 1);
}

/// The session column's display name: the cached name, else `s<id>`.
fn sessionName(ctx: Ctx, id: u32, buf: []u8) []const u8 {
    if (ctx.names) |nm| {
        if (nm.get(id)) |n| return n;
    }
    return std.fmt.bufPrint(buf, "s{d}", .{id}) catch "s?";
}

/// Distinct sessions in the view. Rows are session-contiguous under the session
/// sort, so a change-count is exact — used to reserve group-header rows.
fn distinctSessions(m: *const Model) u16 {
    var n: u16 = 0;
    var prev: u32 = 0;
    var have = false;
    var i: usize = 0;
    while (i < m.visibleCount()) : (i += 1) {
        const s = m.rowAt(i).session;
        if (!have or s != prev) {
            n += 1;
            prev = s;
            have = true;
        }
    }
    return n;
}

/// Full-screen ANSI frame into `buf` (for the interactive TUI).
pub fn frame(buf: *std.ArrayList(u8), a: std.mem.Allocator, m: *const Model, rows: u16, cols: u16, ctx: Ctx) !void {
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
    try w.print("{s}  {s}{s}\x1b[K", .{ dim, try headerLine(a), reset });
    line += 1;

    // The inline interaction panel (expanded under the selected row) and the
    // detail panel are mutually exclusive — both expand the selection.
    const it: ?*const prompt.Interact = blk: {
        const p = ctx.interact orelse break :blk null;
        if (p.mode != .none and m.selectedRow() != null) break :blk p;
        break :blk null;
    };
    const panel_rows: u16 = if (it) |x| interactRows(x) else 0;
    const detail_rows: u16 = if (it == null and ctx.detail and m.selectedRow() != null) 5 else 0;
    // Agents are always grouped by session (the view is session-contiguous), so
    // we emit a header whenever the session changes. Headers reserve rows.
    const group = m.visibleCount() > 0;
    const header_rows: u16 = distinctSessions(m);
    const reserved: u16 = 4 + detail_rows + panel_rows + header_rows;
    const body_rows = if (rows > reserved + 1) rows - reserved else 1;
    if (m.visibleCount() == 0) {
        try moveTo(w, line);
        try w.print("{s}  no agents \xe2\x80\x94 launch claude/codex/opencode/pi in any pane{s}\x1b[K", .{ dim, reset });
    } else {
        var i: usize = 0;
        var shown: u16 = 0;
        var prev_sess: u32 = 0;
        var have_prev = false;
        var sb: [24]u8 = undefined;
        while (i < m.visibleCount() and shown < body_rows) : (i += 1) {
            const r = m.rowAt(i);
            if (group and (!have_prev or r.session != prev_sess)) {
                try moveTo(w, line);
                try w.print("{s}  {s}{s}\x1b[K", .{ dim, sessionName(ctx, r.session, &sb), reset });
                line += 1;
                prev_sess = r.session;
                have_prev = true;
            }
            try moveTo(w, line);
            if (i == m.selected) {
                // Subtle background highlight; per-cell colors use fg-only resets
                // so the background survives across the row, and \x1b[K fills it.
                try w.print("{s}{s}{s}\x1b[K{s}", .{ sel_bg, marker_sel, try rowLine(a, r, ctx, true), reset });
            } else {
                try w.print("{s}{s}{s}\x1b[K", .{ marker_none, try rowLine(a, r, ctx, true), reset });
            }
            line += 1;
            shown += 1;
            if (it != null and i == m.selected) {
                try drawInteract(w, line, cols, it.?);
                line += panel_rows;
            }
        }
    }

    if (detail_rows > 0) try detailPanel(w, a, m.selectedRow().?, rows - reserved + 1, ctx);

    if (rows >= 2) {
        try moveTo(w, rows - 1);
        try w.print("{s}  {s}{s}\x1b[K", .{ bold, try totalsLine(a, m), reset });
        try moveTo(w, rows);
        try helpLine(w, m, ctx);
    }
}

/// The expanded interaction panel under the selected row: a scrollable view of
/// the agent's last message, then either a reply input line or the parsed option
/// picker. `line0` is the first panel row; it consumes `interactRows(it)` rows.
fn drawInteract(w: anytype, line0: u16, cols: u16, it: *const prompt.Interact) !void {
    var line = line0;
    try moveTo(w, line);
    try w.print("{s}  \xe2\x95\xb0 pane {d} \xc2\xb7 last message{s}\x1b[K", .{ dim, it.pane_id, reset });
    line += 1;

    // Message area: wrap, then show a scrolled window.
    const inner_w: usize = if (cols > 8) cols - 8 else 24;
    var wrapped: [512][]const u8 = undefined;
    const nlines = wrapText(it.msg(), inner_w, &wrapped);
    const start = clampScroll(it.msg_scroll, nlines, interact_msg_rows);
    var k: u16 = 0;
    while (k < interact_msg_rows) : (k += 1) {
        try moveTo(w, line);
        const idx = start + k;
        if (idx < nlines) {
            try w.print("{s}  \xe2\x94\x82 {s}{s}\x1b[K", .{ dim, reset, wrapped[idx] });
        } else if (k == 0 and nlines == 0) {
            try w.print("{s}  \xe2\x94\x82 (no recent message){s}\x1b[K", .{ dim, reset });
        } else {
            try w.print("{s}  \xe2\x94\x82{s}\x1b[K", .{ dim, reset });
        }
        line += 1;
    }

    switch (it.mode) {
        .none => {},
        .reply => {
            try moveTo(w, line);
            try w.print("{s}  reply \xe2\x96\xb8 {s}{s}\xe2\x96\x88\x1b[K", .{ c_input, reset, it.reply() });
            line += 1;
        },
        .options => {
            try moveTo(w, line);
            try w.print("{s}  {s}{s}\x1b[K", .{ dim, it.prompt.question(), reset });
            line += 1;
            try moveTo(w, line);
            try w.writeAll("  ");
            var i: usize = 0;
            while (i < it.prompt.n) : (i += 1) {
                const o = &it.prompt.options[i];
                if (i == it.sel) {
                    try w.print("{s}{s} {d} {s} {s} ", .{ sel_bg, bold, o.num, o.label(), reset });
                } else {
                    try w.print("{s} {d} {s} {s} ", .{ dim, o.num, o.label(), reset });
                }
            }
            try w.writeAll("\x1b[K");
            line += 1;
        },
    }

    try moveTo(w, line);
    const hint = if (it.mode == .options)
        "j/k or 1-9 \xc2\xb7 \xe2\x8f\x8e send \xc2\xb7 ^U/^D scroll \xc2\xb7 esc"
    else
        "\xe2\x8f\x8e send \xc2\xb7 ^U/^D scroll \xc2\xb7 esc cancel";
    try w.print("{s}  {s}{s}\x1b[K", .{ dim, hint, reset });
}

/// Wrap `text` (newline-separated) to `width` byte-columns, filling `out` with
/// slices into `text`. Breaks on UTF-8 boundaries (no mid-codepoint cuts).
/// Approximate for wide chars — fine for a preview. Returns the line count.
fn wrapText(text: []const u8, width: usize, out: [][]const u8) usize {
    var n: usize = 0;
    var segs = std.mem.splitScalar(u8, text, '\n');
    while (segs.next()) |seg| {
        if (n >= out.len) break;
        if (seg.len == 0) {
            out[n] = "";
            n += 1;
            continue;
        }
        var s = seg;
        while (s.len > 0 and n < out.len) {
            if (s.len <= width) {
                out[n] = s;
                n += 1;
                break;
            }
            var brk = width;
            while (brk > 0 and (s[brk] & 0xC0) == 0x80) brk -= 1;
            if (brk == 0) brk = width;
            out[n] = s[0..brk];
            n += 1;
            s = s[brk..];
        }
    }
    return n;
}

fn clampScroll(scroll: usize, total: usize, rows_avail: u16) usize {
    if (total <= rows_avail) return 0;
    return @min(scroll, total - rows_avail);
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
    try w.print("{s}  \xe2\x86\x91\xe2\x86\x93 sel  \xe2\x8f\x8e focus  i reply  z zoom  x close  s sort:{s}  f filter:{s}  / search  \xe2\x87\xa5 detail  q quit{s}\x1b[K", .{ dim, m.sort_mode.label(), m.filter_mode.label(), reset });
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

test "tab_name from the record shows in the TAB column" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Model{};
    m.applyLine(a, "{\"session\":1,\"pane_id\":2,\"tab_name\":\"api-server\",\"state\":\"working\"}", 0);
    var buf = std.ArrayList(u8){};
    try frame(&buf, a, &m, 24, 120, .{});
    try testing.expect(std.mem.indexOf(u8, buf.items, "TAB") != null); // header
    try testing.expect(std.mem.indexOf(u8, buf.items, "api-server") != null);
}

test "inline interact panel renders message, question and options" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Model{};
    m.applyLine(a, "{\"session\":1,\"pane_id\":3,\"state\":\"input\"}", 0);
    var it = prompt.Interact{ .pane_id = 3, .mode = .options };
    it.setMsg("finished the refactor");
    it.prompt = prompt.Prompt.parse("Proceed?\n1. Yes\n2. No").?;
    var buf = std.ArrayList(u8){};
    try frame(&buf, a, &m, 24, 100, .{ .interact = &it });
    try testing.expect(std.mem.indexOf(u8, buf.items, "finished the refactor") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "Proceed?") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "Yes") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "last message") != null);
}

test "agents are grouped under per-session headers (any sort)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Model{};
    m.applyLine(a, "{\"session\":1,\"pane_id\":1,\"state\":\"working\"}", 0);
    m.applyLine(a, "{\"session\":2,\"pane_id\":2,\"state\":\"working\"}", 0);
    var names = NameCache{};
    names.set(1, "web");
    names.set(2, "api");
    m.sort_mode = .state; // grouping is independent of the sort mode now
    m.refresh(0);
    var buf = std.ArrayList(u8){};
    try frame(&buf, a, &m, 24, 100, .{ .names = &names });
    // A header line is a dimmed bare session name (distinct from the row's cell).
    try testing.expect(std.mem.indexOf(u8, buf.items, "\x1b[2m  web\x1b[0m") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\x1b[2m  api\x1b[0m") != null);
}

test "wrapText breaks long lines and respects newlines" {
    var out: [16][]const u8 = undefined;
    // "hello" (1) + "worldworldworld" (15 chars / 6 = 3 chunks) = 4 lines.
    const n = wrapText("hello\nworldworldworld", 6, &out);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualStrings("hello", out[0]);
    try testing.expectEqualStrings("worldw", out[1]);
    try testing.expectEqualStrings("rld", out[3]);
    try testing.expectEqual(@as(usize, 0), clampScroll(10, 3, 5)); // fits → no scroll
    try testing.expectEqual(@as(usize, 2), clampScroll(10, 7, 5)); // clamp to last page
}
