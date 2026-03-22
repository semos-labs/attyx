/// Attyx — Toast overlay
///
/// Lightweight, auto-dismissing text pill shown briefly (e.g. "Copied").
/// Uses the overlay system with the `.toast` layer ID.

const std = @import("std");
const overlay_mod = @import("overlay.zig");
const ui = @import("ui.zig");

const StyledCell = ui.StyledCell;
const Rgb = ui.Rgb;
const OverlayManager = overlay_mod.OverlayManager;
const OverlayId = overlay_mod.OverlayId;

/// How long the toast stays visible (nanoseconds).
const display_duration_ns: i128 = 1_200 * std.time.ns_per_ms;

/// Timestamp (nanoTimestamp) when the toast was shown; 0 = inactive.
var show_time: i128 = 0;

/// Show a toast with the given text, positioned at bottom-center of the grid.
pub fn showToast(mgr: *OverlayManager, text: []const u8, grid_cols: u16, grid_rows: u16) void {
    const padding = 2; // 1 cell padding on each side
    const width: u16 = @intCast(@min(text.len + padding, grid_cols));
    const height: u16 = 1;

    // Bottom-center, 2 rows from the bottom edge
    const col: u16 = if (grid_cols > width) (grid_cols - width) / 2 else 0;
    const row: u16 = if (grid_rows > 3) grid_rows - 3 else 0;

    const bg = Rgb{ .r = 60, .g = 60, .b = 70 };
    const fg = Rgb{ .r = 230, .g = 230, .b = 230 };

    var cells: [64]StyledCell = undefined;
    const w: usize = @intCast(width);
    for (0..w) |i| {
        const ch: u21 = if (i >= 1 and i - 1 < text.len) text[i - 1] else ' ';
        cells[i] = .{ .char = ch, .fg = fg, .bg = bg, .bg_alpha = 220 };
    }

    mgr.setContent(.toast, col, row, width, height, cells[0..w]) catch return;
    mgr.layers[@intFromEnum(OverlayId.toast)].style = .{
        .bg = bg,
        .fg = fg,
        .border = false,
        .bg_alpha = 220,
    };
    mgr.show(.toast);
    show_time = std.time.nanoTimestamp();
}

/// Check if the toast should be auto-dismissed. Returns true if it was dismissed
/// (caller should re-publish overlays).
pub fn tickDismiss(mgr: *OverlayManager) bool {
    if (show_time == 0) return false;
    if (!mgr.isVisible(.toast)) {
        show_time = 0;
        return false;
    }
    const now = std.time.nanoTimestamp();
    if (now - show_time >= display_duration_ns) {
        mgr.hide(.toast);
        show_time = 0;
        return true;
    }
    return false;
}
