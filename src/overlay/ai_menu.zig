const std = @import("std");
const content_mod = @import("content.zig");
const action_mod = @import("action.zig");
const layout = @import("layout.zig");
const overlay = @import("overlay.zig");

const CardResult = layout.CardResult;
const Rgb = overlay.Rgb;

// ---------------------------------------------------------------------------
// AI menu state machine
// ---------------------------------------------------------------------------

pub const MenuSelection = enum(u8) {
    rewrite_command = 0,
    explain_command = 1,
    generate_command = 2,
};

pub const MenuState = enum(u8) {
    closed,
    open,
};

pub const MenuContext = struct {
    state: MenuState = .closed,
    selection: MenuSelection = .rewrite_command,

    pub fn init() MenuContext {
        return .{};
    }

    pub fn open(self: *MenuContext) void {
        self.state = .open;
        self.selection = .rewrite_command;
    }

    pub fn close(self: *MenuContext) void {
        self.state = .closed;
    }

    pub fn moveUp(self: *MenuContext) void {
        self.selection = switch (self.selection) {
            .rewrite_command => .generate_command, // wrap
            .explain_command => .rewrite_command,
            .generate_command => .explain_command,
        };
    }

    pub fn moveDown(self: *MenuContext) void {
        self.selection = switch (self.selection) {
            .rewrite_command => .explain_command,
            .explain_command => .generate_command,
            .generate_command => .rewrite_command, // wrap
        };
    }
};

// ---------------------------------------------------------------------------
// Menu item labels
// ---------------------------------------------------------------------------

const menu_items = [_]struct { label: []const u8, hint: []const u8 }{
    .{ .label = "Rewrite Command", .hint = "Modify current command" },
    .{ .label = "Explain Command", .hint = "Understand what a command does" },
    .{ .label = "Generate Command", .hint = "Create a new command from description" },
};

// ---------------------------------------------------------------------------
// Layout: Menu card
// ---------------------------------------------------------------------------

/// Highlight color for the selected menu row.
const highlight_bg = Rgb{ .r = 60, .g = 60, .b = 90 };

pub fn layoutMenuCard(
    allocator: std.mem.Allocator,
    menu: *const MenuContext,
    max_width: u16,
    style: content_mod.ContentStyle,
) !CardResult {
    const sel_idx = @intFromEnum(menu.selection);

    // Combine all menu items into a single paragraph (one line per item, no inter-block gap)
    var items_buf: [128]u8 = undefined;
    const items_text = std.fmt.bufPrint(&items_buf, "  {s}\n  {s}\n  {s}", .{
        menu_items[0].label,
        menu_items[1].label,
        menu_items[2].label,
    }) catch "  Rewrite Command\n  Explain Command\n  Generate Command";

    const blocks = [_]content_mod.ContentBlock{
        .{ .tag = .paragraph, .text = items_text },
        .{ .tag = .paragraph, .text = menu_items[sel_idx].hint },
        .{ .tag = .paragraph, .text = "\xe2\x86\x91\xe2\x86\x93 Navigate \xc2\xb7 Enter select \xc2\xb7 Esc cancel" },
    };

    var bar = action_mod.ActionBar{};
    bar.add(.dismiss, "Cancel");

    var result = try content_mod.layoutStructuredCard(
        allocator,
        "AI Assistant",
        &blocks,
        max_width,
        style,
        bar,
    );

    // Post-process: highlight the selected item row (row 1 = first item after top border)
    const sel_row: usize = 1 + @as(usize, sel_idx);
    const stride: usize = result.width;
    for (0..stride) |col| {
        const idx = sel_row * stride + col;
        if (idx >= result.cells.len) break;
        // Skip border columns (first and last)
        if (col == 0 or col == stride - 1) continue;
        result.cells[idx].bg = highlight_bg;
    }

    return result;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "MenuContext: state transitions" {
    var menu = MenuContext.init();
    try std.testing.expectEqual(MenuState.closed, menu.state);

    menu.open();
    try std.testing.expectEqual(MenuState.open, menu.state);
    try std.testing.expectEqual(MenuSelection.rewrite_command, menu.selection);

    menu.close();
    try std.testing.expectEqual(MenuState.closed, menu.state);
}

test "MenuContext: moveDown wraps" {
    var menu = MenuContext.init();
    menu.open();

    try std.testing.expectEqual(MenuSelection.rewrite_command, menu.selection);
    menu.moveDown();
    try std.testing.expectEqual(MenuSelection.explain_command, menu.selection);
    menu.moveDown();
    try std.testing.expectEqual(MenuSelection.generate_command, menu.selection);
    menu.moveDown();
    try std.testing.expectEqual(MenuSelection.rewrite_command, menu.selection);
}

test "MenuContext: moveUp wraps" {
    var menu = MenuContext.init();
    menu.open();

    try std.testing.expectEqual(MenuSelection.rewrite_command, menu.selection);
    menu.moveUp();
    try std.testing.expectEqual(MenuSelection.generate_command, menu.selection);
    menu.moveUp();
    try std.testing.expectEqual(MenuSelection.explain_command, menu.selection);
    menu.moveUp();
    try std.testing.expectEqual(MenuSelection.rewrite_command, menu.selection);
}

test "layoutMenuCard: basic" {
    const allocator = std.testing.allocator;
    var menu = MenuContext.init();
    menu.open();

    const result = try layoutMenuCard(allocator, &menu, 48, .{});
    defer allocator.free(result.cells);

    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height > 0);
}

test "layoutMenuCard: different selection" {
    const allocator = std.testing.allocator;
    var menu = MenuContext.init();
    menu.open();
    menu.moveDown(); // explain_command

    const result = try layoutMenuCard(allocator, &menu, 48, .{});
    defer allocator.free(result.cells);

    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height > 0);
}
