/// Tab picker panel — builds Element tree from TabPickerState and
/// renders via panel.renderPanel().
const std = @import("std");
const ui = @import("ui.zig");
const panel_mod = @import("panel.zig");
const picker_state = @import("tab_picker.zig");

const ui_cell = @import("ui_cell.zig");
const Element = ui.Element;
const Rgb = ui.Rgb;
const PanelConfig = panel_mod.PanelConfig;
const PanelResult = panel_mod.PanelResult;
const TabPickerState = picker_state.TabPickerState;

const OverlayTheme = ui.OverlayTheme;

pub fn renderTabPicker(
    allocator: std.mem.Allocator,
    state: *const TabPickerState,
    grid_cols: u16,
    grid_rows: u16,
    theme: OverlayTheme,
) !PanelResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const tmp = arena.allocator();

    // Build menu items from visible range of filtered tabs
    var menu_items: [picker_state.max_tabs]Element.MenuItem = undefined;
    var menu_count: u16 = 0;

    const vis_start = state.scroll_offset;
    const vis_end = @min(state.filtered_count, state.scroll_offset +| state.visible_rows);

    for (vis_start..vis_end) |i| {
        const entry = &state.entries[state.filtered_indices[i]];
        const tab_num = entry.index + 1;
        const is_current = entry.index == state.current_tab;

        // Format: "N  title" with optional current indicator
        const prefix = if (is_current) "● " else "  ";
        const label = try std.fmt.allocPrint(tmp, "{s}{d}  {s}", .{ prefix, tab_num, entry.getName() });

        menu_items[menu_count] = .{
            .label = label,
            .enabled = true,
            .hint_text = if (entry.is_zoomed) "zoomed" else "",
        };
        menu_count += 1;
    }

    // Filter input row
    const filter_label = "> ";
    const filter_children = [_]Element{
        .{ .text = .{
            .content = filter_label,
            .wrap = false,
            .style = .{ .text_flags = .{ .bold = true } },
        } },
        .{ .input = .{
            .value = state.filter_buf[0..state.filter_len],
            .cursor_pos = state.filter_len,
            .placeholder = "type to filter...",
        } },
    };
    const filter_row = Element{ .box = .{
        .children = &filter_children,
        .direction = .horizontal,
        .fill_width = true,
    } };

    // Menu
    const label_cols = ui_cell.utf8Count(filter_label);
    const menu_inner = Element{ .menu = .{
        .items = menu_items[0..menu_count],
        .selected = if (state.selected >= state.scroll_offset)
            state.selected - state.scroll_offset
        else
            0,
        .scroll_offset = 0,
        .visible_count = state.visible_rows,
        .selected_style = .{
            .bg = theme.selected_bg,
            .fg = theme.selected_fg,
        },
    } };
    const menu_children = [_]Element{menu_inner};
    const menu = Element{ .box = .{
        .children = &menu_children,
        .padding = .{ .left = label_cols },
        .fill_width = true,
    } };

    // Hint row
    const count_str = try std.fmt.allocPrint(tmp, "{d}/{d} tabs", .{ state.filtered_count, state.entry_count });
    const hint_parts = [_][]const u8{ "\xe2\x86\x91\xe2\x86\x93 navigate \xe2\x80\xa2 enter switch \xe2\x80\xa2 esc cancel \xe2\x80\xa2 ", count_str };
    const hint_text = try std.mem.concat(tmp, u8, &hint_parts);
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
        .title = "Tabs",
        .width = .{ .percent = 40 },
        .height = .{ .percent = 50 },
        .border = .rounded,
        .theme = theme,
    };

    return panel_mod.renderPanel(allocator, config, content, grid_cols, grid_rows);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "renderTabPicker: produces valid result" {
    const allocator = std.testing.allocator;
    var state = TabPickerState{};
    const name = "zsh";
    @memcpy(state.entries[0].name[0..name.len], name);
    state.entries[0].name_len = name.len;
    state.entries[0].index = 0;
    state.entry_count = 1;
    state.applyFilter();
    state.visible_rows = 10;

    const result = try renderTabPicker(allocator, &state, 80, 24, .{});
    defer allocator.free(result.cells);

    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height > 0);
}
