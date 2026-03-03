// Attyx — Popup terminal (tmux-style)
//
// Core lifecycle: spawn/deinit popup PTY+Engine, convert cells for rendering,
// publish to C bridge globals. Imported by terminal.zig.

const std = @import("std");
const posix = std.posix;
const attyx = @import("attyx");
const Engine = attyx.Engine;
const color_mod = attyx.render_color;
const Pty = @import("pty.zig").Pty;
const Pane = @import("pane.zig").Pane;
const theme_registry_mod = @import("../theme/registry.zig");
const Theme = theme_registry_mod.Theme;

const c = @cImport({
    @cInclude("bridge.h");
});

pub const BorderStyle = enum {
    single,
    double,
    rounded,
    heavy,
    none,

    // [tl, horiz, tr, vert, bl, br]
    pub fn chars(self: BorderStyle) [6]u32 {
        return switch (self) {
            .single => .{ 0x250C, 0x2500, 0x2510, 0x2502, 0x2514, 0x2518 },
            .double => .{ 0x2554, 0x2550, 0x2557, 0x2551, 0x255A, 0x255D },
            .rounded => .{ 0x256D, 0x2500, 0x256E, 0x2502, 0x2570, 0x256F },
            .heavy => .{ 0x250F, 0x2501, 0x2513, 0x2503, 0x2517, 0x251B },
            .none => .{ 0, 0, 0, 0, 0, 0 },
        };
    }
};

pub const Padding = struct {
    top: u16 = 0,
    bottom: u16 = 0,
    left: u16 = 0,
    right: u16 = 0,
};

/// Resolve CSS-like padding cascade: specific > axis > shorthand.
pub fn parsePadding(
    all: ?u16,
    x: ?u16,
    y: ?u16,
    top: ?u16,
    bottom: ?u16,
    left: ?u16,
    right: ?u16,
) Padding {
    const base = all orelse 0;
    return .{
        .top = top orelse y orelse base,
        .bottom = bottom orelse y orelse base,
        .left = left orelse x orelse base,
        .right = right orelse x orelse base,
    };
}

pub const PopupConfig = struct {
    command: []const u8, // e.g. "lazygit"
    width_pct: u8, // 1-100
    height_pct: u8, // 1-100
    border_style: BorderStyle,
    border_fg: [3]u8, // r, g, b
    pad: Padding = .{},
    on_return_cmd: ?[]const u8 = null, // command prefix run with grid text on exit 0
    inject_alt: bool = false, // inject on_return_cmd even when alt screen is active
    capture_stdout: bool = false, // capture child stdout via pipe (independent of on_return_cmd)
    direct_exec: bool = false, // exec command directly, no shell wrap (instant startup)
    bg_opacity: u8 = 255, // 0 (transparent) – 255 (opaque)
    bg_color: ?[3]u8 = null, // override background color (r, g, b); null = use theme
};

pub const PopupState = struct {
    pane: *Pane,
    config_index: u8, // which PopupConfig spawned this
    cols: u16, // inner terminal grid cols
    rows: u16, // inner terminal grid rows
    outer_col: u16, // position on main grid (top-left)
    outer_row: u16,
    outer_w: u16, // total including border
    outer_h: u16,
    allocator: std.mem.Allocator,
    child_exited: bool = false, // true when command exited with non-zero code

    pub fn spawn(allocator: std.mem.Allocator, cfg: PopupConfig, grid_cols: u16, grid_rows: u16, cwd: ?[]const u8) !PopupState {
        const dims = calcDims(cfg, grid_cols, grid_rows);

        const cwd_z: ?[:0]u8 = if (cwd) |d| allocator.dupeZ(u8, d) catch null else null;
        defer if (cwd_z) |z| allocator.free(z);

        const pane = try allocator.create(Pane);

        if (cfg.direct_exec) {
            // Direct exec: tokenize command, skip shell wrapper.
            // Avoids shell init overhead for built-in tools (e.g. session picker).
            var tokens: [8][:0]u8 = undefined;
            var tc: usize = 0;
            defer for (tokens[0..tc]) |t| allocator.free(t);
            var iter = std.mem.tokenizeScalar(u8, cfg.command, ' ');
            while (iter.next()) |tok| {
                if (tc >= tokens.len) break;
                tokens[tc] = allocator.dupeZ(u8, tok) catch {
                    allocator.destroy(pane);
                    return error.OutOfMemory;
                };
                tc += 1;
            }
            var argv: [8][:0]const u8 = undefined;
            for (tokens[0..tc], 0..) |t, i| argv[i] = t;
            pane.* = Pane.spawnOpts(allocator, dims.rows, dims.cols, argv[0..tc], if (cwd_z) |z| z.ptr else null, .{
                .capture_stdout = cfg.capture_stdout or cfg.on_return_cmd != null,
                .preserve_tmux = true,
            }) catch |err| {
                allocator.destroy(pane);
                return err;
            };
        } else {
            // Shell-wrapped: $SHELL -i -c '<command>'
            // Interactive shell (-i) ensures .zshrc / .bashrc are sourced so
            // PATH includes homebrew, nix, and other user-configured additions.
            const shell_env = std.posix.getenv("SHELL") orelse "/bin/sh";
            const shell_z = try allocator.dupeZ(u8, shell_env);
            defer allocator.free(shell_z);
            const i_flag: [:0]const u8 = "-i";
            const c_flag: [:0]const u8 = "-c";
            const cmd_z = try allocator.dupeZ(u8, cfg.command);
            defer allocator.free(cmd_z);
            const shell_argv = [_][:0]const u8{ shell_z, i_flag, c_flag, cmd_z };
            pane.* = Pane.spawnOpts(allocator, dims.rows, dims.cols, &shell_argv, if (cwd_z) |z| z.ptr else null, .{
                .capture_stdout = cfg.capture_stdout or cfg.on_return_cmd != null,
                .preserve_tmux = true,
            }) catch |err| {
                allocator.destroy(pane);
                return err;
            };
        }

        return .{
            .pane = pane,
            .config_index = 0, // overwritten by caller
            .cols = dims.cols,
            .rows = dims.rows,
            .outer_col = dims.outer_col,
            .outer_row = dims.outer_row,
            .outer_w = dims.outer_w,
            .outer_h = dims.outer_h,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PopupState) void {
        self.pane.deinit();
        self.allocator.destroy(self.pane);
    }

    pub fn resize(self: *PopupState, cfg: PopupConfig, grid_cols: u16, grid_rows: u16) void {
        const dims = calcDims(cfg, grid_cols, grid_rows);
        self.cols = dims.cols;
        self.rows = dims.rows;
        self.outer_col = dims.outer_col;
        self.outer_row = dims.outer_row;
        self.outer_w = dims.outer_w;
        self.outer_h = dims.outer_h;
        self.pane.resize(dims.rows, dims.cols);
    }

    pub fn feed(self: *PopupState, data: []const u8) void {
        self.pane.feed(data);
    }

    pub fn publishCells(self: *PopupState, theme: *const Theme, cfg: PopupConfig) void {
        const ow: usize = self.outer_w;
        const oh: usize = self.outer_h;
        const total = ow * oh;
        if (total > c.ATTYX_POPUP_MAX_CELLS) return;

        const has_border = cfg.border_style != .none;
        const border_off: usize = if (has_border) 1 else 0;
        const col_off: usize = border_off + cfg.pad.left;
        const row_off: usize = border_off + cfg.pad.top;
        const content_end_col: usize = col_off + self.cols;
        const content_end_row: usize = row_off + self.rows;

        // Fill border + padding + inner cells
        var ci: usize = 0;
        for (0..oh) |r| {
            for (0..ow) |col| {
                if (ci >= c.ATTYX_POPUP_MAX_CELLS) break;
                if (has_border and (r == 0 or r == oh - 1 or col == 0 or col == ow - 1)) {
                    // Border cell
                    var cell = borderCell(r, col, ow, oh, cfg.border_style, cfg.border_fg);
                    if (cfg.bg_color) |bg| {
                        cell.bg_r = bg[0];
                        cell.bg_g = bg[1];
                        cell.bg_b = bg[2];
                    }
                    cell.bg_alpha = cfg.bg_opacity;
                    c.g_popup_cells[ci] = cell;
                } else if (r >= row_off and r < content_end_row and col >= col_off and col < content_end_col) {
                    // Content cell — map from engine grid
                    const inner_r = r - row_off;
                    const inner_c = col - col_off;
                    const grid_idx = inner_r * self.cols + inner_c;
                    var overlay = if (inner_r < self.rows and inner_c < self.cols and
                        grid_idx < self.pane.engine.state.grid.cells.len)
                    blk: {
                        const cell = self.pane.engine.state.grid.cells[grid_idx];
                        // Only override bg for cells using the default (theme) bg;
                        // cells with explicit program-set colors stay as-is.
                        const eff_bg = if (cell.style.reverse) cell.style.fg else cell.style.bg;
                        var ov = cellToOverlayCell(cell, theme);
                        if (cfg.bg_color) |bg| {
                            if (eff_bg == .default) {
                                ov.bg_r = bg[0];
                                ov.bg_g = bg[1];
                                ov.bg_b = bg[2];
                            }
                        }
                        break :blk ov;
                    } else blk: {
                        var dc = defaultCell(theme);
                        if (cfg.bg_color) |bg| {
                            dc.bg_r = bg[0];
                            dc.bg_g = bg[1];
                            dc.bg_b = bg[2];
                        }
                        break :blk dc;
                    };
                    overlay.bg_alpha = cfg.bg_opacity;
                    c.g_popup_cells[ci] = overlay;
                } else {
                    // Padding zone
                    var cell = defaultCell(theme);
                    if (cfg.bg_color) |bg| {
                        cell.bg_r = bg[0];
                        cell.bg_g = bg[1];
                        cell.bg_b = bg[2];
                    }
                    cell.bg_alpha = cfg.bg_opacity;
                    c.g_popup_cells[ci] = cell;
                }
                ci += 1;
            }
        }

        // Publish descriptor
        const cursor_vis: bool = self.pane.engine.state.cursor_visible;
        c.g_popup_desc = .{
            .active = 1,
            .col = @intCast(self.outer_col),
            .row = @intCast(self.outer_row),
            .width = @intCast(self.outer_w),
            .height = @intCast(self.outer_h),
            .inner_cols = @intCast(self.cols),
            .inner_rows = @intCast(self.rows),
            .cursor_row = @intCast(self.pane.engine.state.cursor.row + row_off),
            .cursor_col = @intCast(self.pane.engine.state.cursor.col + col_off),
            .cursor_visible = if (cursor_vis) 1 else 0,
            .cursor_shape = @intCast(@intFromEnum(self.pane.engine.state.cursor_shape)),
        };

        _ = @atomicRmw(u32, @as(*u32, @ptrCast(@volatileCast(&c.g_popup_gen))), .Add, 1, .seq_cst);
    }

    pub fn publishImagePlacements(self: *PopupState, cfg: PopupConfig) void {
        const state = &self.pane.engine.state;
        const store = state.graphics_store orelse {
            c.g_popup_image_placement_count = 0;
            return;
        };

        const gs = attyx.graphics_store;
        var buf: [c.ATTYX_POPUP_MAX_IMAGE_PLACEMENTS]gs.Placement = undefined;
        const visible = store.visiblePlacements(self.rows, &buf);

        const has_border = cfg.border_style != .none;
        const border_off: i32 = if (has_border) 1 else 0;
        const col_off: i32 = border_off + @as(i32, cfg.pad.left);
        const row_off: i32 = border_off + @as(i32, cfg.pad.top);

        var out_count: c_int = 0;
        for (visible) |p| {
            if (out_count >= c.ATTYX_POPUP_MAX_IMAGE_PLACEMENTS) break;

            const img = store.getImage(p.image_id) orelse continue;
            const idx: usize = @intCast(out_count);

            // Offset to absolute main-grid coordinates
            const abs_row = p.row + row_off + @as(i32, self.outer_row);
            const abs_col = p.col + col_off + @as(i32, self.outer_col);

            // Set high bit on image_id to avoid texture cache collisions
            // with main terminal images (separate engines have independent IDs)
            c.g_popup_image_placements[idx] = .{
                .image_id = p.image_id | 0x8000_0000,
                .row = abs_row,
                .col = abs_col,
                .img_width = img.width,
                .img_height = img.height,
                .src_x = p.src_x,
                .src_y = p.src_y,
                .src_w = p.src_width,
                .src_h = p.src_height,
                .display_cols = p.display_cols,
                .display_rows = p.display_rows,
                .z_index = p.z_index,
                .pixels = img.pixels.ptr,
            };
            out_count += 1;
        }

        c.g_popup_image_placement_count = out_count;
    }
};

// ---------------------------------------------------------------------------
// Dimension calculation
// ---------------------------------------------------------------------------

const Dims = struct {
    cols: u16,
    rows: u16,
    outer_col: u16,
    outer_row: u16,
    outer_w: u16,
    outer_h: u16,
};

fn calcDims(cfg: PopupConfig, grid_cols: u16, grid_rows: u16) Dims {
    const raw_w = @as(u16, @intCast(@min(
        @as(u32, grid_cols),
        @as(u32, grid_cols) * cfg.width_pct / 100,
    )));
    const raw_h = @as(u16, @intCast(@min(
        @as(u32, grid_rows),
        @as(u32, grid_rows) * cfg.height_pct / 100,
    )));
    const has_border = cfg.border_style != .none;
    const border: u16 = if (has_border) 2 else 0;
    const pad_h = cfg.pad.left + cfg.pad.right;
    const pad_v = cfg.pad.top + cfg.pad.bottom;
    const chrome_h = border + pad_h;
    const chrome_v = border + pad_v;
    // Minimum outer size: chrome + at least 1 cell of content
    const min_w = chrome_h + 1;
    const min_h = chrome_v + 1;
    const outer_w = @max(raw_w, min_w);
    const outer_h = @max(raw_h, min_h);
    const inner_cols = outer_w - chrome_h;
    const inner_rows = outer_h - chrome_v;
    // Center on grid
    const outer_col = if (grid_cols > outer_w) (grid_cols - outer_w) / 2 else 0;
    const outer_row = if (grid_rows > outer_h) (grid_rows - outer_h) / 2 else 0;

    return .{
        .cols = inner_cols,
        .rows = inner_rows,
        .outer_col = outer_col,
        .outer_row = outer_row,
        .outer_w = outer_w,
        .outer_h = outer_h,
    };
}

// ---------------------------------------------------------------------------
// Cell conversion helpers
// ---------------------------------------------------------------------------

fn resolveWithTheme(color: anytype, is_bg: bool, theme: *const Theme) color_mod.Rgb {
    switch (color) {
        .default => {
            const src = if (is_bg) theme.background else theme.foreground;
            return .{ .r = src.r, .g = src.g, .b = src.b };
        },
        .ansi => |n| {
            if (theme.palette[n]) |p| return .{ .r = p.r, .g = p.g, .b = p.b };
            return color_mod.resolve(color, is_bg);
        },
        else => return color_mod.resolve(color, is_bg),
    }
}

fn cellToOverlayCell(cell: attyx.Cell, theme: *const Theme) c.AttyxOverlayCell {
    // Kitty Unicode placeholder: suppress all visual attributes.
    // The fg color encodes image_id and must not be rendered.
    if (cell.char == 0x10EEEE) {
        const eff_bg = if (cell.style.reverse) cell.style.fg else cell.style.bg;
        const bg = resolveWithTheme(eff_bg, !cell.style.reverse, theme);
        return .{
            .character = ' ',
            .combining = .{ 0, 0 },
            .fg_r = 0,
            .fg_g = 0,
            .fg_b = 0,
            .bg_r = bg.r,
            .bg_g = bg.g,
            .bg_b = bg.b,
            .bg_alpha = 255,
        };
    }

    const eff_fg = if (cell.style.reverse) cell.style.bg else cell.style.fg;
    const eff_bg = if (cell.style.reverse) cell.style.fg else cell.style.bg;
    const fg = resolveWithTheme(eff_fg, cell.style.reverse, theme);
    const bg = resolveWithTheme(eff_bg, !cell.style.reverse, theme);
    const fg_r = if (cell.style.dim) fg.r / 2 else fg.r;
    const fg_g = if (cell.style.dim) fg.g / 2 else fg.g;
    const fg_b = if (cell.style.dim) fg.b / 2 else fg.b;
    return .{
        .character = cell.char,
        .combining = .{ cell.combining[0], cell.combining[1] },
        .fg_r = fg_r,
        .fg_g = fg_g,
        .fg_b = fg_b,
        .bg_r = bg.r,
        .bg_g = bg.g,
        .bg_b = bg.b,
        .bg_alpha = 255,
    };
}

fn defaultCell(theme: *const Theme) c.AttyxOverlayCell {
    return .{
        .character = ' ',
        .fg_r = theme.foreground.r,
        .fg_g = theme.foreground.g,
        .fg_b = theme.foreground.b,
        .bg_r = theme.background.r,
        .bg_g = theme.background.g,
        .bg_b = theme.background.b,
        .bg_alpha = 255,
    };
}

fn borderCell(r: usize, col: usize, w: usize, h: usize, style: BorderStyle, fg: [3]u8) c.AttyxOverlayCell {
    const tbl = style.chars();
    const ch: u32 = if (r == 0 and col == 0) tbl[0] // TL
    else if (r == 0 and col == w - 1) tbl[2] // TR
    else if (r == h - 1 and col == 0) tbl[4] // BL
    else if (r == h - 1 and col == w - 1) tbl[5] // BR
    else if (r == 0 or r == h - 1) tbl[1] // horizontal
    else tbl[3]; // vertical
    return .{
        .character = ch,
        .fg_r = fg[0],
        .fg_g = fg[1],
        .fg_b = fg[2],
        .bg_r = 30,
        .bg_g = 30,
        .bg_b = 40,
        .bg_alpha = 255,
    };
}

// ---------------------------------------------------------------------------
// Config parsing helpers
// ---------------------------------------------------------------------------

/// Parse border style string, defaulting to .single on unrecognized input.
pub fn parseBorderStyle(s: []const u8) BorderStyle {
    if (std.mem.eql(u8, s, "single")) return .single;
    if (std.mem.eql(u8, s, "double")) return .double;
    if (std.mem.eql(u8, s, "rounded")) return .rounded;
    if (std.mem.eql(u8, s, "heavy")) return .heavy;
    if (std.mem.eql(u8, s, "none")) return .none;
    return .single;
}

/// Parse "#RRGGBB" hex color string, returning default on failure.
pub fn parseHexColor(s: []const u8, default: [3]u8) [3]u8 {
    if (s.len != 7 or s[0] != '#') return default;
    const r = std.fmt.parseInt(u8, s[1..3], 16) catch return default;
    const g = std.fmt.parseInt(u8, s[3..5], 16) catch return default;
    const b = std.fmt.parseInt(u8, s[5..7], 16) catch return default;
    return .{ r, g, b };
}

/// Parse a percentage string like "80%" into a u8 (1-100), or return default.
pub fn parsePct(s: []const u8, default: u8) u8 {
    if (s.len < 2) return default;
    if (s[s.len - 1] != '%') return default;
    const num = std.fmt.parseInt(u8, s[0 .. s.len - 1], 10) catch return default;
    if (num < 1 or num > 100) return default;
    return num;
}

/// Read captured stdout from the popup's pipe fd.
/// Returns allocated text (caller owns) with escape sequences stripped
/// and whitespace trimmed, or null if nothing was captured.
/// Takes only the last non-empty line to skip shell init noise
/// (OSC 7 from shell integration, MOTD, etc.).
pub fn readCapturedStdout(allocator: std.mem.Allocator, fd: posix.fd_t) ?[]u8 {
    if (fd == -1) return null;
    // Set non-blocking: shell background processes (.zshrc plugins, nix hooks)
    // may inherit the pipe write end, preventing EOF even after the main child
    // exits. Since we only call this after waitForExit(), any data the child
    // wrote is already in the kernel pipe buffer.
    const platform = @import("../platform/platform.zig");
    const F_GETFL: i32 = 3;
    const F_SETFL: i32 = 4;
    const flags = std.posix.fcntl(fd, F_GETFL, 0) catch 0;
    _ = std.posix.fcntl(fd, F_SETFL, flags | platform.O_NONBLOCK) catch {};

    var raw: std.ArrayList(u8) = .{};
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &buf) catch break;
        if (n == 0) break;
        raw.appendSlice(allocator, buf[0..n]) catch { raw.deinit(allocator); return null; };
    }
    defer raw.deinit(allocator);
    if (raw.items.len == 0) return null;

    // Last non-empty line — skip trailing newlines, then find line start.
    var end = raw.items.len;
    while (end > 0 and (raw.items[end - 1] == '\n' or raw.items[end - 1] == '\r')) end -= 1;
    if (end == 0) return null;
    var line_start = end;
    while (line_start > 0 and raw.items[line_start - 1] != '\n' and raw.items[line_start - 1] != '\r') line_start -= 1;
    const line = raw.items[line_start..end];

    // Strip escape sequences (CSI, OSC, single-char) and control characters.
    var result: std.ArrayList(u8) = .{};
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1B) {
            i = skipEscape(line, i);
        } else if (line[i] < 0x20 or line[i] == 0x7F) {
            i += 1;
        } else {
            result.append(allocator, line[i]) catch { result.deinit(allocator); return null; };
            i += 1;
        }
    }
    // Trim whitespace
    while (result.items.len > 0 and
        (result.items[result.items.len - 1] == ' ' or result.items[result.items.len - 1] == '\t'))
        result.items.len -= 1;
    var start: usize = 0;
    while (start < result.items.len and (result.items[start] == ' ' or result.items[start] == '\t'))
        start += 1;
    if (start > 0) {
        std.mem.copyForwards(u8, result.items[0..result.items.len - start], result.items[start..result.items.len]);
        result.items.len -= start;
    }
    if (result.items.len == 0) { result.deinit(allocator); return null; }
    return result.toOwnedSlice(allocator) catch { result.deinit(allocator); return null; };
}

/// Skip an escape sequence starting at data[start] (ESC byte).
fn skipEscape(data: []const u8, start: usize) usize {
    var i = start + 1;
    if (i >= data.len) return i;
    if (data[i] == '[') { // CSI: ESC [ <params> <final>
        i += 1;
        while (i < data.len and data[i] >= 0x20 and data[i] <= 0x3F) : (i += 1) {}
        if (i < data.len and data[i] >= 0x40 and data[i] <= 0x7E) i += 1;
    } else if (data[i] == ']') { // OSC: ESC ] ... BEL or ESC ] ... ESC backslash
        i += 1;
        while (i < data.len) {
            if (data[i] == 0x07) { i += 1; break; }
            if (data[i] == 0x1B and i + 1 < data.len and data[i + 1] == '\\') { i += 2; break; }
            i += 1;
        }
    } else i += 1; // single-char escape
    return i;
}

// C functions for detached subprocess execution
extern "c" fn execvp(file: [*:0]const u8, argv: [*]const ?[*:0]const u8) c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern "c" fn _exit(status: c_int) noreturn;
extern "c" fn getuid() c_uint;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// Execute `cmd_prefix value` in a detached subprocess (fire-and-forget).
/// Uses double-fork to avoid zombies. The command runs invisibly — no PTY
/// echo, nothing appears in the terminal grid or scrollback.
pub fn execDetached(allocator: std.mem.Allocator, cmd_prefix: []const u8, value: []const u8) void {
    const full_slice = std.fmt.allocPrint(allocator, "{s} {s}", .{ cmd_prefix, value }) catch return;
    defer allocator.free(full_slice);
    const full = allocator.dupeZ(u8, full_slice) catch return;
    defer allocator.free(full);
    const shell = posix.getenv("SHELL") orelse "/bin/sh";
    const shell_z = allocator.dupeZ(u8, shell) catch return;
    defer allocator.free(shell_z);

    const pid = posix.fork() catch return;
    if (pid == 0) {
        const pid2 = posix.fork() catch _exit(1);
        if (pid2 != 0) _exit(0);

        // Detect tmux socket so tools like sesh can switch sessions
        // even when attyx itself wasn't launched from tmux.
        if (getenv("TMUX") == null) {
            const uid = getuid();
            const base = getenv("TMUX_TMPDIR") orelse "/tmp";
            var socket_buf: [256]u8 = undefined;
            const sp = std.fmt.bufPrintZ(&socket_buf, "{s}/tmux-{d}/default", .{ base, uid }) catch null;
            if (sp) |socket_path| {
                if (access(socket_path, 0) == 0) {
                    var env_buf: [512]u8 = undefined;
                    const tv = std.fmt.bufPrintZ(&env_buf, "{s},0,0", .{socket_path}) catch null;
                    if (tv) |tmux_val| _ = setenv("TMUX", tmux_val, 1);
                }
            }
        }

        // -i sources .zshrc/.bashrc for PATH (homebrew, nix, etc.)
        const i_flag: [:0]const u8 = "-i";
        const c_flag: [:0]const u8 = "-c";
        var argv_ptrs = [_]?[*:0]const u8{ shell_z.ptr, i_flag.ptr, c_flag.ptr, full.ptr, null };
        _ = execvp(argv_ptrs[0].?, @ptrCast(&argv_ptrs));
        _exit(127);
    }
    _ = waitpid(pid, null, 0);
}

/// Clear the popup bridge state (called when popup closes).
pub fn clearBridgeState() void {
    c.g_popup_desc.active = 0;
    c.g_popup_image_placement_count = 0;
    @atomicStore(i32, @as(*i32, @ptrCast(@volatileCast(&c.g_popup_active))), 0, .seq_cst);
    _ = @atomicRmw(u32, @as(*u32, @ptrCast(@volatileCast(&c.g_popup_gen))), .Add, 1, .seq_cst);
}
