/// Command palette — pure state machine for the overlay-based command palette.
///
/// No side effects, no app-layer dependencies. Testable in headless mode.
/// Stores command entries (populated by the UI layer from the registry).
const std = @import("std");

pub const max_commands = 96;

pub const CommandEntry = struct {
    name: [64]u8 = undefined,
    name_len: u8 = 0,
    desc: [80]u8 = undefined,
    desc_len: u8 = 0,
    action_id: u8 = 0,
    mac_hotkey: [32]u8 = undefined,
    mac_hotkey_len: u8 = 0,
    linux_hotkey: [32]u8 = undefined,
    linux_hotkey_len: u8 = 0,

    pub fn getName(self: *const CommandEntry) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getDesc(self: *const CommandEntry) []const u8 {
        return self.desc[0..self.desc_len];
    }

    pub fn getMacHotkey(self: *const CommandEntry) []const u8 {
        return self.mac_hotkey[0..self.mac_hotkey_len];
    }

    pub fn getLinuxHotkey(self: *const CommandEntry) []const u8 {
        return self.linux_hotkey[0..self.linux_hotkey_len];
    }
};

pub const PaletteAction = union(enum) {
    none,
    execute: u8, // action_id
    close: void,
    rename_tab: []const u8, // new tab name
};

pub const CommandPaletteState = struct {
    entries: [max_commands]CommandEntry = undefined,
    entry_count: u8 = 0,
    filter_buf: [64]u8 = .{0} ** 64,
    filter_len: u8 = 0,
    selected: u8 = 0,
    scroll_offset: u8 = 0,
    filtered_indices: [max_commands]u8 = undefined,
    filtered_count: u8 = 0,
    visible_rows: u8 = 10,
    rename_mode: bool = false,

    /// Handle a character input. Appends to filter and refilters.
    pub fn handleChar(self: *CommandPaletteState, codepoint: u32) PaletteAction {
        if (codepoint >= 0x20 and codepoint < 0x7f and self.filter_len < 63) {
            self.filter_buf[self.filter_len] = @intCast(codepoint);
            self.filter_len += 1;
            if (!self.rename_mode) {
                self.applyFilter();
                self.selected = 0;
                self.scroll_offset = 0;
            }
        }
        return .none;
    }

    /// Handle a command code. Returns action if one should be executed.
    /// Command codes: 1=backspace, 7=escape/close, 8=enter/execute,
    /// 9=up, 10=down. Picker-specific codes (11-13) are ignored.
    pub fn handleCmd(self: *CommandPaletteState, cmd: i32) PaletteAction {
        if (self.rename_mode) {
            switch (cmd) {
                1 => { // Backspace
                    if (self.filter_len > 0) self.filter_len -= 1;
                },
                7 => return .close, // Escape
                8 => { // Enter — apply rename
                    if (self.filter_len == 0) return .none;
                    return .{ .rename_tab = self.filter_buf[0..self.filter_len] };
                },
                else => {},
            }
            return .none;
        }
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
            8 => { // Enter — execute selected command
                if (self.filtered_count > 0 and self.selected < self.filtered_count) {
                    const idx = self.filtered_indices[self.selected];
                    return .{ .execute = self.entries[idx].action_id };
                }
            },
            9 => self.moveUp(), // Up
            10 => self.moveDown(), // Down
            else => {}, // Ignore picker-specific commands (11-13)
        }
        return .none;
    }

    /// Enter rename mode: clear filter and switch to text input for tab name.
    pub fn enterRenameMode(self: *CommandPaletteState) void {
        self.rename_mode = true;
        self.filter_len = 0;
        self.filtered_count = 0;
    }

    fn moveUp(self: *CommandPaletteState) void {
        if (self.filtered_count > 0) {
            self.selected = if (self.selected == 0) self.filtered_count - 1 else self.selected - 1;
            self.adjustScroll();
        }
    }

    fn moveDown(self: *CommandPaletteState) void {
        if (self.filtered_count > 0) {
            self.selected = if (self.selected + 1 >= self.filtered_count) 0 else self.selected + 1;
            self.adjustScroll();
        }
    }

    pub fn applyFilter(self: *CommandPaletteState) void {
        var n: u8 = 0;
        for (0..self.entry_count) |i| {
            if (self.filter_len == 0 or
                substringMatch(self.entries[i].getName(), self.filter_buf[0..self.filter_len]) or
                substringMatch(self.entries[i].getDesc(), self.filter_buf[0..self.filter_len]))
            {
                self.filtered_indices[n] = @intCast(i);
                n += 1;
            }
        }
        self.filtered_count = n;
    }

    pub fn adjustScroll(self: *CommandPaletteState) void {
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

fn makeTestEntry(name: []const u8, desc: []const u8, action_id: u8) CommandEntry {
    var e = CommandEntry{};
    e.name_len = @intCast(name.len);
    @memcpy(e.name[0..name.len], name);
    e.desc_len = @intCast(desc.len);
    @memcpy(e.desc[0..desc.len], desc);
    e.action_id = action_id;
    return e;
}

test "applyFilter: empty filter returns all" {
    var state = CommandPaletteState{};
    state.entries[0] = makeTestEntry("copy", "Copy selection", 1);
    state.entries[1] = makeTestEntry("paste", "Paste clipboard", 2);
    state.entry_count = 2;
    state.applyFilter();
    try std.testing.expectEqual(@as(u8, 2), state.filtered_count);
}

test "applyFilter: filter narrows results" {
    var state = CommandPaletteState{};
    state.entries[0] = makeTestEntry("copy", "Copy selection", 1);
    state.entries[1] = makeTestEntry("paste", "Paste clipboard", 2);
    state.entry_count = 2;
    state.filter_buf[0] = 'c';
    state.filter_buf[1] = 'o';
    state.filter_buf[2] = 'p';
    state.filter_buf[3] = 'y';
    state.filter_len = 4;
    state.applyFilter();
    try std.testing.expectEqual(@as(u8, 1), state.filtered_count);
}

test "handleCmd: escape returns close" {
    var state = CommandPaletteState{};
    state.entries[0] = makeTestEntry("copy", "Copy", 1);
    state.entry_count = 1;
    state.applyFilter();
    const action = state.handleCmd(7);
    switch (action) {
        .close => {},
        else => return error.TestUnexpectedResult,
    }
}

test "handleCmd: enter executes selected" {
    var state = CommandPaletteState{};
    state.entries[0] = makeTestEntry("copy", "Copy", 42);
    state.entry_count = 1;
    state.applyFilter();
    state.selected = 0;
    const action = state.handleCmd(8);
    switch (action) {
        .execute => |id| try std.testing.expectEqual(@as(u8, 42), id),
        else => return error.TestUnexpectedResult,
    }
}

test "handleCmd: up/down wraps" {
    var state = CommandPaletteState{};
    state.entries[0] = makeTestEntry("a", "A", 1);
    state.entries[1] = makeTestEntry("b", "B", 2);
    state.entry_count = 2;
    state.applyFilter();
    _ = state.handleCmd(9); // up wraps to last
    try std.testing.expectEqual(@as(u8, 1), state.selected);
    _ = state.handleCmd(10); // down wraps to first
    try std.testing.expectEqual(@as(u8, 0), state.selected);
}

test "handleCmd: picker-specific codes are no-ops" {
    var state = CommandPaletteState{};
    state.entries[0] = makeTestEntry("a", "A", 1);
    state.entry_count = 1;
    state.applyFilter();
    const a11 = state.handleCmd(11);
    const a12 = state.handleCmd(12);
    const a13 = state.handleCmd(13);
    switch (a11) {
        .none => {},
        else => return error.TestUnexpectedResult,
    }
    switch (a12) {
        .none => {},
        else => return error.TestUnexpectedResult,
    }
    switch (a13) {
        .none => {},
        else => return error.TestUnexpectedResult,
    }
}

test "substringMatch: case-insensitive" {
    try std.testing.expect(substringMatch("Toggle search bar", "search"));
    try std.testing.expect(substringMatch("Toggle search bar", "SEARCH"));
    try std.testing.expect(!substringMatch("copy", "xyz"));
}

test "rename mode ignores empty enter" {
    var state = CommandPaletteState{};
    state.enterRenameMode();

    const action = state.handleCmd(8);
    switch (action) {
        .none => {},
        else => return error.TestUnexpectedResult,
    }
}

test "rename mode returns rename action for non-empty title" {
    var state = CommandPaletteState{};
    state.enterRenameMode();
    _ = state.handleChar('e');
    _ = state.handleChar('d');
    _ = state.handleChar('i');
    _ = state.handleChar('t');
    _ = state.handleChar('o');
    _ = state.handleChar('r');

    const action = state.handleCmd(8);
    switch (action) {
        .rename_tab => |name| try std.testing.expectEqualStrings("editor", name),
        else => return error.TestUnexpectedResult,
    }
}
