//! Agent dashboard data model — pure, TTY-free, fully unit-testable.
//!
//! Holds the live agent table keyed by (session, pane). Frames arrive as NDJSON
//! lines from a `watch_agents` stream; `applyLine` merges each in. `state ==
//! "none"` removes a row. A sort/filter/search "view" (indices into the sorted
//! rows) drives what's shown; selection indexes into the view. Session-name
//! resolution lives in the UI layer (the model is id-based).
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
    fn rank(self: State) u8 {
        return switch (self) {
            .input => 0,
            .working => 1,
            .idle => 2,
            .none => 3,
        };
    }
};

pub const SortMode = enum {
    state,
    cost,
    tokens,
    ctx,
    session,

    pub fn label(self: SortMode) []const u8 {
        return switch (self) {
            .state => "state",
            .cost => "cost",
            .tokens => "tokens",
            .ctx => "ctx",
            .session => "session",
        };
    }
    pub fn next(self: SortMode) SortMode {
        return switch (self) {
            .state => .cost,
            .cost => .tokens,
            .tokens => .ctx,
            .ctx => .session,
            .session => .state,
        };
    }
};

pub const FilterMode = enum {
    all,
    input,
    working,
    idle,

    pub fn label(self: FilterMode) []const u8 {
        return switch (self) {
            .all => "all",
            .input => "needs-input",
            .working => "working",
            .idle => "idle",
        };
    }
    pub fn next(self: FilterMode) FilterMode {
        return switch (self) {
            .all => .input,
            .input => .working,
            .working => .idle,
            .idle => .all,
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
    tab_buf: [48]u8 = undefined,
    tab_len: u8 = 0,
    msg_buf: [120]u8 = undefined,
    msg_len: u8 = 0,
    state_since_ms: i64 = 0, // when the row entered its current state (for elapsed)

    pub fn model(self: *const Row) []const u8 {
        return self.model_buf[0..self.model_len];
    }
    pub fn tabName(self: *const Row) []const u8 {
        return self.tab_buf[0..self.tab_len];
    }
    pub fn message(self: *const Row) []const u8 {
        return self.msg_buf[0..self.msg_len];
    }
    fn tokensTotal(self: *const Row) u64 {
        return (self.input_tokens orelse 0) + (self.output_tokens orelse 0);
    }
};

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
    tab_name: []const u8 = "",
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

fn lowerEql(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

pub const Model = struct {
    rows: [max_rows]Row = undefined, // canonical store, kept sorted by sort_mode
    count: usize = 0,
    view: [max_rows]u8 = undefined, // indices into rows passing filter+search
    view_count: usize = 0,
    selected: usize = 0, // index into view

    sort_mode: SortMode = .state,
    filter_mode: FilterMode = .all,
    search_buf: [64]u8 = undefined,
    search_len: u8 = 0,

    // Totals across ALL rows (header), independent of filter/search.
    total_input: u64 = 0,
    total_output: u64 = 0,
    total_cost: f64 = 0,
    any_estimate: bool = false,
    n_input: usize = 0,
    n_working: usize = 0,
    n_idle: usize = 0,

    pub fn searchQuery(self: *const Model) []const u8 {
        return self.search_buf[0..self.search_len];
    }

    fn find(self: *Model, session: u32, pane: u32) ?usize {
        for (self.rows[0..self.count], 0..) |*r, i| {
            if (r.session == session and r.pane_id == pane) return i;
        }
        return null;
    }

    fn removeAt(self: *Model, idx: usize) void {
        var i = idx;
        while (i + 1 < self.count) : (i += 1) self.rows[i] = self.rows[i + 1];
        self.count -= 1;
    }

    /// Apply one NDJSON record. `now_ms` stamps the state-change time (for the
    /// elapsed column). Allocator is used only transiently for JSON parsing.
    pub fn applyLine(self: *Model, gpa: std.mem.Allocator, line: []const u8, now_ms: i64) void {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] != '{') return;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const parsed = std.json.parseFromSliceLeaky(RawRecord, arena.allocator(), trimmed, .{ .ignore_unknown_fields = true }) catch return;

        const st = State.fromStr(parsed.state);
        const existing = self.find(parsed.session, parsed.pane_id);
        if (st == .none) {
            if (existing) |i| self.removeAt(i);
            self.refresh(now_ms);
            return;
        }
        const idx = existing orelse blk: {
            if (self.count >= max_rows) {
                self.refresh(now_ms);
                return;
            }
            self.rows[self.count] = .{ .state_since_ms = now_ms };
            self.count += 1;
            break :blk self.count - 1;
        };
        var r = &self.rows[idx];
        if (r.state != st) r.state_since_ms = now_ms;
        r.session = parsed.session;
        r.pane_id = parsed.pane_id;
        r.tab_id = parsed.tab_id;
        r.tab_len = copyBuf(&r.tab_buf, parsed.tab_name);
        r.pid = parsed.pid;
        r.state = st;
        r.msg_len = copyBuf(&r.msg_buf, parsed.message);
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
        self.refresh(now_ms);
    }

    /// Re-sort rows, recompute totals, and rebuild the filtered/searched view.
    /// `now_ms` unused here but kept for symmetry/future use.
    pub fn refresh(self: *Model, now_ms: i64) void {
        _ = now_ms;
        self.sort();
        self.recompute();
        self.rebuildView();
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
    }

    fn passesFilter(self: *const Model, r: *const Row) bool {
        return switch (self.filter_mode) {
            .all => true,
            .input => r.state == .input,
            .working => r.state == .working,
            .idle => r.state == .idle,
        };
    }

    fn matchesSearch(self: *const Model, r: *const Row) bool {
        const q = self.searchQuery();
        if (q.len == 0) return true;
        if (lowerEql(r.model(), q)) return true;
        if (lowerEql(r.message(), q)) return true;
        var nb: [24]u8 = undefined;
        if (std.fmt.bufPrint(&nb, "s{d} {d}", .{ r.session, r.pane_id })) |ids| {
            if (lowerEql(ids, q)) return true;
        } else |_| {}
        return false;
    }

    fn rebuildView(self: *Model) void {
        var n: usize = 0;
        for (self.rows[0..self.count], 0..) |*r, i| {
            if (self.passesFilter(r) and self.matchesSearch(r)) {
                self.view[n] = @intCast(i);
                n += 1;
            }
        }
        self.view_count = n;
        if (self.selected >= self.view_count) self.selected = if (self.view_count > 0) self.view_count - 1 else 0;
    }

    fn sort(self: *Model) void {
        const rows = self.rows[0..self.count];
        var i: usize = 1;
        while (i < rows.len) : (i += 1) {
            const tmp = rows[i];
            var j: usize = i;
            while (j > 0 and less(tmp, rows[j - 1], self.sort_mode)) : (j -= 1) rows[j] = rows[j - 1];
            rows[j] = tmp;
        }
    }

    pub fn visibleCount(self: *const Model) usize {
        return self.view_count;
    }
    pub fn rowAt(self: *const Model, i: usize) *const Row {
        return &self.rows[self.view[i]];
    }
    pub fn selectedRow(self: *const Model) ?*const Row {
        if (self.view_count == 0) return null;
        return &self.rows[self.view[self.selected]];
    }

    pub fn moveUp(self: *Model) void {
        if (self.selected > 0) self.selected -= 1;
    }
    pub fn moveDown(self: *Model) void {
        if (self.selected + 1 < self.view_count) self.selected += 1;
    }
    pub fn moveTop(self: *Model) void {
        self.selected = 0;
    }
    pub fn moveBottom(self: *Model) void {
        self.selected = if (self.view_count > 0) self.view_count - 1 else 0;
    }

    pub fn cycleSort(self: *Model) void {
        self.sort_mode = self.sort_mode.next();
        self.refresh(0);
    }
    pub fn cycleFilter(self: *Model) void {
        self.filter_mode = self.filter_mode.next();
        self.rebuildView();
    }
    pub fn searchAppend(self: *Model, ch: u8) void {
        if (self.search_len < self.search_buf.len) {
            self.search_buf[self.search_len] = ch;
            self.search_len += 1;
            self.rebuildView();
        }
    }
    pub fn searchBackspace(self: *Model) void {
        if (self.search_len > 0) {
            self.search_len -= 1;
            self.rebuildView();
        }
    }
    pub fn searchClear(self: *Model) void {
        self.search_len = 0;
        self.rebuildView();
    }
};

fn less(a: Row, b: Row, mode: SortMode) bool {
    // Always group by session first; the mode orders rows within a session. This
    // keeps the view session-contiguous so the dashboard can render group headers.
    if (a.session != b.session) return a.session < b.session;
    switch (mode) {
        .state => {
            if (a.state.rank() != b.state.rank()) return a.state.rank() < b.state.rank();
            const ca = a.cost_usd orelse 0;
            const cb = b.cost_usd orelse 0;
            if (ca != cb) return ca > cb;
        },
        .cost => {
            const ca = a.cost_usd orelse 0;
            const cb = b.cost_usd orelse 0;
            if (ca != cb) return ca > cb;
        },
        .tokens => {
            if (a.tokensTotal() != b.tokensTotal()) return a.tokensTotal() > b.tokensTotal();
        },
        .ctx => {
            const ka = a.context_used orelse 0;
            const kb = b.context_used orelse 0;
            if (ka != kb) return ka > kb;
        },
        .session => {},
    }
    return a.pane_id < b.pane_id;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "applyLine upserts, sticky-merges usage; groups by session then state/cost" {
    const a = testing.allocator;
    var m = Model{};
    m.applyLine(a, "{\"session\":1,\"pane_id\":3,\"state\":\"working\",\"usage\":{\"input_tokens\":100,\"cost_usd\":0.10}}", 0);
    m.applyLine(a, "{\"session\":1,\"pane_id\":8,\"state\":\"input\",\"usage\":{}}", 0);
    m.applyLine(a, "{\"session\":2,\"pane_id\":5,\"state\":\"working\",\"usage\":{\"input_tokens\":50,\"cost_usd\":0.50}}", 0);
    try testing.expectEqual(@as(usize, 3), m.count);
    try testing.expectEqual(@as(usize, 3), m.view_count);
    // Session 1 rows first (grouped); within it input ranks before working.
    try testing.expectEqual(@as(u32, 8), m.rows[0].pane_id); // s1, input
    try testing.expectEqual(@as(u32, 3), m.rows[1].pane_id); // s1, working
    try testing.expectEqual(@as(u32, 5), m.rows[2].pane_id); // s2
    try testing.expectApproxEqAbs(@as(f64, 0.60), m.total_cost, 1e-9);

    m.applyLine(a, "{\"session\":2,\"pane_id\":5,\"state\":\"idle\"}", 0);
    const r = blk: {
        for (m.rows[0..m.count]) |*x| if (x.session == 2 and x.pane_id == 5) break :blk x;
        unreachable;
    };
    try testing.expectEqual(@as(?u64, 50), r.input_tokens); // sticky
    try testing.expectEqual(State.idle, r.state);
}

test "elapsed: state_since_ms stamps on new row and on state change only" {
    const a = testing.allocator;
    var m = Model{};
    m.applyLine(a, "{\"session\":1,\"pane_id\":1,\"state\":\"working\"}", 1000);
    try testing.expectEqual(@as(i64, 1000), m.rows[0].state_since_ms);
    m.applyLine(a, "{\"session\":1,\"pane_id\":1,\"state\":\"working\",\"usage\":{\"input_tokens\":5}}", 2000);
    try testing.expectEqual(@as(i64, 1000), m.rows[0].state_since_ms); // unchanged state
    m.applyLine(a, "{\"session\":1,\"pane_id\":1,\"state\":\"input\"}", 3000);
    try testing.expectEqual(@as(i64, 3000), m.rows[0].state_since_ms); // changed
}

test "filter narrows the view; totals stay over all rows" {
    const a = testing.allocator;
    var m = Model{};
    m.applyLine(a, "{\"session\":1,\"pane_id\":1,\"state\":\"working\"}", 0);
    m.applyLine(a, "{\"session\":1,\"pane_id\":2,\"state\":\"input\"}", 0);
    m.applyLine(a, "{\"session\":1,\"pane_id\":3,\"state\":\"idle\"}", 0);
    try testing.expectEqual(@as(usize, 3), m.visibleCount());
    m.cycleFilter(); // all → needs-input
    try testing.expectEqual(FilterMode.input, m.filter_mode);
    try testing.expectEqual(@as(usize, 1), m.visibleCount());
    try testing.expectEqual(State.input, m.selectedRow().?.state);
}

test "search matches model and message, case-insensitive" {
    const a = testing.allocator;
    var m = Model{};
    m.applyLine(a, "{\"session\":1,\"pane_id\":1,\"state\":\"working\",\"message\":\"Editing parser\",\"usage\":{\"model\":\"opus-4.8\"}}", 0);
    m.applyLine(a, "{\"session\":1,\"pane_id\":2,\"state\":\"working\",\"message\":\"running tests\",\"usage\":{\"model\":\"gpt-5\"}}", 0);
    for ("OPUS") |c| m.searchAppend(c);
    try testing.expectEqual(@as(usize, 1), m.visibleCount());
    m.searchClear();
    try testing.expectEqual(@as(usize, 2), m.visibleCount());
    for ("tests") |c| m.searchAppend(c);
    try testing.expectEqual(@as(usize, 1), m.visibleCount());
    try testing.expectEqual(@as(u32, 2), m.selectedRow().?.pane_id);
}

test "cycleSort reorders the view (tokens)" {
    const a = testing.allocator;
    var m = Model{};
    m.applyLine(a, "{\"session\":1,\"pane_id\":1,\"state\":\"idle\",\"usage\":{\"input_tokens\":10}}", 0);
    m.applyLine(a, "{\"session\":1,\"pane_id\":2,\"state\":\"idle\",\"usage\":{\"input_tokens\":999}}", 0);
    m.sort_mode = .tokens;
    m.refresh(0);
    try testing.expectEqual(@as(u32, 2), m.rowAt(0).pane_id); // most tokens first
}

test "remove on none fixes selection; movement clamps to view" {
    const a = testing.allocator;
    var m = Model{};
    m.applyLine(a, "{\"session\":1,\"pane_id\":1,\"state\":\"working\"}", 0);
    m.applyLine(a, "{\"session\":1,\"pane_id\":2,\"state\":\"working\"}", 0);
    m.selected = 1;
    m.applyLine(a, "{\"session\":1,\"pane_id\":2,\"state\":\"none\"}", 0);
    try testing.expectEqual(@as(usize, 1), m.count);
    try testing.expectEqual(@as(usize, 0), m.selected);
    m.moveDown();
    try testing.expectEqual(@as(usize, 0), m.selected); // clamped to view
}

test "malformed lines ignored" {
    const a = testing.allocator;
    var m = Model{};
    m.applyLine(a, "not json", 0);
    m.applyLine(a, "", 0);
    try testing.expectEqual(@as(usize, 0), m.count);
}
