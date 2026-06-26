//! Agent dashboard — pure state for the live token/cost/context overlay.
//!
//! No side effects, no app-layer dependencies (testable headless). The app glue
//! (`src/app/ui/agent_dashboard_ui.zig`) enumerates panes, resolves usage +
//! estimated cost, and fills this with display-ready rows; the panel renders it.
//! A fixed-layout modal table redrawn on a tick — deliberately not reflow-aware
//! inline content.
const std = @import("std");
const AgentStatus = @import("../term/actions.zig").AgentStatus;

pub const max_rows = 64;

/// One agent's row. Numeric fields are optional — `null` renders as "—", never
/// "0", so we never imply zero spend where we simply lack data.
pub const Row = struct {
    pane_id: u32 = 0,
    status: AgentStatus = .none,
    session_buf: [24]u8 = undefined,
    session_len: u8 = 0,
    model_buf: [24]u8 = undefined,
    model_len: u8 = 0,
    note_buf: [24]u8 = undefined,
    note_len: u8 = 0,
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    context_used: ?u64 = null,
    context_max: ?u64 = null,
    cost_usd: ?f64 = null,
    cost_is_estimate: bool = false,

    pub fn session(self: *const Row) []const u8 {
        return self.session_buf[0..self.session_len];
    }
    pub fn model(self: *const Row) []const u8 {
        return self.model_buf[0..self.model_len];
    }
    pub fn note(self: *const Row) []const u8 {
        return self.note_buf[0..self.note_len];
    }
};

pub const DashboardState = struct {
    rows: [max_rows]Row = undefined,
    row_count: u8 = 0,
    // Totals across rows (footer). Cost is summed; `any_estimate` marks the sum
    // as containing at least one estimated component.
    total_input: u64 = 0,
    total_output: u64 = 0,
    total_cost: f64 = 0,
    any_estimate: bool = false,

    pub fn clear(self: *DashboardState) void {
        self.row_count = 0;
        self.total_input = 0;
        self.total_output = 0;
        self.total_cost = 0;
        self.any_estimate = false;
    }

    /// Append a row and fold its numbers into the totals. No-op past max_rows.
    pub fn addRow(self: *DashboardState, row: Row) void {
        if (self.row_count >= max_rows) return;
        self.rows[self.row_count] = row;
        self.row_count += 1;
        if (row.input_tokens) |v| self.total_input += v;
        if (row.output_tokens) |v| self.total_output += v;
        if (row.cost_usd) |c| {
            self.total_cost += c;
            if (row.cost_is_estimate) self.any_estimate = true;
        }
    }

    pub fn rowsSlice(self: *const DashboardState) []const Row {
        return self.rows[0..self.row_count];
    }
};

/// Copy `s` into a fixed row buffer (truncating), returning the written length.
/// Helper for the app glue when filling a Row.
pub fn copyField(buf: []u8, s: []const u8) u8 {
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    return @intCast(n);
}

/// Humanize a token count: `1.2M`, `842K`, `500`. Writes into `buf`.
pub fn humanize(buf: []u8, n: u64) []const u8 {
    if (n >= 1_000_000) {
        const m = @as(f64, @floatFromInt(n)) / 1_000_000.0;
        return std.fmt.bufPrint(buf, "{d:.1}M", .{m}) catch buf[0..0];
    } else if (n >= 1_000) {
        return std.fmt.bufPrint(buf, "{d}K", .{n / 1000}) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{d}", .{n}) catch buf[0..0];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "humanize formats K/M thresholds" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("500", humanize(&buf, 500));
    try std.testing.expectEqualStrings("842K", humanize(&buf, 842_000));
    try std.testing.expectEqualStrings("1.2M", humanize(&buf, 1_200_000));
    try std.testing.expectEqualStrings("1.6M", humanize(&buf, 1_600_000));
}

test "addRow accumulates totals and flags estimates" {
    var st = DashboardState{};
    var r1 = Row{ .pane_id = 3, .status = .working, .input_tokens = 1_200_000, .output_tokens = 842_000, .cost_usd = 0.42 };
    r1.session_len = copyField(&r1.session_buf, "myapp");
    st.addRow(r1);
    st.addRow(.{ .pane_id = 5, .status = .working, .input_tokens = 430_000, .output_tokens = 210_000, .cost_usd = 0.31, .cost_is_estimate = true });

    try std.testing.expectEqual(@as(u8, 2), st.row_count);
    try std.testing.expectEqual(@as(u64, 1_630_000), st.total_input);
    try std.testing.expectEqual(@as(u64, 1_052_000), st.total_output);
    try std.testing.expectApproxEqAbs(@as(f64, 0.73), st.total_cost, 1e-9);
    try std.testing.expect(st.any_estimate);
    try std.testing.expectEqualStrings("myapp", st.rows[0].session());

    st.clear();
    try std.testing.expectEqual(@as(u8, 0), st.row_count);
    try std.testing.expectEqual(@as(f64, 0), st.total_cost);
    try std.testing.expect(!st.any_estimate);
}

test "addRow caps at max_rows" {
    var st = DashboardState{};
    for (0..max_rows + 10) |_| st.addRow(.{ .pane_id = 1 });
    try std.testing.expectEqual(@as(u8, max_rows), st.row_count);
}
