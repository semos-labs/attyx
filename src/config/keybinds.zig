// Attyx — Configurable keybindings
//
// Parses key combo strings (e.g. "ctrl+shift+r"), builds a lookup table
// merging defaults with user overrides and sequence entries, and exports
// attyx_keybind_match() for platform input handlers.

const std = @import("std");
const builtin = @import("builtin");

// ---------------------------------------------------------------------------
// KeyCode constants (must match C enums in macos_input_keyboard.m / linux_input.c
// and the Zig KeyCode enum in key_encode.zig)
// ---------------------------------------------------------------------------

const KC_UP: u16 = 0;
const KC_DOWN: u16 = 1;
const KC_LEFT: u16 = 2;
const KC_RIGHT: u16 = 3;
const KC_HOME: u16 = 4;
const KC_END: u16 = 5;
const KC_PAGE_UP: u16 = 6;
const KC_PAGE_DOWN: u16 = 7;
const KC_INSERT: u16 = 8;
const KC_DELETE: u16 = 9;
const KC_BACKSPACE: u16 = 10;
const KC_ENTER: u16 = 11;
const KC_TAB: u16 = 12;
const KC_ESCAPE: u16 = 13;
const KC_F1: u16 = 14;
const KC_CODEPOINT: u16 = 26;

// Modifier bits (match buildMods() in macOS/Linux input code)
pub const MOD_SHIFT: u8 = 1;
pub const MOD_ALT: u8 = 2;
pub const MOD_CTRL: u8 = 4;
pub const MOD_SUPER: u8 = 8;

// ---------------------------------------------------------------------------
// Action enum — values mirrored as ATTYX_ACTION_* in bridge.h
// ---------------------------------------------------------------------------

pub const Action = enum(u8) {
    none = 0,
    copy = 1,
    paste = 2,
    search_toggle = 3,
    search_next = 4,
    search_prev = 5,
    scroll_page_up = 6,
    scroll_page_down = 7,
    scroll_to_top = 8,
    scroll_to_bottom = 9,
    config_reload = 10,
    debug_toggle = 11,
    anchor_demo_toggle = 12,
    new_window = 13,
    close_window = 14,
    popup_toggle_0 = 15,
    send_sequence = 47,
    ai_demo_toggle = 48,
    tab_new = 49,
    tab_close = 50,
    tab_next = 51,
    tab_prev = 52,
    _,

    /// Return the popup index if this is a popup_toggle action.
    pub fn popupIndex(self: Action) ?u8 {
        const v = @intFromEnum(self);
        const base = @intFromEnum(Action.popup_toggle_0);
        if (v >= base and v < base + 32) return @intCast(v - base);
        return null;
    }
};

/// Map a popup index (0–31) to the corresponding popup_toggle action.
pub fn popupToggleAction(index: u8) Action {
    return @enumFromInt(@intFromEnum(Action.popup_toggle_0) + index);
}

// ---------------------------------------------------------------------------
// Key combo and keybind types
// ---------------------------------------------------------------------------

pub const KeyCombo = struct {
    key: u16, // KC_* value; KC_CODEPOINT for letters/symbols
    mods: u8, // bitmask: MOD_SHIFT | MOD_ALT | MOD_CTRL | MOD_SUPER
    codepoint: u32, // Unicode codepoint when key == KC_CODEPOINT
};

pub const Keybind = struct {
    combo: KeyCombo,
    action: Action,
    seq_offset: u16 = 0, // offset into Table.seq_buf (send_sequence only)
    seq_len: u16 = 0, // byte length of sequence data
};

pub const MAX_KEYBINDS: usize = 64;
const MAX_SEQ_BUF: usize = 2048;

pub const Table = struct {
    entries: [MAX_KEYBINDS]Keybind = undefined,
    count: u8 = 0,
    seq_buf: [MAX_SEQ_BUF]u8 = undefined,
    seq_used: u16 = 0,
};

// ---------------------------------------------------------------------------
// Config overlay types (populated by config.zig TOML parsing)
// ---------------------------------------------------------------------------

pub const KeybindOverride = struct {
    action_name: []const u8, // e.g. "copy", or "none" to unbind
    key_combo: []const u8, // e.g. "ctrl+shift+c"
};

pub const SequenceEntry = struct {
    key_combo: []const u8, // e.g. "ctrl+shift+k"
    data: []const u8, // raw bytes to send (TOML-decoded)
};

pub const PopupHotkey = struct {
    index: u8, // popup config index (0-based)
    hotkey: []const u8, // key combo string from config
};

// ---------------------------------------------------------------------------
// Parser: key combo strings → KeyCombo
// ---------------------------------------------------------------------------

pub fn parseKeyCombo(input: []const u8) ?KeyCombo {
    if (input.len == 0) return null;

    var mods: u8 = 0;
    var key_name: ?[]const u8 = null;
    var start: usize = 0;

    // Tokenize on '+'
    for (input, 0..) |ch, i| {
        if (ch == '+' or i == input.len - 1) {
            const end = if (ch == '+') i else i + 1;
            const token = std.mem.trim(u8, input[start..end], " ");
            start = i + 1;
            if (token.len == 0) continue;

            if (modifierBit(token)) |bit| {
                mods |= bit;
            } else {
                if (key_name != null) return null; // two non-modifier tokens
                key_name = token;
            }
        }
    }

    const name = key_name orelse return null;
    const resolved = resolveKeyName(name) orelse return null;
    return .{ .key = resolved.key, .mods = mods, .codepoint = resolved.codepoint };
}

fn modifierBit(s: []const u8) ?u8 {
    if (eql(s, "ctrl") or eql(s, "control")) return MOD_CTRL;
    if (eql(s, "shift")) return MOD_SHIFT;
    if (eql(s, "alt") or eql(s, "option")) return MOD_ALT;
    if (eql(s, "super") or eql(s, "cmd") or eql(s, "command")) return MOD_SUPER;
    return null;
}

const ResolvedKey = struct { key: u16, codepoint: u32 };

fn resolveKeyName(name: []const u8) ?ResolvedKey {
    // Single character
    if (name.len == 1) {
        const ch = name[0];
        if (ch >= 'a' and ch <= 'z') return .{ .key = KC_CODEPOINT, .codepoint = ch };
        if (ch >= 'A' and ch <= 'Z') return .{ .key = KC_CODEPOINT, .codepoint = ch | 0x20 };
        if (ch >= '0' and ch <= '9') return .{ .key = KC_CODEPOINT, .codepoint = ch };
    }
    // Named special keys
    if (eql(name, "enter") or eql(name, "return")) return .{ .key = KC_ENTER, .codepoint = 0 };
    if (eql(name, "tab")) return .{ .key = KC_TAB, .codepoint = 0 };
    if (eql(name, "escape") or eql(name, "esc")) return .{ .key = KC_ESCAPE, .codepoint = 0 };
    if (eql(name, "backspace")) return .{ .key = KC_BACKSPACE, .codepoint = 0 };
    if (eql(name, "delete")) return .{ .key = KC_DELETE, .codepoint = 0 };
    if (eql(name, "insert")) return .{ .key = KC_INSERT, .codepoint = 0 };
    if (eql(name, "space")) return .{ .key = KC_CODEPOINT, .codepoint = ' ' };
    if (eql(name, "page_up") or eql(name, "pageup")) return .{ .key = KC_PAGE_UP, .codepoint = 0 };
    if (eql(name, "page_down") or eql(name, "pagedown")) return .{ .key = KC_PAGE_DOWN, .codepoint = 0 };
    if (eql(name, "home")) return .{ .key = KC_HOME, .codepoint = 0 };
    if (eql(name, "end")) return .{ .key = KC_END, .codepoint = 0 };
    if (eql(name, "up")) return .{ .key = KC_UP, .codepoint = 0 };
    if (eql(name, "down")) return .{ .key = KC_DOWN, .codepoint = 0 };
    if (eql(name, "left")) return .{ .key = KC_LEFT, .codepoint = 0 };
    if (eql(name, "right")) return .{ .key = KC_RIGHT, .codepoint = 0 };
    // Function keys: f1–f12
    if (name.len >= 2 and name.len <= 3 and (name[0] == 'f' or name[0] == 'F')) {
        const num = std.fmt.parseInt(u8, name[1..], 10) catch return null;
        if (num >= 1 and num <= 12) return .{ .key = KC_F1 + num - 1, .codepoint = 0 };
    }
    return null;
}

// ---------------------------------------------------------------------------
// Action name mapping
// ---------------------------------------------------------------------------

pub fn actionFromString(s: []const u8) ?Action {
    const map = .{
        .{ "copy", Action.copy },
        .{ "paste", Action.paste },
        .{ "search_toggle", Action.search_toggle },
        .{ "search_next", Action.search_next },
        .{ "search_prev", Action.search_prev },
        .{ "scroll_page_up", Action.scroll_page_up },
        .{ "scroll_page_down", Action.scroll_page_down },
        .{ "scroll_to_top", Action.scroll_to_top },
        .{ "scroll_to_bottom", Action.scroll_to_bottom },
        .{ "config_reload", Action.config_reload },
        .{ "debug_toggle", Action.debug_toggle },
        .{ "anchor_demo_toggle", Action.anchor_demo_toggle },
        .{ "new_window", Action.new_window },
        .{ "close_window", Action.close_window },
        .{ "ai_demo_toggle", Action.ai_demo_toggle },
        .{ "tab_new", Action.tab_new },
        .{ "tab_close", Action.tab_close },
        .{ "tab_next", Action.tab_next },
        .{ "tab_prev", Action.tab_prev },
    };
    inline for (map) |entry| {
        if (eql(s, entry[0])) return entry[1];
    }
    return null;
}

// ---------------------------------------------------------------------------
// Platform-aware defaults
// ---------------------------------------------------------------------------

fn defaultKeybinds() []const Keybind {
    const is_macos = comptime builtin.os.tag == .macos;
    const defaults = comptime blk: {
        var list: []const Keybind = &.{
            kb(.{ .key = KC_PAGE_UP, .mods = MOD_SHIFT, .codepoint = 0 }, .scroll_page_up),
            kb(.{ .key = KC_PAGE_DOWN, .mods = MOD_SHIFT, .codepoint = 0 }, .scroll_page_down),
            kb(.{ .key = KC_HOME, .mods = MOD_SHIFT, .codepoint = 0 }, .scroll_to_top),
            kb(.{ .key = KC_END, .mods = MOD_SHIFT, .codepoint = 0 }, .scroll_to_bottom),
            kb(.{ .key = KC_CODEPOINT, .mods = MOD_CTRL | MOD_SHIFT, .codepoint = 'r' }, .config_reload),
            kb(.{ .key = KC_CODEPOINT, .mods = MOD_CTRL | MOD_SHIFT, .codepoint = 'd' }, .debug_toggle),
            kb(.{ .key = KC_CODEPOINT, .mods = MOD_CTRL | MOD_SHIFT, .codepoint = 'a' }, .anchor_demo_toggle),
            kb(.{ .key = KC_CODEPOINT, .mods = MOD_CTRL | MOD_SHIFT, .codepoint = 'n' }, .new_window),
            kb(.{ .key = KC_CODEPOINT, .mods = MOD_CTRL | MOD_SHIFT, .codepoint = 'w' }, .close_window),
            kb(.{ .key = KC_CODEPOINT, .mods = MOD_CTRL | MOD_SHIFT, .codepoint = 'i' }, .ai_demo_toggle),
        };
        // Tab management (cross-platform)
        list = list ++ &[_]Keybind{
            kb(.{ .key = KC_TAB, .mods = MOD_CTRL, .codepoint = 0 }, .tab_next),
            kb(.{ .key = KC_TAB, .mods = MOD_CTRL | MOD_SHIFT, .codepoint = 0 }, .tab_prev),
        };
        if (is_macos) {
            list = list ++ &[_]Keybind{
                kb(.{ .key = KC_CODEPOINT, .mods = MOD_SUPER, .codepoint = 'f' }, .search_toggle),
                kb(.{ .key = KC_CODEPOINT, .mods = MOD_SUPER, .codepoint = 'g' }, .search_next),
                kb(.{ .key = KC_CODEPOINT, .mods = MOD_SUPER | MOD_SHIFT, .codepoint = 'g' }, .search_prev),
                kb(.{ .key = KC_CODEPOINT, .mods = MOD_SUPER, .codepoint = 't' }, .tab_new),
                kb(.{ .key = KC_CODEPOINT, .mods = MOD_SUPER, .codepoint = 'w' }, .tab_close),
            };
        } else {
            list = list ++ &[_]Keybind{
                kb(.{ .key = KC_CODEPOINT, .mods = MOD_CTRL | MOD_SHIFT, .codepoint = 'c' }, .copy),
                kb(.{ .key = KC_CODEPOINT, .mods = MOD_CTRL | MOD_SHIFT, .codepoint = 'v' }, .paste),
                kb(.{ .key = KC_CODEPOINT, .mods = MOD_CTRL, .codepoint = 'f' }, .search_toggle),
                kb(.{ .key = KC_CODEPOINT, .mods = MOD_CTRL, .codepoint = 'g' }, .search_next),
                kb(.{ .key = KC_CODEPOINT, .mods = MOD_CTRL | MOD_SHIFT, .codepoint = 'g' }, .search_prev),
                kb(.{ .key = KC_CODEPOINT, .mods = MOD_CTRL | MOD_SHIFT, .codepoint = 't' }, .tab_new),
                kb(.{ .key = KC_CODEPOINT, .mods = MOD_CTRL | MOD_SHIFT, .codepoint = 'w' }, .tab_close),
            };
        }
        break :blk list;
    };
    return defaults;
}

fn kb(combo: KeyCombo, action: Action) Keybind {
    return .{ .combo = combo, .action = action };
}

// ---------------------------------------------------------------------------
// Table building: merge defaults + overrides + sequences + popup hotkeys
// ---------------------------------------------------------------------------

pub fn buildTable(
    overrides: ?[]const KeybindOverride,
    sequences: ?[]const SequenceEntry,
    popup_hotkeys: []const PopupHotkey,
) Table {
    var table = Table{};

    // 1. Seed with defaults
    for (defaultKeybinds()) |d| {
        appendEntry(&table, d);
    }

    // 2. Apply keybinding overrides
    if (overrides) |ovs| {
        for (ovs) |ov| {
            const action = actionFromString(ov.action_name) orelse continue;
            if (eql(ov.key_combo, "none")) {
                removeAction(&table, action);
                continue;
            }
            const combo = parseKeyCombo(ov.key_combo) orelse continue;
            replaceOrAddAction(&table, .{ .combo = combo, .action = action });
        }
    }

    // 3. Add popup hotkeys
    for (popup_hotkeys) |ph| {
        const combo = parseKeyCombo(ph.hotkey) orelse continue;
        const action = popupToggleAction(ph.index);
        replaceOrAddCombo(&table, .{ .combo = combo, .action = action });
    }

    // 4. Add sequence entries (override any existing combo)
    if (sequences) |seqs| {
        for (seqs) |seq| {
            const combo = parseKeyCombo(seq.key_combo) orelse continue;
            if (seq.data.len == 0) continue;
            if (table.seq_used + seq.data.len > MAX_SEQ_BUF) continue; // buffer full
            const offset = table.seq_used;
            @memcpy(table.seq_buf[offset .. offset + seq.data.len], seq.data);
            table.seq_used += @intCast(seq.data.len);
            replaceOrAddCombo(&table, .{
                .combo = combo,
                .action = .send_sequence,
                .seq_offset = @intCast(offset),
                .seq_len = @intCast(seq.data.len),
            });
        }
    }

    return table;
}

fn appendEntry(table: *Table, entry: Keybind) void {
    if (table.count >= MAX_KEYBINDS) return;
    table.entries[table.count] = entry;
    table.count += 1;
}

fn removeAction(table: *Table, action: Action) void {
    var dst: u8 = 0;
    for (table.entries[0..table.count]) |e| {
        if (e.action != action) {
            table.entries[dst] = e;
            dst += 1;
        }
    }
    table.count = dst;
}

/// Replace the entry for this action (keeps same slot), or append.
fn replaceOrAddAction(table: *Table, entry: Keybind) void {
    for (table.entries[0..table.count]) |*e| {
        if (e.action == entry.action) {
            e.* = entry;
            return;
        }
    }
    appendEntry(table, entry);
}

/// Replace any entry with the same combo, or append.
fn replaceOrAddCombo(table: *Table, entry: Keybind) void {
    for (table.entries[0..table.count]) |*e| {
        if (combosEqual(e.combo, entry.combo)) {
            e.* = entry;
            return;
        }
    }
    appendEntry(table, entry);
}

fn combosEqual(a: KeyCombo, b: KeyCombo) bool {
    if (a.key != b.key or a.mods != b.mods) return false;
    if (a.key == KC_CODEPOINT) return toLower(a.codepoint) == toLower(b.codepoint);
    return true;
}

// ---------------------------------------------------------------------------
// Module-level keybind table (written by PTY thread, read by input thread)
// ---------------------------------------------------------------------------

var g_table: Table = .{};

/// Install a new keybind table (called at startup and on config reload).
pub fn installTable(table: *const Table) void {
    g_table = table.*;
}

// Matched sequence result (set by attyx_keybind_match for send_sequence actions)
pub export var g_keybind_matched_seq: [*]const u8 = @as([*]const u8, @ptrCast(&g_table.seq_buf));
pub export var g_keybind_matched_seq_len: c_int = 0;

/// C-callable keybind match. Returns action ID (0 = no match).
/// For send_sequence, sets g_keybind_matched_seq/len before returning.
pub export fn attyx_keybind_match(key: u16, mods: u8, codepoint: u32) u8 {
    const count: usize = g_table.count;
    for (g_table.entries[0..count]) |entry| {
        if (entry.combo.mods != mods) continue;
        if (entry.combo.key != key) continue;
        if (key == KC_CODEPOINT and toLower(entry.combo.codepoint) != toLower(codepoint)) continue;
        if (entry.action == .send_sequence and entry.seq_len > 0) {
            g_keybind_matched_seq = @ptrCast(&g_table.seq_buf[entry.seq_offset]);
            g_keybind_matched_seq_len = @intCast(entry.seq_len);
        }
        return @intFromEnum(entry.action);
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn toLower(cp: u32) u32 {
    if (cp >= 'A' and cp <= 'Z') return cp + 32;
    return cp;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseKeyCombo: ctrl+shift+r" {
    const combo = parseKeyCombo("ctrl+shift+r").?;
    try std.testing.expectEqual(KC_CODEPOINT, combo.key);
    try std.testing.expectEqual(MOD_CTRL | MOD_SHIFT, combo.mods);
    try std.testing.expectEqual(@as(u32, 'r'), combo.codepoint);
}

test "parseKeyCombo: super+f" {
    const combo = parseKeyCombo("super+f").?;
    try std.testing.expectEqual(KC_CODEPOINT, combo.key);
    try std.testing.expectEqual(MOD_SUPER, combo.mods);
    try std.testing.expectEqual(@as(u32, 'f'), combo.codepoint);
}

test "parseKeyCombo: shift+page_up" {
    const combo = parseKeyCombo("shift+page_up").?;
    try std.testing.expectEqual(KC_PAGE_UP, combo.key);
    try std.testing.expectEqual(MOD_SHIFT, combo.mods);
    try std.testing.expectEqual(@as(u32, 0), combo.codepoint);
}

test "parseKeyCombo: f12" {
    const combo = parseKeyCombo("f12").?;
    try std.testing.expectEqual(KC_F1 + 11, combo.key);
    try std.testing.expectEqual(@as(u8, 0), combo.mods);
}

test "parseKeyCombo: alt+enter" {
    const combo = parseKeyCombo("alt+enter").?;
    try std.testing.expectEqual(KC_ENTER, combo.key);
    try std.testing.expectEqual(MOD_ALT, combo.mods);
}

test "parseKeyCombo: invalid" {
    try std.testing.expect(parseKeyCombo("") == null);
    try std.testing.expect(parseKeyCombo("ctrl+shift") == null); // no key
    try std.testing.expect(parseKeyCombo("ctrl+shift+xx") == null); // unknown key
}

test "actionFromString" {
    try std.testing.expectEqual(Action.copy, actionFromString("copy").?);
    try std.testing.expectEqual(Action.config_reload, actionFromString("config_reload").?);
    try std.testing.expect(actionFromString("bogus") == null);
}

test "buildTable: defaults present" {
    const table = buildTable(null, null, &.{});
    try std.testing.expect(table.count > 0);
    // config_reload should be in defaults
    var found = false;
    for (table.entries[0..table.count]) |e| {
        if (e.action == .config_reload) { found = true; break; }
    }
    try std.testing.expect(found);
}

test "buildTable: override replaces binding" {
    const overrides = [_]KeybindOverride{
        .{ .action_name = "config_reload", .key_combo = "alt+r" },
    };
    const table = buildTable(&overrides, null, &.{});
    for (table.entries[0..table.count]) |e| {
        if (e.action == .config_reload) {
            try std.testing.expectEqual(MOD_ALT, e.combo.mods);
            try std.testing.expectEqual(@as(u32, 'r'), e.combo.codepoint);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "buildTable: none unbinds" {
    const overrides = [_]KeybindOverride{
        .{ .action_name = "config_reload", .key_combo = "none" },
    };
    const table = buildTable(&overrides, null, &.{});
    for (table.entries[0..table.count]) |e| {
        if (e.action == .config_reload) return error.TestUnexpectedResult;
    }
}

test "buildTable: popup hotkeys" {
    const hotkeys = [_]PopupHotkey{
        .{ .index = 0, .hotkey = "ctrl+shift+g" },
        .{ .index = 1, .hotkey = "ctrl+shift+t" },
    };
    const table = buildTable(null, null, &hotkeys);
    var found: u8 = 0;
    for (table.entries[0..table.count]) |e| {
        if (e.action.popupIndex()) |_| found += 1;
    }
    try std.testing.expectEqual(@as(u8, 2), found);
}

test "buildTable: sequence entries" {
    const seqs = [_]SequenceEntry{
        .{ .key_combo = "ctrl+shift+k", .data = "\x1b[K" },
    };
    const table = buildTable(null, &seqs, &.{});
    var found = false;
    for (table.entries[0..table.count]) |e| {
        if (e.action == .send_sequence) {
            try std.testing.expectEqual(@as(u16, 3), e.seq_len);
            const seq = table.seq_buf[e.seq_offset .. e.seq_offset + e.seq_len];
            try std.testing.expectEqualSlices(u8, "\x1b[K", seq);
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "match: basic lookup" {
    const table = buildTable(null, null, &.{});
    installTable(&table);
    // config_reload is ctrl+shift+r
    const action = attyx_keybind_match(KC_CODEPOINT, MOD_CTRL | MOD_SHIFT, 'R');
    try std.testing.expectEqual(@intFromEnum(Action.config_reload), action);
}

test "match: no match returns 0" {
    const table = buildTable(null, null, &.{});
    installTable(&table);
    const action = attyx_keybind_match(KC_CODEPOINT, 0, 'z');
    try std.testing.expectEqual(@as(u8, 0), action);
}

test "match: case insensitive" {
    const table = buildTable(null, null, &.{});
    installTable(&table);
    // Should match whether platform sends 'r' or 'R'
    const a1 = attyx_keybind_match(KC_CODEPOINT, MOD_CTRL | MOD_SHIFT, 'r');
    const a2 = attyx_keybind_match(KC_CODEPOINT, MOD_CTRL | MOD_SHIFT, 'R');
    try std.testing.expectEqual(a1, a2);
    try std.testing.expect(a1 != 0);
}

test "popupIndex" {
    try std.testing.expectEqual(@as(?u8, 0), Action.popup_toggle_0.popupIndex());
    try std.testing.expectEqual(@as(?u8, null), Action.copy.popupIndex());
    const t5 = popupToggleAction(5);
    try std.testing.expectEqual(@as(?u8, 5), t5.popupIndex());
}
