// Attyx — Completion overlay state machine and renderer.
//
// Receives completion candidates from xyron via IPC push events.
// Renders a cursor-anchored dropdown using declarative UI components.
// The overlay system handles positioning via cursor_line anchor.

const std = @import("std");
const ui = @import("ui.zig");
const ui_render = @import("ui_render.zig");
const ui_cell = @import("ui_cell.zig");
const panel_mod = @import("panel.zig");
const anchor_mod = @import("anchor.zig");

const Element = ui.Element;
const StyledCell = ui.StyledCell;
const OverlayTheme = ui.OverlayTheme;
const PanelResult = panel_mod.PanelResult;

pub const max_candidates = 50;
pub const max_visible: u16 = 12;

pub const Candidate = struct {
    text: [256]u8 = undefined,
    text_len: u16 = 0,
    desc: [80]u8 = undefined,
    desc_len: u16 = 0,
    kind: u8 = 0,

    pub fn textSlice(self: *const Candidate) []const u8 {
        return self.text[0..self.text_len];
    }

    pub fn descSlice(self: *const Candidate) []const u8 {
        return self.desc[0..self.desc_len];
    }
};

pub const CompletionState = struct {
    active: bool = false,
    candidates: [max_candidates]Candidate = undefined,
    count: u16 = 0,
    selected: u16 = 0,
    scroll: u16 = 0,
    total: u16 = 0,

    pub fn show(self: *CompletionState, selected_idx: u16, scroll_off: u16, total_count: u16) void {
        self.active = true;
        self.selected = selected_idx;
        self.scroll = scroll_off;
        self.total = total_count;
    }

    pub fn update(self: *CompletionState, selected_idx: u16, scroll_off: u16) void {
        self.selected = selected_idx;
        self.scroll = scroll_off;
    }

    pub fn dismiss(self: *CompletionState) void {
        self.active = false;
        self.count = 0;
        self.selected = 0;
        self.scroll = 0;
    }

    pub fn visibleCount(self: *const CompletionState) u16 {
        return @min(self.count, max_visible);
    }

    /// Compute overlay width based on widest candidate text + description.
    pub fn computeWidth(self: *const CompletionState) u16 {
        var max_label: u16 = 0;
        var max_desc: u16 = 0;
        for (self.candidates[0..self.count]) |*c| {
            const tw: u16 = @intCast(ui_cell.utf8Count(c.textSlice()));
            max_label = @max(max_label, tw);
            if (c.desc_len > 0) {
                const dw: u16 = @intCast(ui_cell.utf8Count(c.descSlice()));
                max_desc = @max(max_desc, dw);
            }
        }
        const desc_extra: u16 = if (max_desc > 0) max_desc + 3 else 0;
        return @max(max_label + desc_extra + 2, 20); // min width 20
    }
};

/// Render the completion dropdown. Returns cells + dimensions.
/// Caller should set these on the overlay layer with a cursor_line anchor.
pub fn render(
    allocator: std.mem.Allocator,
    state: *const CompletionState,
    theme: OverlayTheme,
) !PanelResult {
    if (!state.active or state.count == 0) {
        return .{ .cells = &.{}, .width = 0, .height = 0, .col = 0, .row = 0 };
    }

    const vis = state.visibleCount();
    const scroll = @min(state.scroll, state.count -| vis);
    const vis_end = @min(scroll + vis, state.count);

    // Build menu items from visible slice
    var items: [max_visible]Element.MenuItem = undefined;
    var n: u16 = 0;
    for (scroll..vis_end) |i| {
        const c = &state.candidates[i];
        items[n] = .{
            .label = c.textSlice(),
            .hint_text = c.descSlice(),
            .enabled = true,
        };
        n += 1;
    }

    const menu = Element{ .menu = .{
        .items = items[0..n],
        .selected = if (state.selected >= scroll) state.selected - scroll else 0,
        .scroll_offset = 0,
        .visible_count = null, // auto — render all items
        .selected_style = .{ .bg = theme.selected_bg, .fg = theme.selected_fg },
    } };

    const content = Element{ .box = .{
        .children = &[_]Element{menu},
        .border = .none,
        .height = .{ .cells = n },
        .fill_width = true,
        .style = .{ .fg = theme.fg, .bg = .{ .r = 40, .g = 40, .b = 46 }, .bg_alpha = 255 },
    } };

    const width = state.computeWidth();
    const r = try ui_render.renderAlloc(allocator, content, width, theme);

    return .{
        .cells = r.cells,
        .width = r.result.width,
        .height = r.result.height,
        .col = 0,
        .row = 0,
    };
}
