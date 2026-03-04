/// Session picker — pure state machine for the overlay-based session switcher.
///
/// No side effects, no daemon imports, no app-layer dependencies.
/// Testable in headless mode.
const std = @import("std");

pub const max_entries = 32;

pub const PickerMode = enum { browsing, renaming, confirm_kill };

pub const SessionEntry = struct {
    id: u32 = 0,
    name: [64]u8 = undefined,
    name_len: u8 = 0,
    alive: bool = false,

    pub fn getName(self: *const SessionEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const PickerAction = union(enum) {
    none,
    switch_session: u32,
    create_session: void,
    kill_session: u32,
    rename_session: struct { id: u32, name: []const u8 },
    close: void,
};

pub const SessionPickerState = struct {
    entries: [max_entries]SessionEntry = undefined,
    entry_count: u8 = 0,
    selected: u8 = 0,
    scroll_offset: u8 = 0,
    mode: PickerMode = .browsing,

    // Filter
    filter_buf: [64]u8 = .{0} ** 64,
    filter_len: u8 = 0,
    filtered_indices: [max_entries]u8 = undefined,
    filtered_count: u8 = 0,

    // Rename
    rename_buf: [64]u8 = .{0} ** 64,
    rename_len: u8 = 0,

    // Context
    current_session_id: ?u32 = null,
    visible_rows: u8 = 10,

    /// Load session entries and initialize state.
    pub fn load(self: *SessionPickerState, entries: []const SessionEntry, count: u8, current_id: ?u32) void {
        const n: u8 = @intCast(@min(count, max_entries));
        for (0..n) |i| {
            self.entries[i] = entries[i];
        }
        self.entry_count = n;
        self.current_session_id = current_id;
        self.selected = 0;
        self.scroll_offset = 0;
        self.mode = .browsing;
        self.filter_len = 0;
        self.rename_len = 0;
        self.applyFilter();
        self.preselect();
    }

    /// Pre-select first non-current alive session.
    fn preselect(self: *SessionPickerState) void {
        for (0..self.filtered_count) |i| {
            const e = &self.entries[self.filtered_indices[i]];
            if (e.alive and (self.current_session_id == null or e.id != self.current_session_id.?)) {
                self.selected = @intCast(i);
                self.adjustScroll();
                return;
            }
        }
    }

    /// Handle a character input. Returns action if one should be executed.
    pub fn handleChar(self: *SessionPickerState, codepoint: u32) PickerAction {
        switch (self.mode) {
            .renaming => {
                if (codepoint >= 0x20 and codepoint < 0x7f) {
                    if (self.rename_len < 63) {
                        self.rename_buf[self.rename_len] = @intCast(codepoint);
                        self.rename_len += 1;
                    }
                }
                return .none;
            },
            .confirm_kill => {
                if (codepoint == 'y' or codepoint == 'Y') {
                    if (self.selected < self.filtered_count) {
                        const e = &self.entries[self.filtered_indices[self.selected]];
                        self.mode = .browsing;
                        return .{ .kill_session = e.id };
                    }
                }
                self.mode = .browsing;
                return .none;
            },
            .browsing => {
                if (codepoint >= 0x20 and codepoint < 0x7f and self.filter_len < 63) {
                    self.filter_buf[self.filter_len] = @intCast(codepoint);
                    self.filter_len += 1;
                    self.applyFilter();
                    self.selected = 0;
                    self.adjustScroll();
                }
                return .none;
            },
        }
    }

    /// Handle a command. Returns action if one should be executed.
    /// Command codes: 1=backspace, 7=escape/close, 8=enter/select,
    /// 9=up, 10=down, 11=ctrl_r(rename), 12=ctrl_x(kill),
    /// 13=ctrl_u(clear filter)
    pub fn handleCmd(self: *SessionPickerState, cmd: i32) PickerAction {
        switch (self.mode) {
            .renaming => return self.handleRenameCmd(cmd),
            .confirm_kill => {
                // Any key except 'y' (handled in handleChar) cancels
                if (cmd == 7) return .close; // Esc closes picker
                self.mode = .browsing;
                return .none;
            },
            .browsing => return self.handleBrowsingCmd(cmd),
        }
    }

    fn handleRenameCmd(self: *SessionPickerState, cmd: i32) PickerAction {
        switch (cmd) {
            1 => { // Backspace
                if (self.rename_len > 0) self.rename_len -= 1;
            },
            7 => { // Esc — cancel rename
                self.mode = .browsing;
            },
            8 => { // Enter — commit rename
                if (self.rename_len > 0 and self.selected < self.filtered_count) {
                    const e = &self.entries[self.filtered_indices[self.selected]];
                    self.mode = .browsing;
                    return .{ .rename_session = .{
                        .id = e.id,
                        .name = self.rename_buf[0..self.rename_len],
                    } };
                }
                self.mode = .browsing;
            },
            else => {},
        }
        return .none;
    }

    fn handleBrowsingCmd(self: *SessionPickerState, cmd: i32) PickerAction {
        switch (cmd) {
            1 => { // Backspace
                if (self.filter_len > 0) {
                    self.filter_len -= 1;
                    self.applyFilter();
                    self.selected = 0;
                    self.adjustScroll();
                }
            },
            7 => return .close, // Escape
            8 => { // Enter
                const total = self.totalCount();
                if (self.selected == self.filtered_count) {
                    return .create_session;
                } else if (self.filtered_count > 0 and self.selected < self.filtered_count) {
                    const e = &self.entries[self.filtered_indices[self.selected]];
                    return .{ .switch_session = e.id };
                }
                _ = total;
            },
            9 => self.moveUp(), // Up
            10 => self.moveDown(), // Down
            11 => { // Ctrl-R — rename
                if (self.filtered_count > 0 and self.selected < self.filtered_count) {
                    const e = &self.entries[self.filtered_indices[self.selected]];
                    const nlen = e.name_len;
                    @memcpy(self.rename_buf[0..nlen], e.name[0..nlen]);
                    self.rename_len = nlen;
                    self.mode = .renaming;
                }
            },
            12 => { // Ctrl-X — kill
                if (self.filtered_count > 0 and self.selected < self.filtered_count) {
                    self.mode = .confirm_kill;
                }
            },
            13 => { // Ctrl-U — clear filter
                self.filter_len = 0;
                self.applyFilter();
                self.selected = 0;
                self.adjustScroll();
            },
            else => {},
        }
        return .none;
    }

    pub fn moveUp(self: *SessionPickerState) void {
        const total = self.totalCount();
        if (total > 0) {
            self.selected = if (self.selected == 0) total - 1 else self.selected - 1;
            self.adjustScroll();
        }
    }

    pub fn moveDown(self: *SessionPickerState) void {
        const total = self.totalCount();
        if (total > 0) {
            self.selected = if (self.selected + 1 >= total) 0 else self.selected + 1;
            self.adjustScroll();
        }
    }

    /// Total items = filtered sessions + 1 ("New session" entry).
    pub fn totalCount(self: *const SessionPickerState) u8 {
        return self.filtered_count +| 1;
    }

    pub fn applyFilter(self: *SessionPickerState) void {
        var n: u8 = 0;
        for (0..self.entry_count) |i| {
            if (self.filter_len == 0 or fuzzyMatch(self.entries[i].getName(), self.filter_buf[0..self.filter_len])) {
                self.filtered_indices[n] = @intCast(i);
                n += 1;
            }
        }
        self.filtered_count = n;
    }

    pub fn adjustScroll(self: *SessionPickerState) void {
        const cap = self.visible_rows;
        const total = self.totalCount();
        if (self.selected < self.scroll_offset) {
            self.scroll_offset = self.selected;
        }
        if (self.selected >= self.scroll_offset +| cap) {
            self.scroll_offset = self.selected -| (cap -| 1);
        }
        if (total > cap) {
            const max_offset = total - cap;
            if (self.scroll_offset > max_offset) self.scroll_offset = max_offset;
        } else {
            self.scroll_offset = 0;
        }
    }
};

fn fuzzyMatch(name: []const u8, query: []const u8) bool {
    if (query.len > name.len) return false;
    for (0..name.len - query.len + 1) |start| {
        var matched = true;
        for (0..query.len) |j| {
            if (toLower(name[start + j]) != toLower(query[j])) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn toLower(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "applyFilter: empty filter returns all" {
    var state = SessionPickerState{};
    state.entries[0] = .{ .id = 1, .name_len = 5, .alive = true };
    @memcpy(state.entries[0].name[0..5], "alpha");
    state.entries[1] = .{ .id = 2, .name_len = 4, .alive = true };
    @memcpy(state.entries[1].name[0..4], "beta");
    state.entry_count = 2;
    state.applyFilter();
    try std.testing.expectEqual(@as(u8, 2), state.filtered_count);
}

test "applyFilter: filter narrows results" {
    var state = SessionPickerState{};
    state.entries[0] = .{ .id = 1, .name_len = 5, .alive = true };
    @memcpy(state.entries[0].name[0..5], "alpha");
    state.entries[1] = .{ .id = 2, .name_len = 4, .alive = true };
    @memcpy(state.entries[1].name[0..4], "beta");
    state.entry_count = 2;
    state.filter_buf[0] = 'a';
    state.filter_buf[1] = 'l';
    state.filter_len = 2;
    state.applyFilter();
    try std.testing.expectEqual(@as(u8, 1), state.filtered_count);
    try std.testing.expectEqual(@as(u8, 0), state.filtered_indices[0]);
}

test "handleChar: filter input in browsing mode" {
    var state = SessionPickerState{};
    state.entries[0] = .{ .id = 1, .name_len = 5, .alive = true };
    @memcpy(state.entries[0].name[0..5], "alpha");
    state.entry_count = 1;
    state.applyFilter();
    const action = state.handleChar('x');
    try std.testing.expectEqual(@as(u8, 1), state.filter_len);
    switch (action) {
        .none => {},
        else => return error.TestUnexpectedResult,
    }
}

test "handleCmd: navigation up/down wraps" {
    var state = SessionPickerState{};
    state.entries[0] = .{ .id = 1, .name_len = 3, .alive = true };
    @memcpy(state.entries[0].name[0..3], "one");
    state.entries[1] = .{ .id = 2, .name_len = 3, .alive = true };
    @memcpy(state.entries[1].name[0..3], "two");
    state.entry_count = 2;
    state.applyFilter();
    // total = 3 (2 sessions + 1 "New")
    _ = state.handleCmd(10); // down
    try std.testing.expectEqual(@as(u8, 1), state.selected);
    _ = state.handleCmd(10); // down
    try std.testing.expectEqual(@as(u8, 2), state.selected); // "New session"
    _ = state.handleCmd(10); // down wraps
    try std.testing.expectEqual(@as(u8, 0), state.selected);
    _ = state.handleCmd(9); // up wraps
    try std.testing.expectEqual(@as(u8, 2), state.selected);
}

test "handleCmd: enter on session returns switch_session" {
    var state = SessionPickerState{};
    state.entries[0] = .{ .id = 42, .name_len = 4, .alive = true };
    @memcpy(state.entries[0].name[0..4], "test");
    state.entry_count = 1;
    state.applyFilter();
    state.selected = 0;
    const action = state.handleCmd(8); // Enter
    switch (action) {
        .switch_session => |id| try std.testing.expectEqual(@as(u32, 42), id),
        else => return error.TestUnexpectedResult,
    }
}

test "handleCmd: enter on 'New session' returns create_session" {
    var state = SessionPickerState{};
    state.entries[0] = .{ .id = 1, .name_len = 3, .alive = true };
    @memcpy(state.entries[0].name[0..3], "one");
    state.entry_count = 1;
    state.applyFilter();
    state.selected = 1; // "New session" entry
    const action = state.handleCmd(8); // Enter
    switch (action) {
        .create_session => {},
        else => return error.TestUnexpectedResult,
    }
}

test "handleCmd: rename flow" {
    var state = SessionPickerState{};
    state.entries[0] = .{ .id = 5, .name_len = 3, .alive = true };
    @memcpy(state.entries[0].name[0..3], "old");
    state.entry_count = 1;
    state.applyFilter();
    state.selected = 0;

    // Ctrl-R enters rename mode
    _ = state.handleCmd(11);
    try std.testing.expectEqual(PickerMode.renaming, state.mode);
    try std.testing.expectEqual(@as(u8, 3), state.rename_len);

    // Type new name
    _ = state.handleChar('X');
    try std.testing.expectEqual(@as(u8, 4), state.rename_len);

    // Backspace
    _ = state.handleCmd(1);
    try std.testing.expectEqual(@as(u8, 3), state.rename_len);

    // Enter commits
    const action = state.handleCmd(8);
    switch (action) {
        .rename_session => |rs| {
            try std.testing.expectEqual(@as(u32, 5), rs.id);
            try std.testing.expectEqualStrings("old", rs.name);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(PickerMode.browsing, state.mode);
}

test "handleCmd: kill confirmation flow" {
    var state = SessionPickerState{};
    state.entries[0] = .{ .id = 7, .name_len = 4, .alive = true };
    @memcpy(state.entries[0].name[0..4], "kill");
    state.entry_count = 1;
    state.applyFilter();
    state.selected = 0;

    // Ctrl-X enters confirm mode
    _ = state.handleCmd(12);
    try std.testing.expectEqual(PickerMode.confirm_kill, state.mode);

    // 'y' confirms
    const action = state.handleChar('y');
    switch (action) {
        .kill_session => |id| try std.testing.expectEqual(@as(u32, 7), id),
        else => return error.TestUnexpectedResult,
    }
}

test "adjustScroll: viewport clamping" {
    var state = SessionPickerState{};
    state.visible_rows = 3;
    state.entries[0] = .{ .id = 1, .name_len = 1, .alive = true };
    state.entries[0].name[0] = 'a';
    state.entries[1] = .{ .id = 2, .name_len = 1, .alive = true };
    state.entries[1].name[0] = 'b';
    state.entries[2] = .{ .id = 3, .name_len = 1, .alive = true };
    state.entries[2].name[0] = 'c';
    state.entries[3] = .{ .id = 4, .name_len = 1, .alive = true };
    state.entries[3].name[0] = 'd';
    state.entry_count = 4;
    state.applyFilter();

    // total = 5 (4 sessions + New), visible_rows = 3
    state.selected = 4; // last item
    state.adjustScroll();
    try std.testing.expectEqual(@as(u8, 2), state.scroll_offset);

    state.selected = 0;
    state.adjustScroll();
    try std.testing.expectEqual(@as(u8, 0), state.scroll_offset);
}

test "fuzzyMatch: case-insensitive" {
    try std.testing.expect(fuzzyMatch("Hello", "hello"));
    try std.testing.expect(fuzzyMatch("WORLD", "world"));
    try std.testing.expect(!fuzzyMatch("ab", "abc"));
    try std.testing.expect(fuzzyMatch("abc", "bc"));
}
