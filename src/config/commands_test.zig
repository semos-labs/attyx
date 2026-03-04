// Attyx — Command registry tests

const std = @import("std");
const commands = @import("commands.zig");
const kb = @import("keybinds.zig");
const Action = kb.Action;

test "actionFromName: known actions" {
    try std.testing.expectEqual(Action.copy, commands.actionFromName("copy").?);
    try std.testing.expectEqual(Action.paste, commands.actionFromName("paste").?);
    try std.testing.expectEqual(Action.config_reload, commands.actionFromName("config_reload").?);
    try std.testing.expectEqual(Action.tab_new, commands.actionFromName("tab_new").?);
    try std.testing.expectEqual(Action.clear_screen, commands.actionFromName("clear_screen").?);
    try std.testing.expectEqual(Action.session_switcher_toggle, commands.actionFromName("session_switcher_toggle").?);
}

test "actionFromName: unknown returns null" {
    try std.testing.expect(commands.actionFromName("bogus") == null);
    try std.testing.expect(commands.actionFromName("") == null);
}

test "commandForAction: known action" {
    const cmd = commands.commandForAction(.config_reload).?;
    try std.testing.expectEqualStrings("config_reload", cmd.name);
    try std.testing.expectEqual(commands.Scope.global, cmd.scope);
}

test "commandForAction: unknown returns null" {
    try std.testing.expect(commands.commandForAction(.none) == null);
}

test "registry: all entries have non-empty name and description" {
    for (commands.registry) |cmd| {
        try std.testing.expect(cmd.name.len > 0);
        try std.testing.expect(cmd.description.len > 0);
    }
}

test "registry: no duplicate action values (except tab_prev/tab_next for arrow variants)" {
    // Actions can repeat (e.g. tab_prev has both Ctrl+Shift+Tab and Cmd+Shift+Left)
    // but names must be unique
    for (commands.registry, 0..) |a, i| {
        for (commands.registry[0..i]) |b| {
            if (std.mem.eql(u8, a.name, b.name)) {
                return error.TestUnexpectedResult; // duplicate name
            }
        }
    }
}

test "defaultKeybinds: produces entries" {
    const defaults = commands.defaultKeybinds();
    try std.testing.expect(defaults.len > 0);
}

test "defaultKeybinds: config_reload present" {
    const defaults = commands.defaultKeybinds();
    var found = false;
    for (defaults) |entry| {
        if (entry.action == .config_reload) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "defaultKeybinds: tab_new present" {
    const defaults = commands.defaultKeybinds();
    var found = false;
    for (defaults) |entry| {
        if (entry.action == .tab_new) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "actionFromName: round-trip with registry" {
    // Every registry entry's name should map back to its action
    inline for (commands.registry) |cmd| {
        const resolved = commands.actionFromName(cmd.name);
        try std.testing.expect(resolved != null);
        try std.testing.expectEqual(cmd.action, resolved.?);
    }
}
