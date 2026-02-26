// Attyx — Popup terminal (tmux-style)
//
// Core lifecycle: spawn/deinit popup PTY+Engine, convert cells for rendering,
// publish to C bridge globals. Imported by ui2.zig.

const std = @import("std");
const posix = std.posix;
const attyx = @import("attyx");
const Engine = attyx.Engine;
const color_mod = attyx.render_color;
const Pty = @import("pty.zig").Pty;
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

pub const PopupConfig = struct {
    command: []const u8, // e.g. "lazygit"
    width_pct: u8, // 1-100
    height_pct: u8, // 1-100
    border_style: BorderStyle,
    border_fg: [3]u8, // r, g, b
};

pub const PopupState = struct {
    engine: *Engine,
    pty: Pty,
    config_index: u8, // which PopupConfig spawned this
    cols: u16, // inner terminal grid cols
    rows: u16, // inner terminal grid rows
    outer_col: u16, // position on main grid (top-left)
    outer_row: u16,
    outer_w: u16, // total including border
    outer_h: u16,
    allocator: std.mem.Allocator,

    pub fn spawn(allocator: std.mem.Allocator, cfg: PopupConfig, grid_cols: u16, grid_rows: u16, cwd: ?[]const u8) !PopupState {
        const dims = calcDims(cfg, grid_cols, grid_rows);

        var engine = try allocator.create(Engine);
        engine.* = try Engine.init(allocator, dims.rows, dims.cols);
        errdefer {
            engine.deinit();
            allocator.destroy(engine);
        }

        // Build argv: $SHELL -c '<command>'
        const shell_env = std.posix.getenv("SHELL") orelse "/bin/sh";
        const shell_z = try allocator.dupeZ(u8, shell_env);
        defer allocator.free(shell_z);
        const c_flag: [:0]const u8 = "-c";
        const cmd_z = try allocator.dupeZ(u8, cfg.command);
        defer allocator.free(cmd_z);

        const argv = [_][:0]const u8{ shell_z, c_flag, cmd_z };

        const cwd_z: ?[:0]u8 = if (cwd) |d| allocator.dupeZ(u8, d) catch null else null;
        defer if (cwd_z) |z| allocator.free(z);

        const pty = try Pty.spawn(.{
            .rows = dims.rows,
            .cols = dims.cols,
            .argv = &argv,
            .cwd = if (cwd_z) |z| z.ptr else null,
        });

        return .{
            .engine = engine,
            .pty = pty,
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
        // Send SIGHUP to child
        _ = std.posix.kill(self.pty.pid, std.posix.SIG.HUP) catch {};
        self.pty.deinit();
        self.engine.deinit();
        self.allocator.destroy(self.engine);
    }

    pub fn resize(self: *PopupState, cfg: PopupConfig, grid_cols: u16, grid_rows: u16) void {
        const dims = calcDims(cfg, grid_cols, grid_rows);
        self.cols = dims.cols;
        self.rows = dims.rows;
        self.outer_col = dims.outer_col;
        self.outer_row = dims.outer_row;
        self.outer_w = dims.outer_w;
        self.outer_h = dims.outer_h;
        self.engine.state.resize(dims.rows, dims.cols) catch {};
        self.pty.resize(dims.rows, dims.cols) catch {};
    }

    pub fn feed(self: *PopupState, data: []const u8) void {
        self.engine.feed(data);
        if (self.engine.state.drainResponse()) |resp| {
            _ = self.pty.writeToPty(resp) catch {};
        }
    }

    pub fn publishCells(self: *PopupState, theme: *const Theme, cfg: PopupConfig) void {
        const ow: usize = self.outer_w;
        const oh: usize = self.outer_h;
        const total = ow * oh;
        if (total > c.ATTYX_POPUP_MAX_CELLS) return;

        const has_border = cfg.border_style != .none;
        const offset: usize = if (has_border) 1 else 0;

        // Fill border + inner cells
        var ci: usize = 0;
        for (0..oh) |r| {
            for (0..ow) |col| {
                if (ci >= c.ATTYX_POPUP_MAX_CELLS) break;
                if (has_border and (r == 0 or r == oh - 1 or col == 0 or col == ow - 1)) {
                    // Border cell
                    c.g_popup_cells[ci] = borderCell(r, col, ow, oh, cfg.border_style, cfg.border_fg);
                } else {
                    // Inner cell — map from engine grid
                    const inner_r = r - offset;
                    const inner_c = col - offset;
                    const grid_idx = inner_r * self.cols + inner_c;
                    if (inner_r < self.rows and inner_c < self.cols and
                        grid_idx < self.engine.state.grid.cells.len)
                    {
                        const cell = self.engine.state.grid.cells[grid_idx];
                        c.g_popup_cells[ci] = cellToOverlayCell(cell, theme);
                    } else {
                        c.g_popup_cells[ci] = defaultCell(theme);
                    }
                }
                ci += 1;
            }
        }

        // Publish descriptor
        const cursor_vis: bool = self.engine.state.cursor_visible;
        c.g_popup_desc = .{
            .active = 1,
            .col = @intCast(self.outer_col),
            .row = @intCast(self.outer_row),
            .width = @intCast(self.outer_w),
            .height = @intCast(self.outer_h),
            .inner_cols = @intCast(self.cols),
            .inner_rows = @intCast(self.rows),
            .cursor_row = @intCast(self.engine.state.cursor.row + offset),
            .cursor_col = @intCast(self.engine.state.cursor.col + offset),
            .cursor_visible = if (cursor_vis) 1 else 0,
            .cursor_shape = @intCast(@intFromEnum(self.engine.state.cursor_shape)),
        };

        _ = @atomicRmw(u32, @as(*u32, @ptrCast(@volatileCast(&c.g_popup_gen))), .Add, 1, .seq_cst);
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
    const min_size: u16 = if (has_border) 4 else 1;
    const outer_w = @max(raw_w, min_size);
    const outer_h = @max(raw_h, min_size);
    const inner_cols = outer_w - border;
    const inner_rows = outer_h - border;
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

/// Clear the popup bridge state (called when popup closes).
pub fn clearBridgeState() void {
    c.g_popup_desc.active = 0;
    @atomicStore(i32, @as(*i32, @ptrCast(@volatileCast(&c.g_popup_active))), 0, .seq_cst);
    _ = @atomicRmw(u32, @as(*u32, @ptrCast(@volatileCast(&c.g_popup_gen))), .Add, 1, .seq_cst);
}
