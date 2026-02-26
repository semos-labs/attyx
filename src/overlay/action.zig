const std = @import("std");

pub const ActionId = enum(u8) {
    dismiss,
    insert,
    copy,
    apply,
    next,
    prev,
    custom_0,
    custom_1,
};

pub const OverlayAction = struct {
    id: ActionId,
    label: []const u8,
};

pub const max_actions = 6;

pub const ActionBar = struct {
    actions: [max_actions]OverlayAction = undefined,
    count: u8 = 0,
    focused: u8 = 0,

    pub fn add(self: *ActionBar, id: ActionId, label: []const u8) void {
        if (self.count >= max_actions) return;
        self.actions[self.count] = .{ .id = id, .label = label };
        self.count += 1;
    }

    pub fn focusNext(self: *ActionBar) void {
        if (self.count == 0) return;
        self.focused = (self.focused + 1) % self.count;
    }

    pub fn focusPrev(self: *ActionBar) void {
        if (self.count == 0) return;
        if (self.focused == 0) {
            self.focused = self.count - 1;
        } else {
            self.focused -= 1;
        }
    }

    pub fn focusedId(self: *const ActionBar) ?ActionId {
        if (self.count == 0) return null;
        return self.actions[self.focused].id;
    }

    pub fn hasActions(self: *const ActionBar) bool {
        return self.count > 0;
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "ActionBar: add and focusedId" {
    var bar = ActionBar{};
    try std.testing.expectEqual(@as(?ActionId, null), bar.focusedId());
    try std.testing.expect(!bar.hasActions());

    bar.add(.dismiss, "Dismiss");
    try std.testing.expect(bar.hasActions());
    try std.testing.expectEqual(@as(?ActionId, .dismiss), bar.focusedId());
    try std.testing.expectEqual(@as(u8, 1), bar.count);

    bar.add(.insert, "Insert");
    try std.testing.expectEqual(@as(u8, 2), bar.count);
    // Focus still on first
    try std.testing.expectEqual(@as(?ActionId, .dismiss), bar.focusedId());
}

test "ActionBar: focusNext wraps" {
    var bar = ActionBar{};
    bar.add(.dismiss, "Dismiss");
    bar.add(.copy, "Copy");
    bar.add(.insert, "Insert");

    try std.testing.expectEqual(@as(u8, 0), bar.focused);
    bar.focusNext();
    try std.testing.expectEqual(@as(u8, 1), bar.focused);
    bar.focusNext();
    try std.testing.expectEqual(@as(u8, 2), bar.focused);
    bar.focusNext();
    try std.testing.expectEqual(@as(u8, 0), bar.focused); // wrapped
}

test "ActionBar: focusPrev wraps" {
    var bar = ActionBar{};
    bar.add(.dismiss, "Dismiss");
    bar.add(.copy, "Copy");

    try std.testing.expectEqual(@as(u8, 0), bar.focused);
    bar.focusPrev();
    try std.testing.expectEqual(@as(u8, 1), bar.focused); // wrapped to last
    bar.focusPrev();
    try std.testing.expectEqual(@as(u8, 0), bar.focused);
}

test "ActionBar: capacity limit" {
    var bar = ActionBar{};
    for (0..max_actions + 2) |_| {
        bar.add(.dismiss, "X");
    }
    try std.testing.expectEqual(@as(u8, max_actions), bar.count);
}

test "ActionBar: empty bar operations" {
    var bar = ActionBar{};
    bar.focusNext(); // should not crash
    bar.focusPrev(); // should not crash
    try std.testing.expectEqual(@as(?ActionId, null), bar.focusedId());
    try std.testing.expect(!bar.hasActions());
}
