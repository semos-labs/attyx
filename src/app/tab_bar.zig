// Attyx — Tab bar overlay generator
//
// Produces a single row of StyledCell values representing the tab bar.
// Each tab shows " title  N " with the active tab's number highlighted.
// Supports horizontal scrolling with < / > overflow indicators when tabs
// exceed the available viewport width.

const std = @import("std");
const attyx = @import("attyx");
const StyledCell = attyx.overlay_mod.StyledCell;
const Rgb = attyx.overlay_mod.Rgb;
const unicode = attyx.unicode;
const tab_manager = @import("tab_manager.zig");
const agent_status_mod = @import("agent_status.zig");
pub const max_tabs = tab_manager.max_tabs;

pub const Style = struct {
    tab_bg: Rgb = .{ .r = 50, .g = 50, .b = 58 },
    active_tab_bg: ?Rgb = null, // null = same as tab_bg
    fg: Rgb = .{ .r = 140, .g = 140, .b = 160 },
    active_fg: ?Rgb = null, // null = same as fg
    num_highlight_bg: Rgb = .{ .r = 90, .g = 90, .b = 100 },
    num_highlight_fg: Rgb = .{ .r = 230, .g = 230, .b = 240 },
    agent_fg: Rgb = .{ .r = 96, .g = 160, .b = 255 },
    agent_idle_fg: Rgb = .{ .r = 96, .g = 208, .b = 120 },
    agent_running_fg: Rgb = .{ .r = 255, .g = 170, .b = 64 },
    agent_waiting_fg: Rgb = .{ .r = 176, .g = 112, .b = 255 },
    /// Foreground for the vertical separator border in side mode. Defaults
    /// to a dimmed gray; callers can blend toward the active theme bg/fg
    /// for better contrast.
    border_fg: Rgb = .{ .r = 70, .g = 70, .b = 80 },
    bg_alpha: u8 = 230,
};

pub const Result = struct {
    cells: []StyledCell,
    width: u16,
    height: u16, // always 1
};

/// Per-tab title, resolved by the caller (OSC title or process name).
pub const TabTitles = [max_tabs]?[]const u8;
pub const AgentStatus = agent_status_mod.AgentStatus;
pub const AgentStatuses = agent_status_mod.AgentStatuses;

/// Cached per-tab widths written by generate(), read by tabIndexAtCol().
var cached_widths: [max_tabs]u16 = .{0} ** max_tabs;
var cached_count: u8 = 0;

/// Scroll state for horizontal tab overflow.
var scroll_offset: u16 = 0;
var cached_has_left_ind: bool = false;
var cached_has_right_ind: bool = false;
var manual_scroll: bool = false;
var cached_active: u8 = 0;

/// Decode the next UTF-8 codepoint from `s[i..*]`, advancing `i`.
/// Skips invalid bytes gracefully, returning 0xFFFD (replacement char).
fn nextCodepoint(s: []const u8, i: *usize) ?u21 {
    if (i.* >= s.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(s[i.*]) catch {
        i.* += 1;
        return 0xFFFD;
    };
    if (i.* + len > s.len) {
        i.* = s.len;
        return 0xFFFD;
    }
    const cp = std.unicode.utf8Decode(s[i.*..][0..len]) catch {
        i.* += 1;
        return 0xFFFD;
    };
    i.* += len;
    return cp;
}

/// Count display columns for a UTF-8 string, accounting for wide (CJK) chars
/// and zero-width / combining marks.
fn displayWidth(s: []const u8) u16 {
    var i: usize = 0;
    var count: u16 = 0;
    while (nextCodepoint(s, &i)) |cp| {
        if (unicode.isCombiningMark(cp) or unicode.isZeroWidth(cp)) continue;
        count += unicode.charDisplayWidth(cp);
    }
    return count;
}

/// Number of digits in a 1-indexed tab number.
fn numLen(n: u8) u16 {
    return if (n >= 10) 2 else 1;
}

const ParsedTitle = struct {
    title: []const u8,
    agent_status: AgentStatus = .none,
};

fn parseAgentTitle(title: []const u8) ParsedTitle {
    var i: usize = 0;
    const marker = nextCodepoint(title, &i) orelse return .{ .title = title };
    const status: AgentStatus = switch (marker) {
        0x25CB => .idle, // white circle
        0x273B => .running, // teardrop-spoked asterisk
        0x25CF => .waiting, // black circle
        else => {
            if (agent_status_mod.looksLikeAgentText(title)) {
                return .{ .title = title, .agent_status = .generic };
            }
            return .{ .title = title };
        },
    };

    if (i < title.len and title[i] == ' ') {
        i += 1;
        return .{ .title = title[i..], .agent_status = status };
    }
    return .{ .title = title, .agent_status = .none };
}

/// Compute the natural width for a tab: " title " + " N " = (1+title+1) + (1+numlen+1).
/// When zoomed, prepend "⊞ " (2 extra columns).
fn tabWidth(title_len: u16, tab_number: u8, zoomed: bool, agent_status: AgentStatus) u16 {
    const zoom_extra: u16 = if (zoomed) 2 else 0;
    const agent_extra: u16 = if (agent_status != .none) 2 else 0;
    return 1 + zoom_extra + agent_extra + title_len + 1 + 1 + numLen(tab_number) + 1;
}

/// Resolve the title for tab `i`, writing fallback into `fallback_buf`.
fn resolveTitle(titles: *const TabTitles, i: usize, fallback_buf: *[20]u8) []const u8 {
    return titles[i] orelse
        (std.fmt.bufPrint(fallback_buf, "Tab {d}", .{i + 1}) catch "Tab ?");
}

/// Write a cell into the output buffer if the virtual column falls within
/// the visible viewport [vis_start, vis_end).
fn emitVCell(buf: []StyledCell, vcol: u16, vis_start: u16, vis_end: u16, left_ind: u16, cell: StyledCell) void {
    if (vcol >= vis_start and vcol < vis_end) {
        buf[vcol - vis_start + left_ind] = cell;
    }
}

/// Auto-scroll so the active tab is fully visible within the viewport.
/// Must be called after cached_widths/cached_count are populated.
pub fn autoScroll(active_idx: u8, tab_count: u8, viewport_width: u16) void {
    if (tab_count == 0 or viewport_width == 0) return;
    const count: u16 = @min(tab_count, cached_count);
    if (count == 0) return;
    const active: u16 = @min(active_idx, count - 1);

    // Compute active tab's virtual start position
    var active_start: u16 = 0;
    for (0..active) |i| {
        active_start += cached_widths[i] + 1; // width + gap
    }
    const active_end = active_start + cached_widths[active];

    // Compute total virtual width
    var total: u16 = 0;
    for (0..count) |i| {
        total += cached_widths[i];
        if (i + 1 < count) total += 1;
    }

    // Scroll to keep active tab visible
    if (active_start < scroll_offset) {
        scroll_offset = active_start;
    } else if (active_end > scroll_offset + viewport_width) {
        scroll_offset = active_end -| viewport_width;
    }

    // Clamp
    if (total <= viewport_width) {
        scroll_offset = 0;
    } else {
        scroll_offset = @min(scroll_offset, total -| viewport_width);
    }
}

/// Manually scroll the tab bar by `delta` lines (positive = scroll left, negative = scroll right).
/// Suppresses auto-scroll until the active tab changes.
pub fn scrollTabs(delta: c_int, tab_count: u8) void {
    const count = @min(tab_count, cached_count);
    if (count == 0) return;

    // Compute total virtual width from cache
    var total: u16 = 0;
    for (0..count) |i| {
        total += cached_widths[i];
        if (i + 1 < count) total += 1;
    }

    const step: u16 = 3;
    if (delta > 0) {
        // Scroll left (show earlier tabs)
        const amount: u16 = @intCast(@min(delta, std.math.maxInt(c_int)) * step);
        scroll_offset -|= amount;
    } else if (delta < 0) {
        // Scroll right (show later tabs)
        const neg: u32 = @intCast(-@as(i64, delta));
        const amount: u16 = @intCast(@min(neg * step, std.math.maxInt(u16)));
        scroll_offset = @min(scroll_offset + amount, total -| 1);
    }
    manual_scroll = true;
}

/// Generate tab bar overlay cells into a caller-provided buffer.
/// Returns the number of cells written, or null if buffer is too small.
/// `titles` provides per-tab display names; falls back to "Tab N" when null.
/// `zoomed_tabs` is a bitmask: if bit i is set, tab i shows a zoom indicator.
pub fn generate(
    buf: []StyledCell,
    tab_count: u8,
    active: u8,
    grid_cols: u16,
    style: Style,
    titles: *const TabTitles,
    zoomed_tabs: u16,
    statuses: *const AgentStatuses,
) ?Result {
    if (grid_cols == 0 or tab_count == 0) return null;
    const width: u16 = grid_cols;
    if (buf.len < width) return null;

    // Fill entire row with transparent background
    for (buf[0..width]) |*cell| {
        cell.* = .{
            .char = ' ',
            .fg = style.fg,
            .bg = .{ .r = 0, .g = 0, .b = 0 },
            .bg_alpha = 0,
        };
    }

    // Compute content-based widths and cache them for tabIndexAtCol().
    var fallback_bufs: [max_tabs][20]u8 = undefined;
    var resolved: [max_tabs]ParsedTitle = undefined;
    var widths: [max_tabs]u16 = undefined;
    for (0..tab_count) |i| {
        resolved[i] = parseAgentTitle(resolveTitle(titles, i, &fallback_bufs[i]));
        const is_zoomed = (zoomed_tabs & (@as(u16, 1) << @intCast(i))) != 0;
        const merged_status = if (statuses[i] != .none) statuses[i] else resolved[i].agent_status;
        widths[i] = tabWidth(displayWidth(resolved[i].title), @intCast(i + 1), is_zoomed, merged_status);
    }

    // Reset scroll on tab count change
    if (tab_count != cached_count) scroll_offset = 0;

    @memcpy(cached_widths[0..tab_count], widths[0..tab_count]);
    cached_count = tab_count;

    // Format each tab number (1-indexed) into a small buffer.
    var num_bufs: [max_tabs][3]u8 = undefined;
    var num_slices: [max_tabs][]const u8 = undefined;
    for (0..tab_count) |i| {
        num_slices[i] = std.fmt.bufPrint(&num_bufs[i], "{d}", .{i + 1}) catch "?";
    }

    // Compute total virtual width of all tabs + gaps
    var total_virtual: u16 = 0;
    for (0..tab_count) |i| {
        total_virtual += widths[i];
        if (i + 1 < tab_count) total_virtual += 1;
    }

    // Determine scrolling mode — only show indicator cells when there is
    // actual overflow in that direction (no empty placeholder cells).
    var left_ind: u16 = 0;
    var right_ind: u16 = 0;
    var effective_width = width;

    if (total_virtual > width and width > 2) {
        // Pass 1: estimate with both indicators reserved
        effective_width = width -| 2;
        autoScroll(active, tab_count, effective_width);
        left_ind = if (scroll_offset > 0) @as(u16, 1) else 0;
        right_ind = if (scroll_offset + effective_width < total_virtual) @as(u16, 1) else 0;

        // Pass 2: refine with actual indicator count
        effective_width = width - left_ind - right_ind;
        autoScroll(active, tab_count, effective_width);
        left_ind = if (scroll_offset > 0) @as(u16, 1) else 0;
        right_ind = if (scroll_offset + effective_width < total_virtual) @as(u16, 1) else 0;
        effective_width = width - left_ind - right_ind;

        // Final pass to settle
        autoScroll(active, tab_count, effective_width);
        left_ind = if (scroll_offset > 0) @as(u16, 1) else 0;
        right_ind = if (scroll_offset + effective_width < total_virtual) @as(u16, 1) else 0;
        effective_width = width - left_ind - right_ind;

        cached_has_left_ind = left_ind > 0;
        cached_has_right_ind = right_ind > 0;
    } else {
        scroll_offset = 0;
        cached_has_left_ind = false;
        cached_has_right_ind = false;
    }

    // Render tabs with virtual column tracking
    const vis_start = scroll_offset;
    const vis_end = scroll_offset + effective_width;
    var vcol: u16 = 0;

    for (0..tab_count) |i| {
        if (vcol >= vis_end) break;

        const is_active = (i == active);
        const natural_width = widths[i];
        const title = resolved[i].title;
        const agent_status = if (statuses[i] != .none) statuses[i] else resolved[i].agent_status;
        const num = num_slices[i];

        // Resolve per-tab colors: active tab can have distinct bg/fg
        const t_bg = if (is_active) (style.active_tab_bg orelse style.tab_bg) else style.tab_bg;
        const t_fg = if (is_active) (style.active_fg orelse style.fg) else style.fg;

        // Number area: double-space + digits + trailing space — all use num bg for active
        const n_fg = if (is_active) style.num_highlight_fg else style.fg;
        const n_bg = if (is_active) style.num_highlight_bg else style.tab_bg;

        var pos: u16 = 0;

        // Title area: " title " (with optional zoom icon)
        if (pos < natural_width) {
            emitVCell(buf, vcol + pos, vis_start, vis_end, left_ind, .{ .char = ' ', .fg = t_fg, .bg = t_bg, .bg_alpha = style.bg_alpha });
            pos += 1;
        }
        // Zoom indicator: "⊞ " before title
        {
            const tab_zoomed = (zoomed_tabs & (@as(u16, 1) << @intCast(i))) != 0;
            if (tab_zoomed) {
                if (pos < natural_width) {
                    emitVCell(buf, vcol + pos, vis_start, vis_end, left_ind, .{ .char = 0x229E, .fg = t_fg, .bg = t_bg, .bg_alpha = style.bg_alpha });
                    pos += 1;
                }
                if (pos < natural_width) {
                    emitVCell(buf, vcol + pos, vis_start, vis_end, left_ind, .{ .char = ' ', .fg = t_fg, .bg = t_bg, .bg_alpha = style.bg_alpha });
                    pos += 1;
                }
            }
        }
        if (agent_status != .none) {
            const dot_fg = switch (agent_status) {
                .generic => style.agent_fg,
                .idle => style.agent_idle_fg,
                .running => style.agent_running_fg,
                .waiting => style.agent_waiting_fg,
                .none => t_fg,
            };
            if (pos < natural_width) {
                emitVCell(buf, vcol + pos, vis_start, vis_end, left_ind, .{ .char = 0x25CF, .fg = dot_fg, .bg = t_bg, .bg_alpha = style.bg_alpha });
                pos += 1;
            }
            if (pos < natural_width) {
                emitVCell(buf, vcol + pos, vis_start, vis_end, left_ind, .{ .char = ' ', .fg = t_fg, .bg = t_bg, .bg_alpha = style.bg_alpha });
                pos += 1;
            }
        }
        {
            var ti: usize = 0;
            while (nextCodepoint(title, &ti)) |cp| {
                if (pos >= natural_width) break;
                if (unicode.isCombiningMark(cp) or unicode.isZeroWidth(cp)) {
                    // Attach to previous cell's combining slots if visible
                    if (pos > 0) {
                        const prev_vcol = vcol + pos - 1;
                        if (prev_vcol >= vis_start and prev_vcol < vis_end) {
                            const buf_idx = prev_vcol - vis_start + left_ind;
                            if (buf[buf_idx].combining[0] == 0) {
                                buf[buf_idx].combining[0] = cp;
                            } else if (buf[buf_idx].combining[1] == 0) {
                                buf[buf_idx].combining[1] = cp;
                            }
                        }
                    }
                    continue;
                }
                emitVCell(buf, vcol + pos, vis_start, vis_end, left_ind, .{ .char = cp, .fg = t_fg, .bg = t_bg, .bg_alpha = style.bg_alpha });
                pos += 1;
                // Wide char: emit spacer in next column
                if (unicode.charDisplayWidth(cp) == 2 and pos < natural_width) {
                    emitVCell(buf, vcol + pos, vis_start, vis_end, left_ind, .{ .char = ' ', .fg = t_fg, .bg = t_bg, .bg_alpha = style.bg_alpha });
                    pos += 1;
                }
            }
        }
        if (pos < natural_width) {
            emitVCell(buf, vcol + pos, vis_start, vis_end, left_ind, .{ .char = ' ', .fg = t_fg, .bg = t_bg, .bg_alpha = style.bg_alpha });
            pos += 1;
        }

        // Number area: " N " — leading space + digits + trailing space
        if (pos < natural_width) {
            emitVCell(buf, vcol + pos, vis_start, vis_end, left_ind, .{ .char = ' ', .fg = n_fg, .bg = n_bg, .bg_alpha = style.bg_alpha });
            pos += 1;
        }
        for (num) |ch| {
            if (pos >= natural_width) break;
            emitVCell(buf, vcol + pos, vis_start, vis_end, left_ind, .{ .char = ch, .fg = n_fg, .bg = n_bg, .bg_alpha = style.bg_alpha });
            pos += 1;
        }
        while (pos < natural_width) : (pos += 1) {
            emitVCell(buf, vcol + pos, vis_start, vis_end, left_ind, .{ .char = ' ', .fg = n_fg, .bg = n_bg, .bg_alpha = style.bg_alpha });
        }

        vcol += natural_width;

        // 1-cell gap between tabs (bar background, not part of any tab)
        if (i + 1 < tab_count) {
            emitVCell(buf, vcol, vis_start, vis_end, left_ind, .{ .char = ' ', .fg = style.fg, .bg = .{ .r = 0, .g = 0, .b = 0 }, .bg_alpha = 0 });
            vcol += 1;
        }
    }

    // Render overflow indicators (only when there's content in that direction)
    if (cached_has_left_ind) {
        buf[0] = .{ .char = '<', .fg = style.fg, .bg = style.tab_bg, .bg_alpha = style.bg_alpha };
    }
    if (cached_has_right_ind) {
        buf[width - 1] = .{ .char = '>', .fg = style.fg, .bg = style.tab_bg, .bg_alpha = style.bg_alpha };
    }

    return .{
        .cells = buf[0..width],
        .width = width,
        .height = 1,
    };
}

pub const min_side_width: u16 = 8;
pub const default_side_width: u16 = 24;

/// Side bar width in cells. Honors the user override (`requested`) when
/// non-zero; otherwise falls back to a readable fixed default. Always
/// clamped to [min_side_width, grid_cols / 2] so the content area stays
/// usable.
pub fn sideBarWidthRequested(grid_cols: u16, requested: u16) u16 {
    if (grid_cols == 0) return 0;
    const half: u16 = grid_cols / 2;
    var w: u16 = if (requested != 0) requested else default_side_width;
    if (w < min_side_width) w = min_side_width;
    if (w > half) w = half;
    if (w == 0) w = 1;
    return w;
}

pub fn sideBarWidth(grid_cols: u16) u16 {
    return sideBarWidthRequested(grid_cols, 0);
}

/// Vertical tab bar result: a `width` × `height` block of cells laid out
/// row-major (`cells[row * width + col]`).
pub const VerticalResult = struct {
    cells: []StyledCell,
    width: u16,
    height: u16,
};

/// Cached row span [start, end) per tab for hit testing in vertical mode.
var v_cached_starts: [max_tabs]u16 = .{0} ** max_tabs;
var v_cached_ends: [max_tabs]u16 = .{0} ** max_tabs;
var v_cached_count: u8 = 0;

/// Generate vertical tab bar cells into a caller-provided buffer.
/// Each tab takes one row; cells inside the bar are laid out row-major
/// with `width` columns and `height` rows.
///
/// Visual style: rows are mostly transparent (terminal background shows
/// through). The active row gets a subtle highlight bg behind its text.
/// A vertical box-drawing separator `│` runs along the inner edge —
/// rightmost col when `border_on_right = true` (left-side bar), leftmost
/// col otherwise (right-side bar).
pub fn generateVertical(
    buf: []StyledCell,
    tab_count: u8,
    active: u8,
    width: u16,
    height: u16,
    style: Style,
    titles: *const TabTitles,
    zoomed_tabs: u16,
    statuses: *const AgentStatuses,
    border_on_right: bool,
) ?VerticalResult {
    if (width == 0 or height == 0 or tab_count == 0) return null;
    const total: usize = @as(usize, width) * @as(usize, height);
    if (buf.len < total) return null;

    const transparent: StyledCell = .{
        .char = ' ',
        .fg = style.fg,
        .bg = .{ .r = 0, .g = 0, .b = 0 },
        .bg_alpha = 0,
    };

    // Border lives on the inner edge: rightmost col for left-side bars,
    // leftmost col for right-side bars. The remaining columns hold tab text
    // and stay transparent so the terminal background shows through.
    const border_col: u16 = if (border_on_right) width - 1 else 0;
    const text_start: u16 = if (border_on_right) 0 else 1;
    const text_end: u16 = if (border_on_right) width - 1 else width;

    // Initialize: transparent everywhere, with a vertical line on border col.
    for (0..height) |r| {
        const base = r * @as(usize, width);
        for (0..width) |c2| buf[base + c2] = transparent;
        buf[base + border_col] = .{
            .char = 0x2502, // │
            .fg = style.border_fg,
            .bg = .{ .r = 0, .g = 0, .b = 0 },
            .bg_alpha = 0,
        };
    }

    var fallback_bufs: [max_tabs][20]u8 = undefined;
    var resolved: [max_tabs]ParsedTitle = undefined;
    for (0..tab_count) |i| {
        resolved[i] = parseAgentTitle(resolveTitle(titles, i, &fallback_bufs[i]));
    }

    const writeCell = struct {
        fn w(buf2: []StyledCell, idx: usize, ch: u21, fg: Rgb, is_act: bool, st: Style) void {
            if (is_act) {
                const abg = st.active_tab_bg orelse st.tab_bg;
                buf2[idx] = .{ .char = ch, .fg = fg, .bg = abg, .bg_alpha = st.bg_alpha };
            } else {
                buf2[idx] = .{ .char = ch, .fg = fg, .bg = .{ .r = 0, .g = 0, .b = 0 }, .bg_alpha = 0 };
            }
        }
    }.w;

    v_cached_count = tab_count;
    var row: u16 = 0;
    for (0..tab_count) |i| {
        if (row >= height) break;
        v_cached_starts[i] = row;

        const is_active = (i == active);
        const t_fg = if (is_active) (style.active_fg orelse style.fg) else style.fg;
        const merged_status = if (statuses[i] != .none) statuses[i] else resolved[i].agent_status;
        const row_base = @as(usize, row) * width;

        if (text_end <= text_start) {
            v_cached_ends[i] = row + 1;
            row += 1;
            continue;
        }

        // Paint active row's text area with the highlight bg.
        if (is_active) {
            const abg = style.active_tab_bg orelse style.tab_bg;
            for (text_start..text_end) |c2| {
                buf[row_base + c2] = .{ .char = ' ', .fg = t_fg, .bg = abg, .bg_alpha = style.bg_alpha };
            }
        }

        // Layout: " " (1) [zoom 2]? [agent 2]? title… " N "(right)
        var col: u16 = text_start;
        if (col < text_end) { writeCell(buf, row_base + col, ' ', t_fg, is_active, style); col += 1; }
        const tab_zoomed = (zoomed_tabs & (@as(u16, 1) << @intCast(i))) != 0;
        if (tab_zoomed) {
            if (col < text_end) { writeCell(buf, row_base + col, 0x229E, t_fg, is_active, style); col += 1; }
            if (col < text_end) { writeCell(buf, row_base + col, ' ', t_fg, is_active, style); col += 1; }
        }
        if (merged_status != .none) {
            const dot_fg = switch (merged_status) {
                .generic => style.agent_fg,
                .idle => style.agent_idle_fg,
                .running => style.agent_running_fg,
                .waiting => style.agent_waiting_fg,
                .none => t_fg,
            };
            if (col < text_end) { writeCell(buf, row_base + col, 0x25CF, dot_fg, is_active, style); col += 1; }
            if (col < text_end) { writeCell(buf, row_base + col, ' ', t_fg, is_active, style); col += 1; }
        }

        // Tab number badge at the right edge of the text area: " N " or " NN ".
        var num_buf: [3]u8 = undefined;
        const num = std.fmt.bufPrint(&num_buf, "{d}", .{i + 1}) catch "?";
        const badge_w: u16 = @intCast(num.len + 2);
        const badge_start: u16 = if (text_end > text_start + badge_w) text_end - badge_w else text_start;
        const title_end: u16 = if (badge_start > col) badge_start else col;

        // Title characters fill [col, title_end).
        var title_col: u16 = col;
        const title = resolved[i].title;
        var ti: usize = 0;
        while (nextCodepoint(title, &ti)) |cp| {
            if (title_col >= title_end) break;
            if (unicode.isCombiningMark(cp) or unicode.isZeroWidth(cp)) {
                if (title_col > text_start) {
                    const cidx = row_base + (title_col - 1);
                    if (buf[cidx].combining[0] == 0) {
                        buf[cidx].combining[0] = cp;
                    } else if (buf[cidx].combining[1] == 0) {
                        buf[cidx].combining[1] = cp;
                    }
                }
                continue;
            }
            const w = unicode.charDisplayWidth(cp);
            if (title_col + w > title_end) break;
            writeCell(buf, row_base + title_col, cp, t_fg, is_active, style);
            title_col += 1;
            if (w == 2 and title_col < title_end) {
                writeCell(buf, row_base + title_col, ' ', t_fg, is_active, style);
                title_col += 1;
            }
        }

        // Badge: " N " — uses num highlight colors when active.
        if (badge_start < text_end) {
            const n_fg = if (is_active) style.num_highlight_fg else style.fg;
            const n_bg = if (is_active) style.num_highlight_bg else style.tab_bg;
            const use_alpha: u8 = if (is_active) style.bg_alpha else 0;
            buf[row_base + badge_start] = .{ .char = ' ', .fg = n_fg, .bg = n_bg, .bg_alpha = use_alpha };
            var bi: u16 = badge_start + 1;
            for (num) |ch| {
                if (bi >= text_end) break;
                buf[row_base + bi] = .{ .char = ch, .fg = n_fg, .bg = n_bg, .bg_alpha = use_alpha };
                bi += 1;
            }
            while (bi < text_end) : (bi += 1) {
                buf[row_base + bi] = .{ .char = ' ', .fg = n_fg, .bg = n_bg, .bg_alpha = use_alpha };
            }
        }

        v_cached_ends[i] = row + 1;
        row += 1;
    }

    return .{ .cells = buf[0..total], .width = width, .height = height };
}

/// Map a row within the side tab bar back to a tab index.
pub fn tabIndexAtRow(row: u16, tab_count: u8) ?u8 {
    const count = @min(tab_count, v_cached_count);
    for (0..count) |i| {
        if (row >= v_cached_starts[i] and row < v_cached_ends[i]) return @intCast(i);
    }
    return null;
}

/// Given a column position, return the tab index at that column (or null if outside tabs
/// or on a gap between tabs). Accounts for scroll offset and overflow indicators.
pub fn tabIndexAtCol(col: u16, tab_count: u8, grid_cols: u16) ?u8 {
    if (grid_cols == 0 or tab_count == 0) return null;

    // Click on indicator cells — not a tab
    if (cached_has_left_ind and col == 0) return null;
    if (cached_has_right_ind and col >= grid_cols -| 1) return null;

    // Map screen column to virtual column
    const left_ind: u16 = if (cached_has_left_ind) 1 else 0;
    const vcol = (col -| left_ind) + scroll_offset;

    const count = @min(tab_count, cached_count);
    var offset: u16 = 0;
    for (0..count) |i| {
        const w = cached_widths[i];
        if (vcol >= offset and vcol < offset + w) return @intCast(i);
        offset += w;
        // Skip the 1-cell gap between tabs
        if (i + 1 < count) offset += 1;
    }
    return null;
}

// ===========================================================================
// Tests
// ===========================================================================

const no_titles: TabTitles = .{null} ** max_tabs;
const no_statuses: AgentStatuses = .{.none} ** max_tabs;

test "generate: null on 0 cols" {
    var buf: [100]StyledCell = undefined;
    try std.testing.expect(generate(&buf, 2, 0, 0, .{}, &no_titles, 0, &no_statuses) == null);
}

test "generate: null on 0 tabs" {
    var buf: [100]StyledCell = undefined;
    try std.testing.expect(generate(&buf, 0, 0, 40, .{}, &no_titles, 0, &no_statuses) == null);
}

test "generate: null on small buffer" {
    var buf: [5]StyledCell = undefined;
    try std.testing.expect(generate(&buf, 1, 0, 10, .{}, &no_titles, 0, &no_statuses) == null);
}

test "generate: tab layout is ' title ' + ' N '" {
    var buf: [80]StyledCell = undefined;
    const style = Style{};
    var titles: TabTitles = .{null} ** max_tabs;
    titles[0] = "vim";
    // " vim " + " 1 " = (1+3+1) + (1+1+1) = 5 + 3 = 8
    const result = generate(&buf, 1, 0, 80, style, &titles, 0, &no_statuses) orelse return error.TestUnexpectedResult;
    // Title area: " vim " — tab_bg
    try std.testing.expectEqual(@as(u21, ' '), result.cells[0].char);
    try std.testing.expectEqual(style.tab_bg, result.cells[0].bg);
    try std.testing.expectEqual(@as(u21, 'v'), result.cells[1].char);
    try std.testing.expectEqual(@as(u21, 'i'), result.cells[2].char);
    try std.testing.expectEqual(@as(u21, 'm'), result.cells[3].char);
    try std.testing.expectEqual(@as(u21, ' '), result.cells[4].char); // trailing space
    try std.testing.expectEqual(style.tab_bg, result.cells[4].bg);
    // Number area: " 1 " — num_highlight_bg (active)
    try std.testing.expectEqual(@as(u21, ' '), result.cells[5].char);
    try std.testing.expectEqual(style.num_highlight_bg, result.cells[5].bg);
    try std.testing.expectEqual(@as(u21, '1'), result.cells[6].char);
    try std.testing.expectEqual(style.num_highlight_bg, result.cells[6].bg);
    try std.testing.expectEqual(@as(u21, ' '), result.cells[7].char);
    try std.testing.expectEqual(style.num_highlight_bg, result.cells[7].bg);
}

test "generate: inactive number area uses tab_bg, active uses num_highlight_bg" {
    var buf: [80]StyledCell = undefined;
    const style = Style{};
    var titles: TabTitles = .{null} ** max_tabs;
    titles[0] = "zsh";
    titles[1] = "vim";
    // Each tab: " xxx " + " N " = 5+3 = 8, gap at 8, tab 1 starts at 9
    const result = generate(&buf, 2, 1, 80, style, &titles, 0, &no_statuses) orelse return error.TestUnexpectedResult;

    // Tab 0 (inactive) — title area tab_bg
    try std.testing.expectEqual(style.tab_bg, result.cells[0].bg);
    // Tab 0 number area (cols 5-7) — inactive, tab_bg
    try std.testing.expectEqual(style.tab_bg, result.cells[5].bg);
    try std.testing.expectEqual(style.tab_bg, result.cells[6].bg);
    try std.testing.expectEqual(style.fg, result.cells[6].fg);

    // Gap at col 8 — transparent
    try std.testing.expectEqual(@as(u8, 0), result.cells[8].bg_alpha);

    // Tab 1 (active) — title area tab_bg
    try std.testing.expectEqual(style.tab_bg, result.cells[9].bg);
    // Tab 1 number area (cols 14-16) — active, highlighted
    try std.testing.expectEqual(style.num_highlight_bg, result.cells[14].bg);
    try std.testing.expectEqual(style.num_highlight_bg, result.cells[15].bg);
    try std.testing.expectEqual(style.num_highlight_fg, result.cells[15].fg);
    try std.testing.expectEqual(style.num_highlight_bg, result.cells[16].bg);
}

test "generate: two-digit tab numbers" {
    // tabWidth: 1 + title + 1 + 1 + numlen + 1
    // tab 10 (2 digits), title=1: 1+1+1+1+2+1 = 7
    try std.testing.expectEqual(@as(u16, 7), tabWidth(1, 10, false, .none));
    // tab 1 (1 digit), title=1: 1+1+1+1+1+1 = 6
    try std.testing.expectEqual(@as(u16, 6), tabWidth(1, 1, false, .none));
}

test "parseAgentTitle extracts prefixed status marker" {
    const idle = parseAgentTitle("○ OpenCode");
    try std.testing.expectEqual(AgentStatus.idle, idle.agent_status);
    try std.testing.expectEqualStrings("OpenCode", idle.title);

    const running = parseAgentTitle("✻ Claude Code");
    try std.testing.expectEqual(AgentStatus.running, running.agent_status);
    try std.testing.expectEqualStrings("Claude Code", running.title);

    const waiting = parseAgentTitle("● OpenCode");
    try std.testing.expectEqual(AgentStatus.waiting, waiting.agent_status);
    try std.testing.expectEqualStrings("OpenCode", waiting.title);
}

test "parseAgentTitle detects generic agent titles" {
    const open_code = parseAgentTitle("OC | project review");
    try std.testing.expectEqual(AgentStatus.generic, open_code.agent_status);
    try std.testing.expectEqualStrings("OC | project review", open_code.title);

    const claude = parseAgentTitle("claude");
    try std.testing.expectEqual(AgentStatus.generic, claude.agent_status);
    try std.testing.expectEqualStrings("claude", claude.title);
}

test "generate: agent status renders colored dot and strips raw prefix" {
    var buf: [80]StyledCell = undefined;
    const style = Style{};
    var titles: TabTitles = .{null} ** max_tabs;
    titles[0] = "✻ OpenCode";

    const result = generate(&buf, 1, 0, 80, style, &titles, 0, &no_statuses) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u21, ' '), result.cells[0].char);
    try std.testing.expectEqual(@as(u21, 0x25CF), result.cells[1].char);
    try std.testing.expectEqual(style.agent_running_fg, result.cells[1].fg);
    try std.testing.expectEqual(@as(u21, 'O'), result.cells[3].char);
    try std.testing.expectEqual(@as(u21, 'p'), result.cells[4].char);
    try std.testing.expectEqual(@as(u21, 'e'), result.cells[5].char);
    try std.testing.expectEqual(@as(u21, 'n'), result.cells[6].char);
}

test "generate: gap between tabs is transparent" {
    var buf: [80]StyledCell = undefined;
    const style = Style{};
    var titles: TabTitles = .{null} ** max_tabs;
    titles[0] = "a";
    titles[1] = "b";
    // Tab 0: " a " + " 1 " = 3+3 = 6, gap at 6, Tab 1 starts at 7
    _ = generate(&buf, 2, 0, 80, style, &titles, 0, &no_statuses) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(u8, 0), buf[6].bg_alpha);
    try std.testing.expectEqual(style.tab_bg, buf[7].bg);
}

test "tabIndexAtCol: variable width tabs with gaps" {
    var buf: [80]StyledCell = undefined;
    var titles: TabTitles = .{null} ** max_tabs;
    titles[0] = "vim"; // " vim " + " 1 " = 5+3 = 8
    titles[1] = "long-process"; // " long-process " + " 2 " = 14+3 = 17
    titles[2] = "zsh"; // " zsh " + " 3 " = 5+3 = 8
    _ = generate(&buf, 3, 0, 80, .{}, &titles, 0, &no_statuses) orelse return error.TestUnexpectedResult;

    // Tab 0: cols 0..7
    try std.testing.expectEqual(@as(?u8, 0), tabIndexAtCol(0, 3, 80));
    try std.testing.expectEqual(@as(?u8, 0), tabIndexAtCol(7, 3, 80));
    // Gap at col 8
    try std.testing.expectEqual(@as(?u8, null), tabIndexAtCol(8, 3, 80));
    // Tab 1: cols 9..25
    try std.testing.expectEqual(@as(?u8, 1), tabIndexAtCol(9, 3, 80));
    try std.testing.expectEqual(@as(?u8, 1), tabIndexAtCol(25, 3, 80));
    // Gap at col 26
    try std.testing.expectEqual(@as(?u8, null), tabIndexAtCol(26, 3, 80));
    // Tab 2: cols 27..34
    try std.testing.expectEqual(@as(?u8, 2), tabIndexAtCol(27, 3, 80));
    try std.testing.expectEqual(@as(?u8, 2), tabIndexAtCol(34, 3, 80));
    // Beyond all tabs
    try std.testing.expectEqual(@as(?u8, null), tabIndexAtCol(35, 3, 80));
}

test "generate: utf-8 title renders codepoints not bytes" {
    var buf: [80]StyledCell = undefined;
    var titles: TabTitles = .{null} ** max_tabs;
    // "café" = 4 codepoints (5 bytes: c a f 0xC3 0xA9)
    titles[0] = "caf\xc3\xa9";
    // displayWidth = 4, tab = " café " + " 1 " = 6 + 3 = 9
    const result = generate(&buf, 1, 0, 80, .{}, &titles, 0, &no_statuses) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u21, 'c'), result.cells[1].char);
    try std.testing.expectEqual(@as(u21, 'a'), result.cells[2].char);
    try std.testing.expectEqual(@as(u21, 'f'), result.cells[3].char);
    try std.testing.expectEqual(@as(u21, 0xe9), result.cells[4].char); // é as single codepoint
    try std.testing.expectEqual(@as(u21, ' '), result.cells[5].char); // trailing space of title
}

test "generate: CJK wide chars take 2 columns" {
    var buf: [80]StyledCell = undefined;
    var titles: TabTitles = .{null} ** max_tabs;
    // "你好" = 2 codepoints, 4 display columns
    titles[0] = "\xe4\xbd\xa0\xe5\xa5\xbd";
    // displayWidth = 4, tab = " 你好 " + " 1 " = (1+4+1) + (1+1+1) = 6 + 3 = 9
    const result = generate(&buf, 1, 0, 80, .{}, &titles, 0, &no_statuses) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u21, ' '), result.cells[0].char); // leading space
    try std.testing.expectEqual(@as(u21, 0x4F60), result.cells[1].char); // 你
    try std.testing.expectEqual(@as(u21, ' '), result.cells[2].char); // wide spacer
    try std.testing.expectEqual(@as(u21, 0x597D), result.cells[3].char); // 好
    try std.testing.expectEqual(@as(u21, ' '), result.cells[4].char); // wide spacer
    try std.testing.expectEqual(@as(u21, ' '), result.cells[5].char); // trailing space
}

test "tabIndexAtCol: null on 0 cols or 0 tabs" {
    try std.testing.expectEqual(@as(?u8, null), tabIndexAtCol(0, 0, 40));
    try std.testing.expectEqual(@as(?u8, null), tabIndexAtCol(0, 2, 0));
}

test "generate: scroll shows active tab and indicators" {
    var buf: [512]StyledCell = undefined;
    const style = Style{};
    var titles: TabTitles = .{null} ** max_tabs;
    // 5 tabs with short names — each is " x " + " N " = 3+3 = 6
    // Total virtual: 5*6 + 4 gaps = 34 columns
    titles[0] = "a";
    titles[1] = "b";
    titles[2] = "c";
    titles[3] = "d";
    titles[4] = "e";

    // Viewport of 20 cols — tabs overflow (34 > 20)
    // Active tab = 4 (last), should scroll to show it
    const result = generate(&buf, 5, 4, 20, style, &titles, 0, &no_statuses) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 20), result.width);

    // Left indicator '<' should appear at col 0 (scrolled past start)
    try std.testing.expectEqual(@as(u21, '<'), result.cells[0].char);
    try std.testing.expectEqual(style.tab_bg, result.cells[0].bg);

    // No right indicator — active tab 4 is last, scrolled to end
    // With left_ind=1, effective_width=19, scroll_offset=34-19=15
    // vis_end = 15+19 = 34 = total_virtual → no right overflow
    // Col 19 is the last tab content cell, not an indicator
    try std.testing.expect(result.cells[19].bg_alpha == style.bg_alpha or result.cells[19].bg_alpha == 0);
}

test "generate: no scroll when tabs fit" {
    var buf: [80]StyledCell = undefined;
    const style = Style{};
    var titles: TabTitles = .{null} ** max_tabs;
    titles[0] = "a";
    titles[1] = "b";
    // Total virtual: 2*6 + 1 gap = 13, fits in 80 cols
    const result = generate(&buf, 2, 0, 80, style, &titles, 0, &no_statuses) orelse return error.TestUnexpectedResult;

    // No indicators — first cell should be tab content, not '<'
    try std.testing.expectEqual(@as(u21, ' '), result.cells[0].char);
    try std.testing.expectEqual(style.tab_bg, result.cells[0].bg);
    // Tab content at col 1
    try std.testing.expectEqual(@as(u21, 'a'), result.cells[1].char);
}

test "generate: scroll right indicator when active is first tab" {
    var buf: [512]StyledCell = undefined;
    const style = Style{};
    var titles: TabTitles = .{null} ** max_tabs;
    titles[0] = "a";
    titles[1] = "b";
    titles[2] = "c";
    titles[3] = "d";
    titles[4] = "e";

    // Active tab 0, viewport 20 — scroll_offset should be 0
    const result = generate(&buf, 5, 0, 20, style, &titles, 0, &no_statuses) orelse return error.TestUnexpectedResult;

    // No left indicator (at start, no overflow left) — col 0 is tab content
    try std.testing.expectEqual(@as(u21, ' '), result.cells[0].char);
    try std.testing.expectEqual(style.tab_bg, result.cells[0].bg);
    // Tab 0 title starts at col 1
    try std.testing.expectEqual(@as(u21, 'a'), result.cells[1].char);

    // Right indicator '>' (tabs overflow right)
    try std.testing.expectEqual(@as(u21, '>'), result.cells[19].char);
    try std.testing.expectEqual(style.tab_bg, result.cells[19].bg);
}

test "tabIndexAtCol: works with scroll offset" {
    var buf: [512]StyledCell = undefined;
    var titles: TabTitles = .{null} ** max_tabs;
    titles[0] = "a"; // width 6
    titles[1] = "b"; // width 6
    titles[2] = "c"; // width 6
    titles[3] = "d"; // width 6
    titles[4] = "e"; // width 6
    // Total: 34, viewport 20, active=4 → scrolled to end
    // left_ind=1, right_ind=0, effective=19, scroll_offset=34-19=15

    _ = generate(&buf, 5, 4, 20, .{}, &titles, 0, &no_statuses) orelse return error.TestUnexpectedResult;

    // Col 0 is left indicator '<' — should return null
    try std.testing.expectEqual(@as(?u8, null), tabIndexAtCol(0, 5, 20));

    // Col 1 maps to virtual col 0+15=15 — that's in tab 2 (starts at 14, width 6, ends at 20)
    try std.testing.expectEqual(@as(?u8, 2), tabIndexAtCol(1, 5, 20));

    // Col 19 is tab content (no right indicator) — virtual col 18+15=33, tab 4 (starts 28, width 6)
    try std.testing.expectEqual(@as(?u8, 4), tabIndexAtCol(19, 5, 20));
}

test "sideBarWidth: fixed 24 cells, shrinks only on narrow windows" {
    try std.testing.expectEqual(@as(u16, 24), sideBarWidth(80));
    try std.testing.expectEqual(@as(u16, 24), sideBarWidth(120));
    try std.testing.expectEqual(@as(u16, 24), sideBarWidth(300));
    try std.testing.expectEqual(@as(u16, 20), sideBarWidth(40)); // half of 40
    try std.testing.expectEqual(@as(u16, 0), sideBarWidth(0));
}

test "sideBarWidthRequested: honors override clamped to [min, half]" {
    try std.testing.expectEqual(@as(u16, 30), sideBarWidthRequested(120, 30));
    try std.testing.expectEqual(@as(u16, 8), sideBarWidthRequested(120, 4)); // below min
    try std.testing.expectEqual(@as(u16, 60), sideBarWidthRequested(120, 200)); // capped at half
    try std.testing.expectEqual(@as(u16, 24), sideBarWidthRequested(120, 0)); // default
}

test "generateVertical: lays out one tab per row with badge + border" {
    var buf: [16 * 24]StyledCell = undefined;
    var titles: TabTitles = .{null} ** max_tabs;
    titles[0] = "vim";
    titles[1] = "zsh";
    // Left-side bar → border on right (column width-1 = 15).
    const result = generateVertical(&buf, 2, 1, 16, 24, .{}, &titles, 0, &no_statuses, true) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 16), result.width);
    try std.testing.expectEqual(@as(u16, 24), result.height);

    // Border column: vertical line at col 15 of every row.
    try std.testing.expectEqual(@as(u21, 0x2502), result.cells[15].char);
    try std.testing.expectEqual(@as(u21, 0x2502), result.cells[16 * 5 + 15].char);

    // Row 0: tab 0 — title text, badge `" 1 "` ends just before the border.
    try std.testing.expectEqual(@as(u21, 'v'), result.cells[1].char);
    try std.testing.expectEqual(@as(u21, '1'), result.cells[13].char);

    // Row 1: tab 1 (active)
    const r1 = 16 * 1;
    try std.testing.expectEqual(@as(u21, 'z'), result.cells[r1 + 1].char);
    try std.testing.expectEqual(@as(u21, '2'), result.cells[r1 + 13].char);

    // Empty rows below the last tab keep transparent bg with border line.
    try std.testing.expectEqual(@as(u8, 0), result.cells[16 * 10 + 5].bg_alpha);
    try std.testing.expectEqual(@as(u21, 0x2502), result.cells[16 * 10 + 15].char);

    // Hit test
    try std.testing.expectEqual(@as(?u8, 0), tabIndexAtRow(0, 2));
    try std.testing.expectEqual(@as(?u8, 1), tabIndexAtRow(1, 2));
    try std.testing.expectEqual(@as(?u8, null), tabIndexAtRow(5, 2));
}

test "generateVertical: right-side bar puts border at column 0" {
    var buf: [16 * 8]StyledCell = undefined;
    var titles: TabTitles = .{null} ** max_tabs;
    titles[0] = "a";
    const result = generateVertical(&buf, 1, 0, 16, 8, .{}, &titles, 0, &no_statuses, false) orelse return error.TestUnexpectedResult;
    // Border at col 0 every row.
    try std.testing.expectEqual(@as(u21, 0x2502), result.cells[0].char);
    try std.testing.expectEqual(@as(u21, 0x2502), result.cells[16].char);
}

test "autoScroll: active tab scrolled into view" {
    // Set up cached state manually
    cached_widths = .{0} ** max_tabs;
    cached_widths[0] = 6;
    cached_widths[1] = 6;
    cached_widths[2] = 6;
    cached_widths[3] = 6;
    cached_widths[4] = 6;
    cached_count = 5;
    scroll_offset = 0;

    // Scroll to tab 4 with viewport 19 (only left indicator, no right)
    // Tab 4 starts at virtual col 28, ends at 34
    // 34 - 19 = 15
    autoScroll(4, 5, 19);
    try std.testing.expectEqual(@as(u16, 15), scroll_offset);

    // Now scroll back to tab 0
    autoScroll(0, 5, 19);
    try std.testing.expectEqual(@as(u16, 0), scroll_offset);

    // Scroll to middle tab 2 from offset 0
    // Tab 2 starts at 14, ends at 20. Fits in viewport (0+19=19 > 14), but end 20 > 19
    autoScroll(2, 5, 19);
    try std.testing.expectEqual(@as(u16, 1), scroll_offset);
}
