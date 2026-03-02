// Attyx — Command Capture: passive shell command/output extraction
//
// Observes PTY data flow and terminal grid to extract structured command
// blocks without requiring shell cooperation (no OSC 133, no hooks).
// Strategy: input echo correlation + idle timing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const attyx = @import("attyx");
const Grid = attyx.Grid;
const Cursor = attyx.Cursor;

pub const CommandBlock = struct {
    command: []const u8, // owned, prompt-stripped
    output: []const u8, // owned (empty &.{} if none)
    started_ns: u64, // timestamp when Enter was sent
    finished_ns: u64, // timestamp when next prompt detected
};

pub const State = enum {
    initial,
    at_prompt,
    collecting_output,
    alt_screen,
};

const idle_timeout_ns: u64 = 200_000_000; // 200ms
const max_output: usize = 65536; // 64KB
const ring_size: usize = 32;

pub const CmdCapture = struct {
    allocator: Allocator,
    state: State = .initial,

    // Prompt position (cursor at idle = end of prompt)
    prompt_row: usize = 0,
    prompt_col: usize = 0,

    // Output accumulation (pre-allocated 64KB buffer)
    output_buf: []u8,
    output_len: usize = 0,

    // Pending command (between Enter and finalization)
    pending_command: ?[]const u8 = null,
    pending_started_ns: u64 = 0,

    // Timing
    last_output_ns: u64 = 0,

    // Alt screen tracking
    was_alt_active: bool = false,

    // Ring buffer of completed blocks
    ring: [ring_size]?CommandBlock = .{null} ** ring_size,
    ring_head: usize = 0,
    ring_count: usize = 0,

    pub fn init(allocator: Allocator) !CmdCapture {
        const buf = try allocator.alloc(u8, max_output);
        return .{
            .allocator = allocator,
            .output_buf = buf,
        };
    }

    pub fn deinit(self: *CmdCapture) void {
        if (self.pending_command) |cmd| {
            self.allocator.free(cmd);
            self.pending_command = null;
        }
        for (&self.ring) |*slot| {
            if (slot.*) |block| {
                freeBlock(self.allocator, block);
                slot.* = null;
            }
        }
        self.allocator.free(self.output_buf);
    }

    /// Called from pane.feed() — accumulate output bytes when collecting.
    pub fn notifyOutput(self: *CmdCapture, data: []const u8, now_ns: u64) void {
        self.last_output_ns = now_ns;
        if (self.state == .collecting_output) {
            const remaining = self.output_buf.len - self.output_len;
            const to_copy = @min(data.len, remaining);
            if (to_copy > 0) {
                @memcpy(
                    self.output_buf[self.output_len..][0..to_copy],
                    data[0..to_copy],
                );
                self.output_len += to_copy;
            }
        }
    }

    /// Main tick — call from PTY thread after data processing.
    pub fn tick(
        self: *CmdCapture,
        grid: *const Grid,
        cursor: Cursor,
        alt_active: bool,
        cr: bool,
        now_ns: u64,
    ) void {
        // Handle alt screen transitions
        if (alt_active and !self.was_alt_active) {
            if (self.state == .collecting_output) self.finalize(now_ns);
            self.state = .alt_screen;
        } else if (!alt_active and self.was_alt_active) {
            self.state = .initial;
            self.last_output_ns = now_ns;
        }
        self.was_alt_active = alt_active;

        if (self.state == .alt_screen) return;

        // Consume CR signal
        if (cr) self.handleCR(grid, cursor, now_ns);

        // Check idle timeout
        if (self.last_output_ns > 0 and now_ns > self.last_output_ns) {
            if (now_ns - self.last_output_ns >= idle_timeout_ns) {
                self.handleIdle(cursor, now_ns);
            }
        }
    }

    fn handleCR(self: *CmdCapture, grid: *const Grid, cursor: Cursor, now_ns: u64) void {
        switch (self.state) {
            .at_prompt => {
                // Read command text from grid (after prompt)
                const cmd = readGridText(
                    self.allocator,
                    grid,
                    self.prompt_row,
                    self.prompt_col,
                    cursor.row,
                    cursor.col,
                ) orelse return; // empty command — stay at_prompt
                self.pending_command = cmd;
                self.pending_started_ns = now_ns;
                self.output_len = 0;
                self.state = .collecting_output;
            },
            .collecting_output => {
                // Rapid command: finalize current, go to initial
                // (prompt position unknown after output)
                self.finalize(now_ns);
                self.state = .initial;
                self.last_output_ns = now_ns;
            },
            else => {},
        }
    }

    fn handleIdle(self: *CmdCapture, cursor: Cursor, now_ns: u64) void {
        switch (self.state) {
            .collecting_output => {
                self.finalize(now_ns);
                self.state = .at_prompt;
                self.prompt_row = cursor.row;
                self.prompt_col = cursor.col;
            },
            .initial => {
                self.state = .at_prompt;
                self.prompt_row = cursor.row;
                self.prompt_col = cursor.col;
            },
            else => {},
        }
    }

    fn finalize(self: *CmdCapture, now_ns: u64) void {
        const cmd = self.pending_command orelse return;

        var output: []const u8 = &[_]u8{};
        if (self.output_len > 0) {
            output = self.allocator.dupe(u8, self.output_buf[0..self.output_len]) catch {
                self.allocator.free(cmd);
                self.pending_command = null;
                self.output_len = 0;
                return;
            };
        }

        self.pushBlock(.{
            .command = cmd,
            .output = output,
            .started_ns = self.pending_started_ns,
            .finished_ns = now_ns,
        });

        self.pending_command = null;
        self.output_len = 0;
    }

    fn pushBlock(self: *CmdCapture, block: CommandBlock) void {
        if (self.ring_count >= ring_size) {
            // Evict oldest
            if (self.ring[self.ring_head]) |old| freeBlock(self.allocator, old);
        } else {
            self.ring_count += 1;
        }
        self.ring[self.ring_head] = block;
        self.ring_head = (self.ring_head + 1) % ring_size;
    }

    /// Get block by index (0 = oldest).
    pub fn getBlock(self: *const CmdCapture, index: usize) ?*const CommandBlock {
        if (index >= self.ring_count) return null;
        const oldest = (self.ring_head + ring_size - self.ring_count) % ring_size;
        const actual = (oldest + index) % ring_size;
        return if (self.ring[actual]) |*block| block else null;
    }

    pub fn blockCount(self: *const CmdCapture) usize {
        return self.ring_count;
    }

    fn freeBlock(allocator: Allocator, block: CommandBlock) void {
        if (block.command.len > 0) allocator.free(block.command);
        if (block.output.len > 0) allocator.free(block.output);
    }
};

/// Extract UTF-8 text from grid cells between two positions.
/// Handles soft-wrapped rows, combining marks, and trims trailing spaces.
pub fn readGridText(
    allocator: Allocator,
    grid: *const Grid,
    start_row: usize,
    start_col: usize,
    end_row: usize,
    end_col: usize,
) ?[]const u8 {
    if (end_row < start_row) return null;
    if (end_row == start_row and end_col <= start_col) return null;

    var scratch: [4096]u8 = undefined;
    var pos: usize = 0;

    var row = start_row;
    while (row <= end_row) : (row += 1) {
        if (row >= grid.rows) break;

        const col_start: usize = if (row == start_row) start_col else 0;
        const col_end: usize = if (row == end_row) end_col else grid.cols;

        var col = col_start;
        while (col < col_end) : (col += 1) {
            if (col >= grid.cols) break;
            const cell = grid.getCell(row, col);
            if (cell.char == 0) continue;
            if (pos + 4 > scratch.len) break;
            const n = std.unicode.utf8Encode(cell.char, scratch[pos..]) catch continue;
            pos += n;

            for (cell.combining) |comb| {
                if (comb != 0) {
                    if (pos + 4 > scratch.len) break;
                    const cn = std.unicode.utf8Encode(comb, scratch[pos..]) catch continue;
                    pos += cn;
                }
            }
        }

        // Non-wrapped, non-last rows get a newline separator
        if (row < end_row and !grid.row_wrapped[row]) {
            if (pos < scratch.len) {
                scratch[pos] = '\n';
                pos += 1;
            }
        }
    }

    // Trim trailing whitespace
    while (pos > 0 and (scratch[pos - 1] == ' ' or scratch[pos - 1] == '\n')) {
        pos -= 1;
    }

    if (pos == 0) return null;
    return allocator.dupe(u8, scratch[0..pos]) catch null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "basic capture cycle" {
    const allocator = std.testing.allocator;
    var cap = try CmdCapture.init(allocator);
    defer cap.deinit();

    var grid = try Grid.init(allocator, 5, 20);
    defer grid.deinit();

    // Prompt "$ " at row 0
    grid.setCell(0, 0, .{ .char = '$' });
    grid.setCell(0, 1, .{ .char = ' ' });
    // Command "ls -la"
    grid.setCell(0, 2, .{ .char = 'l' });
    grid.setCell(0, 3, .{ .char = 's' });
    grid.setCell(0, 4, .{ .char = ' ' });
    grid.setCell(0, 5, .{ .char = '-' });
    grid.setCell(0, 6, .{ .char = 'l' });
    grid.setCell(0, 7, .{ .char = 'a' });

    const t0: u64 = 1_000_000_000;

    // Idle -> at_prompt (prompt ends at col 2)
    cap.last_output_ns = t0;
    cap.tick(&grid, .{ .row = 0, .col = 2 }, false, false, t0 + 300_000_000);
    try std.testing.expectEqual(State.at_prompt, cap.state);
    try std.testing.expectEqual(@as(usize, 0), cap.prompt_row);
    try std.testing.expectEqual(@as(usize, 2), cap.prompt_col);

    // CR -> collecting_output (cursor at end of command)
    cap.tick(&grid, .{ .row = 0, .col = 8 }, false, true, t0 + 500_000_000);
    try std.testing.expectEqual(State.collecting_output, cap.state);
    try std.testing.expect(cap.pending_command != null);
    try std.testing.expectEqualStrings("ls -la", cap.pending_command.?);

    // Output arrives
    cap.notifyOutput("file1.txt\nfile2.txt\n", t0 + 600_000_000);

    // Idle -> finalize -> at_prompt
    cap.tick(&grid, .{ .row = 2, .col = 2 }, false, false, t0 + 900_000_000);
    try std.testing.expectEqual(State.at_prompt, cap.state);
    try std.testing.expectEqual(@as(usize, 1), cap.blockCount());

    const block = cap.getBlock(0).?;
    try std.testing.expectEqualStrings("ls -la", block.command);
    try std.testing.expectEqualStrings("file1.txt\nfile2.txt\n", block.output);
}

test "empty command at prompt" {
    const allocator = std.testing.allocator;
    var cap = try CmdCapture.init(allocator);
    defer cap.deinit();

    var grid = try Grid.init(allocator, 5, 20);
    defer grid.deinit();

    grid.setCell(0, 0, .{ .char = '$' });
    grid.setCell(0, 1, .{ .char = ' ' });

    const t0: u64 = 1_000_000_000;

    // Idle -> at_prompt
    cap.last_output_ns = t0;
    cap.tick(&grid, .{ .row = 0, .col = 2 }, false, false, t0 + 300_000_000);
    try std.testing.expectEqual(State.at_prompt, cap.state);

    // CR at prompt position (empty command) -> stays at_prompt
    cap.tick(&grid, .{ .row = 0, .col = 2 }, false, true, t0 + 500_000_000);
    try std.testing.expectEqual(State.at_prompt, cap.state);
    try std.testing.expectEqual(@as(usize, 0), cap.blockCount());
}

test "alt screen pauses capture" {
    const allocator = std.testing.allocator;
    var cap = try CmdCapture.init(allocator);
    defer cap.deinit();

    var grid = try Grid.init(allocator, 5, 20);
    defer grid.deinit();

    const t0: u64 = 1_000_000_000;
    cap.last_output_ns = t0;
    cap.tick(&grid, .{ .row = 0, .col = 2 }, false, false, t0 + 300_000_000);
    try std.testing.expectEqual(State.at_prompt, cap.state);

    // Enter alt screen
    cap.tick(&grid, .{ .row = 0, .col = 0 }, true, false, t0 + 400_000_000);
    try std.testing.expectEqual(State.alt_screen, cap.state);

    // Leave alt screen -> initial
    cap.tick(&grid, .{ .row = 0, .col = 0 }, false, false, t0 + 500_000_000);
    try std.testing.expectEqual(State.initial, cap.state);
}

test "ring buffer overflow" {
    const allocator = std.testing.allocator;
    var cap = try CmdCapture.init(allocator);
    defer cap.deinit();

    // Push 33 blocks, verify oldest is evicted
    for (0..33) |i| {
        var cmd_buf: [16]u8 = undefined;
        const cmd_slice = std.fmt.bufPrint(&cmd_buf, "cmd{d}", .{i}) catch continue;
        const cmd = allocator.dupe(u8, cmd_slice) catch continue;
        cap.pushBlock(.{
            .command = cmd,
            .output = &[_]u8{},
            .started_ns = @intCast(i),
            .finished_ns = @intCast(i + 1),
        });
    }

    try std.testing.expectEqual(@as(usize, 32), cap.blockCount());

    // Oldest should be cmd1 (cmd0 was evicted)
    const oldest = cap.getBlock(0).?;
    try std.testing.expectEqualStrings("cmd1", oldest.command);

    // Newest should be cmd32
    const newest = cap.getBlock(31).?;
    try std.testing.expectEqualStrings("cmd32", newest.command);
}

test "grid text: single row and trailing spaces" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 5, 10);
    defer grid.deinit();

    for ("hello", 0..) |ch, i| {
        grid.setCell(0, i, .{ .char = ch });
    }

    // Exact range
    const t1 = readGridText(allocator, &grid, 0, 0, 0, 5).?;
    defer allocator.free(t1);
    try std.testing.expectEqualStrings("hello", t1);

    // Extended range (trailing spaces trimmed)
    const t2 = readGridText(allocator, &grid, 0, 0, 0, 10).?;
    defer allocator.free(t2);
    try std.testing.expectEqualStrings("hello", t2);

    // Empty range
    try std.testing.expect(readGridText(allocator, &grid, 0, 5, 0, 5) == null);
}

test "grid text: multi-row with soft wrap" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 5, 5);
    defer grid.deinit();

    // "hello" on row 0, soft-wrapped, "world" on row 1
    for ("hello", 0..) |ch, i| grid.setCell(0, i, .{ .char = ch });
    grid.row_wrapped[0] = true;
    for ("world", 0..) |ch, i| grid.setCell(1, i, .{ .char = ch });

    const t = readGridText(allocator, &grid, 0, 0, 1, 5).?;
    defer allocator.free(t);
    try std.testing.expectEqualStrings("helloworld", t);
}

test "grid text: unicode characters" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 5, 10);
    defer grid.deinit();

    // Set cells with Unicode codepoints (e.g. accented characters)
    grid.setCell(0, 0, .{ .char = 0xE9 }); // 'e' with acute: é
    grid.setCell(0, 1, .{ .char = 'x' });

    const t = readGridText(allocator, &grid, 0, 0, 0, 2).?;
    defer allocator.free(t);
    try std.testing.expectEqualStrings("\xc3\xa9x", t); // UTF-8 for "éx"
}
