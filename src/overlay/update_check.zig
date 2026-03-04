const std = @import("std");
const build_options = @import("build_options");
const overlay = @import("overlay.zig");
const layout_mod = @import("layout.zig");
const action_mod = @import("action.zig");
const ai_auth = @import("ai_auth.zig");
const ui = @import("ui.zig");
const ui_render = @import("ui_render.zig");

const OverlayCell = overlay.OverlayCell;
const OverlayStyle = overlay.OverlayStyle;
const CardResult = layout_mod.CardResult;

pub const CheckStatus = enum(u8) {
    idle = 0,
    checking = 1,
    update_available = 2,
    up_to_date = 3,
    failed = 4,
    throttled = 5,
};

pub const UpdateChecker = struct {
    status: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(CheckStatus.idle)),
    /// Fixed buffer for the latest version string (e.g. "0.1.28")
    version_buf: [32]u8 = undefined,
    version_len: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    thread: ?std.Thread = null,
    allocator: std.mem.Allocator,

    pub fn start(self: *UpdateChecker) void {
        if (self.thread != null) return;
        self.status.store(@intFromEnum(CheckStatus.checking), .release);
        self.thread = std.Thread.spawn(.{}, updateWorker, .{self}) catch {
            self.status.store(@intFromEnum(CheckStatus.failed), .release);
            return;
        };
    }

    pub fn getStatus(self: *const UpdateChecker) CheckStatus {
        return @enumFromInt(self.status.load(.acquire));
    }

    pub fn getLatestVersion(self: *const UpdateChecker) []const u8 {
        const len = self.version_len.load(.acquire);
        if (len == 0) return "";
        return self.version_buf[0..len];
    }

    pub fn tryJoin(self: *UpdateChecker) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }
};

/// Background worker thread.
fn updateWorker(checker: *UpdateChecker) void {
    updateWorkerInner(checker) catch {
        checker.status.store(@intFromEnum(CheckStatus.failed), .release);
    };
}

fn updateWorkerInner(checker: *UpdateChecker) !void {
    // 1. Read throttle file — skip if checked within 24h
    const throttle_path = getThrottlePath(checker.allocator) catch {
        checker.status.store(@intFromEnum(CheckStatus.failed), .release);
        return;
    };
    defer checker.allocator.free(throttle_path);

    if (shouldSkipCheck(throttle_path)) {
        checker.status.store(@intFromEnum(CheckStatus.throttled), .release);
        return;
    }

    // 2. Fetch latest release from GitHub
    const response = fetchGithubRelease(checker.allocator) catch {
        checker.status.store(@intFromEnum(CheckStatus.failed), .release);
        return;
    };
    defer checker.allocator.free(response.body);

    // 3. Write current timestamp to throttle file
    writeThrottleTimestamp(throttle_path);

    if (response.status != 200) {
        checker.status.store(@intFromEnum(CheckStatus.failed), .release);
        return;
    }

    // 4. Extract tag_name from JSON
    const tag = ai_auth.extractJsonString(response.body, "tag_name") orelse {
        checker.status.store(@intFromEnum(CheckStatus.failed), .release);
        return;
    };

    // Strip leading 'v' if present
    const version_str = if (tag.len > 0 and tag[0] == 'v') tag[1..] else tag;

    if (version_str.len == 0 or version_str.len > 31) {
        checker.status.store(@intFromEnum(CheckStatus.failed), .release);
        return;
    }

    // 5. Compare against compiled-in version
    const current = build_options.version;
    if (isNewer(version_str, current)) {
        @memcpy(checker.version_buf[0..version_str.len], version_str);
        checker.version_len.store(@intCast(version_str.len), .release);
        checker.status.store(@intFromEnum(CheckStatus.update_available), .release);
    } else {
        checker.status.store(@intFromEnum(CheckStatus.up_to_date), .release);
    }
}

/// Simple semver comparison: returns true if `latest` is newer than `current`.
/// Compares up to 3 numeric components (major.minor.patch).
fn isNewer(latest: []const u8, current: []const u8) bool {
    const l = parseVersion(latest);
    const c = parseVersion(current);

    if (l[0] != c[0]) return l[0] > c[0];
    if (l[1] != c[1]) return l[1] > c[1];
    return l[2] > c[2];
}

fn parseVersion(v: []const u8) [3]u32 {
    var parts: [3]u32 = .{ 0, 0, 0 };
    var idx: usize = 0;
    var start: usize = 0;

    for (v, 0..) |ch, i| {
        if (ch == '.') {
            if (idx < 3) {
                parts[idx] = std.fmt.parseInt(u32, v[start..i], 10) catch 0;
                idx += 1;
            }
            start = i + 1;
        }
    }
    if (idx < 3 and start < v.len) {
        parts[idx] = std.fmt.parseInt(u32, v[start..], 10) catch 0;
    }
    return parts;
}

/// Fetch GitHub releases/latest with gzip decompression support.
fn fetchGithubRelease(allocator: std.mem.Allocator) !ai_auth.HttpResponse {
    const url = "https://api.github.com/repos/semos-labs/attyx/releases/latest";
    const uri = try std.Uri.parse(url);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var req = try client.request(.GET, uri, .{
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "User-Agent", .value = "attyx-update-checker" },
        },
    });
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buf: [0]u8 = .{};
    var response = try req.receiveHead(&redirect_buf);
    const status: u16 = @intFromEnum(response.head.status);

    var transfer_buf: [4096]u8 = undefined;
    const decompress_buf = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(decompress_buf);
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buf);
    const resp_body = reader.allocRemaining(allocator, .limited(256_000)) catch |err| switch (err) {
        error.StreamTooLong => return error.ResponseTooLarge,
        error.ReadFailed => return error.ReadFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };

    return .{ .status = status, .body = resp_body };
}

fn getThrottlePath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    const config_base = std.posix.getenv("XDG_CONFIG_HOME") orelse "";
    if (config_base.len > 0) {
        return std.fmt.allocPrint(allocator, "{s}/attyx/last_update_check", .{config_base});
    }
    return std.fmt.allocPrint(allocator, "{s}/.config/attyx/last_update_check", .{home});
}

fn shouldSkipCheck(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();

    var buf: [20]u8 = undefined;
    const n = file.readAll(&buf) catch return false;
    if (n == 0) return false;

    const ts = std.fmt.parseInt(i64, std.mem.trimRight(u8, buf[0..n], "\n\r "), 10) catch return false;
    const now = std.time.timestamp();
    const elapsed = now - ts;
    return elapsed < 86400; // 24 hours
}

fn writeThrottleTimestamp(path: []const u8) void {
    // Ensure parent directory exists
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.makeDirAbsolute(dir) catch {};
    }

    const file = std.fs.createFileAbsolute(path, .{}) catch return;
    defer file.close();

    var buf: [20]u8 = undefined;
    const ts_str = std.fmt.bufPrint(&buf, "{d}", .{std.time.timestamp()}) catch return;
    file.writeAll(ts_str) catch {};
}

pub const UpdateCardResult = struct {
    cells: []OverlayCell,
    width: u16,
    height: u16,
    action_bar: action_mod.ActionBar,
};

/// Build the update notification (borderless, single row: text + gap + button).
pub fn layoutUpdateCard(
    allocator: std.mem.Allocator,
    latest_version: []const u8,
) !UpdateCardResult {
    const style = OverlayStyle{ .border = false };

    var line_buf: [64]u8 = undefined;
    const line = std.fmt.bufPrint(
        &line_buf,
        "Attyx {s} available (you: {s})",
        .{ latest_version, build_options.version },
    ) catch "Update available";

    const line_len: u16 = @intCast(line.len);
    const btn_w: u16 = 4 + 7; // "[ Dismiss ]"
    const gap: u16 = 2;
    const total_w = 1 + line_len + gap + btn_w + 1;

    // Build element tree: horizontal box with text
    const children = [_]ui.Element{
        .{ .text = .{ .content = " ", .wrap = false } }, // left padding
        .{ .text = .{ .content = line, .wrap = false } },
    };
    const theme = ui.OverlayTheme{ .fg = style.fg, .bg = style.bg, .bg_alpha = style.bg_alpha };
    const r = try ui_render.renderAlloc(allocator, .{ .box = .{
        .children = &children,
        .direction = .horizontal,
        .width = .{ .cells = total_w },
        .style = .{ .fg = style.fg, .bg = style.bg, .bg_alpha = style.bg_alpha },
    } }, total_w, theme);

    // Post-process: fill action bar button
    var bar = action_mod.ActionBar{};
    bar.add(.dismiss, "Dismiss");
    const btn_start = 1 + line_len + gap;
    bar.start_col = btn_start;
    layout_mod.fillActionBar(r.cells, total_w, 0, btn_start, total_w, bar.actions[0..bar.count], bar.focused, .{}, style);

    return .{ .cells = r.cells, .width = r.result.width, .height = r.result.height, .action_bar = bar };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseVersion: basic" {
    const v = parseVersion("1.2.3");
    try std.testing.expectEqual(@as(u32, 1), v[0]);
    try std.testing.expectEqual(@as(u32, 2), v[1]);
    try std.testing.expectEqual(@as(u32, 3), v[2]);
}

test "parseVersion: two components" {
    const v = parseVersion("0.1");
    try std.testing.expectEqual(@as(u32, 0), v[0]);
    try std.testing.expectEqual(@as(u32, 1), v[1]);
    try std.testing.expectEqual(@as(u32, 0), v[2]);
}

test "isNewer: newer patch" {
    try std.testing.expect(isNewer("0.1.28", "0.1.27"));
}

test "isNewer: same version" {
    try std.testing.expect(!isNewer("0.1.27", "0.1.27"));
}

test "isNewer: older version" {
    try std.testing.expect(!isNewer("0.1.26", "0.1.27"));
}

test "isNewer: newer minor" {
    try std.testing.expect(isNewer("0.2.0", "0.1.27"));
}

test "isNewer: newer major" {
    try std.testing.expect(isNewer("1.0.0", "0.99.99"));
}
