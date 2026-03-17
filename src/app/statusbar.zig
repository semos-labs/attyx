const std = @import("std");
const posix = std.posix;
const attyx = @import("attyx");
const overlay_mod = attyx.overlay_mod;
const StyledCell = overlay_mod.StyledCell;
pub const Rgb = overlay_mod.Rgb;
const unicode = attyx.unicode;
const platform = @import("../platform/platform.zig");
const statusbar_config = @import("../config/statusbar_config.zig");
const StatusbarConfig = statusbar_config.StatusbarConfig;
const StatusbarWidgetConfig = statusbar_config.StatusbarWidgetConfig;
const git_widget = @import("git_widget.zig");
const tab_bar_mod = @import("tab_bar.zig");
const bridge = @cImport({ @cInclude("bridge.h"); });

const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

const CTime = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
};

// Platform-specific local time conversion.
const time_ffi = if (is_windows) struct {
    // Windows UCRT: _localtime64_s(struct tm*, const __time64_t*) → errno_t
    extern "c" fn _localtime64_s(result: *CTime, timep: *const i64) c_int;
} else struct {
    // POSIX: localtime_r(const time_t*, struct tm*) → struct tm*
    extern "c" fn localtime_r(timep: *const i64, result: *CTime) ?*CTime;
};

fn getLocalTime(epoch: *i64, tm: *CTime) bool {
    if (is_windows) {
        return time_ffi._localtime64_s(tm, epoch) == 0;
    } else {
        return time_ffi.localtime_r(epoch, tm) != null;
    }
}

pub const max_widgets = statusbar_config.max_widgets;
pub const max_output_len = 256;

pub const ColorSpan = struct {
    start: u16, // byte offset in output
    end: u16, // byte offset end (exclusive)
    fg: Rgb,
};
pub const max_color_spans = 16;

/// Standard ANSI 16-color palette (renderer defaults).
pub const default_ansi_palette = [16]Rgb{
    .{ .r = 0, .g = 0, .b = 0 }, // 0  black
    .{ .r = 170, .g = 0, .b = 0 }, // 1  red
    .{ .r = 0, .g = 170, .b = 0 }, // 2  green
    .{ .r = 170, .g = 85, .b = 0 }, // 3  yellow
    .{ .r = 0, .g = 0, .b = 170 }, // 4  blue
    .{ .r = 170, .g = 0, .b = 170 }, // 5  magenta
    .{ .r = 0, .g = 170, .b = 170 }, // 6  cyan
    .{ .r = 170, .g = 170, .b = 170 }, // 7  white
    .{ .r = 85, .g = 85, .b = 85 }, // 8  bright black
    .{ .r = 255, .g = 85, .b = 85 }, // 9  bright red
    .{ .r = 85, .g = 255, .b = 85 }, // 10 bright green
    .{ .r = 255, .g = 255, .b = 85 }, // 11 bright yellow
    .{ .r = 85, .g = 85, .b = 255 }, // 12 bright blue
    .{ .r = 255, .g = 85, .b = 255 }, // 13 bright magenta
    .{ .r = 85, .g = 255, .b = 255 }, // 14 bright cyan
    .{ .r = 255, .g = 255, .b = 255 }, // 15 bright white
};

/// Parse a file:// URI to extract the path component.
/// Returns a slice into `buf` on success, null on failure.
/// On Windows, converts MSYS-style paths (/c/Users/...) to Windows paths (C:\Users\...).
pub fn parseFileUri(uri: []const u8, buf: *[max_output_len]u8) ?[]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    const after_scheme = uri[prefix.len..];
    // Skip hostname: find next '/'
    const slash_idx = std.mem.indexOfScalar(u8, after_scheme, '/') orelse return null;
    const path = after_scheme[slash_idx..];
    if (path.len == 0) return null;

    if (is_windows) {
        return msysToWinPath(path, buf);
    }

    const len = @min(path.len, buf.len);
    @memcpy(buf[0..len], path[0..len]);
    return buf[0..len];
}

/// Convert MSYS-style path (/c/Users/Foo) to Windows path (C:\Users\Foo).
/// Returns a slice into `buf`, or null if the path doesn't match the pattern.
fn msysToWinPath(path: []const u8, buf: *[max_output_len]u8) ?[]const u8 {
    // Pattern: /x/... where x is a drive letter
    if (path.len >= 3 and path[0] == '/' and path[2] == '/' and
        ((path[1] >= 'a' and path[1] <= 'z') or (path[1] >= 'A' and path[1] <= 'Z')))
    {
        if (buf.len < path.len) return null;
        // Drive letter uppercase + ':'
        buf[0] = if (path[1] >= 'a') path[1] - ('a' - 'A') else path[1];
        buf[1] = ':';
        // Copy rest, converting / to backslash
        var i: usize = 2;
        while (i < path.len) : (i += 1) {
            buf[i] = if (path[i] == '/') '\\' else path[i];
        }
        return buf[0..path.len];
    }
    // Not an MSYS path — copy as-is with slash conversion
    const len = @min(path.len, buf.len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        buf[i] = if (path[i] == '/') '\\' else path[i];
    }
    return buf[0..len];
}

/// Column offset where tabs begin in the statusbar (for click detection).
pub var tab_col_offset: u16 = 0;

pub const WidgetState = struct {
    output: [max_output_len]u8 = undefined,
    output_len: u16 = 0,
    last_tick: i64 = 0,
    last_cwd_ptr: ?[*]const u8 = null,
    color_spans: [max_color_spans]ColorSpan = undefined,
    span_count: u8 = 0,
};

pub const Style = struct {
    bg: Rgb = .{ .r = 30, .g = 30, .b = 40 },
    fg: Rgb = .{ .r = 180, .g = 180, .b = 200 },
    tab_bg: Rgb = .{ .r = 50, .g = 50, .b = 58 },
    active_tab_bg: Rgb = .{ .r = 90, .g = 90, .b = 100 },
    active_tab_fg: Rgb = .{ .r = 230, .g = 230, .b = 240 },
    bg_alpha: u8 = 0,
};

pub const RenderResult = struct {
    cells: []StyledCell,
    width: u16,
    height: u16,
};

pub const Statusbar = struct {
    config: StatusbarConfig,
    widgets: [max_widgets]WidgetState = [_]WidgetState{.{}} ** max_widgets,
    config_dir: ?[]const u8 = null,
    allocator: std.mem.Allocator,
    ansi_palette: [16]Rgb = default_ansi_palette,

    pub fn init(allocator: std.mem.Allocator, config: StatusbarConfig) Statusbar {
        return .{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Statusbar) void {
        if (self.config_dir) |d| self.allocator.free(d);
    }

    /// Reset all widget cached state so they refresh on the next tick.
    /// Call this after a session switch to avoid stale CWD/git output.
    pub fn resetWidgets(self: *Statusbar) void {
        for (&self.widgets) |*ws| {
            ws.output_len = 0;
            ws.last_tick = 0;
            ws.last_cwd_ptr = null;
            ws.span_count = 0;
        }
    }

    /// Tick all widgets — refresh any whose interval has elapsed.
    /// `osc7_cwd` is the terminal's working_directory from OSC 7 (if any).
    /// Returns true if any widget was refreshed (caller should re-generate overlay).
    pub fn tick(self: *Statusbar, now_s: i64, master_fd: posix.fd_t, osc7_cwd: ?[]const u8) bool {
        var any_refreshed = false;
        for (self.config.widgets[0..self.config.widget_count], 0..) |wc, i| {
            const ws = &self.widgets[i];

            // For cwd/git widgets: detect OSC 7 changes for instant refresh
            const is_cwd = std.mem.eql(u8, wc.name, "cwd");
            const is_git = std.mem.eql(u8, wc.name, "git");
            const osc7_changed = (is_cwd or is_git) and cwdPtrChanged(ws, osc7_cwd);

            if (!osc7_changed and now_s - ws.last_tick < @as(i64, wc.interval_s)) continue;
            ws.last_tick = now_s;
            any_refreshed = true;

            if (is_cwd) {
                refreshCwd(ws, &wc, self.allocator, master_fd, osc7_cwd);
            } else if (is_git) {
                git_widget.refresh(ws, &wc, self.allocator, master_fd, osc7_cwd, &self.ansi_palette);
            } else if (std.mem.eql(u8, wc.name, "time")) {
                refreshTime(ws, &wc);
            } else {
                refreshScript(self, &wc, ws);
            }
        }
        return any_refreshed;
    }

    /// Check if the OSC 7 cwd pointer has changed since last refresh.
    fn cwdPtrChanged(ws: *WidgetState, osc7_cwd: ?[]const u8) bool {
        const new_ptr: ?[*]const u8 = if (osc7_cwd) |c| c.ptr else null;
        if (new_ptr != ws.last_cwd_ptr) {
            ws.last_cwd_ptr = new_ptr;
            return true;
        }
        return false;
    }

    fn refreshCwd(ws: *WidgetState, wc: *const StatusbarWidgetConfig, allocator: std.mem.Allocator, master_fd: posix.fd_t, osc7_cwd: ?[]const u8) void {
        // Try OSC 7 working directory first (instant), fall back to platform polling
        var osc7_path_buf: [max_output_len]u8 = undefined;
        if (osc7_cwd) |uri| {
            if (parseFileUri(uri, &osc7_path_buf)) |p| {
                formatCwd(ws, wc, p);
                return;
            }
        }
        const cwd = platform.getForegroundCwd(allocator, master_fd) orelse return;
        defer allocator.free(cwd);
        formatCwd(ws, wc, cwd);
    }

    fn getHomeDir() ?[]const u8 {
        if (is_windows) {
            // Cache USERPROFILE in a static buffer (it doesn't change at runtime).
            const S = struct {
                var buf: [512]u8 = undefined;
                var len: usize = 0;
                var initialized: bool = false;
            };
            if (!S.initialized) {
                S.initialized = true;
                const val = std.process.getEnvVarOwned(std.heap.page_allocator, "USERPROFILE") catch null;
                if (val) |v| {
                    const n = @min(v.len, S.buf.len);
                    @memcpy(S.buf[0..n], v[0..n]);
                    S.len = n;
                    std.heap.page_allocator.free(v);
                }
            }
            return if (S.len > 0) S.buf[0..S.len] else null;
        } else {
            return std.posix.getenv("HOME");
        }
    }

    fn formatCwd(ws: *WidgetState, wc: *const StatusbarWidgetConfig, cwd: []const u8) void {
        const home = getHomeDir();
        var path: []const u8 = cwd;
        var prefix: []const u8 = "";
        if (home) |h| {
            if (std.mem.startsWith(u8, cwd, h)) {
                path = cwd[h.len..];
                prefix = "~";
            }
        }
        const truncate = parseTruncate(wc);
        if (truncate > 0) {
            const orig_path = path;
            path = truncatePath(path, truncate);
            // If truncation removed components and we're under HOME, add separator after "~"
            if (path.len < orig_path.len and prefix.len > 0) {
                prefix = if (is_windows) "~\\" else "~/";
            }
        }
        // Root filesystem: ensure we output separator not empty string
        if (prefix.len == 0 and path.len == 0) {
            prefix = if (is_windows) "\\" else "/";
        }
        const plen = @min(prefix.len, max_output_len);
        @memcpy(ws.output[0..plen], prefix[0..plen]);
        const rlen = @min(path.len, max_output_len - plen);
        @memcpy(ws.output[plen .. plen + rlen], path[0..rlen]);
        ws.output_len = @intCast(plen + rlen);
    }

    fn parseTruncate(wc: *const StatusbarWidgetConfig) u16 {
        const val = wc.getParam("truncate") orelse return 0;
        return std.fmt.parseInt(u16, val, 10) catch 0;
    }

    fn truncatePath(path: []const u8, keep: u16) []const u8 {
        if (keep == 0) return path;
        var count: u16 = 0;
        var i: usize = path.len;
        while (i > 0) {
            i -= 1;
            if (path[i] == '/' or path[i] == '\\') {
                count += 1;
                if (count == keep) return path[i + 1 ..];
            }
        }
        // Fewer components than requested — return whole path
        return path;
    }

    fn refreshTime(ws: *WidgetState, wc: *const StatusbarWidgetConfig) void {
        var epoch = std.time.timestamp();
        var tm: CTime = undefined;
        if (!getLocalTime(&epoch, &tm)) return;
        const h24: u8 = @intCast(tm.tm_hour);
        const minutes: u8 = @intCast(tm.tm_min);
        const use_24h = if (wc.getParam("24h")) |v| !std.mem.eql(u8, v, "false") else true;
        if (use_24h) {
            const len = std.fmt.bufPrint(&ws.output, "{d:0>2}:{d:0>2}", .{ h24, minutes }) catch return;
            ws.output_len = @intCast(len.len);
        } else {
            const suffix: []const u8 = if (h24 >= 12) "PM" else "AM";
            const h12 = if (h24 == 0) @as(u8, 12) else if (h24 > 12) h24 - 12 else h24;
            const len = std.fmt.bufPrint(&ws.output, "{d}:{d:0>2} {s}", .{ h12, minutes, suffix }) catch return;
            ws.output_len = @intCast(len.len);
        }
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
    buf: []StyledCell,
    bar: *const Statusbar,
    tab_count: u8,
    active_tab: u8,
    grid_cols: u16,
    style: Style,
    titles: *const tab_bar_mod.TabTitles,
    zoomed_tabs: u16,
) ?RenderResult {
    if (!bar.config.enabled or grid_cols == 0) return null;
    if (buf.len < grid_cols) return null;

    // 1. Fill entire row with bg
    for (buf[0..grid_cols]) |*cell| {
        cell.* = .{ .char = ' ', .fg = style.fg, .bg = style.bg, .bg_alpha = style.bg_alpha };
    }

    var col: u16 = 0;

    // 2. Left widgets (or search prompt if copy-mode search is active)
    if (bridge.g_copy_search_active != 0) {
        const dir_char: u21 = if (bridge.g_copy_search_dir < 0) '?' else '/';
        const prompt_fg = Rgb{ .r = 255, .g = 200, .b = 50 };
        if (col < grid_cols) { buf[col] = .{ .char = ' ', .fg = style.fg, .bg = style.bg, .bg_alpha = style.bg_alpha }; col += 1; }
        if (col < grid_cols) { buf[col] = .{ .char = dir_char, .fg = prompt_fg, .bg = style.bg, .bg_alpha = style.bg_alpha }; col += 1; }
        const slen: usize = @intCast(@max(bridge.g_copy_search_len, 0));
        for (0..slen) |si| {
            if (col >= grid_cols) break;
            const ch: u21 = @intCast(bridge.g_copy_search_buf[si]);
            buf[col] = .{ .char = ch, .fg = prompt_fg, .bg = style.bg, .bg_alpha = style.bg_alpha };
            col += 1;
        }
        // Block cursor at insertion point (inverted colors)
        if (col < grid_cols) { buf[col] = .{ .char = ' ', .fg = style.bg, .bg = prompt_fg, .bg_alpha = 255 }; col += 1; }
        if (col < grid_cols) { buf[col] = .{ .char = ' ', .fg = style.fg, .bg = style.bg, .bg_alpha = style.bg_alpha }; col += 1; }
    } else {
        var first_left = true;
        for (bar.config.widgets[0..bar.config.widget_count], 0..) |wc, i| {
            if (wc.side != .left) continue;
            const ws = &bar.widgets[i];
            if (ws.output_len == 0) continue;
            const text = ws.output[0..ws.output_len];
            // Skip leading space on first widget to reduce outer padding
            if (!first_left) {
                if (col < grid_cols) {
                    buf[col] = .{ .char = ' ', .fg = style.fg, .bg = style.bg, .bg_alpha = style.bg_alpha };
                    col += 1;
                }
            }
            first_left = false;
            col = writeUtf8Colored(buf, col, grid_cols, text, ws.color_spans[0..ws.span_count], style.fg, style.bg, style.bg_alpha);
            if (col < grid_cols) {
                buf[col] = .{ .char = ' ', .fg = style.fg, .bg = style.bg, .bg_alpha = style.bg_alpha };
                col += 1;
            }
        }
    }

    // 3. Right widgets — compute total width first so we can reserve space for tabs
    var right_total: u16 = 0;
    var right_widget_count: u16 = 0;
    for (bar.config.widgets[0..bar.config.widget_count], 0..) |wc, i| {
        if (wc.side != .right) continue;
        const ws = &bar.widgets[i];
        if (ws.output_len == 0) continue;
        right_total += utf8CodepointCount(ws.output[0..ws.output_len]) + 2; // " text "
        right_widget_count += 1;
    }
    // Remove trailing space from last widget (reduce outer padding by 1 cell)
    if (right_widget_count > 0) right_total -= 1;

    // Clamp right widgets to leave minimum space for tabs
    {
        const min_tab_cols: u16 = 10;
        const max_right = (grid_cols -| col) -| min_tab_cols;
        if (right_total > max_right) right_total = max_right;
    }

    // 4. Tabs — always render in statusbar (even for a single tab)
    tab_col_offset = col;
    {
        const remaining = grid_cols -| col -| right_total;
        var tab_buf: [512]StyledCell = undefined;
        const tab_style = tab_bar_mod.Style{
            .tab_bg = style.tab_bg,
            .fg = style.fg,
            .num_highlight_bg = style.active_tab_bg,
            .num_highlight_fg = style.active_tab_fg,
            .bg_alpha = 255, // Always opaque within statusbar; row opacity is controlled by statusbar bg_alpha
        };
        if (tab_bar_mod.generate(&tab_buf, tab_count, active_tab, remaining, tab_style, titles, zoomed_tabs)) |tb_result| {
            for (tb_result.cells[0..tb_result.width]) |tc| {
                if (col >= grid_cols) break;
                if (tc.bg_alpha > 0) {
                    // Tab cell — keep tab_bar's own bg_alpha
                    buf[col] = .{ .char = tc.char, .fg = tc.fg, .bg = tc.bg, .bg_alpha = tc.bg_alpha };
                } else {
                    // Transparent gap — keep statusbar background
                    buf[col] = .{ .char = ' ', .fg = style.fg, .bg = style.bg, .bg_alpha = style.bg_alpha };
                }
                col += 1;
            }
        }
    }

    // 5. Right widgets — render from right edge
    if (right_total > 0 and right_total < grid_cols) {
        var rcol: u16 = grid_cols - right_total;
        var right_idx: u16 = 0;
        for (bar.config.widgets[0..bar.config.widget_count], 0..) |wc, i| {
            if (wc.side != .right) continue;
            const ws = &bar.widgets[i];
            if (ws.output_len == 0) continue;
            right_idx += 1;
            const text = ws.output[0..ws.output_len];
            if (rcol < grid_cols) {
                buf[rcol] = .{ .char = ' ', .fg = style.fg, .bg = style.bg, .bg_alpha = style.bg_alpha };
                rcol += 1;
            }
            rcol = writeUtf8Colored(buf, rcol, grid_cols, text, ws.color_spans[0..ws.span_count], style.fg, style.bg, style.bg_alpha);
            // Skip trailing space on last right widget
            if (right_idx < right_widget_count) {
                if (rcol < grid_cols) {
                    buf[rcol] = .{ .char = ' ', .fg = style.fg, .bg = style.bg, .bg_alpha = style.bg_alpha };
                    rcol += 1;
                }
            }
        }
    }

    return .{ .cells = buf[0..grid_cols], .width = grid_cols, .height = 1 };
}

/// Write UTF-8 text into overlay cells, decoding codepoints. Returns new column.
fn writeUtf8(cells: []StyledCell, start: u16, limit: u16, text: []const u8, fg: Rgb, bg: Rgb, bg_alpha: u8) u16 {
    var col = start;
    var i: usize = 0;
    while (i < text.len and col < limit) {
        const cp = decodeOne(text, &i) orelse continue;
        if (unicode.isCombiningMark(cp) or unicode.isZeroWidth(cp)) {
            if (col > start) {
                const prev = &cells[col - 1];
                if (prev.combining[0] == 0) {
                    prev.combining[0] = cp;
                } else if (prev.combining[1] == 0) {
                    prev.combining[1] = cp;
                }
            }
            continue;
        }
        cells[col] = .{ .char = cp, .fg = fg, .bg = bg, .bg_alpha = bg_alpha };
        col += 1;
        if (unicode.charDisplayWidth(cp) == 2 and col < limit) {
            cells[col] = .{ .char = ' ', .fg = fg, .bg = bg, .bg_alpha = bg_alpha };
            col += 1;
        }
    }
    return col;
}

/// Write UTF-8 text into overlay cells with per-byte color spans. Returns new column.
fn writeUtf8Colored(cells: []StyledCell, start: u16, limit: u16, text: []const u8, spans: []const ColorSpan, default_fg: Rgb, bg: Rgb, bg_alpha: u8) u16 {
    var col = start;
    var i: usize = 0;
    while (i < text.len and col < limit) {
        const byte_offset = i;
        const cp = decodeOne(text, &i) orelse continue;
        if (unicode.isCombiningMark(cp) or unicode.isZeroWidth(cp)) {
            if (col > start) {
                const prev = &cells[col - 1];
                if (prev.combining[0] == 0) {
                    prev.combining[0] = cp;
                } else if (prev.combining[1] == 0) {
                    prev.combining[1] = cp;
                }
            }
            continue;
        }
        var fg = default_fg;
        for (spans) |span| {
            if (byte_offset >= span.start and byte_offset < span.end) {
                fg = span.fg;
                break;
            }
        }
        cells[col] = .{ .char = cp, .fg = fg, .bg = bg, .bg_alpha = bg_alpha };
        col += 1;
        if (unicode.charDisplayWidth(cp) == 2 and col < limit) {
            cells[col] = .{ .char = ' ', .fg = fg, .bg = bg, .bg_alpha = bg_alpha };
            col += 1;
        }
    }
    return col;
}

/// Count display columns for a UTF-8 byte slice (wide chars = 2, combining/ZW = 0).
fn utf8CodepointCount(text: []const u8) u16 {
    var count: u16 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const cp = decodeOne(text, &i) orelse continue;
        if (unicode.isCombiningMark(cp) or unicode.isZeroWidth(cp)) continue;
        count += unicode.charDisplayWidth(cp);
    }
    return count;
}

/// Decode one UTF-8 codepoint from text[i..], advancing i. Returns null on invalid byte.
fn decodeOne(text: []const u8, i: *usize) ?u21 {
    const byte = text[i.*];
    const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch {
        i.* += 1;
        return null;
    };
    if (i.* + seq_len > text.len) {
        i.* = text.len;
        return null;
    }
    const cp: u21 = switch (seq_len) {
        1 => @intCast(byte),
        2 => std.unicode.utf8Decode2(text[i.*..][0..2].*) catch {
            i.* += 2;
            return null;
        },
        3 => std.unicode.utf8Decode3(text[i.*..][0..3].*) catch {
            i.* += 3;
            return null;
        },
        4 => std.unicode.utf8Decode4(text[i.*..][0..4].*) catch {
            i.* += 4;
            return null;
        },
        else => {
            i.* += 1;
            return null;
        },
    };
    i.* += seq_len;
    return cp;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const no_titles: tab_bar_mod.TabTitles = .{null} ** tab_bar_mod.max_tabs;

test "generate: returns null when disabled" {
    var config = StatusbarConfig{};
    config.enabled = false;
    var bar = Statusbar.init(std.testing.allocator, config);
    defer bar.deinit();

    var buf: [100]StyledCell = undefined;
    try std.testing.expect(generate(&buf, &bar, 1, 0, 80, .{}, &no_titles, 0) == null);
}

test "generate: returns cells when enabled" {
    var config = StatusbarConfig{};
    config.enabled = true;
    var bar = Statusbar.init(std.testing.allocator, config);
    defer bar.deinit();

    var buf: [100]StyledCell = undefined;
    const result = generate(&buf, &bar, 1, 0, 80, .{}, &no_titles, 0) orelse
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

    var buf: [100]StyledCell = undefined;
    const result = generate(&buf, &bar, 1, 0, 40, .{}, &no_titles, 0) orelse
        return error.TestUnexpectedResult;
    // First left widget has no leading space — text starts at col 0.
    try std.testing.expectEqual(@as(u21, '~'), result.cells[0].char);
    try std.testing.expectEqual(@as(u21, '/'), result.cells[1].char);
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

    var buf: [100]StyledCell = undefined;
    const result = generate(&buf, &bar, 1, 0, 40, .{}, &no_titles, 0) orelse
        return error.TestUnexpectedResult;
    // Right widget: " 12:34" = 6 chars (no trailing space), starts at col 34
    try std.testing.expectEqual(@as(u21, ' '), result.cells[34].char);
    try std.testing.expectEqual(@as(u21, '1'), result.cells[35].char);
    try std.testing.expectEqual(@as(u21, '2'), result.cells[36].char);
    try std.testing.expectEqual(@as(u21, ':'), result.cells[37].char);
    try std.testing.expectEqual(@as(u21, '3'), result.cells[38].char);
    try std.testing.expectEqual(@as(u21, '4'), result.cells[39].char);
}

test "generate: tabs with titles appear when count > 1" {
    var config = StatusbarConfig{};
    config.enabled = true;
    var bar = Statusbar.init(std.testing.allocator, config);
    defer bar.deinit();

    var titles: tab_bar_mod.TabTitles = .{null} ** tab_bar_mod.max_tabs;
    titles[0] = "zsh";
    titles[1] = "vim";
    titles[2] = "htop";

    var buf: [512]StyledCell = undefined;
    const result = generate(&buf, &bar, 3, 1, 80, .{}, &titles, 0) orelse
        return error.TestUnexpectedResult;
    // Tab bar starts at col 0 (no left widgets), cells should include tab content
    // First tab: " zsh " + " 1 " = 5+3 = 8 cells
    try std.testing.expectEqual(@as(u21, ' '), result.cells[0].char);
    try std.testing.expectEqual(@as(u21, 'z'), result.cells[1].char);
    try std.testing.expectEqual(@as(u21, 's'), result.cells[2].char);
    try std.testing.expectEqual(@as(u21, 'h'), result.cells[3].char);
}

test "generate: active tab uses tab_bar highlight colors" {
    var config = StatusbarConfig{};
    config.enabled = true;
    var bar = Statusbar.init(std.testing.allocator, config);
    defer bar.deinit();

    var titles: tab_bar_mod.TabTitles = .{null} ** tab_bar_mod.max_tabs;
    titles[0] = "a";
    titles[1] = "b";

    const sb_style = Style{};
    var buf: [512]StyledCell = undefined;
    const result = generate(&buf, &bar, 2, 1, 80, sb_style, &titles, 0) orelse
        return error.TestUnexpectedResult;
    // Tab 0 (" a " + " 1 " = 3+3 = 6), gap at 6, Tab 1 starts at 7
    // Tab 1 is active — its number area should use active_tab_bg from statusbar style
    // Tab 1: " b " starts at col 7, number area " 2 " at col 10
    try std.testing.expectEqual(sb_style.active_tab_bg, result.cells[10].bg);
}

test "refreshTime: formats hours and minutes in 24h" {
    var ws = WidgetState{};
    const wc = StatusbarWidgetConfig{ .name = "time" };
    Statusbar.refreshTime(&ws, &wc);
    // Should have produced "HH:MM"
    try std.testing.expect(ws.output_len == 5);
    try std.testing.expectEqual(@as(u8, ':'), ws.output[2]);
}

test "refreshTime: 12h format with AM/PM" {
    var ws = WidgetState{};
    var wc = StatusbarWidgetConfig{ .name = "time" };
    wc.params[0] = .{ .key = "24h", .value = "false" };
    wc.param_count = 1;
    Statusbar.refreshTime(&ws, &wc);
    // Should have produced something like "H:MM AM" or "HH:MM PM"
    const output = ws.output[0..ws.output_len];
    try std.testing.expect(ws.output_len >= 7 and ws.output_len <= 8);
    try std.testing.expect(std.mem.endsWith(u8, output, "AM") or std.mem.endsWith(u8, output, "PM"));
}

test "truncatePath: keeps last N components" {
    try std.testing.expectEqualStrings("c/d", Statusbar.truncatePath("/a/b/c/d", 2));
    try std.testing.expectEqualStrings("d", Statusbar.truncatePath("/a/b/c/d", 1));
    try std.testing.expectEqualStrings("/a/b/c/d", Statusbar.truncatePath("/a/b/c/d", 10));
    try std.testing.expectEqualStrings("hello", Statusbar.truncatePath("hello", 2));
}
