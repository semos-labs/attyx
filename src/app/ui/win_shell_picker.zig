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
    // Start async read immediately — ConPTY only flushes output when a
    // ReadFile is pending. cmd.exe/PowerShell start fast and produce their
    // banner before we'd normally call startAsyncRead in switchActiveTab,
    // so that initial output is lost if no read is pending.
    new_pane.pty.startAsyncRead();
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

const Element = attyx.overlay_ui.Element;
const panel_mod = attyx.overlay_panel;

fn renderAndPublish(ctx: *WinCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    const theme = publish.overlayThemeFromTheme(ctx.theme);

    // Build menu items from shell entries.
    var menu_items: [entry_count]Element.MenuItem = undefined;
    for (shell_entries, 0..) |entry, i| {
        menu_items[i] = .{ .label = entry.label };
    }

    const menu = Element{ .menu = .{
        .items = &menu_items,
        .selected = g_selected,
        .selected_style = .{ .bg = theme.selected_bg, .fg = theme.selected_fg },
    } };

    const result = panel_mod.renderPanel(
        ctx.allocator,
        .{
            .title = "Select Shell",
            .width = .{ .cells = 30 },
            .height = .{ .cells = entry_count + 4 },
            .border = .rounded,
            .theme = theme,
        },
        menu,
        ctx.grid_cols,
        ctx.grid_rows,
    ) catch return;

    if (result.width == 0 or result.height == 0) return;

    mgr.setContent(
        .shell_picker,
        result.col,
        result.row,
        result.width,
        result.height,
        result.cells,
    ) catch {};
    mgr.show(.shell_picker);
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.shell_picker)].backdrop_alpha = 100;
    ctx.allocator.free(result.cells);

    win_search.publishOverlays(ctx);
}
