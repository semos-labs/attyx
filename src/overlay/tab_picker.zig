/// Tab picker — pure state machine for the overlay-based tab switcher.
///
/// No side effects, no app-layer dependencies. Testable in headless mode.
/// Stores tab entries (populated by the UI layer from tab_manager).
const std = @import("std");

pub const max_tabs = 16;

pub const TabEntry = struct {
    index: u8 = 0, // original tab index
    name: [64]u8 = undefined,
    name_len: u8 = 0,
    is_zoomed: bool = false,

    pub fn getName(self: *const TabEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const PickerAction = union(enum) {
    none,
    switch_tab: u8, // original tab index to switch to
    close: void,
};

pub const TabPickerState = struct {
    entries: [max_tabs]TabEntry = undefined,
    entry_count: u8 = 0,
    current_tab: u8 = 0, // currently active tab (highlighted differently)
    filter_buf: [64]u8 = .{0} ** 64,
    filter_len: u8 = 0,
    selected: u8 = 0,
    scroll_offset: u8 = 0,
    filtered_indices: [max_tabs]u8 = undefined,
    filtered_count: u8 = 0,
    visible_rows: u8 = 10,

    /// Handle a character input. Appends to filter and refilters.
    pub fn handleChar(self: *TabPickerState, codepoint: u32) PickerAction {
        if (codepoint >= 0x20 and codepoint < 0x7f and self.filter_len < 63) {
            self.filter_buf[self.filter_len] = @intCast(codepoint);
            self.filter_len += 1;
            self.applyFilter();
            self.selected = 0;
            self.scroll_offset = 0;
        }
        return .none;
    }

    /// Handle a command code. Returns action if one should be executed.
    /// Command codes: 1=backspace, 7=escape/close, 8=enter/select,
    /// 9=up, 10=down, 13=ctrl_u (clear filter), 15=ctrl_w (delete word).
    pub fn handleCmd(self: *TabPickerState, cmd: i32) PickerAction {
        switch (cmd) {
            1 => { // Backspace
                if (self.filter_len > 0) {
                    self.filter_len -= 1;
                    self.applyFilter();
                    self.selected = 0;
                    self.scroll_offset = 0;
                }
            },
            7 => return .close, // Escape
            8 => { // Enter — switch to selected tab
                if (self.filtered_count > 0 and self.selected < self.filtered_count) {
                    return .{ .switch_tab = self.entries[self.filtered_indices[self.selected]].index };
                }
            },
            9 => self.moveUp(), // Up
            10 => self.moveDown(), // Down
            13 => { // Ctrl+U — clear filter
                self.filter_len = 0;
                self.applyFilter();
                self.selected = 0;
                self.scroll_offset = 0;
            },
            15 => { // Ctrl+W — delete word
                while (self.filter_len > 0 and self.filter_buf[self.filter_len - 1] == ' ')
                    self.filter_len -= 1;
                while (self.filter_len > 0 and self.filter_buf[self.filter_len - 1] != ' ')
                    self.filter_len -= 1;
                self.applyFilter();
                self.selected = 0;
                self.scroll_offset = 0;
            },
            else => {},
        }
        return .none;
    }

    fn moveUp(self: *TabPickerState) void {
        if (self.filtered_count > 0) {
            self.selected = if (self.selected == 0) self.filtered_count - 1 else self.selected - 1;
            self.adjustScroll();
        }
    }

    fn moveDown(self: *TabPickerState) void {
        if (self.filtered_count > 0) {
            self.selected = if (self.selected + 1 >= self.filtered_count) 0 else self.selected + 1;
            self.adjustScroll();
        }
    }

    pub fn applyFilter(self: *TabPickerState) void {
        var n: u8 = 0;
        for (0..self.entry_count) |i| {
            if (self.filter_len == 0 or
                substringMatch(self.entries[i].getName(), self.filter_buf[0..self.filter_len]))
            {
                self.filtered_indices[n] = @intCast(i);
                n += 1;
            }
        }
        self.filtered_count = n;
    }

    pub fn adjustScroll(self: *TabPickerState) void {
        const cap = self.visible_rows;
        if (self.selected < self.scroll_offset) {
            self.scroll_offset = self.selected;
        }
        if (self.selected >= self.scroll_offset +| cap) {
            self.scroll_offset = self.selected -| (cap -| 1);
        }
        if (self.filtered_count > cap) {
            const max_offset = self.filtered_count - cap;
            if (self.scroll_offset > max_offset) self.scroll_offset = max_offset;
        } else {
            self.scroll_offset = 0;
        }
    }
};

fn substringMatch(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |start| {
        var matched = true;
        for (0..needle.len) |j| {
            if (toLower(haystack[start + j]) != toLower(needle[j])) {
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

fn makeEntry(name: []const u8, index: u8) TabEntry {
    var e = TabEntry{};
    e.name_len = @intCast(name.len);
    e.index = index;
    @memcpy(e.name[0..name.len], name);
    return e;
}

test "handleChar: appends to filter and refilters" {
    var state = TabPickerState{};
    state.entries[0] = makeEntry("zsh", 0);
    state.entries[1] = makeEntry("vim", 1);
    state.entries[2] = makeEntry("htop", 2);
    state.entry_count = 3;
    state.applyFilter();

    try std.testing.expectEqual(@as(u8, 3), state.filtered_count);

    _ = state.handleChar('v');
    try std.testing.expectEqual(@as(u8, 1), state.filtered_count);
    try std.testing.expectEqual(@as(u8, 1), state.filtered_indices[0]); // vim
}

test "handleCmd: enter returns switch_tab" {
    var state = TabPickerState{};
    state.entries[0] = makeEntry("zsh", 0);
    state.entries[1] = makeEntry("vim", 1);
    state.entry_count = 2;
    state.applyFilter();
    state.selected = 1;

    const action = state.handleCmd(8); // Enter
    switch (action) {
        .switch_tab => |idx| try std.testing.expectEqual(@as(u8, 1), idx),
        else => return error.TestUnexpectedResult,
    }
}

test "handleCmd: escape returns close" {
    var state = TabPickerState{};
    state.entry_count = 0;
    const action = state.handleCmd(7);
    switch (action) {
        .close => {},
        else => return error.TestUnexpectedResult,
    }
}

test "moveUp/moveDown: wraps around" {
    var state = TabPickerState{};
    state.entries[0] = makeEntry("a", 0);
    state.entries[1] = makeEntry("b", 1);
    state.entries[2] = makeEntry("c", 2);
    state.entry_count = 3;
    state.applyFilter();

    try std.testing.expectEqual(@as(u8, 0), state.selected);
    _ = state.handleCmd(9); // Up — wraps to 2
    try std.testing.expectEqual(@as(u8, 2), state.selected);
    _ = state.handleCmd(10); // Down — wraps to 0
    try std.testing.expectEqual(@as(u8, 0), state.selected);
}

test "filter: case insensitive substring match" {
    var state = TabPickerState{};
    state.entries[0] = makeEntry("MyServer", 0);
    state.entries[1] = makeEntry("localhost", 1);
    state.entry_count = 2;
    state.applyFilter();

    _ = state.handleChar('s');
    _ = state.handleChar('e');
    _ = state.handleChar('r');
    // "ser" matches "MyServer" and "localhost" does not
    try std.testing.expectEqual(@as(u8, 1), state.filtered_count);
}
