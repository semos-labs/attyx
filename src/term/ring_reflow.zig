const std = @import("std");
const grid_mod = @import("grid.zig");
const ring_mod = @import("ring.zig");

const Cell = grid_mod.Cell;
const RingBuffer = ring_mod.RingBuffer;
const isDefaultCell = grid_mod.isDefaultCell;

/// Result of a ring resize/reflow operation.
pub const ResizeResult = struct {
    ring: RingBuffer,
    cursor_row: usize,
    cursor_col: usize,
};

/// Logical line: a contiguous range of physical rows joined by soft-wrap.
const LogicalLine = struct {
    start_abs: usize, // first absolute row index
    row_count: usize, // number of physical rows
    content_len: usize, // total character positions with content
};

/// Max logical lines we can track during reflow (generous upper bound).
const max_logical_lines = 16384;

/// Resize the ring buffer with reflow. Builds a new ring at new dimensions,
/// re-wrapping logical lines at the new column width.
/// Cursor position is mapped through the reflow.
pub fn resize(
    old: *RingBuffer,
    new_screen_rows: usize,
    new_cols: usize,
    cursor_row: usize,
    cursor_col: usize,
) !ResizeResult {
    std.debug.assert(new_screen_rows > 0 and new_cols > 0);

    const old_cols = old.cols;
    const old_count = old.count;
    const max_scrollback = old.capacity - old.screen_rows;

    // -- Phase 0: RPROMPT stripping (same logic as old state_resize.zig) --
    if (new_cols < old_cols) {
        stripRprompts(old, new_cols);
    }

    // -- Phase 1: collect logical lines --
    var ll_buf: [max_logical_lines]LogicalLine = undefined;
    var ll_count: usize = 0;
    {
        var abs: usize = 0;
        while (abs < old_count) {
            if (ll_count >= max_logical_lines) break;
            const start = abs;
            var content_len: usize = 0;
            while (abs < old_count) : (abs += 1) {
                if (old.getWrapped(abs)) {
                    content_len += old_cols;
                } else {
                    // Measure content length on the final row
                    const row = old.getRow(abs);
                    var last: usize = 0;
                    for (0..old_cols) |c| {
                        if (!isDefaultCell(row[c])) last = c + 1;
                    }
                    content_len += last;
                    abs += 1;
                    break;
                }
            }
            ll_buf[ll_count] = .{
                .start_abs = start,
                .row_count = abs - start,
                .content_len = content_len,
            };
            ll_count += 1;
        }
    }

    // -- Phase 1.5: trim trailing blank lines below cursor --
    // Don't preserve blank rows below the cursor — they inflate the total
    // and push real content into scrollback.
    const old_sb = old.scrollbackCount();
    const cursor_abs = old_sb + cursor_row;
    {
        while (ll_count > 0) {
            const last = ll_buf[ll_count - 1];
            // Keep if it has content, or if the cursor is on or before it
            if (last.content_len > 0) break;
            if (cursor_abs >= last.start_abs and cursor_abs < last.start_abs + last.row_count) break;
            // Also keep if it's before the cursor's logical line
            if (last.start_abs + last.row_count <= cursor_abs) break;
            ll_count -= 1;
        }
        // Ensure at least one line (cursor's line) remains
        if (ll_count == 0) ll_count = 1;
    }

    // -- Phase 2: compute new physical row count and map cursor --
    // Also track how many reflowed rows come from old scrollback content.
    var new_total: usize = 0;
    var new_sb_rows: usize = 0;
    var mapped_cr: usize = 0;
    var mapped_cc: usize = 0;

    for (ll_buf[0..ll_count]) |ll| {
        const rows_needed = if (ll.content_len == 0) 1 else (ll.content_len + new_cols - 1) / new_cols;

        // Map cursor if it falls within this logical line
        if (cursor_abs >= ll.start_abs and cursor_abs < ll.start_abs + ll.row_count) {
            const offset_in_ll = (cursor_abs - ll.start_abs) * old_cols + cursor_col;
            mapped_cr = new_total + offset_in_ll / new_cols;
            mapped_cc = offset_in_ll % new_cols;
        }

        // Track rows that originated entirely from scrollback
        if (old_sb > 0 and ll.start_abs + ll.row_count <= old_sb) {
            new_sb_rows += rows_needed;
        } else if (old_sb > 0 and ll.start_abs < old_sb) {
            // Logical line spans scrollback/screen boundary
            new_sb_rows += rows_needed;
        }

        new_total += rows_needed;
    }

    // -- Phase 3: build new ring --
    var new_ring = try RingBuffer.init(old.allocator, new_screen_rows, new_cols, max_scrollback);
    errdefer new_ring.deinit();

    // Determine how many rows go to scrollback vs screen.
    // Cursor must be visible on screen.
    var scroll_off: usize = 0;
    if (mapped_cr >= new_screen_rows) {
        scroll_off = mapped_cr - new_screen_rows + 1;
    }
    // Preserve old scrollback content — whether columns changed or not.
    // Without this, scrollback from `clear` or prior output gets pulled
    // onto the visible screen, pushing the cursor down and causing the
    // shell's SIGWINCH redraw to leave ghost copies above.
    if (old_sb > 0) {
        scroll_off = @max(scroll_off, new_sb_rows);
    }

    // The new ring starts with screen_rows blank rows (from init).
    // We need to place content starting from the appropriate position.
    // First, determine how many total rows to write.
    // If new_total > capacity, we skip the oldest rows.
    const skip_rows = if (new_total > new_ring.capacity) new_total - new_ring.capacity else 0;

    // Reset ring to empty state and fill it
    new_ring.count = 0;
    new_ring.head = 0;

    var dst_row: usize = 0;
    for (ll_buf[0..ll_count]) |ll| {
        const rows_needed = if (ll.content_len == 0) 1 else (ll.content_len + new_cols - 1) / new_cols;

        for (0..rows_needed) |pr| {
            const abs_row = dst_row + pr;

            if (abs_row < skip_rows) continue;

            // Ensure we have a slot in the ring
            if (new_ring.count < new_ring.capacity) {
                new_ring.count += 1;
            } else {
                new_ring.head = (new_ring.head + 1) % new_ring.capacity;
            }

            const target_idx = new_ring.count - 1;
            const target_cells = new_ring.getRowMut(target_idx);
            @memset(target_cells, Cell{});

            // Copy cells from old ring
            const cells_start = pr * new_cols;
            const cells_end = @min(cells_start + new_cols, ll.content_len);
            if (cells_end > cells_start) {
                for (0..cells_end - cells_start) |c| {
                    const src_idx = cells_start + c;
                    const old_row_in_ll = src_idx / old_cols;
                    const old_col_in_ll = src_idx % old_cols;
                    const old_abs = ll.start_abs + old_row_in_ll;
                    if (old_abs < old_count) {
                        const src_row = old.getRow(old_abs);
                        if (old_col_in_ll < old_cols) {
                            target_cells[c] = src_row[old_col_in_ll];
                        }
                    }
                }
            }

            // Set wrapped flag
            new_ring.setWrapped(target_idx, pr < rows_needed - 1);
        }
        dst_row += rows_needed;
    }

    // Ensure ring has enough rows for scrollback + full screen.
    // Without this, scroll_off rows meant for scrollback would be counted
    // as screen rows (ring.count - screen_rows < scroll_off).
    // Cap to capacity so we never grow count past the ring's allocation.
    const min_ring_count = @min(scroll_off + new_screen_rows, new_ring.capacity);
    while (new_ring.count < min_ring_count) {
        new_ring.count += 1;
        const idx = new_ring.count - 1;
        @memset(new_ring.getRowMut(idx), Cell{});
        new_ring.setWrapped(idx, false);
    }

    // Map cursor to new coordinates.
    const adjusted_cr = if (mapped_cr >= skip_rows) mapped_cr - skip_rows else 0;
    const new_sb = new_ring.scrollbackCount();
    // Convert from absolute to screen-relative
    var final_cr = if (adjusted_cr >= new_sb) adjusted_cr - new_sb else 0;
    final_cr = @min(final_cr, new_screen_rows - 1);
    const final_cc = @min(mapped_cc, new_cols - 1);

    return .{
        .ring = new_ring,
        .cursor_row = final_cr,
        .cursor_col = final_cc,
    };
}

/// Strip right-aligned content (RPROMPT) that would cause garbled wrapping.
///
/// Detects right-aligned prompt content by finding a gap of default cells
/// within a logical line (joined wrapped rows). The gap separates left
/// content from right-aligned content. Everything from the gap onward is
/// cleared, and blank trailing rows are collapsed.
///
/// The gap threshold scales with column width to avoid false positives on
/// normal output while catching the smaller gaps that appear when prompts
/// are re-rendered at narrow widths.
fn stripRprompts(ring: *RingBuffer, new_cols: usize) void {
    const cols = ring.cols;
    const gap_threshold: usize = @max(4, cols / 8);

    var abs: usize = 0;
    while (abs < ring.count) {
        // Find extent of this logical line (consecutive wrapped rows)
        const ll_start = abs;
        while (abs < ring.count and ring.getWrapped(abs)) : (abs += 1) {}
        abs += 1; // include the final non-wrapped row
        const ll_end = @min(abs, ring.count);
        const ll_rows = ll_end - ll_start;

        // Measure total content length across the logical line
        var content_len: usize = 0;
        for (ll_start..ll_end) |r| {
            if (r < ll_end - 1) {
                content_len += cols;
            } else {
                const row = ring.getRow(r);
                var last: usize = 0;
                for (0..cols) |c| {
                    if (!isDefaultCell(row[c])) last = c + 1;
                }
                content_len += last;
            }
        }

        // Only process if content would wrap at new_cols
        if (content_len <= new_cols) continue;

        // Scan left-to-right for a qualifying gap (>= threshold consecutive
        // default cells after some content). The gap is only "found" when
        // non-default content appears AFTER it, so trailing spaces at the end
        // of a line never trigger false positives.
        var gap_start_pos: usize = 0;
        var gap_len: usize = 0;
        var found_gap = false;

        for (0..content_len) |pos| {
            const r = ll_start + pos / cols;
            const c = pos % cols;
            if (r >= ll_end) break;
            const row = ring.getRow(r);
            if (isDefaultCell(row[c])) {
                if (gap_len == 0) gap_start_pos = pos;
                gap_len += 1;
            } else {
                if (gap_len >= gap_threshold and gap_start_pos > 0) {
                    found_gap = true;
                    break;
                }
                gap_len = 0;
            }
        }

        if (!found_gap) continue;

        // Clear everything from gap_start_pos to end of the logical line
        for (gap_start_pos..ll_rows * cols) |pos| {
            const r = ll_start + pos / cols;
            const c = pos % cols;
            if (r >= ll_end) break;
            ring.getRowMut(r)[c] = Cell{};
        }

        // Un-wrap rows that no longer fill the full width after stripping.
        // A wrapped row means "content continues on the next row." After
        // stripping, partially-filled rows must be unwrapped so the next
        // resize doesn't incorrectly join them with the following row.
        for (ll_start..ll_end) |r| {
            if (r == ll_end - 1) continue;
            const row = ring.getRow(r);
            // Check if the last column has content (row is truly full)
            const last_col_has_content = !isDefaultCell(row[cols - 1]);
            if (!last_col_has_content) {
                ring.setWrapped(r, false);
            }
        }
    }
}

/// Simple resize without reflow — for the alt screen buffer.
/// Copies overlapping rectangle of content. No cursor mapping.
pub fn resizeNoReflow(
    old: *RingBuffer,
    new_screen_rows: usize,
    new_cols: usize,
) !RingBuffer {
    std.debug.assert(new_screen_rows > 0 and new_cols > 0);
    const max_scrollback = old.capacity - old.screen_rows;
    var new_ring = try RingBuffer.init(old.allocator, new_screen_rows, new_cols, max_scrollback);
    errdefer new_ring.deinit();

    const copy_rows = @min(old.screen_rows, new_screen_rows);
    const copy_cols = @min(old.cols, new_cols);

    for (0..copy_rows) |r| {
        const src = old.getScreenRow(r);
        const dst = new_ring.getScreenRowMut(r);
        @memcpy(dst[0..copy_cols], src[0..copy_cols]);
    }

    return new_ring;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "ring_reflow: grow cols unwraps" {
    const alloc = testing.allocator;
    var ring = try RingBuffer.init(alloc, 4, 3, 10);
    defer ring.deinit();

    // Write "ABCDEF" as a wrapped line across 2 rows at 3 cols
    ring.setScreenCell(0, 0, .{ .char = 'A' });
    ring.setScreenCell(0, 1, .{ .char = 'B' });
    ring.setScreenCell(0, 2, .{ .char = 'C' });
    ring.setScreenWrapped(0, true);
    ring.setScreenCell(1, 0, .{ .char = 'D' });
    ring.setScreenCell(1, 1, .{ .char = 'E' });
    ring.setScreenCell(1, 2, .{ .char = 'F' });

    const result = try resize(&ring, 4, 6, 1, 2);
    var new_ring = result.ring;
    defer new_ring.deinit();

    // Should unwrap into a single row
    try testing.expectEqual(@as(u21, 'A'), new_ring.getScreenCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'F'), new_ring.getScreenCell(0, 5).char);
    try testing.expect(!new_ring.getScreenWrapped(0));
}

test "ring_reflow: shrink cols wraps" {
    const alloc = testing.allocator;
    var ring = try RingBuffer.init(alloc, 2, 6, 10);
    defer ring.deinit();

    // Write "ABCDEF" on one row
    const chars = "ABCDEF";
    for (chars, 0..) |ch, i| ring.setScreenCell(0, i, .{ .char = ch });

    const result = try resize(&ring, 4, 3, 0, 0);
    var new_ring = result.ring;
    defer new_ring.deinit();

    // Should wrap into 2 rows
    try testing.expectEqual(@as(u21, 'A'), new_ring.getScreenCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'C'), new_ring.getScreenCell(0, 2).char);
    try testing.expect(new_ring.getScreenWrapped(0));
    try testing.expectEqual(@as(u21, 'D'), new_ring.getScreenCell(1, 0).char);
    try testing.expectEqual(@as(u21, 'F'), new_ring.getScreenCell(1, 2).char);
    try testing.expect(!new_ring.getScreenWrapped(1));
}

test "ring_reflow: cursor mapping" {
    const alloc = testing.allocator;
    var ring = try RingBuffer.init(alloc, 2, 6, 10);
    defer ring.deinit();

    const chars = "ABCDEF";
    for (chars, 0..) |ch, i| ring.setScreenCell(0, i, .{ .char = ch });

    // Cursor at row 0, col 4 (on 'E')
    const result = try resize(&ring, 4, 3, 0, 4);
    var new_ring = result.ring;
    defer new_ring.deinit();

    // 'E' is position 4 → row 1, col 1
    try testing.expectEqual(@as(usize, 1), result.cursor_row);
    try testing.expectEqual(@as(usize, 1), result.cursor_col);
}

test "ring_reflow: scrollback wraps on shrink" {
    const alloc = testing.allocator;
    var ring = try RingBuffer.init(alloc, 2, 8, 10);
    defer ring.deinit();

    // Write "ABCDEFGH" on screen row 0 (full 8-col row)
    const chars = "ABCDEFGH";
    for (chars, 0..) |ch, i| ring.setScreenCell(0, i, .{ .char = ch });
    // Push to scrollback
    _ = ring.advanceScreen();
    // Screen row 0 now has "ABCDEFGH" in scrollback, screen is blank
    ring.setScreenCell(0, 0, .{ .char = 'X' });

    try testing.expectEqual(@as(usize, 1), ring.scrollbackCount());

    // Shrink to 4 cols — scrollback "ABCDEFGH" should wrap into 2 rows
    const result = try resize(&ring, 2, 4, 0, 0);
    var new_ring = result.ring;
    defer new_ring.deinit();

    // Scrollback should now have 2 rows (ABCD + EFGH)
    try testing.expectEqual(@as(usize, 2), new_ring.scrollbackCount());
    try testing.expectEqual(@as(u21, 'A'), new_ring.getRow(0)[0].char);
    try testing.expectEqual(@as(u21, 'D'), new_ring.getRow(0)[3].char);
    try testing.expectEqual(@as(u21, 'E'), new_ring.getRow(1)[0].char);
    try testing.expectEqual(@as(u21, 'H'), new_ring.getRow(1)[3].char);
    // First scrollback row should be wrapped (continuation)
    try testing.expect(new_ring.getWrapped(0));
    try testing.expect(!new_ring.getWrapped(1));
    // Screen content should still have X
    try testing.expectEqual(@as(u21, 'X'), new_ring.getScreenCell(0, 0).char);
}

test "ring_reflow: scrollback content preserved" {
    const alloc = testing.allocator;
    var ring = try RingBuffer.init(alloc, 2, 4, 10);
    defer ring.deinit();

    // Put content and push to scrollback
    ring.setScreenCell(0, 0, .{ .char = 'A' });
    ring.setScreenCell(0, 1, .{ .char = 'B' });
    ring.setScreenCell(0, 2, .{ .char = 'C' });
    ring.setScreenCell(0, 3, .{ .char = 'D' });
    ring.setScreenCell(1, 0, .{ .char = 'E' });
    _ = ring.advanceScreen();
    ring.setScreenCell(1, 0, .{ .char = 'F' });

    try testing.expectEqual(@as(usize, 1), ring.scrollbackCount());

    // Resize cols (triggers reflow)
    const result = try resize(&ring, 2, 4, 1, 0);
    var new_ring = result.ring;
    defer new_ring.deinit();

    // Scrollback content should be preserved
    try testing.expectEqual(@as(usize, 1), new_ring.scrollbackCount());
    try testing.expectEqual(@as(u21, 'A'), new_ring.getRow(0)[0].char);
}
