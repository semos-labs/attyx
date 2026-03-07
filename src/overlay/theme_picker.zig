/// Theme picker — pure state machine for the overlay-based theme browser.
///
/// No side effects, no app-layer dependencies. Testable in headless mode.
/// Stores theme name entries (populated by the UI layer from the registry).
const std = @import("std");

pub const max_themes = 64;

pub const ThemeEntry = struct {
    name: [64]u8 = undefined,
    name_len: u8 = 0,

    pub fn getName(self: *const ThemeEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const PickerAction = union(enum) {
    none,
    preview: u8, // index — hover changed, preview this theme
    select: u8, // index — user confirmed selection
    close: void,
};

pub const ThemePickerState = struct {
    entries: [max_themes]ThemeEntry = undefined,
    entry_count: u8 = 0,
    filter_buf: [64]u8 = .{0} ** 64,
    filter_len: u8 = 0,
    selected: u8 = 0,
    scroll_offset: u8 = 0,
    filtered_indices: [max_themes]u8 = undefined,
    filtered_count: u8 = 0,
    visible_rows: u8 = 10,

    /// Handle a character input. Appends to filter and refilters.
    pub fn handleChar(self: *ThemePickerState, codepoint: u32) PickerAction {
        if (codepoint >= 0x20 and codepoint < 0x7f and self.filter_len < 63) {
            self.filter_buf[self.filter_len] = @intCast(codepoint);
            self.filter_len += 1;
            self.applyFilter();
            self.selected = 0;
            self.scroll_offset = 0;
            return self.previewCurrent();
        }
        return .none;
    }

    /// Handle a command code. Returns action if one should be executed.
    /// Command codes: 1=backspace, 7=escape/close, 8=enter/select,
    /// 9=up, 10=down.
    pub fn handleCmd(self: *ThemePickerState, cmd: i32) PickerAction {
        switch (cmd) {
            1 => { // Backspace
                if (self.filter_len > 0) {
                    self.filter_len -= 1;
                    self.applyFilter();
                    self.selected = 0;
                    self.scroll_offset = 0;
                    return self.previewCurrent();
                }
            },
            7 => return .close, // Escape
            8 => { // Enter — confirm selection
                if (self.filtered_count > 0 and self.selected < self.filtered_count) {
                    return .{ .select = self.filtered_indices[self.selected] };
                }
            },
            9 => { // Up
                self.moveUp();
                return self.previewCurrent();
            },
            10 => { // Down
                self.moveDown();
                return self.previewCurrent();
            },
            else => {},
        }
        return .none;
    }

    fn previewCurrent(self: *const ThemePickerState) PickerAction {
        if (self.filtered_count > 0 and self.selected < self.filtered_count) {
            return .{ .preview = self.filtered_indices[self.selected] };
        }
        return .none;
    }

    fn moveUp(self: *ThemePickerState) void {
        if (self.filtered_count > 0) {
            self.selected = if (self.selected == 0) self.filtered_count - 1 else self.selected - 1;
            self.adjustScroll();
        }
    }

    fn moveDown(self: *ThemePickerState) void {
        if (self.filtered_count > 0) {
            self.selected = if (self.selected + 1 >= self.filtered_count) 0 else self.selected + 1;
            self.adjustScroll();
        }
    }

    pub fn applyFilter(self: *ThemePickerState) void {
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

    pub fn adjustScroll(self: *ThemePickerState) void {
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

fn makeEntry(name: []const u8) ThemeEntry {
    var e = ThemeEntry{};
    e.name_len = @intCast(name.len);
    @memcpy(e.name[0..name.len], name);
    return e;
}

test "applyFilter: empty filter returns all" {
    var state = ThemePickerState{};
    state.entries[0] = makeEntry("dracula");
    state.entries[1] = makeEntry("nord");
    state.entry_count = 2;
    state.applyFilter();
    try std.testing.expectEqual(@as(u8, 2), state.filtered_count);
}

test "applyFilter: filter narrows results" {
    var state = ThemePickerState{};
    state.entries[0] = makeEntry("dracula");
    state.entries[1] = makeEntry("nord");
    state.entry_count = 2;
    state.filter_buf[0] = 'n';
    state.filter_buf[1] = 'o';
    state.filter_len = 2;
    state.applyFilter();
    try std.testing.expectEqual(@as(u8, 1), state.filtered_count);
}

test "handleCmd: escape returns close" {
    var state = ThemePickerState{};
    state.entries[0] = makeEntry("dracula");
    state.entry_count = 1;
    state.applyFilter();
    const action = state.handleCmd(7);
    switch (action) {
        .close => {},
        else => return error.TestUnexpectedResult,
    }
}

test "handleCmd: enter selects" {
    var state = ThemePickerState{};
    state.entries[0] = makeEntry("dracula");
    state.entry_count = 1;
    state.applyFilter();
    state.selected = 0;
    const action = state.handleCmd(8);
    switch (action) {
        .select => |idx| try std.testing.expectEqual(@as(u8, 0), idx),
        else => return error.TestUnexpectedResult,
    }
}

test "handleCmd: up/down emits preview" {
    var state = ThemePickerState{};
    state.entries[0] = makeEntry("a");
    state.entries[1] = makeEntry("b");
    state.entry_count = 2;
    state.applyFilter();
    const action = state.handleCmd(10); // down
    switch (action) {
        .preview => |idx| try std.testing.expectEqual(@as(u8, 1), idx),
        else => return error.TestUnexpectedResult,
    }
}
