//! Viewport math for the interactive dashboard table.
const model = @import("model.zig");

pub const Plan = struct {
    start: usize = 0,
    body_lines: u16 = 1,
};

fn hasGroupHeader(m: *const model.Model, row_index: usize) bool {
    if (m.visibleCount() == 0) return false;
    if (row_index == 0) return true;
    return m.rowAt(row_index).session != m.rowAt(row_index - 1).session;
}

fn rowHeight(m: *const model.Model, row_index: usize, selected_extra: u16) u16 {
    var h: u16 = 1;
    if (hasGroupHeader(m, row_index)) h += 1;
    if (row_index == m.selected) h += selected_extra;
    return h;
}

/// Pick the first visible row to render so the selected row stays in view.
/// `selected_extra` is the height of an expanded inline panel under selection.
pub fn plan(m: *const model.Model, body_lines: u16, selected_extra: u16) Plan {
    const count = m.visibleCount();
    if (count == 0) return .{ .body_lines = body_lines };

    const selected = @min(m.selected, count - 1);
    var start = selected;
    var used = rowHeight(m, selected, selected_extra);
    while (start > 0) {
        const prev = start - 1;
        const h = rowHeight(m, prev, selected_extra);
        if (used + h > body_lines) break;
        start = prev;
        used += h;
    }
    return .{ .start = start, .body_lines = body_lines };
}

pub fn rowHasGroupHeader(m: *const model.Model, row_index: usize) bool {
    return hasGroupHeader(m, row_index);
}

const testing = @import("std").testing;

test "viewport follows selection past first screen" {
    var m = model.Model{};
    m.count = 30;
    m.view_count = 30;
    for (0..30) |i| {
        m.rows[i] = .{ .session = 1, .pane_id = @intCast(i + 1), .state = .working };
        m.view[i] = @intCast(i);
    }
    m.selected = 29;
    const p = plan(&m, 10, 0);
    try testing.expect(p.start > 0);
    try testing.expect(p.start <= m.selected);
}

test "viewport accounts for selected panel height" {
    var m = model.Model{};
    m.count = 4;
    m.view_count = 4;
    for (0..4) |i| {
        m.rows[i] = .{ .session = 1, .pane_id = @intCast(i + 1), .state = .working };
        m.view[i] = @intCast(i);
    }
    m.selected = 3;
    const p = plan(&m, 8, 4);
    try testing.expectEqual(@as(usize, 1), p.start);
}
