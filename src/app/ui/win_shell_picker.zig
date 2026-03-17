// Windows shell picker — lets users choose which shell to open in a new tab.
// Shows a simple list: zsh (MSYS2), PowerShell, Command Prompt.

const std = @import("std");
const attyx = @import("attyx");
const overlay_mod = attyx.overlay_mod;
const StyledCell = overlay_mod.StyledCell;
const Rgb = overlay_mod.Rgb;
const ws = @import("../windows_stubs.zig");
const publish = @import("publish.zig");
const c = publish.c;
const win_search = @import("win_search.zig");
const event_loop = @import("event_loop_windows.zig");
const WinCtx = event_loop.WinCtx;
const Pty = @import("../pty_windows.zig").Pty;
const Pane = @import("../pane.zig").Pane;
const logging = @import("../../logging/log.zig");

const ShellType = Pty.ShellType;

const shell_entries = [_]struct { shell: ShellType, label: []const u8 }{
    .{ .shell = .zsh, .label = "zsh (MSYS2)" },
    .{ .shell = .pwsh, .label = "PowerShell" },
    .{ .shell = .cmd, .label = "Command Prompt" },
};
const entry_count: u8 = shell_entries.len;

var g_selected: u8 = 0;

pub fn open(ctx: *WinCtx) void {
    g_selected = 0;
    @atomicStore(i32, &ws.g_shell_picker_active, 1, .seq_cst);
    renderAndPublish(ctx);
}

pub fn close(ctx: *WinCtx) void {
    @atomicStore(i32, &ws.g_shell_picker_active, 0, .seq_cst);
    if (ctx.overlay_mgr) |mgr| mgr.hide(.shell_picker);
    win_search.publishOverlays(ctx);
}

pub fn consumeInput(ctx: *WinCtx) bool {
    var consumed = false;

    // Character ring (typed characters — not used for this picker, but drain them)
    while (true) {
        const r = @atomicLoad(u32, &ws.picker_char_read, .seq_cst);
        const w = @atomicLoad(u32, &ws.picker_char_write, .seq_cst);
        if (r == w) break;
        @atomicStore(u32, &ws.picker_char_read, r +% 1, .seq_cst);
        consumed = true;
    }

    // Command ring (arrow keys, enter, esc)
    while (true) {
        const r = @atomicLoad(u32, &ws.picker_cmd_read, .seq_cst);
        const w = @atomicLoad(u32, &ws.picker_cmd_write, .seq_cst);
        if (r == w) break;
        const cmd = ws.picker_cmd_ring[r % 16];
        @atomicStore(u32, &ws.picker_cmd_read, r +% 1, .seq_cst);
        consumed = true;

        switch (cmd) {
            9 => { // Up
                if (g_selected > 0) g_selected -= 1;
            },
            10 => { // Down
                if (g_selected < entry_count - 1) g_selected += 1;
            },
            8 => { // Enter / confirm
                const selected_shell = shell_entries[g_selected].shell;
                close(ctx);
                spawnShellTab(ctx, selected_shell);
                return true;
            },
            7 => { // Esc
                close(ctx);
                return true;
            },
            else => {},
        }
    }

    if (consumed) renderAndPublish(ctx);
    return consumed;
}

fn spawnShellTab(ctx: *WinCtx, shell: ShellType) void {
    const rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - ws.g_grid_top_offset - ws.g_grid_bottom_offset));

    // Always spawn locally with the selected shell. The daemon protocol
    // doesn't support per-pane shell override, and the user explicitly
    // chose a non-default shell — local spawn is the right call.
    const new_pane = ctx.allocator.create(Pane) catch return;
    new_pane.* = Pane.spawnOpts(ctx.allocator, rows, ctx.grid_cols, null, null, ctx.applied_scrollback_lines, .{ .shell = shell }) catch |err| {
        logging.err("shell-picker", "Pane.spawn failed: {}", .{err});
        ctx.allocator.destroy(new_pane);
        return;
    };
    ctx.tab_mgr.addTabWithPane(new_pane, rows, ctx.grid_cols) catch |err| {
        logging.err("shell-picker", "addTabWithPane failed: {}", .{err});
        new_pane.deinit();
        ctx.allocator.destroy(new_pane);
        return;
    };

    event_loop.updateGridOffsets(ctx);
    const pane = ctx.tab_mgr.activePane();
    pane.engine.state.theme_colors = publish.themeToEngineColors(ctx.theme);
    pane.engine.state.dirty.markAll(pane.engine.state.ring.screen_rows);
    event_loop.switchActiveTab(ctx);
    event_loop.saveLayoutToDaemon(ctx);
    logging.info("shell-picker", "opened new tab with {s}", .{@tagName(shell)});
}

// ── Rendering ──

fn renderAndPublish(ctx: *WinCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    const theme = publish.overlayThemeFromTheme(ctx.theme);

    const panel_width: u16 = 30;
    const panel_height: u16 = entry_count + 3; // title + separator + entries + bottom border
    const col = if (ctx.grid_cols > panel_width) (ctx.grid_cols - panel_width) / 2 else 0;
    const row = if (ctx.grid_rows > panel_height + 2) (ctx.grid_rows - panel_height) / 3 else 0;

    const total = @as(usize, panel_width) * @as(usize, panel_height);
    const cells = ctx.allocator.alloc(StyledCell, total) catch return;

    const bg = theme.bg;
    const fg = theme.fg;
    const highlight_bg = theme.selected_bg;
    const highlight_fg = theme.selected_fg;
    const dim_fg = theme.border_color;

    // Fill background
    for (cells) |*cell| {
        cell.* = .{ .char = ' ', .fg = fg, .bg = bg, .bg_alpha = 230 };
    }

    // Title row
    const title = "Select Shell";
    writeString(cells, 0, (panel_width - @as(u16, @intCast(title.len))) / 2, panel_width, title, fg, bg, 230);

    // Separator row
    for (0..panel_width) |x| {
        cells[1 * panel_width + x] = .{ .char = 0x2500, .fg = dim_fg, .bg = bg, .bg_alpha = 230 }; // ─
    }

    // Entries
    for (shell_entries, 0..) |entry, i| {
        const y: u16 = @intCast(2 + i);
        const is_selected = (@as(u8, @intCast(i)) == g_selected);
        const entry_bg = if (is_selected) highlight_bg else bg;
        const entry_fg = if (is_selected) highlight_fg else fg;
        const alpha: u8 = 230;

        // Fill row background
        for (0..panel_width) |x| {
            cells[y * panel_width + x] = .{ .char = ' ', .fg = entry_fg, .bg = entry_bg, .bg_alpha = alpha };
        }

        // Indicator
        const indicator: u21 = if (is_selected) 0x25B8 else ' '; // ▸
        cells[y * panel_width + 1] = .{ .char = indicator, .fg = entry_fg, .bg = entry_bg, .bg_alpha = alpha };

        // Label
        writeString(cells, y, 3, panel_width, entry.label, entry_fg, entry_bg, alpha);
    }

    mgr.setContent(.shell_picker, col, row, panel_width, panel_height, cells) catch {
        ctx.allocator.free(cells);
        return;
    };
    mgr.show(.shell_picker);
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.shell_picker)].backdrop_alpha = 100;
    ctx.allocator.free(cells);

    win_search.publishOverlays(ctx);
}

fn writeString(
    cells: []StyledCell,
    row: u16,
    col: u16,
    width: u16,
    text: []const u8,
    fg: Rgb,
    bg: Rgb,
    alpha: u8,
) void {
    for (text, 0..) |ch, i| {
        const x = col + @as(u16, @intCast(i));
        if (x >= width) break;
        cells[@as(usize, row) * @as(usize, width) + @as(usize, x)] = .{
            .char = ch,
            .fg = fg,
            .bg = bg,
            .bg_alpha = alpha,
        };
    }
}
