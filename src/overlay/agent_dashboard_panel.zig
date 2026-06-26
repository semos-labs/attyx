//! Agent dashboard panel — builds an Element tree from DashboardState and renders
//! it via panel.renderPanel(). A fixed-layout modal table: one row per active
//! agent (status dot + columns) plus a totals footer.
const std = @import("std");
const ui = @import("ui.zig");
const panel_mod = @import("panel.zig");
const dash = @import("agent_dashboard.zig");

const ui_cell = @import("ui_cell.zig");
const Element = ui.Element;
const Rgb = ui.Rgb;
const OverlayTheme = ui.OverlayTheme;
const PanelConfig = panel_mod.PanelConfig;
const PanelResult = panel_mod.PanelResult;
const DashboardState = dash.DashboardState;
const Row = dash.Row;
const AgentStatus = @import("../term/actions.zig").AgentStatus;

const dot_glyph = "\xe2\x97\x8f"; // "●" (no trailing space; padded to dot_w cols)
const middot = "\xe2\x80\xa2"; // "·"

fn statusColor(theme: OverlayTheme, s: AgentStatus) Rgb {
    return switch (s) {
        .working => theme.agent_working_fg,
        .input => theme.agent_attention_fg,
        .idle => theme.agent_ready_fg,
        .none => theme.hint_fg,
    };
}

/// Token count or "—".
fn tok(tmp: std.mem.Allocator, v: ?u64) []const u8 {
    if (v) |n| {
        var b: [16]u8 = undefined;
        return std.fmt.allocPrint(tmp, "{s}", .{dash.humanize(&b, n)}) catch "—";
    }
    return "\xe2\x80\x94"; // —
}

/// "used/max", "used", or "—".
fn ctxStr(tmp: std.mem.Allocator, used: ?u64, max: ?u64) []const u8 {
    if (used) |u| {
        var ub: [16]u8 = undefined;
        const us = dash.humanize(&ub, u);
        if (max) |m| {
            var mb: [16]u8 = undefined;
            return std.fmt.allocPrint(tmp, "{s}/{s}", .{ us, dash.humanize(&mb, m) }) catch "—";
        }
        return std.fmt.allocPrint(tmp, "{s}", .{us}) catch "—";
    }
    return "\xe2\x80\x94";
}

/// "$0.42", "~$0.31" (estimate), the row note ("needs input"), or "—".
fn costStr(tmp: std.mem.Allocator, row: *const Row) []const u8 {
    if (row.cost_usd) |c| {
        return std.fmt.allocPrint(tmp, "{s}${d:.2}", .{ if (row.cost_is_estimate) "~" else "", c }) catch "—";
    }
    if (row.note().len > 0) return row.note();
    return "\xe2\x80\x94";
}

// Column widths (display columns). dot_w is the status cell; the rest form the
// table body. content_w is the full table width the panel is sized to. All
// padding below is measured in DISPLAY columns (ui_cell.utf8Count), not bytes —
// "—"/"·"/"●" are multibyte but 1–2 columns, and Zig's {s:>N} would mis-pad them.
const dot_w: u16 = 2;
const pane_w: u16 = 5;
const session_w: u16 = 10;
const model_w: u16 = 13;
const in_w: u16 = 8;
const out_w: u16 = 8;
const ctx_w: u16 = 12;
const cost_w: u16 = 10;
const body_w: u16 = pane_w + session_w + model_w + in_w + out_w + ctx_w + cost_w; // 66
const lead_w: u16 = pane_w + session_w + model_w; // 28 (footer "TOTAL" span)
const content_w: u16 = dot_w + body_w; // 68

/// Append `s` to `buf` padded/truncated to exactly `width` display columns.
fn appendCol(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8, width: u16, right: bool) !void {
    const off = ui_cell.utf8ByteOffset(s, width);
    const shown = s[0..off];
    const w = ui_cell.utf8Count(shown);
    const pad: usize = if (width > w) width - w else 0;
    if (right) {
        try buf.appendNTimes(a, ' ', pad);
        try buf.appendSlice(a, shown);
    } else {
        try buf.appendSlice(a, shown);
        try buf.appendNTimes(a, ' ', pad);
    }
}

/// Build the `body_w`-column table body (pane/session/model left, numerics right).
fn buildBody(a: std.mem.Allocator, pane: []const u8, session: []const u8, model: []const u8, in: []const u8, out: []const u8, ctx: []const u8, cost: []const u8) ![]const u8 {
    var b = std.ArrayList(u8){};
    try appendCol(&b, a, pane, pane_w, false);
    try appendCol(&b, a, session, session_w, false);
    try appendCol(&b, a, model, model_w, false);
    try appendCol(&b, a, in, in_w, true);
    try appendCol(&b, a, out, out_w, true);
    try appendCol(&b, a, ctx, ctx_w, true);
    try appendCol(&b, a, cost, cost_w, true);
    return b.items;
}

/// A horizontal rule of `content_w` box-drawing chars (each 1 display column).
fn rule(tmp: std.mem.Allocator) []const u8 {
    const buf = tmp.alloc(u8, content_w * 3) catch return "";
    var i: usize = 0;
    while (i < content_w) : (i += 1) @memcpy(buf[i * 3 ..][0..3], "\xe2\x94\x80"); // ─
    return buf[0 .. content_w * 3];
}

/// The status cell, padded to exactly dot_w display columns (so the body always
/// starts at the same column whether `●` measures as 1 or 2 wide).
fn dotCell(tmp: std.mem.Allocator) []const u8 {
    const w = ui_cell.utf8Count(dot_glyph);
    if (w >= dot_w) return dot_glyph;
    var b = std.ArrayList(u8){};
    b.appendSlice(tmp, dot_glyph) catch return dot_glyph;
    b.appendNTimes(tmp, ' ', dot_w - w) catch return dot_glyph;
    return b.items;
}

fn dim(content: []const u8) Element {
    return .{ .text = .{ .content = content, .wrap = false, .style = .{ .text_flags = .{ .dim = true } } } };
}

/// `"  " + body` (a non-data row: the 2-col status cell is blank).
fn bodyRow(tmp: std.mem.Allocator, body: []const u8) ![]const u8 {
    return std.fmt.allocPrint(tmp, "  {s}", .{body});
}

pub fn renderAgentDashboard(
    allocator: std.mem.Allocator,
    state: *const DashboardState,
    grid_cols: u16,
    grid_rows: u16,
    theme: OverlayTheme,
) !PanelResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const tmp = arena.allocator();

    var children = std.ArrayList(Element){};

    // Summary line (bold) + spacer.
    const summary = try std.fmt.allocPrint(tmp, "{d} {s} {s} ${d:.2} this session{s}", .{
        state.row_count,
        if (state.row_count == 1) "agent" else "agents",
        middot,
        state.total_cost,
        if (state.any_estimate) " (incl. est)" else "",
    });
    try children.append(tmp, .{ .text = .{ .content = summary, .wrap = false, .style = .{ .text_flags = .{ .bold = true } } } });
    try children.append(tmp, .{ .text = .{ .content = " ", .wrap = false } });

    // Header + rule.
    const header_body = try buildBody(tmp, "pane", "session", "model", "in", "out", "ctx", "cost");
    try children.append(tmp, dim(try bodyRow(tmp, header_body)));
    try children.append(tmp, dim(rule(tmp)));

    if (state.row_count == 0) {
        try children.append(tmp, dim("  no active agents"));
    }

    // One row per agent: [status cell (colored, dot_w wide)][body]. The body
    // starts at the same column as the header/footer (which use a blank cell).
    for (state.rowsSlice()) |*row| {
        const pane = try std.fmt.allocPrint(tmp, "{d}", .{row.pane_id});
        const body = try buildBody(
            tmp,
            pane,
            row.session(),
            row.model(),
            tok(tmp, row.input_tokens),
            tok(tmp, row.output_tokens),
            ctxStr(tmp, row.context_used, row.context_max),
            costStr(tmp, row),
        );
        const pair = try tmp.alloc(Element, 2);
        pair[0] = .{ .text = .{ .content = dotCell(tmp), .wrap = false, .style = .{ .fg = statusColor(theme, row.status) } } };
        pair[1] = .{ .text = .{ .content = body, .wrap = false } };
        try children.append(tmp, .{ .box = .{ .children = pair, .direction = .horizontal } });
    }

    // Rule + totals footer (bold). "TOTAL" spans the lead group; numerics align.
    try children.append(tmp, dim(rule(tmp)));
    const cost_total = try std.fmt.allocPrint(tmp, "{s}${d:.2}", .{ if (state.any_estimate) "~" else "", state.total_cost });
    var fb = std.ArrayList(u8){};
    try appendCol(&fb, tmp, "TOTAL", lead_w, false);
    try appendCol(&fb, tmp, tok(tmp, state.total_input), in_w, true);
    try appendCol(&fb, tmp, tok(tmp, state.total_output), out_w, true);
    try appendCol(&fb, tmp, "", ctx_w, true);
    try appendCol(&fb, tmp, cost_total, cost_w, true);
    try children.append(tmp, .{ .text = .{ .content = try bodyRow(tmp, fb.items), .wrap = false, .style = .{ .text_flags = .{ .bold = true } } } });

    const content = Element{ .box = .{ .children = children.items, .direction = .vertical } };
    // Size the panel to the content: width = table + padding(2) + border(2);
    // height = one row per child + border(2). No giant empty box.
    const panel_w: u16 = content_w + 4;
    const panel_h: u16 = @as(u16, @intCast(children.items.len)) + 2;
    const config = PanelConfig{
        .title = "Agents",
        .width = .{ .cells = panel_w },
        .height = .{ .cells = panel_h },
        .border = .rounded,
        .theme = theme,
    };
    return panel_mod.renderPanel(allocator, config, content, grid_cols, grid_rows);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "renderAgentDashboard produces a non-empty panel" {
    const allocator = std.testing.allocator;
    var st = DashboardState{};
    var r = Row{ .pane_id = 3, .status = .working, .input_tokens = 1_200_000, .output_tokens = 842_000, .context_used = 82_000, .context_max = 200_000, .cost_usd = 0.42 };
    r.session_len = dash.copyField(&r.session_buf, "myapp");
    r.model_len = dash.copyField(&r.model_buf, "opus-4.6");
    st.addRow(r);

    const result = try renderAgentDashboard(allocator, &st, 100, 30, .{});
    defer allocator.free(result.cells);
    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height > 0);
}

test "buildBody pads every row to body_w display columns (alignment)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Header, a fully-unknown row (em-dashes), a unicode session, and a full
    // data row must all measure exactly body_w columns so the table aligns.
    const cases = [_][]const u8{
        try buildBody(a, "pane", "session", "model", "in", "out", "ctx", "cost"),
        try buildBody(a, "7", "\xe2\x80\xa2 Check", "gpt-5.5", "\xe2\x80\x94", "\xe2\x80\x94", "\xe2\x80\x94", "\xe2\x80\x94"),
        try buildBody(a, "3", "myapp", "opus-4.8", "1.2M", "842K", "82K/200K", "$0.42"),
        try buildBody(a, "12", "a-very-long-session-name", "a-very-long-model-name", "999K", "999K", "1.0M/1.0M", "~$123.45"),
    };
    for (cases) |c| try std.testing.expectEqual(body_w, ui_cell.utf8Count(c));
    // The status cell is always exactly dot_w columns.
    try std.testing.expectEqual(dot_w, ui_cell.utf8Count(dotCell(a)));
}

test "renderAgentDashboard handles the empty case" {
    const allocator = std.testing.allocator;
    const st = DashboardState{};
    const result = try renderAgentDashboard(allocator, &st, 80, 24, .{});
    defer allocator.free(result.cells);
    try std.testing.expect(result.width > 0);
}
