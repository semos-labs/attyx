//! Agent dashboard data model — pure, TTY-free, fully unit-testable.
//!
//! Holds the live agent table keyed by (session, pane). Frames arrive as NDJSON
//! lines from a `watch_agents` stream (one record per agent transition, see
//! `src/ipc/agents.zig writeAgentJson`); `applyLine` merges each into the table.
//! `state == "none"` removes a row (agent ended). Sorting, totals, and selection
//! movement live here as pure operations over the row list.
const std = @import("std");

pub const max_rows = 128;

pub const State = enum {
    idle,
    working,
    input,
    none,

    fn fromStr(s: []const u8) State {
        if (std.mem.eql(u8, s, "working")) return .working;
        if (std.mem.eql(u8, s, "input")) return .input;
        if (std.mem.eql(u8, s, "idle")) return .idle;
        return .none;
    }
    /// Sort priority: needs-input first (loudest), then working, then idle.
    fn rank(self: State) u8 {
        return switch (self) {
            .input => 0,
            .working => 1,
            .idle => 2,
            .none => 3,
        };
    }
};

pub const Row = struct {
    session: u32 = 0,
    pane_id: u32 = 0,
    tab_id: u32 = 0,
    pid: u32 = 0,
    state: State = .none,
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    context_used: ?u64 = null,
    context_max: ?u64 = null,
    cost_usd: ?f64 = null,
    cost_is_estimate: bool = false,
    model_buf: [40]u8 = undefined,
    model_len: u8 = 0,
    msg_buf: [120]u8 = undefined,
    msg_len: u8 = 0,

    pub fn model(self: *const Row) []const u8 {
        return self.model_buf[0..self.model_len];
    }
    pub fn message(self: *const Row) []const u8 {
        return self.msg_buf[0..self.msg_len];
    }
};

// JSON shapes for std.json (defaults make every field optional; unknown keys ignored).
const RawUsage = struct {
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    context_used: ?u64 = null,
    context_max: ?u64 = null,
    cost_usd: ?f64 = null,
    cost_is_estimate: bool = false,
    model: ?[]const u8 = null,
};
const RawRecord = struct {
    pane_id: u32 = 0,
    tab_id: u32 = 0,
    session: u32 = 0,
    pid: u32 = 0,
    state: []const u8 = "none",
    message: []const u8 = "",
    usage: RawUsage = .{},
};

fn copyBuf(buf: []u8, s: []const u8) u8 {
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    return @intCast(n);
}

pub const Model = struct {
    rows: [max_rows]Row = undefined,
    count: usize = 0,
    selected: usize = 0,

    // Totals (recomputed on change).
    total_input: u64 = 0,
    total_output: u64 = 0,
    total_cost: f64 = 0,
    any_estimate: bool = false,
    n_input: usize = 0, // agents needing input
    n_working: usize = 0,
    n_idle: usize = 0,

    fn find(self: *Model, session: u32, pane: u32) ?usize {
        for (self.rows[0..self.count], 0..) |*r, i| {
            if (r.session == session and r.pane_id == pane) return i;
        }
        return null;
    }

    fn removeAt(self: *Model, idx: usize) void {
        // Order-preserving remove so the table doesn't jump around.
        var i = idx;
        while (i + 1 < self.count) : (i += 1) self.rows[i] = self.rows[i + 1];
        self.count -= 1;
        if (self.selected >= self.count and self.selected > 0) self.selected = self.count - 1;
    }

    /// Apply one NDJSON record. Allocator is used only transiently for JSON
    /// parsing (freed before return); the model itself owns no heap memory.
    pub fn applyLine(self: *Model, gpa: std.mem.Allocator, line: []const u8) void {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] != '{') return;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const parsed = std.json.parseFromSliceLeaky(RawRecord, arena.allocator(), trimmed, .{ .ignore_unknown_fields = true }) catch return;

        const st = State.fromStr(parsed.state);
        const existing = self.find(parsed.session, parsed.pane_id);
        if (st == .none) {
            if (existing) |i| self.removeAt(i);
            self.recompute();
            return;
        }
        const idx = existing orelse blk: {
            if (self.count >= max_rows) {
                self.recompute();
                return;
            }
            self.rows[self.count] = .{};
            self.count += 1;
            break :blk self.count - 1;
        };
        var r = &self.rows[idx];
        r.session = parsed.session;
        r.pane_id = parsed.pane_id;
        r.tab_id = parsed.tab_id;
        r.pid = parsed.pid;
        r.state = st;
        r.msg_len = copyBuf(&r.msg_buf, parsed.message);
        // Usage merges sticky: a status-only frame must not wipe known usage.
        const u = parsed.usage;
        if (u.input_tokens) |v| r.input_tokens = v;
        if (u.output_tokens) |v| r.output_tokens = v;
        if (u.context_used) |v| r.context_used = v;
        if (u.context_max) |v| r.context_max = v;
        if (u.cost_usd) |v| {
            r.cost_usd = v;
            r.cost_is_estimate = u.cost_is_estimate;
        }
        if (u.model) |m| r.model_len = copyBuf(&r.model_buf, m);
        self.sort();
        self.recompute();
    }

    fn recompute(self: *Model) void {
        self.total_input = 0;
        self.total_output = 0;
        self.total_cost = 0;
        self.any_estimate = false;
        self.n_input = 0;
        self.n_working = 0;
        self.n_idle = 0;
        for (self.rows[0..self.count]) |*r| {
            if (r.input_tokens) |v| self.total_input += v;
            if (r.output_tokens) |v| self.total_output += v;
            if (r.cost_usd) |c| {
                self.total_cost += c;
                if (r.cost_is_estimate) self.any_estimate = true;
            }
            switch (r.state) {
                .input => self.n_input += 1,
                .working => self.n_working += 1,
                .idle => self.n_idle += 1,
                .none => {},
            }
        }
        if (self.selected >= self.count and self.count > 0) self.selected = self.count - 1;
        if (self.count == 0) self.selected = 0;
    }

    /// Sort by state rank (input→working→idle), then descending cost, then
    /// session/pane for stability. Insertion sort — the table is small.
    fn sort(self: *Model) void {
        const rows = self.rows[0..self.count];
        var i: usize = 1;
        while (i < rows.len) : (i += 1) {
            const tmp = rows[i];
            var j: usize = i;
            while (j > 0 and less(tmp, rows[j - 1])) : (j -= 1) rows[j] = rows[j - 1];
            rows[j] = tmp;
        }
    }

    pub fn selectedRow(self: *const Model) ?*const Row {
        if (self.count == 0) return null;
        return &self.rows[self.selected];
    }

    pub fn moveUp(self: *Model) void {
        if (self.selected > 0) self.selected -= 1;
    }
    pub fn moveDown(self: *Model) void {
        if (self.selected + 1 < self.count) self.selected += 1;
    }
    pub fn moveTop(self: *Model) void {
        self.selected = 0;
    }
    pub fn moveBottom(self: *Model) void {
        self.selected = if (self.count > 0) self.count - 1 else 0;
    }
};

fn less(a: Row, b: Row) bool {
    const ra = a.state.rank();
    const rb = b.state.rank();
    if (ra != rb) return ra < rb;
    const ca = a.cost_usd orelse 0;
    const cb = b.cost_usd orelse 0;
    if (ca != cb) return ca > cb; // higher cost first
    if (a.session != b.session) return a.session < b.session;
    return a.pane_id < b.pane_id;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "applyLine upserts, sticky-merges usage, and sorts by state then cost" {
    const a = testing.allocator;
    var m = Model{};
    m.applyLine(a, "{\"session\":1,\"pane_id\":3,\"state\":\"working\",\"usage\":{\"input_tokens\":100,\"cost_usd\":0.10}}");
    m.applyLine(a, "{\"session\":1,\"pane_id\":8,\"state\":\"input\",\"usage\":{}}");
    m.applyLine(a, "{\"session\":2,\"pane_id\":5,\"state\":\"working\",\"usage\":{\"input_tokens\":50,\"cost_usd\":0.50}}");
    try testing.expectEqual(@as(usize, 3), m.count);
    // input first, then working sorted by cost desc (0.50 before 0.10).
    try testing.expectEqual(State.input, m.rows[0].state);
    try testing.expectEqual(@as(u32, 5), m.rows[1].pane_id);
    try testing.expectEqual(@as(u32, 3), m.rows[2].pane_id);
    try testing.expectEqual(@as(usize, 1), m.n_input);
    try testing.expectEqual(@as(usize, 2), m.n_working);
    try testing.expectApproxEqAbs(@as(f64, 0.60), m.total_cost, 1e-9);

    // Status-only frame must keep prior usage (sticky).
    m.applyLine(a, "{\"session\":2,\"pane_id\":5,\"state\":\"idle\"}");
    const r = blk: {
        for (m.rows[0..m.count]) |*x| if (x.session == 2 and x.pane_id == 5) break :blk x;
        unreachable;
    };
    try testing.expectEqual(@as(?u64, 50), r.input_tokens);
    try testing.expectEqual(State.idle, r.state);
}

test "applyLine removes a row on state none and fixes selection" {
    const a = testing.allocator;
    var m = Model{};
    m.applyLine(a, "{\"session\":1,\"pane_id\":1,\"state\":\"working\"}");
    m.applyLine(a, "{\"session\":1,\"pane_id\":2,\"state\":\"working\"}");
    m.selected = 1;
    m.applyLine(a, "{\"session\":1,\"pane_id\":2,\"state\":\"none\"}");
    try testing.expectEqual(@as(usize, 1), m.count);
    try testing.expectEqual(@as(usize, 0), m.selected);
}

test "selection movement clamps" {
    const a = testing.allocator;
    var m = Model{};
    m.applyLine(a, "{\"session\":1,\"pane_id\":1,\"state\":\"working\"}");
    m.applyLine(a, "{\"session\":1,\"pane_id\":2,\"state\":\"working\"}");
    m.moveUp();
    try testing.expectEqual(@as(usize, 0), m.selected);
    m.moveBottom();
    try testing.expectEqual(@as(usize, 1), m.selected);
    m.moveDown();
    try testing.expectEqual(@as(usize, 1), m.selected); // clamped
    m.moveTop();
    try testing.expectEqual(@as(usize, 0), m.selected);
}

test "malformed and non-object lines are ignored" {
    const a = testing.allocator;
    var m = Model{};
    m.applyLine(a, "not json");
    m.applyLine(a, "");
    m.applyLine(a, "{bad");
    try testing.expectEqual(@as(usize, 0), m.count);
}
