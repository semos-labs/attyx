const std = @import("std");
const posix = std.posix;
const attyx = @import("attyx");
const overlay_mod = attyx.overlay_mod;
const OverlayCell = overlay_mod.OverlayCell;
const Rgb = overlay_mod.Rgb;
const platform = @import("../platform/platform.zig");
const statusbar_config = @import("../config/statusbar_config.zig");
const StatusbarConfig = statusbar_config.StatusbarConfig;
const StatusbarWidgetConfig = statusbar_config.StatusbarWidgetConfig;

pub const max_widgets = statusbar_config.max_widgets;
pub const max_output_len = 256;

pub const WidgetState = struct {
    output: [max_output_len]u8 = undefined,
    output_len: u16 = 0,
    last_tick: i64 = 0,
};

pub const Style = struct {
    bg: Rgb = .{ .r = 30, .g = 30, .b = 40 },
    fg: Rgb = .{ .r = 180, .g = 180, .b = 200 },
    active_tab_bg: Rgb = .{ .r = 60, .g = 60, .b = 90 },
    active_tab_fg: Rgb = .{ .r = 230, .g = 230, .b = 240 },
    bg_alpha: u8 = 240,
};

pub const RenderResult = struct {
    cells: []OverlayCell,
    width: u16,
    height: u16,
};

pub const Statusbar = struct {
    config: StatusbarConfig,
    widgets: [max_widgets]WidgetState = [_]WidgetState{.{}} ** max_widgets,
    config_dir: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: StatusbarConfig) Statusbar {
        return .{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Statusbar) void {
        if (self.config_dir) |d| self.allocator.free(d);
    }

    /// Tick all widgets — refresh any whose interval has elapsed.
    pub fn tick(self: *Statusbar, now_s: i64, master_fd: posix.fd_t) void {
        for (self.config.widgets[0..self.config.widget_count], 0..) |wc, i| {
            const ws = &self.widgets[i];
            if (now_s - ws.last_tick < @as(i64, wc.interval_s)) continue;
            ws.last_tick = now_s;

            if (std.mem.eql(u8, wc.name, "cwd")) {
                refreshCwd(ws, self.allocator, master_fd);
            } else if (std.mem.eql(u8, wc.name, "git")) {
                refreshGit(ws, self.allocator, master_fd);
            } else if (std.mem.eql(u8, wc.name, "time")) {
                refreshTime(ws, &wc);
            } else {
                refreshScript(self, &wc, ws);
            }
        }
    }

    fn refreshCwd(ws: *WidgetState, allocator: std.mem.Allocator, master_fd: posix.fd_t) void {
        const cwd = platform.getForegroundCwd(allocator, master_fd) orelse return;
        defer allocator.free(cwd);
        const home = std.posix.getenv("HOME");
        // Shorten: replace $HOME with ~
        if (home) |h| {
            if (std.mem.startsWith(u8, cwd, h)) {
                const suffix = cwd[h.len..];
                ws.output[0] = '~';
                const copy_len = @min(suffix.len, max_output_len - 1);
                @memcpy(ws.output[1 .. 1 + copy_len], suffix[0..copy_len]);
                ws.output_len = @intCast(1 + copy_len);
                return;
            }
        }
        const len = @min(cwd.len, max_output_len);
        @memcpy(ws.output[0..len], cwd[0..len]);
        ws.output_len = @intCast(len);
    }

    fn refreshGit(ws: *WidgetState, allocator: std.mem.Allocator, master_fd: posix.fd_t) void {
        const cwd = platform.getForegroundCwd(allocator, master_fd) orelse return;
        defer allocator.free(cwd);

        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" },
            .cwd = cwd,
            .max_output_bytes = 256,
        }) catch return;
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }

        if (result.term.Exited != 0) {
            ws.output_len = 0;
            return;
        }

        const branch = std.mem.trimRight(u8, result.stdout, "\n\r ");
        if (branch.len == 0) {
            ws.output_len = 0;
            return;
        }
        const prefix = " ";
        const total = prefix.len + branch.len;
        const len = @min(total, max_output_len);
        @memcpy(ws.output[0..prefix.len], prefix);
        const blen = @min(branch.len, len - prefix.len);
        @memcpy(ws.output[prefix.len .. prefix.len + blen], branch[0..blen]);
        ws.output_len = @intCast(len);
    }

    fn refreshTime(ws: *WidgetState, wc: *const StatusbarWidgetConfig) void {
        _ = wc; // format param can be used later for custom strftime
        const epoch = std.time.timestamp();
        const es = std.time.epoch.EpochSeconds{ .secs = @intCast(epoch) };
        const day_secs = es.getDaySeconds();
        const hours = day_secs.getHoursIntoDay();
        const minutes = day_secs.getMinutesIntoHour();
        const len = std.fmt.bufPrint(&ws.output, "{d:0>2}:{d:0>2}", .{ hours, minutes }) catch return;
        ws.output_len = @intCast(len.len);
    }

    fn refreshScript(self: *Statusbar, wc: *const StatusbarWidgetConfig, ws: *WidgetState) void {
        const config_dir = self.config_dir orelse return;
        // Build path: config_dir/statusbar/<name>
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/statusbar/{s}", .{ config_dir, wc.name }) catch return;

        // Build JSON params for stdin
        var json_buf: [512]u8 = undefined;
        var json_len: usize = 0;
        json_buf[0] = '{';
        json_len = 1;
        for (wc.params[0..wc.param_count], 0..) |p, i| {
            if (i > 0) {
                json_buf[json_len] = ',';
                json_len += 1;
            }
            const written = std.fmt.bufPrint(json_buf[json_len..], "\"{s}\":\"{s}\"", .{ p.key, p.value }) catch break;
            json_len += written.len;
        }
        if (json_len < json_buf.len) {
            json_buf[json_len] = '}';
            json_len += 1;
        }

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{path},
            .max_output_bytes = max_output_len,
        }) catch return;
        defer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }

        if (result.term.Exited != 0) {
            ws.output_len = 0;
            return;
        }

        const output = std.mem.trimRight(u8, result.stdout, "\n\r ");
        const len = @min(output.len, max_output_len);
        @memcpy(ws.output[0..len], output[0..len]);
        ws.output_len = @intCast(len);
    }
};

/// Generate statusbar overlay cells into a caller-provided buffer.
pub fn generate(
    buf: []OverlayCell,
    bar: *const Statusbar,
    tab_count: u8,
    active_tab: u8,
    grid_cols: u16,
    style: Style,
) ?RenderResult {
    if (!bar.config.enabled or grid_cols == 0) return null;
    if (buf.len < grid_cols) return null;

    // 1. Fill entire row with bg
    for (buf[0..grid_cols]) |*cell| {
        cell.* = .{ .char = ' ', .fg = style.fg, .bg = style.bg, .bg_alpha = style.bg_alpha };
    }

    var col: u16 = 0;

    // 2. Left widgets
    for (bar.config.widgets[0..bar.config.widget_count], 0..) |wc, i| {
        if (wc.side != .left) continue;
        const ws = &bar.widgets[i];
        if (ws.output_len == 0) continue;
        const text = ws.output[0..ws.output_len];
        // Write " text "
        if (col < grid_cols) {
            buf[col] = .{ .char = ' ', .fg = style.fg, .bg = style.bg, .bg_alpha = style.bg_alpha };
            col += 1;
        }
        for (text) |ch| {
            if (col >= grid_cols) break;
            buf[col] = .{ .char = ch, .fg = style.fg, .bg = style.bg, .bg_alpha = style.bg_alpha };
            col += 1;
        }
        if (col < grid_cols) {
            buf[col] = .{ .char = ' ', .fg = style.fg, .bg = style.bg, .bg_alpha = style.bg_alpha };
            col += 1;
        }
    }

    // 3. Tabs (only when count > 1)
    if (tab_count > 1) {
        if (col < grid_cols) {
            buf[col] = .{ .char = ' ', .fg = style.fg, .bg = style.bg, .bg_alpha = style.bg_alpha };
            col += 1;
        }
        for (0..tab_count) |ti| {
            if (col >= grid_cols) break;
            const is_active = (ti == active_tab);
            const fg = if (is_active) style.active_tab_fg else style.fg;
            const bg = if (is_active) style.active_tab_bg else style.bg;

            var title_buf: [20]u8 = undefined;
            const title = std.fmt.bufPrint(&title_buf, " {d} ", .{ti + 1}) catch " ? ";

            for (title) |ch| {
                if (col >= grid_cols) break;
                buf[col] = .{ .char = ch, .fg = fg, .bg = bg, .bg_alpha = style.bg_alpha };
                col += 1;
            }
            // Separator
            if (ti + 1 < tab_count and col < grid_cols) {
                buf[col] = .{ .char = '|', .fg = style.fg, .bg = style.bg, .bg_alpha = style.bg_alpha };
                col += 1;
            }
        }
    }

    // 4. Right widgets — compute total width, then render from right edge
    var right_total: u16 = 0;
    for (bar.config.widgets[0..bar.config.widget_count], 0..) |wc, i| {
        if (wc.side != .right) continue;
        const ws = &bar.widgets[i];
        if (ws.output_len == 0) continue;
        right_total += ws.output_len + 2; // " text "
    }

    if (right_total > 0 and right_total < grid_cols) {
        var rcol: u16 = grid_cols - right_total;
        for (bar.config.widgets[0..bar.config.widget_count], 0..) |wc, i| {
            if (wc.side != .right) continue;
            const ws = &bar.widgets[i];
            if (ws.output_len == 0) continue;
            const text = ws.output[0..ws.output_len];
            if (rcol < grid_cols) {
                buf[rcol] = .{ .char = ' ', .fg = style.fg, .bg = style.bg, .bg_alpha = style.bg_alpha };
                rcol += 1;
            }
            for (text) |ch| {
                if (rcol >= grid_cols) break;
                buf[rcol] = .{ .char = ch, .fg = style.fg, .bg = style.bg, .bg_alpha = style.bg_alpha };
                rcol += 1;
            }
            if (rcol < grid_cols) {
                buf[rcol] = .{ .char = ' ', .fg = style.fg, .bg = style.bg, .bg_alpha = style.bg_alpha };
                rcol += 1;
            }
        }
    }

    return .{ .cells = buf[0..grid_cols], .width = grid_cols, .height = 1 };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "generate: returns null when disabled" {
    var config = StatusbarConfig{};
    config.enabled = false;
    var bar = Statusbar.init(std.testing.allocator, config);
    defer bar.deinit();

    var buf: [100]OverlayCell = undefined;
    try std.testing.expect(generate(&buf, &bar, 1, 0, 80, .{}) == null);
}

test "generate: returns cells when enabled" {
    var config = StatusbarConfig{};
    config.enabled = true;
    var bar = Statusbar.init(std.testing.allocator, config);
    defer bar.deinit();

    var buf: [100]OverlayCell = undefined;
    const result = generate(&buf, &bar, 1, 0, 80, .{}) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 80), result.width);
    try std.testing.expectEqual(@as(u16, 1), result.height);
}

test "generate: left widget text appears at start" {
    var config = StatusbarConfig{};
    config.enabled = true;
    config.widgets[0] = .{ .name = "cwd", .side = .left };
    config.widget_count = 1;
    var bar = Statusbar.init(std.testing.allocator, config);
    defer bar.deinit();

    // Manually set widget output
    const text = "~/Projects";
    @memcpy(bar.widgets[0].output[0..text.len], text);
    bar.widgets[0].output_len = text.len;

    var buf: [100]OverlayCell = undefined;
    const result = generate(&buf, &bar, 1, 0, 40, .{}) orelse
        return error.TestUnexpectedResult;
    // First cell is space padding, then "~/Projects"
    try std.testing.expectEqual(@as(u21, ' '), result.cells[0].char);
    try std.testing.expectEqual(@as(u21, '~'), result.cells[1].char);
    try std.testing.expectEqual(@as(u21, '/'), result.cells[2].char);
}

test "generate: right widget is right-aligned" {
    var config = StatusbarConfig{};
    config.enabled = true;
    config.widgets[0] = .{ .name = "time", .side = .right };
    config.widget_count = 1;
    var bar = Statusbar.init(std.testing.allocator, config);
    defer bar.deinit();

    const text = "12:34";
    @memcpy(bar.widgets[0].output[0..text.len], text);
    bar.widgets[0].output_len = text.len;

    var buf: [100]OverlayCell = undefined;
    const result = generate(&buf, &bar, 1, 0, 40, .{}) orelse
        return error.TestUnexpectedResult;
    // Right widget: " 12:34 " = 7 chars, starts at col 33
    try std.testing.expectEqual(@as(u21, ' '), result.cells[33].char);
    try std.testing.expectEqual(@as(u21, '1'), result.cells[34].char);
    try std.testing.expectEqual(@as(u21, '2'), result.cells[35].char);
    try std.testing.expectEqual(@as(u21, ':'), result.cells[36].char);
    try std.testing.expectEqual(@as(u21, '3'), result.cells[37].char);
    try std.testing.expectEqual(@as(u21, '4'), result.cells[38].char);
    try std.testing.expectEqual(@as(u21, ' '), result.cells[39].char);
}

test "generate: tabs appear when count > 1" {
    var config = StatusbarConfig{};
    config.enabled = true;
    var bar = Statusbar.init(std.testing.allocator, config);
    defer bar.deinit();

    var buf: [100]OverlayCell = undefined;
    const result = generate(&buf, &bar, 3, 1, 40, .{}) orelse
        return error.TestUnexpectedResult;
    // Should have " 1 | 2 | 3 " starting at col 1
    try std.testing.expectEqual(@as(u21, ' '), result.cells[0].char);
    try std.testing.expectEqual(@as(u21, ' '), result.cells[1].char);
    try std.testing.expectEqual(@as(u21, '1'), result.cells[2].char);
    try std.testing.expectEqual(@as(u21, ' '), result.cells[3].char);
    try std.testing.expectEqual(@as(u21, '|'), result.cells[4].char);
}

test "generate: active tab has different colors" {
    var config = StatusbarConfig{};
    config.enabled = true;
    var bar = Statusbar.init(std.testing.allocator, config);
    defer bar.deinit();

    const style = Style{};
    var buf: [100]OverlayCell = undefined;
    const result = generate(&buf, &bar, 2, 1, 40, style) orelse
        return error.TestUnexpectedResult;
    // Tab 1 (inactive at col 1-3): " 1 " should have style.bg
    try std.testing.expectEqual(style.bg, result.cells[1].bg);
    // Tab 2 (active at col 5-7): " 2 " should have active_tab_bg
    try std.testing.expectEqual(style.active_tab_bg, result.cells[5].bg);
}

test "refreshTime: formats hours and minutes" {
    var ws = WidgetState{};
    const wc = StatusbarWidgetConfig{ .name = "time" };
    Statusbar.refreshTime(&ws, &wc);
    // Should have produced something like "HH:MM"
    try std.testing.expect(ws.output_len == 5);
    try std.testing.expectEqual(@as(u8, ':'), ws.output[2]);
}
