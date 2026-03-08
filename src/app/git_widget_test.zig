const std = @import("std");
const git_widget = @import("git_widget.zig");
const GitStatus = git_widget.GitStatus;
const statusbar_config = @import("../config/statusbar_config.zig");
const StatusbarWidgetConfig = statusbar_config.StatusbarWidgetConfig;
const statusbar = @import("statusbar.zig");

test "parseGitStatus: branch and ahead/behind" {
    const input =
        \\# branch.head main
        \\# branch.ab +3 -1
        \\
    ;
    const s = git_widget.parseGitStatus(input);
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
    const s = git_widget.parseGitStatus(input);
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
    const s = git_widget.parseGitStatus(input);
    try std.testing.expectEqual(@as(u16, 2), s.untracked);
    try std.testing.expectEqual(@as(u16, 1), s.conflict);
}

test "parseGitStatus: rename entry" {
    const input =
        \\# branch.head main
        \\2 R. N... 100644 100644 abc123 def456 R100 old.zig\tnew.zig
        \\
    ;
    const s = git_widget.parseGitStatus(input);
    try std.testing.expectEqual(@as(u16, 1), s.staged); // R in index
    try std.testing.expectEqual(@as(u16, 0), s.modified); // . in worktree
}

test "parseGitStatus: detached HEAD with oid" {
    const input =
        \\# branch.oid abc1234def5678901234567890abcdef12345678
        \\# branch.head (detached)
        \\
    ;
    const s = git_widget.parseGitStatus(input);
    try std.testing.expect(s.detached);
    try std.testing.expectEqualStrings("abc1234def5678901234567890abcdef12345678", s.oid[0..s.oid_len]);
    try std.testing.expectEqual(@as(u8, 0), s.branch_len);
}

test "countStashes: counts lines" {
    const input = "stash@{0}: WIP on main: abc123 message\nstash@{1}: WIP on main: def456 msg\n";
    try std.testing.expectEqual(@as(u16, 2), git_widget.countStashes(input));
}

test "countStashes: empty output" {
    try std.testing.expectEqual(@as(u16, 0), git_widget.countStashes(""));
}

test "parseDiffNumstat: counts insertions and deletions" {
    const input = "10\t5\tfile1.zig\n3\t0\tfile2.zig\n";
    const d = git_widget.parseDiffNumstat(input);
    try std.testing.expectEqual(@as(u32, 13), d.insertions);
    try std.testing.expectEqual(@as(u32, 5), d.deletions);
}

test "parseDiffNumstat: empty output" {
    const d = git_widget.parseDiffNumstat("");
    try std.testing.expectEqual(@as(u32, 0), d.insertions);
    try std.testing.expectEqual(@as(u32, 0), d.deletions);
}

test "formatOutput: clean repo shows branch + clean icon" {
    var status = GitStatus{};
    const branch = "main";
    @memcpy(status.branch[0..branch.len], branch);
    status.branch_len = branch.len;

    const wc = StatusbarWidgetConfig{ .name = "git" };
    var ws = statusbar.WidgetState{};
    git_widget.formatOutput(&ws, &status, &wc, &statusbar.default_ansi_palette);
    const output = ws.output[0..ws.output_len];
    try std.testing.expect(std.mem.indexOf(u8, output, "main") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x9c\x94") != null); // ✔
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x9c\x9a") == null); // ✚
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
    var ws = statusbar.WidgetState{};
    git_widget.formatOutput(&ws, &status, &wc, &statusbar.default_ansi_palette);
    const output = ws.output[0..ws.output_len];

    try std.testing.expect(std.mem.indexOf(u8, output, "dev") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x9c\x94") == null); // no ✔
    try std.testing.expect(std.mem.indexOf(u8, output, "3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "1") != null);
}

test "formatOutput: omits zero-count sections" {
    var status = GitStatus{};
    const branch = "main";
    @memcpy(status.branch[0..branch.len], branch);
    status.branch_len = branch.len;
    status.modified = 5;

    const wc = StatusbarWidgetConfig{ .name = "git" };
    var ws = statusbar.WidgetState{};
    git_widget.formatOutput(&ws, &status, &wc, &statusbar.default_ansi_palette);
    const output = ws.output[0..ws.output_len];

    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x9c\x9a") != null); // ✚
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x97\x8f") == null); // ●
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x80\xa6") == null); // …
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x9a\x91") == null); // ⚑
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

    var ws = statusbar.WidgetState{};
    git_widget.formatOutput(&ws, &status, &wc, &statusbar.default_ansi_palette);
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
    var ws = statusbar.WidgetState{};
    git_widget.formatOutput(&ws, &status, &wc, &statusbar.default_ansi_palette);

    const pal = statusbar.default_ansi_palette;
    try std.testing.expectEqual(@as(u8, 2), ws.span_count);
    try std.testing.expectEqual(pal[10].r, ws.color_spans[0].fg.r);
    try std.testing.expectEqual(pal[10].g, ws.color_spans[0].fg.g);
    try std.testing.expectEqual(pal[11].r, ws.color_spans[1].fg.r);
    try std.testing.expectEqual(pal[11].g, ws.color_spans[1].fg.g);
}

test "formatOutput: clean repo has clean color span" {
    var status = GitStatus{};
    const branch = "main";
    @memcpy(status.branch[0..branch.len], branch);
    status.branch_len = branch.len;

    const wc = StatusbarWidgetConfig{ .name = "git" };
    var ws = statusbar.WidgetState{};
    git_widget.formatOutput(&ws, &status, &wc, &statusbar.default_ansi_palette);

    try std.testing.expectEqual(@as(u8, 1), ws.span_count);
    try std.testing.expectEqual(statusbar.default_ansi_palette[10].r, ws.color_spans[0].fg.r);
}

test "parseHexColor: valid 6-digit hex" {
    const c = git_widget.parseHexColor("82c378").?;
    try std.testing.expectEqual(@as(u8, 0x82), c.r);
    try std.testing.expectEqual(@as(u8, 0xc3), c.g);
    try std.testing.expectEqual(@as(u8, 0x78), c.b);
}

test "parseHexColor: with # prefix" {
    const c = git_widget.parseHexColor("#ff0000").?;
    try std.testing.expectEqual(@as(u8, 255), c.r);
    try std.testing.expectEqual(@as(u8, 0), c.g);
    try std.testing.expectEqual(@as(u8, 0), c.b);
}

test "parseHexColor: rejects invalid input" {
    try std.testing.expect(git_widget.parseHexColor("fff") == null);
    try std.testing.expect(git_widget.parseHexColor("zzzzzz") == null);
    try std.testing.expect(git_widget.parseHexColor("") == null);
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

    var ws = statusbar.WidgetState{};
    git_widget.formatOutput(&ws, &status, &wc, &statusbar.default_ansi_palette);

    try std.testing.expectEqual(@as(u8, 1), ws.span_count);
    try std.testing.expectEqual(@as(u8, 255), ws.color_spans[0].fg.r);
    try std.testing.expectEqual(@as(u8, 0), ws.color_spans[0].fg.g);
    try std.testing.expectEqual(@as(u8, 0), ws.color_spans[0].fg.b);
}

test "formatOutput: detached HEAD shows hash prefix" {
    var status = GitStatus{};
    status.detached = true;
    const oid = "abc1234def5678901234567890abcdef12345678";
    @memcpy(status.oid[0..oid.len], oid);
    status.oid_len = oid.len;

    const wc = StatusbarWidgetConfig{ .name = "git" };
    var ws = statusbar.WidgetState{};
    git_widget.formatOutput(&ws, &status, &wc, &statusbar.default_ansi_palette);
    const output = ws.output[0..ws.output_len];
    try std.testing.expect(std.mem.indexOf(u8, output, "#abc1234") != null);
}

test "formatOutput: conflict count rendered" {
    var status = GitStatus{};
    const branch = "main";
    @memcpy(status.branch[0..branch.len], branch);
    status.branch_len = branch.len;
    status.conflict = 2;

    const wc = StatusbarWidgetConfig{ .name = "git" };
    var ws = statusbar.WidgetState{};
    git_widget.formatOutput(&ws, &status, &wc, &statusbar.default_ansi_palette);
    const output = ws.output[0..ws.output_len];
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x9c\x96") != null); // ✖
    try std.testing.expect(std.mem.indexOf(u8, output, "2") != null);
}

test "formatOutput: insertions and deletions rendered" {
    var status = GitStatus{};
    const branch = "main";
    @memcpy(status.branch[0..branch.len], branch);
    status.branch_len = branch.len;
    status.modified = 1;
    status.insertions = 42;
    status.deletions = 7;

    const wc = StatusbarWidgetConfig{ .name = "git" };
    var ws = statusbar.WidgetState{};
    git_widget.formatOutput(&ws, &status, &wc, &statusbar.default_ansi_palette);
    const output = ws.output[0..ws.output_len];
    try std.testing.expect(std.mem.indexOf(u8, output, "+42") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-7") != null);
}
