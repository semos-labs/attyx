const std = @import("std");
const posix = std.posix;
const platform = @import("../platform/platform.zig");
const statusbar_config = @import("../config/statusbar_config.zig");
const StatusbarWidgetConfig = statusbar_config.StatusbarWidgetConfig;
const statusbar = @import("statusbar.zig");
const WidgetState = statusbar.WidgetState;
const max_output_len = statusbar.max_output_len;
const Rgb = statusbar.Rgb;
const ColorSpan = statusbar.ColorSpan;
const max_color_spans = statusbar.max_color_spans;

pub const GitStatus = struct {
    branch: [64]u8 = undefined,
    branch_len: u8 = 0,
    ahead: u16 = 0,
    behind: u16 = 0,
    staged: u16 = 0,
    modified: u16 = 0,
    untracked: u16 = 0,
    stashed: u16 = 0,
    conflict: u16 = 0,
};

const Icons = struct {
    branch: []const u8,
    ahead: []const u8,
    behind: []const u8,
    staged: []const u8,
    modified: []const u8,
    untracked: []const u8,
    stashed: []const u8,
    clean: []const u8,
};

const default_icons = Icons{
    .branch = "⎇ ",
    .ahead = "↑·",
    .behind = "↓·",
    .staged = "● ",
    .modified = "✚ ",
    .untracked = "… ",
    .stashed = "⚑ ",
    .clean = " ✔",
};

const Colors = struct {
    staged: Rgb,
    modified: Rgb,
    untracked: Rgb,
    stashed: Rgb,
    ahead: Rgb,
    behind: Rgb,
    clean: Rgb,
};

/// Parse `git status --porcelain=v2 --branch` output into GitStatus.
pub fn parseGitStatus(stdout: []const u8) GitStatus {
    var status = GitStatus{};
    var iter = std.mem.splitScalar(u8, stdout, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "# branch.head ")) {
            const name = line["# branch.head ".len..];
            const len = @min(name.len, status.branch.len);
            @memcpy(status.branch[0..len], name[0..len]);
            status.branch_len = @intCast(len);
        } else if (std.mem.startsWith(u8, line, "# branch.ab ")) {
            // Format: "# branch.ab +N -M"
            const ab = line["# branch.ab ".len..];
            var parts = std.mem.splitScalar(u8, ab, ' ');
            if (parts.next()) |ahead_str| {
                if (ahead_str.len > 1 and ahead_str[0] == '+') {
                    status.ahead = std.fmt.parseInt(u16, ahead_str[1..], 10) catch 0;
                }
            }
            if (parts.next()) |behind_str| {
                if (behind_str.len > 1 and behind_str[0] == '-') {
                    status.behind = std.fmt.parseInt(u16, behind_str[1..], 10) catch 0;
                }
            }
        } else if (line[0] == '1' or line[0] == '2') {
            // Ordinary/rename entry: "1 XY ..." or "2 XY ..."
            if (line.len >= 4) {
                const x = line[2]; // index status
                const y = line[3]; // worktree status
                if (x != '.' and x != '?') status.staged += 1;
                if (y != '.' and y != '?') status.modified += 1;
            }
        } else if (line[0] == '?') {
            status.untracked += 1;
        } else if (line[0] == 'u') {
            status.conflict += 1;
        }
    }
    return status;
}

/// Count stash entries from `git stash list` output.
pub fn countStashes(output: []const u8) u16 {
    if (output.len == 0) return 0;
    var count: u16 = 0;
    var iter = std.mem.splitScalar(u8, output, '\n');
    while (iter.next()) |line| {
        if (line.len > 0) count += 1;
    }
    return count;
}

/// Resolve icons: use config param overrides or fall back to defaults.
fn resolveIcons(wc: *const StatusbarWidgetConfig) Icons {
    return .{
        .branch = wc.getParam("icon_branch") orelse default_icons.branch,
        .ahead = wc.getParam("icon_ahead") orelse default_icons.ahead,
        .behind = wc.getParam("icon_behind") orelse default_icons.behind,
        .staged = wc.getParam("icon_staged") orelse default_icons.staged,
        .modified = wc.getParam("icon_modified") orelse default_icons.modified,
        .untracked = wc.getParam("icon_untracked") orelse default_icons.untracked,
        .stashed = wc.getParam("icon_stashed") orelse default_icons.stashed,
        .clean = wc.getParam("icon_clean") orelse default_icons.clean,
    };
}

/// Parse a hex color string like "82c378" or "#82c378" into Rgb.
fn parseHexColor(s: []const u8) ?Rgb {
    const hex = if (s.len > 0 and s[0] == '#') s[1..] else s;
    if (hex.len != 6) return null;
    const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null;
    const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null;
    const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null;
    return .{ .r = r, .g = g, .b = b };
}

fn resolveColor(wc: *const StatusbarWidgetConfig, param: []const u8, default: Rgb) Rgb {
    const val = wc.getParam(param) orelse return default;
    return parseHexColor(val) orelse default;
}

/// Resolve colors: config param overrides > theme ANSI palette.
fn resolveColors(wc: *const StatusbarWidgetConfig, pal: *const [16]Rgb) Colors {
    return .{
        .staged = resolveColor(wc, "color_staged", pal[10]), // bright green
        .modified = resolveColor(wc, "color_modified", pal[11]), // bright yellow
        .untracked = resolveColor(wc, "color_untracked", pal[8]), // bright black
        .stashed = resolveColor(wc, "color_stashed", pal[14]), // bright cyan
        .ahead = resolveColor(wc, "color_ahead", pal[10]), // bright green
        .behind = resolveColor(wc, "color_behind", pal[9]), // bright red
        .clean = resolveColor(wc, "color_clean", pal[10]), // bright green
    };
}

/// Format GitStatus into WidgetState output + color spans.
pub fn formatOutput(ws: *WidgetState, status: *const GitStatus, wc: *const StatusbarWidgetConfig, ansi_palette: *const [16]Rgb) void {
    const icons = resolveIcons(wc);
    const colors = resolveColors(wc, ansi_palette);
    var pos: usize = 0;
    ws.span_count = 0;

    // Branch icon + name (default fg, no span)
    pos = appendSlice(&ws.output, pos, icons.branch);
    pos = appendSlice(&ws.output, pos, status.branch[0..status.branch_len]);

    const is_clean = status.staged == 0 and status.modified == 0 and
        status.untracked == 0 and status.conflict == 0;

    if (is_clean) {
        const start = pos;
        pos = appendSlice(&ws.output, pos, icons.clean);
        if (pos > start and ws.span_count < max_color_spans) {
            ws.color_spans[ws.span_count] = .{ .start = @intCast(start), .end = @intCast(pos), .fg = colors.clean };
            ws.span_count += 1;
        }
    }

    // Ahead/behind
    pos = appendCountColored(&ws.output, pos, icons.ahead, status.ahead, colors.ahead, &ws.color_spans, &ws.span_count);
    pos = appendCountColored(&ws.output, pos, icons.behind, status.behind, colors.behind, &ws.color_spans, &ws.span_count);

    // Working tree stats (only when dirty)
    pos = appendCountColored(&ws.output, pos, icons.staged, status.staged, colors.staged, &ws.color_spans, &ws.span_count);
    pos = appendCountColored(&ws.output, pos, icons.modified, status.modified, colors.modified, &ws.color_spans, &ws.span_count);
    pos = appendCountColored(&ws.output, pos, icons.untracked, status.untracked, colors.untracked, &ws.color_spans, &ws.span_count);
    pos = appendCountColored(&ws.output, pos, icons.stashed, status.stashed, colors.stashed, &ws.color_spans, &ws.span_count);

    ws.output_len = @intCast(pos);
}

fn appendSlice(buf: []u8, pos: usize, s: []const u8) usize {
    const len = @min(s.len, buf.len -| pos);
    @memcpy(buf[pos..][0..len], s[0..len]);
    return pos + len;
}

fn appendCountColored(buf: []u8, pos: usize, icon: []const u8, count: u16, color: Rgb, spans: *[max_color_spans]ColorSpan, span_count: *u8) usize {
    if (count == 0) return pos;
    var p = appendSlice(buf, pos, " ");
    const color_start = p;
    p = appendSlice(buf, p, icon);
    var num_buf: [8]u8 = undefined;
    const num = std.fmt.bufPrint(&num_buf, "{d}", .{count}) catch return p;
    p = appendSlice(buf, p, num);
    if (p > color_start and span_count.* < max_color_spans) {
        spans[span_count.*] = .{ .start = @intCast(color_start), .end = @intCast(p), .fg = color };
        span_count.* += 1;
    }
    return p;
}

/// Full refresh: run git commands, parse output, format into WidgetState.
pub fn refresh(ws: *WidgetState, wc: *const StatusbarWidgetConfig, allocator: std.mem.Allocator, master_fd: posix.fd_t, ansi_palette: *const [16]Rgb) void {
    const cwd = platform.getForegroundCwd(allocator, master_fd) orelse return;
    defer allocator.free(cwd);

    // Run git status --porcelain=v2 --branch
    const status_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "status", "--porcelain=v2", "--branch" },
        .cwd = cwd,
        .max_output_bytes = 4096,
    }) catch return;
    defer {
        allocator.free(status_result.stdout);
        allocator.free(status_result.stderr);
    }

    if (status_result.term.Exited != 0) {
        ws.output_len = 0;
        return;
    }

    var status = parseGitStatus(status_result.stdout);

    // Run git stash list for stash count
    const stash_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "stash", "list" },
        .cwd = cwd,
        .max_output_bytes = 4096,
    }) catch {
        // Stash count is optional — continue without it
        formatOutput(ws, &status, wc, ansi_palette);
        return;
    };
    defer {
        allocator.free(stash_result.stdout);
        allocator.free(stash_result.stderr);
    }

    if (stash_result.term.Exited == 0) {
        status.stashed = countStashes(stash_result.stdout);
    }

    formatOutput(ws, &status, wc, ansi_palette);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "parseGitStatus: branch and ahead/behind" {
    const input =
        \\# branch.head main
        \\# branch.ab +3 -1
        \\
    ;
    const s = parseGitStatus(input);
    try std.testing.expectEqualStrings("main", s.branch[0..s.branch_len]);
    try std.testing.expectEqual(@as(u16, 3), s.ahead);
    try std.testing.expectEqual(@as(u16, 1), s.behind);
}

test "parseGitStatus: staged and modified counts" {
    const input =
        \\# branch.head feature
        \\1 M. N... 100644 100644 100644 abc123 def456 file1.zig
        \\1 .M N... 100644 100644 100644 abc123 def456 file2.zig
        \\1 MM N... 100644 100644 100644 abc123 def456 file3.zig
        \\
    ;
    const s = parseGitStatus(input);
    try std.testing.expectEqual(@as(u16, 2), s.staged); // M. and MM
    try std.testing.expectEqual(@as(u16, 2), s.modified); // .M and MM
}

test "parseGitStatus: untracked and conflict" {
    const input =
        \\# branch.head dev
        \\? newfile.txt
        \\? another.txt
        \\u UU N... 100644 100644 100644 100644 abc def ghi conflict.txt
        \\
    ;
    const s = parseGitStatus(input);
    try std.testing.expectEqual(@as(u16, 2), s.untracked);
    try std.testing.expectEqual(@as(u16, 1), s.conflict);
}

test "parseGitStatus: rename entry" {
    const input =
        \\# branch.head main
        \\2 R. N... 100644 100644 abc123 def456 R100 old.zig\tnew.zig
        \\
    ;
    const s = parseGitStatus(input);
    try std.testing.expectEqual(@as(u16, 1), s.staged); // R in index
    try std.testing.expectEqual(@as(u16, 0), s.modified); // . in worktree
}

test "countStashes: counts lines" {
    const input = "stash@{0}: WIP on main: abc123 message\nstash@{1}: WIP on main: def456 msg\n";
    try std.testing.expectEqual(@as(u16, 2), countStashes(input));
}

test "countStashes: empty output" {
    try std.testing.expectEqual(@as(u16, 0), countStashes(""));
}

test "formatOutput: clean repo shows branch + clean icon" {
    var status = GitStatus{};
    const branch = "main";
    @memcpy(status.branch[0..branch.len], branch);
    status.branch_len = branch.len;

    const wc = StatusbarWidgetConfig{ .name = "git" };
    var ws = WidgetState{};
    formatOutput(&ws, &status, &wc, &statusbar.default_ansi_palette);
    const output = ws.output[0..ws.output_len];
    // Should contain branch icon, branch name, and clean icon
    try std.testing.expect(std.mem.indexOf(u8, output, "main") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, default_icons.clean) != null);
    // Should NOT contain dirty indicators
    try std.testing.expect(std.mem.indexOf(u8, output, default_icons.modified) == null);
}

test "formatOutput: dirty repo shows counts" {
    var status = GitStatus{};
    const branch = "dev";
    @memcpy(status.branch[0..branch.len], branch);
    status.branch_len = branch.len;
    status.staged = 3;
    status.modified = 2;
    status.untracked = 1;
    status.ahead = 1;
    status.behind = 2;
    status.stashed = 1;

    const wc = StatusbarWidgetConfig{ .name = "git" };
    var ws = WidgetState{};
    formatOutput(&ws, &status, &wc, &statusbar.default_ansi_palette);
    const output = ws.output[0..ws.output_len];

    try std.testing.expect(std.mem.indexOf(u8, output, "dev") != null);
    // Clean icon should NOT appear
    try std.testing.expect(std.mem.indexOf(u8, output, default_icons.clean) == null);
    // Counts should appear
    try std.testing.expect(std.mem.indexOf(u8, output, "3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "1") != null);
}

test "formatOutput: omits zero-count sections" {
    var status = GitStatus{};
    const branch = "main";
    @memcpy(status.branch[0..branch.len], branch);
    status.branch_len = branch.len;
    status.modified = 5; // only modified

    const wc = StatusbarWidgetConfig{ .name = "git" };
    var ws = WidgetState{};
    formatOutput(&ws, &status, &wc, &statusbar.default_ansi_palette);
    const output = ws.output[0..ws.output_len];

    // Modified should appear, but not staged/untracked/stashed icons
    try std.testing.expect(std.mem.indexOf(u8, output, default_icons.modified) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, default_icons.staged) == null);
    try std.testing.expect(std.mem.indexOf(u8, output, default_icons.untracked) == null);
    try std.testing.expect(std.mem.indexOf(u8, output, default_icons.stashed) == null);
}

test "formatOutput: custom icons from config" {
    var status = GitStatus{};
    const branch = "main";
    @memcpy(status.branch[0..branch.len], branch);
    status.branch_len = branch.len;
    status.modified = 1;

    var wc = StatusbarWidgetConfig{ .name = "git" };
    wc.params[0] = .{ .key = "icon_branch", .value = "B:" };
    wc.params[1] = .{ .key = "icon_modified", .value = "M:" };
    wc.param_count = 2;

    var ws = WidgetState{};
    formatOutput(&ws, &status, &wc, &statusbar.default_ansi_palette);
    const output = ws.output[0..ws.output_len];

    try std.testing.expect(std.mem.startsWith(u8, output, "B:main"));
    try std.testing.expect(std.mem.indexOf(u8, output, "M:1") != null);
}

test "formatOutput: color spans for dirty repo stats" {
    var status = GitStatus{};
    const branch = "main";
    @memcpy(status.branch[0..branch.len], branch);
    status.branch_len = branch.len;
    status.staged = 2;
    status.modified = 1;

    const wc = StatusbarWidgetConfig{ .name = "git" };
    var ws = WidgetState{};
    formatOutput(&ws, &status, &wc, &statusbar.default_ansi_palette);

    // Should have 2 color spans: staged + modified
    const pal = statusbar.default_ansi_palette;
    try std.testing.expectEqual(@as(u8, 2), ws.span_count);
    // First span (staged) should be bright green (ANSI 10)
    try std.testing.expectEqual(pal[10].r, ws.color_spans[0].fg.r);
    try std.testing.expectEqual(pal[10].g, ws.color_spans[0].fg.g);
    // Second span (modified) should be bright yellow (ANSI 11)
    try std.testing.expectEqual(pal[11].r, ws.color_spans[1].fg.r);
    try std.testing.expectEqual(pal[11].g, ws.color_spans[1].fg.g);
}

test "formatOutput: clean repo has clean color span" {
    var status = GitStatus{};
    const branch = "main";
    @memcpy(status.branch[0..branch.len], branch);
    status.branch_len = branch.len;

    const wc = StatusbarWidgetConfig{ .name = "git" };
    var ws = WidgetState{};
    formatOutput(&ws, &status, &wc, &statusbar.default_ansi_palette);

    // Clean repo should have 1 span for the clean icon (bright green = ANSI 10)
    try std.testing.expectEqual(@as(u8, 1), ws.span_count);
    try std.testing.expectEqual(statusbar.default_ansi_palette[10].r, ws.color_spans[0].fg.r);
}

test "parseHexColor: valid 6-digit hex" {
    const c = parseHexColor("82c378").?;
    try std.testing.expectEqual(@as(u8, 0x82), c.r);
    try std.testing.expectEqual(@as(u8, 0xc3), c.g);
    try std.testing.expectEqual(@as(u8, 0x78), c.b);
}

test "parseHexColor: with # prefix" {
    const c = parseHexColor("#ff0000").?;
    try std.testing.expectEqual(@as(u8, 255), c.r);
    try std.testing.expectEqual(@as(u8, 0), c.g);
    try std.testing.expectEqual(@as(u8, 0), c.b);
}

test "parseHexColor: rejects invalid input" {
    try std.testing.expect(parseHexColor("fff") == null);
    try std.testing.expect(parseHexColor("zzzzzz") == null);
    try std.testing.expect(parseHexColor("") == null);
}

test "formatOutput: custom colors from config" {
    var status = GitStatus{};
    const branch = "main";
    @memcpy(status.branch[0..branch.len], branch);
    status.branch_len = branch.len;
    status.modified = 1;

    var wc = StatusbarWidgetConfig{ .name = "git" };
    wc.params[0] = .{ .key = "color_modified", .value = "ff0000" };
    wc.param_count = 1;

    var ws = WidgetState{};
    formatOutput(&ws, &status, &wc, &statusbar.default_ansi_palette);

    try std.testing.expectEqual(@as(u8, 1), ws.span_count);
    try std.testing.expectEqual(@as(u8, 255), ws.color_spans[0].fg.r);
    try std.testing.expectEqual(@as(u8, 0), ws.color_spans[0].fg.g);
    try std.testing.expectEqual(@as(u8, 0), ws.color_spans[0].fg.b);
}
