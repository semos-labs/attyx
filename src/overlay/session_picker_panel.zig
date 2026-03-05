/// Session picker panel — builds Element tree from SessionPickerState and
/// renders via panel.renderPanel().
const std = @import("std");
const ui = @import("ui.zig");
const panel_mod = @import("panel.zig");
const picker_state = @import("session_picker.zig");

const ui_cell = @import("ui_cell.zig");
const Element = ui.Element;
const Style = ui.Style;
const Rgb = ui.Rgb;
const SizeValue = ui.SizeValue;
const PanelConfig = panel_mod.PanelConfig;
const PanelResult = panel_mod.PanelResult;
const SessionPickerState = picker_state.SessionPickerState;

pub const Icons = struct {
    filter: []const u8 = ">",
    session: []const u8 = "",
    new: []const u8 = "+",
    active: []const u8 = "(active)",
    recent: []const u8 = "",
};

pub fn renderSessionPicker(
    allocator: std.mem.Allocator,
    state: *const SessionPickerState,
    grid_cols: u16,
    grid_rows: u16,
    icons: Icons,
) !PanelResult {
    // Use arena for transient label allocations (freed after renderPanel)
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const tmp = arena.allocator();

    // Build menu items from state
    var menu_items: [picker_state.max_entries + 1]Element.MenuItem = undefined;
    var menu_count: u16 = 0;

    const vis_start = state.scroll_offset;
    const vis_end = @min(state.totalCount(), state.scroll_offset +| state.visible_rows);

    for (vis_start..vis_end) |i| {
        if (i < state.filtered_count) {
            const e = &state.entries[state.filtered_indices[i]];
            const name = e.getName();
            const is_current = state.current_session_id != null and e.id == state.current_session_id.?;

            // Build label: "icon name (active)" or "icon name"
            var label_buf: [128]u8 = undefined;
            var label_len: usize = 0;

            // Session icon: active > recent > session
            const sess_icon = if (is_current and icons.active.len > 0)
                icons.active
            else if (!e.alive and icons.recent.len > 0)
                icons.recent
            else
                icons.session;
            if (sess_icon.len > 0) {
                @memcpy(label_buf[label_len..][0..sess_icon.len], sess_icon);
                label_len += sess_icon.len;
                label_buf[label_len] = ' ';
                label_len += 1;
            }

            // Name
            const name_copy_len = @min(name.len, label_buf.len - label_len);
            @memcpy(label_buf[label_len..][0..name_copy_len], name[0..name_copy_len]);
            label_len += name_copy_len;

            const label_copy = tmp.dupe(u8, label_buf[0..label_len]) catch "";

            menu_items[menu_count] = .{
                .label = label_copy,
                .enabled = e.alive,
            };
        } else {
            // "New session" entry
            var new_buf: [64]u8 = undefined;
            var new_len: usize = 0;
            @memcpy(new_buf[new_len..][0..icons.new.len], icons.new);
            new_len += icons.new.len;
            const suffix = " New session";
            @memcpy(new_buf[new_len..][0..suffix.len], suffix);
            new_len += suffix.len;

            const new_copy = tmp.dupe(u8, new_buf[0..new_len]) catch "";
            menu_items[menu_count] = .{
                .label = new_copy,
                .enabled = true,
            };
        }
        menu_count += 1;
    }

    // Determine hint text based on mode
    const hint_text: []const u8 = switch (state.mode) {
        .browsing => "\xe2\x86\x91\xe2\x86\x93 navigate \xe2\x80\xa2 enter select \xe2\x80\xa2 ^R rename \xe2\x80\xa2 ^X delete \xe2\x80\xa2 esc close",
        .renaming => "enter commit \xe2\x80\xa2 esc cancel",
        .confirm_kill => "y to confirm kill \xe2\x80\xa2 any key to cancel",
    };

    // Build the filter/rename input or text
    const filter_value: []const u8 = switch (state.mode) {
        .renaming => state.rename_buf[0..state.rename_len],
        else => state.filter_buf[0..state.filter_len],
    };
    const filter_placeholder: []const u8 = switch (state.mode) {
        .renaming => "type new name...",
        else => "filter...",
    };
    const filter_label: []const u8 = switch (state.mode) {
        .renaming => "rename: ",
        else => blk: {
            // Build "<icon> " label from configured filter icon
            var fl_buf: [32]u8 = undefined;
            var fl_len: usize = 0;
            const icon_len = @min(icons.filter.len, fl_buf.len - fl_len - 1);
            @memcpy(fl_buf[fl_len..][0..icon_len], icons.filter[0..icon_len]);
            fl_len += icon_len;
            fl_buf[fl_len] = ' ';
            fl_len += 1;
            break :blk tmp.dupe(u8, fl_buf[0..fl_len]) catch "> ";
        },
    };
    const cursor_pos: u16 = switch (state.mode) {
        .renaming => state.rename_len,
        else => state.filter_len,
    };

    // Build element tree
    // Filter row (horizontal box: label + input)
    const filter_children = [_]Element{
        .{ .text = .{
            .content = filter_label,
            .wrap = false,
            .style = .{ .text_flags = .{ .bold = true } },
        } },
        .{ .input = .{
            .value = filter_value,
            .cursor_pos = cursor_pos,
            .placeholder = filter_placeholder,
        } },
    };
    const filter_row = Element{ .box = .{
        .children = &filter_children,
        .direction = .horizontal,
        .fill_width = true,
    } };

    // Menu (session list), indented to align with the filter input
    const label_cols = ui_cell.utf8Count(filter_label);
    const menu_inner = Element{ .menu = .{
        .items = menu_items[0..menu_count],
        .selected = if (state.selected >= state.scroll_offset)
            state.selected - state.scroll_offset
        else
            0,
        .scroll_offset = 0, // we pre-sliced the items
        .visible_count = state.visible_rows,
        .selected_style = .{
            .bg = .{ .r = 60, .g = 60, .b = 100 },
            .fg = .{ .r = 255, .g = 255, .b = 255 },
        },
    } };
    const menu_children = [_]Element{menu_inner};
    const menu = Element{ .box = .{
        .children = &menu_children,
        .padding = .{ .left = label_cols },
        .fill_width = true,
    } };

    // Hint row
    const hint_row = Element{ .hint = .{
        .content = hint_text,
    } };

    // Main content: vertical box
    const content_children = [_]Element{ filter_row, menu, hint_row };
    const content = Element{ .box = .{
        .children = &content_children,
        .direction = .vertical,
    } };

    const config = PanelConfig{
        .title = "Sessions",
        .width = .{ .percent = 50 },
        .height = .{ .percent = 50 },
        .border = .rounded,
    };

    // renderPanel allocates cells with the provided allocator (not tmp arena)
    return panel_mod.renderPanel(allocator, config, content, grid_cols, grid_rows);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "renderSessionPicker: produces valid result" {
    const allocator = std.testing.allocator;
    var state = SessionPickerState{};
    state.entries[0] = .{ .id = 1, .name_len = 5, .alive = true };
    @memcpy(state.entries[0].name[0..5], "alpha");
    state.entries[1] = .{ .id = 2, .name_len = 4, .alive = true };
    @memcpy(state.entries[1].name[0..4], "beta");
    state.entry_count = 2;
    state.applyFilter();
    state.visible_rows = 10;

    const result = try renderSessionPicker(allocator, &state, 80, 24, .{});
    defer allocator.free(result.cells);

    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height > 0);
    try std.testing.expect(result.col > 0);
    try std.testing.expect(result.row > 0);
}

test "renderSessionPicker: empty state still renders" {
    const allocator = std.testing.allocator;
    var state = SessionPickerState{};
    state.applyFilter();
    state.visible_rows = 10;

    const result = try renderSessionPicker(allocator, &state, 80, 24, .{});
    defer allocator.free(result.cells);

    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height > 0);
}
