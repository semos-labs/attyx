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
    oid: [40]u8 = undefined,
    oid_len: u8 = 0,
    detached: bool = false,
    ahead: u16 = 0,
    behind: u16 = 0,
    staged: u16 = 0,
    modified: u16 = 0,
    untracked: u16 = 0,
    stashed: u16 = 0,
    conflict: u16 = 0,
    insertions: u32 = 0,
    deletions: u32 = 0,
};

const Icons = struct {
    branch: []const u8,
    hashprefix: []const u8,
    ahead: []const u8,
    behind: []const u8,
    staged: []const u8,
    modified: []const u8,
    untracked: []const u8,
    conflict: []const u8,
    stashed: []const u8,
    clean: []const u8,
    insertions: []const u8,
    deletions: []const u8,
};

const default_icons = Icons{
    .branch = "⎇ ",
    .hashprefix = "#",
    .ahead = "↑·",
    .behind = "↓·",
    .staged = "● ",
    .modified = "✚ ",
    .untracked = "… ",
    .conflict = "✖ ",
    .stashed = "⚑ ",
    .clean = " ✔",
    .insertions = "+",
    .deletions = "-",
};

const Colors = struct {
    staged: Rgb,
    modified: Rgb,
    untracked: Rgb,
    conflict: Rgb,
    stashed: Rgb,
    ahead: Rgb,
    behind: Rgb,
    clean: Rgb,
    insertions: Rgb,
    deletions: Rgb,
};

/// Parse `git status --porcelain=v2 --branch` output into GitStatus.
pub fn parseGitStatus(stdout: []const u8) GitStatus {
    var status = GitStatus{};
    var iter = std.mem.splitScalar(u8, stdout, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "# branch.head ")) {
            const name = line["# branch.head ".len..];
            if (std.mem.eql(u8, name, "(detached)")) {
                status.detached = true;
            } else {
                const len = @min(name.len, status.branch.len);
                @memcpy(status.branch[0..len], name[0..len]);
                status.branch_len = @intCast(len);
            }
        } else if (std.mem.startsWith(u8, line, "# branch.oid ")) {
            const oid = line["# branch.oid ".len..];
            const len = @min(oid.len, status.oid.len);
            @memcpy(status.oid[0..len], oid[0..len]);
            status.oid_len = @intCast(len);
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

/// Parse `git diff --numstat` output into total insertions/deletions.
pub fn parseDiffNumstat(stdout: []const u8) struct { insertions: u32, deletions: u32 } {
    var ins: u32 = 0;
    var del: u32 = 0;
    var iter = std.mem.splitScalar(u8, stdout, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        var parts = std.mem.splitScalar(u8, line, '\t');
        if (parts.next()) |i_str| {
            ins += std.fmt.parseInt(u32, i_str, 10) catch continue;
            if (parts.next()) |d_str| {
                del += std.fmt.parseInt(u32, d_str, 10) catch 0;
            }
        }
    }
    return .{ .insertions = ins, .deletions = del };
}

/// Resolve icons: use config param overrides or fall back to defaults.
fn resolveIcons(wc: *const StatusbarWidgetConfig) Icons {
    return .{
        .branch = wc.getParam("icon_branch") orelse default_icons.branch,
        .hashprefix = wc.getParam("icon_hashprefix") orelse default_icons.hashprefix,
        .ahead = wc.getParam("icon_ahead") orelse default_icons.ahead,
        .behind = wc.getParam("icon_behind") orelse default_icons.behind,
        .staged = wc.getParam("icon_staged") orelse default_icons.staged,
        .modified = wc.getParam("icon_modified") orelse default_icons.modified,
        .untracked = wc.getParam("icon_untracked") orelse default_icons.untracked,
        .conflict = wc.getParam("icon_conflict") orelse default_icons.conflict,
        .stashed = wc.getParam("icon_stashed") orelse default_icons.stashed,
        .clean = wc.getParam("icon_clean") orelse default_icons.clean,
        .insertions = wc.getParam("icon_insertions") orelse default_icons.insertions,
        .deletions = wc.getParam("icon_deletions") orelse default_icons.deletions,
    };
}

/// Parse a hex color string like "82c378" or "#82c378" into Rgb.
pub fn parseHexColor(s: []const u8) ?Rgb {
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
        .conflict = resolveColor(wc, "color_conflict", pal[9]), // bright red
        .stashed = resolveColor(wc, "color_stashed", pal[14]), // bright cyan
        .ahead = resolveColor(wc, "color_ahead", pal[10]), // bright green
        .behind = resolveColor(wc, "color_behind", pal[9]), // bright red
        .clean = resolveColor(wc, "color_clean", pal[10]), // bright green
        .insertions = resolveColor(wc, "color_insertions", pal[10]), // bright green
        .deletions = resolveColor(wc, "color_deletions", pal[9]), // bright red
    };
}

/// Format GitStatus into WidgetState output + color spans.
pub fn formatOutput(ws: *WidgetState, status: *const GitStatus, wc: *const StatusbarWidgetConfig, ansi_palette: *const [16]Rgb) void {
    const icons = resolveIcons(wc);
    const colors = resolveColors(wc, ansi_palette);
    var pos: usize = 0;
    ws.span_count = 0;

    // Branch icon + name, or hash prefix for detached HEAD
    if (status.detached) {
        pos = appendSlice(&ws.output, pos, icons.hashprefix);
        const hash_len = @min(status.oid_len, 7);
        pos = appendSlice(&ws.output, pos, status.oid[0..hash_len]);
    } else {
        pos = appendSlice(&ws.output, pos, icons.branch);
        pos = appendSlice(&ws.output, pos, status.branch[0..status.branch_len]);
    }

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
    pos = appendCountColored(&ws.output, pos, icons.conflict, status.conflict, colors.conflict, &ws.color_spans, &ws.span_count);
    pos = appendCountColored(&ws.output, pos, icons.stashed, status.stashed, colors.stashed, &ws.color_spans, &ws.span_count);

    // Insertions/deletions
    pos = appendCountColored32(&ws.output, pos, icons.insertions, status.insertions, colors.insertions, &ws.color_spans, &ws.span_count);
    pos = appendCountColored32(&ws.output, pos, icons.deletions, status.deletions, colors.deletions, &ws.color_spans, &ws.span_count);

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

fn appendCountColored32(buf: []u8, pos: usize, icon: []const u8, count: u32, color: Rgb, spans: *[max_color_spans]ColorSpan, span_count: *u8) usize {
    if (count == 0) return pos;
    var p = appendSlice(buf, pos, " ");
    const color_start = p;
    p = appendSlice(buf, p, icon);
    var num_buf: [12]u8 = undefined;
    const num = std.fmt.bufPrint(&num_buf, "{d}", .{count}) catch return p;
    p = appendSlice(buf, p, num);
    if (p > color_start and span_count.* < max_color_spans) {
        spans[span_count.*] = .{ .start = @intCast(color_start), .end = @intCast(p), .fg = color };
        span_count.* += 1;
    }
    return p;
}

/// Full refresh: run git commands, parse output, format into WidgetState.
/// `osc7_cwd` is the terminal's working_directory from OSC 7 (if any) — used for instant refresh.
pub fn refresh(ws: *WidgetState, wc: *const StatusbarWidgetConfig, allocator: std.mem.Allocator, master_fd: posix.fd_t, osc7_cwd: ?[]const u8, ansi_palette: *const [16]Rgb) void {
    // Try OSC 7 working directory first (instant), fall back to platform polling
    var osc7_path_buf: [statusbar.max_output_len]u8 = undefined;
    const osc7_path = if (osc7_cwd) |uri| statusbar.parseFileUri(uri, &osc7_path_buf) else null;
    const cwd = osc7_path orelse (platform.getForegroundCwd(allocator, master_fd) orelse return);
    defer if (osc7_path == null) allocator.free(cwd);

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

    // Run git diff --numstat for insertions/deletions
    const diff_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "diff", "--numstat" },
        .cwd = cwd,
        .max_output_bytes = 8192,
    }) catch {
        formatOutput(ws, &status, wc, ansi_palette);
        return;
    };
    defer {
        allocator.free(diff_result.stdout);
        allocator.free(diff_result.stderr);
    }

    if (diff_result.term.Exited == 0) {
        const diff = parseDiffNumstat(diff_result.stdout);
        status.insertions = diff.insertions;
        status.deletions = diff.deletions;
    }

    formatOutput(ws, &status, wc, ansi_palette);
}

test {
    _ = @import("git_widget_test.zig");
}
