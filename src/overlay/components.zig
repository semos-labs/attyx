// Attyx — Declarative overlay component helpers
// Convenience functions that return Element trees for common patterns.

const std = @import("std");
const ui = @import("ui.zig");
const Element = ui.Element;
const Style = ui.Style;
const Padding = ui.Padding;
const SizeValue = ui.SizeValue;
const Rgb = ui.Rgb;
const TextFlags = ui.TextFlags;

// ---------------------------------------------------------------------------
// card — bordered box with optional bold title
// ---------------------------------------------------------------------------

/// A bordered card with a title and child elements.
/// `children` must be a comptime-known slice with the title prepended.
pub fn card(title: []const u8, body_children: []const Element) [2]Element {
    return .{
        .{ .text = .{
            .content = title,
            .style = .{ .text_flags = .{ .bold = true } },
            .wrap = false,
        } },
        .{ .box = .{
            .children = body_children,
            .direction = .vertical,
        } },
    };
}

/// Build a card element directly as a single bordered Box.
pub fn cardBox(title: []const u8, body_children: []const Element) Element {
    const title_elem = Element{ .text = .{
        .content = title,
        .style = .{ .text_flags = .{ .bold = true } },
        .wrap = false,
    } };
    // Build array: title + body_children is not possible at runtime with slices,
    // so we wrap title + a vertical box containing the body.
    const inner = [2]Element{
        title_elem,
        .{ .box = .{ .children = body_children, .direction = .vertical } },
    };
    return .{ .box = .{
        .children = &inner,
        .border = .single,
        .padding = .{ .left = 1, .right = 1 },
        .direction = .vertical,
    } };
}

// ---------------------------------------------------------------------------
// hint — shorthand for dim text
// ---------------------------------------------------------------------------

pub fn hint(content: []const u8) Element {
    return .{ .hint = .{ .content = content } };
}

pub fn hintRight(content: []const u8) Element {
    return .{ .hint = .{
        .content = content,
        .alignment = .right,
    } };
}

// ---------------------------------------------------------------------------
// searchBar — horizontal box with label + input + optional info text
// ---------------------------------------------------------------------------

pub fn searchBar(
    label: []const u8,
    value: []const u8,
    cursor_pos: u16,
    placeholder: []const u8,
    right_text: []const u8,
) [3]Element {
    return .{
        .{ .text = .{
            .content = label,
            .style = .{ .text_flags = .{ .bold = true } },
            .wrap = false,
        } },
        .{ .input = .{
            .value = value,
            .cursor_pos = cursor_pos,
            .placeholder = placeholder,
        } },
        .{ .hint = .{
            .content = right_text,
            .alignment = .right,
        } },
    };
}

/// Build a search bar as a single horizontal Box element.
pub fn searchBarBox(
    label: []const u8,
    value: []const u8,
    cursor_pos: u16,
    placeholder: []const u8,
    right_text: []const u8,
    width: ?SizeValue,
) Element {
    const parts = searchBar(label, value, cursor_pos, placeholder, right_text);
    return .{ .box = .{
        .children = &parts,
        .direction = .horizontal,
        .width = width,
        .fill_width = width == null,
    } };
}

// ---------------------------------------------------------------------------
// clampScroll — keep selection visible in scrollable view
// ---------------------------------------------------------------------------

/// Adjusts scroll offset to ensure `selected` is visible within the window.
/// Returns the new scroll offset.
pub fn clampScroll(selected: u16, current_offset: u16, visible_count: u16, total_items: u16) u16 {
    if (total_items == 0 or visible_count == 0) return 0;
    const sel = @min(selected, total_items -| 1);
    var offset = current_offset;

    // If selected is above visible window, scroll up
    if (sel < offset) {
        offset = sel;
    }
    // If selected is below visible window, scroll down
    if (sel >= offset + visible_count) {
        offset = sel - visible_count + 1;
    }
    // Clamp offset so we don't scroll past the end
    const max_offset = total_items -| visible_count;
    return @min(offset, max_offset);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "clampScroll basic" {
    // Selection at 0, offset 0, 5 visible, 10 total — no change
    try std.testing.expectEqual(@as(u16, 0), clampScroll(0, 0, 5, 10));
}

test "clampScroll scroll down" {
    // Selection at 7, offset 0, 5 visible — need to scroll to 3
    try std.testing.expectEqual(@as(u16, 3), clampScroll(7, 0, 5, 10));
}

test "clampScroll scroll up" {
    // Selection at 1, offset 5, 5 visible — scroll to 1
    try std.testing.expectEqual(@as(u16, 1), clampScroll(1, 5, 5, 10));
}

test "clampScroll at end" {
    // Selection at 9 (last item), offset 0, 5 visible, 10 total → offset 5
    try std.testing.expectEqual(@as(u16, 5), clampScroll(9, 0, 5, 10));
}

test "clampScroll empty" {
    try std.testing.expectEqual(@as(u16, 0), clampScroll(0, 0, 5, 0));
    try std.testing.expectEqual(@as(u16, 0), clampScroll(0, 0, 0, 10));
}

test "clampScroll selection beyond total" {
    // selected=20 but only 5 items → clamp to 4, offset adjusts
    try std.testing.expectEqual(@as(u16, 0), clampScroll(20, 0, 5, 5));
}

test "hint returns dim element" {
    const h = hint("press Esc");
    switch (h) {
        .hint => |hv| {
            try std.testing.expect(hv.style.text_flags.dim);
            try std.testing.expectEqualStrings("press Esc", hv.content);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "searchBar returns three elements" {
    const parts = searchBar("Find:", "hello", 3, "type to search", "1/5");
    // First element is bold text label
    switch (parts[0]) {
        .text => |t| try std.testing.expectEqualStrings("Find:", t.content),
        else => return error.TestUnexpectedResult,
    }
    // Second element is input
    switch (parts[1]) {
        .input => |inp| {
            try std.testing.expectEqualStrings("hello", inp.value);
            try std.testing.expectEqual(@as(u16, 3), inp.cursor_pos);
        },
        else => return error.TestUnexpectedResult,
    }
    // Third element is hint
    switch (parts[2]) {
        .hint => |hv| try std.testing.expectEqualStrings("1/5", hv.content),
        else => return error.TestUnexpectedResult,
    }
}
