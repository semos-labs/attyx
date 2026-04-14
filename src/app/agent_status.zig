const std = @import("std");
const attyx = @import("attyx");
const Pane = @import("pane.zig").Pane;
const tab_manager = @import("tab_manager.zig");
const Cell = attyx.grid.Cell;

pub const AgentStatus = enum(u3) {
    none,
    generic,
    idle,
    running,
    waiting,
};

pub const AgentStatuses = [tab_manager.max_tabs]AgentStatus;

pub fn shouldQueryProcessName(display_title: ?[]const u8, osc_title: ?[]const u8, daemon_name: ?[]const u8) bool {
    return display_title == null and osc_title == null and daemon_name == null;
}

pub fn looksLikeAgentText(maybe_text: ?[]const u8) bool {
    const text = maybe_text orelse return false;
    return looksLikeGenericAgent(text);
}

const DetectionContext = struct {
    pane: *const Pane,
    display_title: ?[]const u8,
    process_name: ?[]const u8,
    daemon_name: ?[]const u8,
    osc_title: ?[]const u8,
};

const Detector = struct {
    matchesFn: *const fn (ctx: DetectionContext) bool,
    detectFn: *const fn (ctx: DetectionContext) AgentStatus,
};

const detectors = [_]Detector{
    .{ .matchesFn = matchesOpenCode, .detectFn = detectOpenCode },
    .{ .matchesFn = matchesClaude, .detectFn = detectClaude },
};

pub fn detectPaneStatus(pane: *const Pane, display_title: ?[]const u8, process_name: ?[]const u8) AgentStatus {
    const ctx = DetectionContext{
        .pane = pane,
        .display_title = display_title,
        .process_name = process_name,
        .daemon_name = pane.getDaemonProcName(),
        .osc_title = pane.engine.state.title,
    };

    if (prefixedStatus(ctx.display_title) orelse prefixedStatus(ctx.osc_title) orelse prefixedStatus(ctx.process_name) orelse prefixedStatus(ctx.daemon_name)) |status| {
        return status;
    }

    for (detectors) |detector| {
        if (detector.matchesFn(ctx)) return detector.detectFn(ctx);
    }

    const is_generic_agent = looksLikeGenericAgent(ctx.display_title) or
        looksLikeGenericAgent(ctx.osc_title) or
        looksLikeGenericAgent(ctx.process_name) or
        looksLikeGenericAgent(ctx.daemon_name);
    if (is_generic_agent) return .generic;

    return .none;
}

fn matchesOpenCode(ctx: DetectionContext) bool {
    return looksLikeOpenCode(ctx.display_title) or
        looksLikeOpenCode(ctx.osc_title) or
        looksLikeOpenCode(ctx.process_name) or
        looksLikeOpenCode(ctx.daemon_name);
}

fn detectOpenCode(ctx: DetectionContext) AgentStatus {
    if (hasOpenCodeBusyIndicator(ctx.pane)) return .running;
    if (hasOpenCodeWaitingIndicator(ctx.pane)) return .waiting;
    return .idle;
}

fn matchesClaude(ctx: DetectionContext) bool {
    return looksLikeClaude(ctx.display_title) or
        looksLikeClaude(ctx.osc_title) or
        looksLikeClaude(ctx.process_name) or
        looksLikeClaude(ctx.daemon_name);
}

fn detectClaude(ctx: DetectionContext) AgentStatus {
    if (hasClaudeBusyIndicator(ctx.pane)) return .running;
    if (hasClaudeWaitingIndicator(ctx.pane)) return .waiting;
    return .idle;
}

fn prefixedStatus(maybe_text: ?[]const u8) ?AgentStatus {
    const text = maybe_text orelse return null;
    const marker_bytes = std.unicode.utf8ByteSequenceLength(text[0]) catch return null;
    if (text.len <= marker_bytes) return null;
    const marker = std.unicode.utf8Decode(text[0..marker_bytes]) catch return null;
    const marker_len = std.unicode.utf8CodepointSequenceLength(marker) catch return null;
    if (text.len <= marker_len or text[marker_len] != ' ') return null;
    return switch (marker) {
        0x25CB => .idle,
        0x25CF => .waiting,
        else => if (std.mem.startsWith(u8, text, "✻ ")) .running else null,
    };
}

fn looksLikeOpenCode(maybe_text: ?[]const u8) bool {
    const text = maybe_text orelse return false;
    return startsWithIgnoreCase(text, "OC |") or
        containsIgnoreCase(text, "OpenCode") or
        std.ascii.eqlIgnoreCase(text, "opencode") or
        startsWithIgnoreCase(text, "opencode ");
}

fn looksLikeGenericAgent(maybe_text: ?[]const u8) bool {
    const text = maybe_text orelse return false;
    return looksLikeOpenCode(text) or
        looksLikeClaude(text);
}

fn looksLikeClaude(maybe_text: ?[]const u8) bool {
    const text = maybe_text orelse return false;
    return containsIgnoreCase(text, "Claude Code") or
        containsIgnoreCase(text, "claude-code") or
        std.ascii.eqlIgnoreCase(text, "claude") or
        startsWithIgnoreCase(text, "claude ");
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn hasOpenCodeBusyIndicator(pane: *const Pane) bool {
    const busy_patterns = [_][]const u8{
        "esc interrupt",
        "esc to exit",
        "thinking...",
        "generating...",
        "building tool call...",
        "waiting for tool response...",
    };
    for (busy_patterns) |pattern| {
        if (screenContainsAsciiIgnoreCase(pane, pattern)) return true;
    }
    return false;
}

fn hasOpenCodeWaitingIndicator(pane: *const Pane) bool {
    const prompt_patterns = [_][]const u8{
        "ask anything",
        "press enter to send",
        "enter submit",
        "esc dismiss",
    };
    for (prompt_patterns) |pattern| {
        if (screenContainsAsciiIgnoreCase(pane, pattern)) return true;
    }
    return lastPromptLineEndsWithGreaterThan(pane);
}

fn hasClaudeBusyIndicator(pane: *const Pane) bool {
    const busy_patterns = [_][]const u8{
        "ctrl+c to interrupt",
        "esc to interrupt",
    };
    for (busy_patterns) |pattern| {
        if (screenContainsAsciiIgnoreCase(pane, pattern)) return true;
    }
    return screenHasClaudeSpinnerLine(pane);
}

fn hasClaudeWaitingIndicator(pane: *const Pane) bool {
    const waiting_patterns = [_][]const u8{
        "enter to select",
        "press enter to select",
        "use arrow keys to navigate",
        "yes, allow once",
        "yes, allow always",
        "allow once",
        "allow always",
        "no, and tell claude what to do differently",
        "continue?",
        "proceed?",
    };
    for (waiting_patterns) |pattern| {
        if (screenContainsAsciiIgnoreCase(pane, pattern)) return true;
    }
    return lastPromptLineEndsWithAny(pane, &[_]u21{ '>', 0x203A, 0x276F });
}

fn screenContainsAsciiIgnoreCase(pane: *const Pane, pattern: []const u8) bool {
    const ring = &pane.engine.state.ring;
    for (0..ring.screen_rows) |row_idx| {
        if (rowContainsAsciiIgnoreCase(ring.getScreenRow(row_idx), pattern)) return true;
    }
    return false;
}

fn rowContainsAsciiIgnoreCase(row: []const Cell, pattern: []const u8) bool {
    if (pattern.len == 0) return true;
    if (row.len < pattern.len) return false;

    var start: usize = 0;
    while (start + pattern.len <= row.len) : (start += 1) {
        var matched = true;
        for (pattern, 0..) |expected, offset| {
            const ch = row[start + offset].char;
            if (ch > 0x7f or std.ascii.toLower(@as(u8, @intCast(ch))) != std.ascii.toLower(expected)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }

    return false;
}

fn screenHasClaudeSpinnerLine(pane: *const Pane) bool {
    const spinner_runes = [_]u21{
        '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏',
        '✳', '✽', '✶', '✢', '✻', '·',
    };
    const ring = &pane.engine.state.ring;
    for (0..ring.screen_rows) |row_idx| {
        const row = ring.getScreenRow(row_idx);
        if (rowHasAnyRune(row, &spinner_runes) and rowHasRune(row, '…')) return true;
    }
    return false;
}

fn rowHasAnyRune(row: []const Cell, runes: []const u21) bool {
    for (row) |cell| {
        for (runes) |rune| {
            if (cell.char == rune) return true;
        }
    }
    return false;
}

fn rowHasRune(row: []const Cell, rune: u21) bool {
    for (row) |cell| {
        if (cell.char == rune) return true;
    }
    return false;
}

fn lastPromptLineEndsWithGreaterThan(pane: *const Pane) bool {
    return lastPromptLineEndsWithAny(pane, &[_]u21{'>'});
}

fn lastPromptLineEndsWithAny(pane: *const Pane, runes: []const u21) bool {
    const ring = &pane.engine.state.ring;
    const row_count = ring.screen_rows;
    const start = row_count -| 5;
    var row_idx = row_count;
    while (row_idx > start) {
        row_idx -= 1;
        const row = ring.getScreenRow(row_idx);
        var col = row.len;
        while (col > 0) {
            col -= 1;
            const ch = row[col].char;
            if (ch == ' ') continue;
            for (runes) |rune| {
                if (ch == rune) return true;
            }
            return false;
        }
    }
    return false;
}

test "detectPaneStatus finds generic OpenCode tab from title" {
    var pane = try Pane.initDaemonBacked(std.testing.allocator, 4, 20, 10);
    defer pane.deinit();

    try std.testing.expectEqual(AgentStatus.idle, detectPaneStatus(&pane, "OC | review", null));
}

test "detectPaneStatus finds OpenCode busy markers on screen" {
    var pane = try Pane.initDaemonBacked(std.testing.allocator, 4, 40, 10);
    defer pane.deinit();
    pane.feed("Thinking...");

    try std.testing.expectEqual(AgentStatus.running, detectPaneStatus(&pane, "OC | review", null));
}

test "detectPaneStatus finds OpenCode waiting prompt on screen" {
    var pane = try Pane.initDaemonBacked(std.testing.allocator, 4, 40, 10);
    defer pane.deinit();
    pane.feed("enter submit");

    try std.testing.expectEqual(AgentStatus.waiting, detectPaneStatus(&pane, "OC | review", null));
}

test "detectPaneStatus leaves non-agent tabs alone" {
    var pane = try Pane.initDaemonBacked(std.testing.allocator, 4, 20, 10);
    defer pane.deinit();

    try std.testing.expectEqual(AgentStatus.none, detectPaneStatus(&pane, "zsh", null));
}

test "detectPaneStatus finds Claude idle from title" {
    var pane = try Pane.initDaemonBacked(std.testing.allocator, 4, 20, 10);
    defer pane.deinit();

    try std.testing.expectEqual(AgentStatus.idle, detectPaneStatus(&pane, "claude", null));
}

test "detectPaneStatus finds Claude busy markers on screen" {
    var pane = try Pane.initDaemonBacked(std.testing.allocator, 4, 40, 10);
    defer pane.deinit();
    pane.feed("ctrl+c to interrupt");

    try std.testing.expectEqual(AgentStatus.running, detectPaneStatus(&pane, "claude", null));
}

test "detectPaneStatus finds Claude waiting prompt on screen" {
    var pane = try Pane.initDaemonBacked(std.testing.allocator, 4, 40, 10);
    defer pane.deinit();
    pane.feed("Enter to select");

    try std.testing.expectEqual(AgentStatus.waiting, detectPaneStatus(&pane, "claude", null));
}

test "shouldQueryProcessName only falls back with no cheap hints" {
    try std.testing.expect(shouldQueryProcessName(null, null, null));
    try std.testing.expect(!shouldQueryProcessName("OC | review", null, null));
    try std.testing.expect(!shouldQueryProcessName(null, "claude", null));
    try std.testing.expect(!shouldQueryProcessName(null, null, "claude"));
}
