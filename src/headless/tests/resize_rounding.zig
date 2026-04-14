//! Tests for the pixel→cell rounding formula used by platform resize paths.
//!
//! The platform layer (macos_renderer.m, platform_linux.c, platform_windows.c)
//! computes grid rows/cols from the drawable size with:
//!   rows = (int)((fb - pad) / cell + eps)
//! The epsilon absorbs FP noise near integer boundaries. If it's too loose,
//! a window that genuinely fits N.99 rows gets promoted to N+1, the PTY is
//! told it has N+1 rows, the shell writes its prompt on row N+1, and the
//! renderer only has physical pixels for N — the prompt falls off-screen.
//! That's the "can't scroll to the bottom on 13.3"" bug.
//!
//! Invariant under test: computed_rows * cell + pad <= fb (no overflow).

const std = @import("std");

/// Mirror of the platform formula. Keep eps in sync with the value used in
/// macos_renderer.m, platform_macos.m, platform_linux.c, linux_input.c, and
/// platform_windows.c.
fn computeCells(fb: f32, pad: f32, cell: f32) i32 {
    const eps: f32 = 0.001;
    const n = @as(i32, @intFromFloat((fb - pad) / cell + eps));
    return if (n < 1) 1 else n;
}

fn fits(fb: f32, pad: f32, cell: f32, rows: i32) bool {
    // Allow 1 pixel of rounding slack (platform integer fb math).
    return @as(f32, @floatFromInt(rows)) * cell + pad <= fb + 1.0;
}

test "exact-integer fit: 38 rows at 16px is 38, not 37" {
    // FP division of integers can land just below the true integer.
    // Epsilon must rescue this case.
    try std.testing.expectEqual(@as(i32, 38), computeCells(608.0, 0.0, 16.0));
    try std.testing.expectEqual(@as(i32, 38), computeCells(38.0 * 16.0, 0.0, 16.0));
}

test "just-under-integer fit: 38.99 rows must stay 38, not promote to 39" {
    // This is the 13.3" bug: loose epsilon (+0.01) rounded 38.99 to 39,
    // causing the PTY to be told 39 rows when only 38 physically fit.
    const cell: f32 = 17.0;
    const fb = 38.99 * cell; // 662.83 px
    const rows = computeCells(fb, 0.0, cell);
    try std.testing.expectEqual(@as(i32, 38), rows);
    try std.testing.expect(fits(fb, 0.0, cell, rows));
}

test "invariant: computed rows never overflow the framebuffer" {
    // Sweep realistic (fb, cell, pad) combinations and assert no overflow.
    const cells = [_]f32{ 12.0, 14.0, 15.0, 16.0, 17.0, 18.0, 20.0, 24.0, 28.0, 32.0, 34.0 };
    const pads = [_]f32{ 0.0, 4.0, 8.0, 16.0 };
    for (cells) |cell| {
        for (pads) |pad| {
            // Sweep framebuffer heights from tiny to a 4K display.
            var fb: f32 = cell + pad;
            while (fb < 4320.0) : (fb += 0.5) {
                const rows = computeCells(fb, pad, cell);
                if (!fits(fb, pad, cell, rows)) {
                    std.debug.print(
                        "overflow: fb={d} pad={d} cell={d} rows={d} used={d}\n",
                        .{ fb, pad, cell, rows, @as(f32, @floatFromInt(rows)) * cell + pad },
                    );
                    return error.TestOverflow;
                }
            }
        }
    }
}

test "13.3 inch MBP retina: no phantom row" {
    // Representative small-screen scenario: 13.3" MBP, 80% of 825pt visible,
    // Retina (2x), typical 17pt cell → 34px glyph height.
    // Window content height ≈ 660pt × 2 = 1320px (integer, as drawableSize).
    const fb: f32 = 1320.0;
    const cell: f32 = 34.0;
    const rows = computeCells(fb, 0.0, cell);
    // 1320/34 = 38.823... → 38 rows, not 39.
    try std.testing.expectEqual(@as(i32, 38), rows);
    try std.testing.expect(fits(fb, 0.0, cell, rows));
}

test "minimum row clamp" {
    // Degenerate tiny window still returns >= 1 row.
    try std.testing.expectEqual(@as(i32, 1), computeCells(1.0, 0.0, 16.0));
    try std.testing.expectEqual(@as(i32, 1), computeCells(0.0, 0.0, 16.0));
}
