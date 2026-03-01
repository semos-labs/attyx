// Attyx — Keybind tests (extracted from keybinds.zig)

const std = @import("std");
const kb_mod = @import("keybinds.zig");

const parseKeyCombo = kb_mod.parseKeyCombo;
const actionFromString = kb_mod.actionFromString;
const buildTable = kb_mod.buildTable;
const installTable = kb_mod.installTable;
const attyx_keybind_match = kb_mod.attyx_keybind_match;
const popupToggleAction = kb_mod.popupToggleAction;
const Action = kb_mod.Action;
const KeybindOverride = kb_mod.KeybindOverride;
const SequenceEntry = kb_mod.SequenceEntry;
const PopupHotkey = kb_mod.PopupHotkey;

const KC_CODEPOINT = kb_mod.KC_CODEPOINT;
const KC_PAGE_UP = kb_mod.KC_PAGE_UP;
const KC_ENTER = kb_mod.KC_ENTER;
const KC_F1 = kb_mod.KC_F1;
const MOD_SHIFT = kb_mod.MOD_SHIFT;
const MOD_ALT = kb_mod.MOD_ALT;
const MOD_CTRL = kb_mod.MOD_CTRL;
const MOD_SUPER = kb_mod.MOD_SUPER;

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

test "parseKeyCombo: numpad keys" {
    const kp_enter = parseKeyCombo("kp_enter").?;
    try std.testing.expectEqual(kb_mod.KC_KP_ENTER, kp_enter.key);

    const kp_plus = parseKeyCombo("kp_plus").?;
    try std.testing.expectEqual(kb_mod.KC_KP_PLUS, kp_plus.key);

    const kp_0 = parseKeyCombo("kp_0").?;
    try std.testing.expectEqual(kb_mod.KC_KP_0, kp_0.key);

    const kp_9 = parseKeyCombo("kp_9").?;
    try std.testing.expectEqual(kb_mod.KC_KP_9, kp_9.key);
}
