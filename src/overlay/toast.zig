/// Attyx — Toast overlay
///
/// Lightweight, auto-dismissing text pills shown briefly.
/// `.toast` — bottom-center (e.g. "Copied").
/// `.resize_hint` — center (e.g. "80×24").

const std = @import("std");
const overlay_mod = @import("overlay.zig");
const ui = @import("ui.zig");

const StyledCell = ui.StyledCell;
const Rgb = ui.Rgb;
const OverlayManager = overlay_mod.OverlayManager;
const OverlayId = overlay_mod.OverlayId;

const toast_duration_ns: i128 = 1_200 * std.time.ns_per_ms;
const resize_duration_ns: i128 = 800 * std.time.ns_per_ms;

var toast_show_time: i128 = 0;
var resize_show_time: i128 = 0;

const pill_bg = Rgb{ .r = 60, .g = 60, .b = 70 };
const pill_fg = Rgb{ .r = 230, .g = 230, .b = 230 };
const pill_style = overlay_mod.OverlayStyle{ .bg = pill_bg, .fg = pill_fg, .border = false, .bg_alpha = 220 };

/// Show a toast with the given text, positioned at bottom-center of the grid.
pub fn showToast(mgr: *OverlayManager, text: []const u8, grid_cols: u16, grid_rows: u16) void {
    const width = layoutPill(.toast, mgr, text, grid_cols) orelse return;
    // Bottom-center, 2 rows from the bottom edge
    const col: u16 = if (grid_cols > width) (grid_cols - width) / 2 else 0;
    const row: u16 = if (grid_rows > 3) grid_rows - 3 else 0;
    mgr.layers[@intFromEnum(OverlayId.toast)].col = col;
    mgr.layers[@intFromEnum(OverlayId.toast)].row = row;
    mgr.show(.toast);
    toast_show_time = std.time.nanoTimestamp();
}

/// Show a resize hint (e.g. "80×24") centered on the grid.
pub fn showResizeHint(mgr: *OverlayManager, cols: u16, rows: u16, grid_cols: u16, grid_rows: u16) void {
    var buf: [32]u8 = undefined;
    // Format: "COLSxROWS" using ASCII 'x'
    const text = std.fmt.bufPrint(&buf, "{d} x {d}", .{ cols, rows }) catch return;
    const width = layoutPill(.resize_hint, mgr, text, grid_cols) orelse return;
    const col: u16 = if (grid_cols > width) (grid_cols - width) / 2 else 0;
    const row: u16 = if (grid_rows > 1) grid_rows / 2 else 0;
    mgr.layers[@intFromEnum(OverlayId.resize_hint)].col = col;
    mgr.layers[@intFromEnum(OverlayId.resize_hint)].row = row;
    mgr.show(.resize_hint);
    resize_show_time = std.time.nanoTimestamp();
}

/// Check if toasts should be auto-dismissed. Returns true if any was dismissed.
pub fn tickDismiss(mgr: *OverlayManager) bool {
    var changed = false;
    changed = tickOne(mgr, .toast, &toast_show_time, toast_duration_ns) or changed;
    changed = tickOne(mgr, .resize_hint, &resize_show_time, resize_duration_ns) or changed;
    return changed;
}

// -- internals --

fn tickOne(mgr: *OverlayManager, id: OverlayId, time: *i128, duration: i128) bool {
    if (time.* == 0) return false;
    if (!mgr.isVisible(id)) {
        time.* = 0;
        return false;
    }
    if (std.time.nanoTimestamp() - time.* >= duration) {
        mgr.hide(id);
        time.* = 0;
        return true;
    }
    return false;
}

fn layoutPill(id: OverlayId, mgr: *OverlayManager, text: []const u8, grid_cols: u16) ?u16 {
    const padding = 2;
    const width: u16 = @intCast(@min(text.len + padding, grid_cols));
    const w: usize = @intCast(width);

    var cells: [64]StyledCell = undefined;
    for (0..w) |i| {
        const ch: u21 = if (i >= 1 and i - 1 < text.len) text[i - 1] else ' ';
        cells[i] = .{ .char = ch, .fg = pill_fg, .bg = pill_bg, .bg_alpha = 220 };
    }

    mgr.setContent(id, 0, 0, width, 1, cells[0..w]) catch return null;
    mgr.layers[@intFromEnum(id)].style = pill_style;
    return width;
}
