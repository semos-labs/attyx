const std = @import("std");
const ring_mod = @import("../term/ring.zig");
const extract = @import("context_extract.zig");

const RingBuffer = ring_mod.RingBuffer;

/// Why the AI overlay was invoked. Determines which context fields are
/// populated and how the backend (future) interprets them.
pub const InvocationType = enum(u8) {
    error_explain,
    selection_explain,
    command_generate,
    general,
    edit_selection,
};

/// Immutable snapshot of terminal context captured at AI invocation time.
/// All string fields are owned by the allocator passed to `captureContext`;
/// call `deinit()` to free them.
pub const ContextBundle = struct {
    invocation: InvocationType,
    title: ?[]const u8,
    selection_text: ?[]const u8,
    scrollback_excerpt: ?[]const u8,
    scrollback_line_count: u16,
    cursor_line: ?[]const u8,
    grid_cols: u16,
    grid_rows: u16,
    alt_active: bool,
    edit_prompt: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ContextBundle) void {
        if (self.title) |t| self.allocator.free(t);
        if (self.selection_text) |s| self.allocator.free(s);
        if (self.scrollback_excerpt) |e| self.allocator.free(e);
        if (self.cursor_line) |cl| self.allocator.free(cl);
        if (self.edit_prompt) |ep| self.allocator.free(ep);
        self.* = undefined;
    }

    /// Format a one-line summary into `buf`. Returns the populated slice.
    /// Example: "Context: vim + selection + last 80 lines"
    pub fn summaryLine(self: *const ContextBundle, buf: []u8) []const u8 {
        var stream = std.io.fixedBufferStream(buf);
        const w = stream.writer();
        w.writeAll("Context:") catch return buf[0..0];
        var parts: u8 = 0;

        if (self.title) |t| {
            if (t.len > 0) {
                if (parts > 0) w.writeAll(" +") catch {};
                w.writeAll(" ") catch {};
                const max_title = @min(t.len, 20);
                w.writeAll(t[0..max_title]) catch {};
                if (t.len > 20) w.writeAll("...") catch {};
                parts += 1;
            }
        }

        if (self.selection_text != null) {
            if (parts > 0) w.writeAll(" +") catch {};
            w.writeAll(" selection") catch {};
            parts += 1;
        }

        if (self.scrollback_line_count > 0) {
            if (parts > 0) w.writeAll(" +") catch {};
            w.writeAll(" last ") catch {};
            w.print("{d}", .{self.scrollback_line_count}) catch {};
            w.writeAll(" lines") catch {};
            parts += 1;
        }

        if (self.edit_prompt != null) {
            if (parts > 0) w.writeAll(" +") catch {};
            w.writeAll(" edit") catch {};
            parts += 1;
        }

        if (parts == 0) {
            w.writeAll(" (empty)") catch {};
        }

        return buf[0..stream.pos];
    }

    /// Serialize the context bundle into a human-readable diagnostics string.
    /// Caller owns the returned slice and must free it with `self.allocator`.
    pub fn serializeDiagnostics(self: *const ContextBundle) ![]u8 {
        var list: std.ArrayList(u8) = .{};
        errdefer list.deinit(self.allocator);
        const w = list.writer(self.allocator);

        try w.writeAll("=== Attyx Context Diagnostics ===\n");

        // Invocation type
        try w.writeAll("Invocation: ");
        try w.writeAll(switch (self.invocation) {
            .error_explain => "error_explain",
            .selection_explain => "selection_explain",
            .command_generate => "command_generate",
            .general => "general",
            .edit_selection => "edit_selection",
        });
        try w.writeByte('\n');

        // Grid dimensions
        try w.print("Grid: {d}x{d}", .{ self.grid_cols, self.grid_rows });
        if (self.alt_active) try w.writeAll(" (alt screen)");
        try w.writeByte('\n');

        // Title
        if (self.title) |t| {
            if (t.len > 0) {
                try w.writeAll("Title: ");
                try w.writeAll(t);
                try w.writeByte('\n');
            }
        }

        // Cursor line
        try w.writeAll("\n--- Cursor Line ---\n");
        if (self.cursor_line) |cl| {
            try w.writeAll(cl);
            try w.writeByte('\n');
        } else {
            try w.writeAll("(none)\n");
        }

        // Edit prompt
        if (self.edit_prompt) |ep| {
            try w.writeAll("Edit prompt: ");
            try w.writeAll(ep);
            try w.writeByte('\n');
        }

        // Selection
        try w.writeAll("\n--- Selection ---\n");
        if (self.selection_text) |sel| {
            try w.writeAll(sel);
            try w.writeByte('\n');
        } else {
            try w.writeAll("(none)\n");
        }

        // Scrollback
        try w.print("\n--- Scrollback ({d} lines) ---\n", .{self.scrollback_line_count});
        if (self.scrollback_excerpt) |exc| {
            try w.writeAll(exc);
            if (exc.len > 0 and exc[exc.len - 1] != '\n') try w.writeByte('\n');
        } else {
            try w.writeAll("(none)\n");
        }

        return try list.toOwnedSlice(self.allocator);
    }
};

/// Capture a context bundle from terminal state. Called from the PTY thread.
///
/// `ring`: the unified ring buffer (scrollback + visible screen).
/// `cursor_row`: current cursor screen row.
/// `title_buf` / `title_len`: the terminal's current OSC 2 title.
/// `sel_bounds`: non-null when a selection is active.
/// `excerpt_lines`: how many recent lines to include (scrollback + screen).
pub fn captureContext(
    allocator: std.mem.Allocator,
    ring: *const RingBuffer,
    cursor_row: usize,
    title_buf: ?[*]const u8,
    title_len: usize,
    sel_bounds: ?extract.SelBounds,
    excerpt_lines: u16,
    alt_active: bool,
) !ContextBundle {
    // Title (copy from C buffer)
    var title: ?[]u8 = null;
    if (title_buf) |tbuf| {
        if (title_len > 0) {
            title = try allocator.alloc(u8, title_len);
            @memcpy(title.?, tbuf[0..title_len]);
        }
    }
    errdefer if (title) |t| allocator.free(t);

    // Selection text
    var selection_text: ?[]u8 = null;
    if (sel_bounds) |sel| {
        selection_text = try extract.extractSelectionText(allocator, ring, sel);
        if (selection_text.?.len == 0) {
            allocator.free(selection_text.?);
            selection_text = null;
        }
    }
    errdefer if (selection_text) |s| allocator.free(s);

    // Scrollback excerpt
    var scrollback_excerpt: ?[]u8 = null;
    var scrollback_line_count: u16 = 0;
    if (!alt_active and excerpt_lines > 0) {
        const result = try extract.extractScrollbackExcerpt(allocator, ring, excerpt_lines);
        scrollback_line_count = result.line_count;
        if (result.text.len > 0) {
            scrollback_excerpt = result.text;
        } else {
            allocator.free(result.text);
        }
    }
    errdefer if (scrollback_excerpt) |e| allocator.free(e);

    // Cursor line
    var cursor_line: ?[]u8 = null;
    if (cursor_row < ring.screen_rows) {
        cursor_line = try extract.extractLineFromRing(allocator, ring, cursor_row);
        if (cursor_line.?.len == 0) {
            allocator.free(cursor_line.?);
            cursor_line = null;
        }
    }

    return .{
        .invocation = if (sel_bounds != null) .selection_explain else .general,
        .title = title,
        .selection_text = selection_text,
        .scrollback_excerpt = scrollback_excerpt,
        .scrollback_line_count = scrollback_line_count,
        .cursor_line = cursor_line,
        .grid_cols = @intCast(ring.cols),
        .grid_rows = @intCast(ring.screen_rows),
        .alt_active = alt_active,
        .allocator = allocator,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "captureContext: basic bundle" {
    var ring = try RingBuffer.init(std.testing.allocator, 3, 10, 10);
    defer ring.deinit();

    ring.setScreenCell(1, 0, .{ .char = '$' });
    ring.setScreenCell(1, 1, .{ .char = ' ' });

    var bundle = try captureContext(
        std.testing.allocator,
        &ring,
        1, // cursor on row 1
        null,
        0,
        null,
        10,
        false,
    );
    defer bundle.deinit();

    try std.testing.expectEqual(InvocationType.general, bundle.invocation);
    try std.testing.expectEqual(@as(?[]const u8, null), bundle.title);
    try std.testing.expectEqual(@as(?[]const u8, null), bundle.selection_text);
    try std.testing.expect(bundle.cursor_line != null);
    try std.testing.expectEqualStrings("$", bundle.cursor_line.?);
    try std.testing.expectEqual(@as(u16, 10), bundle.grid_cols);
}

test "captureContext: with title and selection" {
    var ring = try RingBuffer.init(std.testing.allocator, 3, 10, 10);
    defer ring.deinit();

    ring.setScreenCell(0, 0, .{ .char = 'H' });
    ring.setScreenCell(0, 1, .{ .char = 'i' });

    const title_str = "vim";
    var bundle = try captureContext(
        std.testing.allocator,
        &ring,
        0,
        title_str.ptr,
        title_str.len,
        .{ .start_row = 0, .start_col = 0, .end_row = 0, .end_col = 1 },
        10,
        false,
    );
    defer bundle.deinit();

    try std.testing.expectEqual(InvocationType.selection_explain, bundle.invocation);
    try std.testing.expectEqualStrings("vim", bundle.title.?);
    try std.testing.expectEqualStrings("Hi", bundle.selection_text.?);
}

test "ContextBundle: summaryLine formatting" {
    var ring = try RingBuffer.init(std.testing.allocator, 2, 5, 10);
    defer ring.deinit();

    ring.setScreenCell(0, 0, .{ .char = 'X' });

    const title_str = "bash";
    var bundle = try captureContext(
        std.testing.allocator,
        &ring,
        0,
        title_str.ptr,
        title_str.len,
        null,
        5,
        false,
    );
    defer bundle.deinit();

    var buf: [128]u8 = undefined;
    const summary = bundle.summaryLine(&buf);
    try std.testing.expect(std.mem.startsWith(u8, summary, "Context:"));
    try std.testing.expect(std.mem.indexOf(u8, summary, "bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "lines") != null);
}

test "ContextBundle: serializeDiagnostics" {
    const alloc = std.testing.allocator;
    var bundle = ContextBundle{
        .invocation = .general,
        .title = "bash",
        .selection_text = null,
        .scrollback_excerpt = "line1\nline2",
        .scrollback_line_count = 80,
        .cursor_line = "$ ls -la",
        .grid_cols = 80,
        .grid_rows = 24,
        .alt_active = false,
        .allocator = alloc,
    };

    const diag_text = try bundle.serializeDiagnostics();
    defer alloc.free(diag_text);

    try std.testing.expect(std.mem.indexOf(u8, diag_text, "=== Attyx Context Diagnostics ===") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag_text, "Invocation: general") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag_text, "Grid: 80x24") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag_text, "Title: bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag_text, "$ ls -la") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag_text, "line1\nline2") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag_text, "80 lines") != null);
}

test "ContextBundle: deinit frees correctly" {
    var ring = try RingBuffer.init(std.testing.allocator, 2, 5, 10);
    defer ring.deinit();

    ring.setScreenCell(0, 0, .{ .char = 'A' });

    var bundle = try captureContext(
        std.testing.allocator,
        &ring,
        0,
        null,
        0,
        null,
        2,
        false,
    );
    // Explicit deinit -- testing allocator will catch leaks
    bundle.deinit();
}
