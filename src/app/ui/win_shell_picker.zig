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

const ShellEntry = struct {
    shell: ShellType,
    label: []const u8,
    /// For shells not in ShellType (e.g. Git Bash), the full path to pass as shell override.
    shell_override: []const u8 = "",
};

const max_entries = 12;
var g_entries: [max_entries]ShellEntry = undefined;
var g_entry_count: u8 = 0;
var g_selected: u8 = 0;

// Storage for dynamically built WSL labels (e.g. "Ubuntu (WSL)")
const max_wsl_distros = 6;
var g_wsl_labels: [max_wsl_distros][64]u8 = undefined;
var g_wsl_overrides: [max_wsl_distros][80]u8 = undefined;

// Registry bindings for WSL distro enumeration
const HKEY = *opaque {};
const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
const KEY_READ: u32 = 0x20019;
const LPCWSTR = [*:0]const u16;
const DWORD = u32;

extern "advapi32" fn RegOpenKeyExW(hKey: HKEY, lpSubKey: LPCWSTR, ulOptions: DWORD, samDesired: DWORD, phkResult: *?HKEY) callconv(.winapi) DWORD;
extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) DWORD;
extern "advapi32" fn RegEnumKeyExW(hKey: HKEY, dwIndex: DWORD, lpName: [*]u16, lpcchName: *DWORD, lpReserved: ?*DWORD, lpClass: ?[*]u16, lpcchClass: ?*DWORD, lpftLastWriteTime: ?*u64) callconv(.winapi) DWORD;
extern "advapi32" fn RegQueryValueExW(hKey: HKEY, lpValueName: ?LPCWSTR, lpReserved: ?*DWORD, lpType: ?*DWORD, lpData: ?[*]u8, lpcbData: ?*DWORD) callconv(.winapi) DWORD;

fn addWslDistros() void {
    const lxss_path = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Lxss");
    var lxss_key: ?HKEY = null;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, lxss_path, 0, KEY_READ, &lxss_key) != 0)
        return;
    defer _ = RegCloseKey(lxss_key.?);

    var wsl_count: u8 = 0;
    var idx: u32 = 0;
    while (wsl_count < max_wsl_distros and g_entry_count < max_entries) {
        var subkey_name: [256]u16 = undefined;
        var subkey_len: u32 = subkey_name.len;
        if (RegEnumKeyExW(lxss_key.?, idx, &subkey_name, &subkey_len, null, null, null, null) != 0)
            break;
        idx += 1;

        var distro_key: ?HKEY = null;
        if (RegOpenKeyExW(lxss_key.?, subkey_name[0..subkey_len :0], 0, KEY_READ, &distro_key) != 0)
            continue;
        defer _ = RegCloseKey(distro_key.?);

        const val_name = std.unicode.utf8ToUtf16LeStringLiteral("DistributionName");
        var distro_w: [128]u16 = undefined;
        var distro_sz: u32 = @sizeOf(@TypeOf(distro_w));
        var val_type: u32 = 0;
        if (RegQueryValueExW(distro_key.?, val_name, null, &val_type, @ptrCast(&distro_w), &distro_sz) != 0)
            continue;

        // Convert UTF-16 distro name to UTF-8
        const distro_w_len = distro_sz / 2 - 1; // exclude null terminator
        var distro_utf8: [64]u8 = undefined;
        const utf8_len = std.unicode.utf16LeToUtf8(&distro_utf8, distro_w[0..distro_w_len]) catch continue;
        const distro_name = distro_utf8[0..utf8_len];

        // Build label: "Ubuntu (WSL)"
        const label_buf = &g_wsl_labels[wsl_count];
        const label_slice = std.fmt.bufPrint(label_buf, "{s} (WSL)", .{distro_name}) catch continue;

        // Build override: "wsl -d Ubuntu"
        const override_buf = &g_wsl_overrides[wsl_count];
        const override_slice = std.fmt.bufPrint(override_buf, "wsl -d {s}", .{distro_name}) catch continue;

        g_entries[g_entry_count] = .{
            .shell = .wsl,
            .label = label_slice,
            .shell_override = override_slice,
        };
        g_entry_count += 1;
        wsl_count += 1;
    }
}

fn buildEntries() void {
    g_entry_count = 0;

    // PowerShell first (default)
    g_entries[g_entry_count] = .{ .shell = .pwsh, .label = "PowerShell" };
    g_entry_count += 1;

    // WSL distros
    addWslDistros();

    // Git Bash — only if installed
    if (@import("../pty_windows.zig").findGitBashUtf8()) |_| {
        g_entries[g_entry_count] = .{ .shell = .auto, .label = "Git Bash", .shell_override = "bash" };
        g_entry_count += 1;
    }

    // zsh — only if installed (bundled sysroot or system MSYS2)
    if (@import("../bundled_shell.zig").findBundledZsh()) |_| {
        g_entries[g_entry_count] = .{ .shell = .zsh, .label = "zsh (MSYS2)" };
        g_entry_count += 1;
    }

    g_entries[g_entry_count] = .{ .shell = .cmd, .label = "Command Prompt" };
    g_entry_count += 1;
}

pub fn open(ctx: *WinCtx) void {
    buildEntries();
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
                if (g_selected + 1 < g_entry_count) g_selected += 1;
            },
            8 => { // Enter / confirm
                const entry = g_entries[g_selected];
                close(ctx);
                spawnShellTab(ctx, entry);
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

fn spawnShellTab(ctx: *WinCtx, entry: ShellEntry) void {
    const shell = entry.shell;
    const rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - ws.g_grid_top_offset - ws.g_grid_bottom_offset));

    if (ctx.session_client) |sc| {
        // Daemon mode: create daemon-backed pane with shell override.
        const shell_name: []const u8 = if (entry.shell_override.len > 0) entry.shell_override else switch (shell) {
            .zsh => "zsh",
            .pwsh => "pwsh.exe",
            .cmd => "cmd.exe",
            .wsl => "wsl.exe",
            .auto => "",
        };
        sc.sendCreatePaneWithShell(rows, ctx.grid_cols, "", shell_name) catch {
            logging.err("shell-picker", "sendCreatePaneWithShell failed", .{});
            return;
        };
        const pane_id = sc.waitForPaneCreated(5000) catch |err| {
            logging.err("shell-picker", "create daemon pane failed: {}", .{err});
            return;
        };
        const new_pane = ctx.tab_mgr.addDaemonTab(rows, ctx.grid_cols, ctx.applied_scrollback_lines) catch |err| {
            logging.err("shell-picker", "addDaemonTab failed: {}", .{err});
            return;
        };
        new_pane.daemon_pane_id = pane_id;
        new_pane.session_client = sc;
        sc.sendFocusPanes(&.{pane_id}) catch {};
    } else {
        // Local mode: for custom shells (Git Bash, WSL distros), resolve
        // the executable path and pass as argv.
        const S = struct {
            var argv_storage: [2][:0]const u8 = undefined;
            var path_buf: [512:0]u8 = undefined;
        };
        var argv_slice: ?[]const [:0]const u8 = null;
        if (entry.shell_override.len > 0) {
            if (std.mem.eql(u8, entry.shell_override, "bash")) {
                if (@import("../pty_windows.zig").findGitBashUtf8()) |path| {
                    @memcpy(S.path_buf[0..path.len], path);
                    S.path_buf[path.len] = 0;
                    S.argv_storage[0] = S.path_buf[0..path.len :0];
                    argv_slice = S.argv_storage[0..1];
                }
            } else if (std.mem.startsWith(u8, entry.shell_override, "wsl")) {
                // WSL: pass the full "wsl -d DistroName" as argv
                @memcpy(S.path_buf[0..entry.shell_override.len], entry.shell_override);
                S.path_buf[entry.shell_override.len] = 0;
                S.argv_storage[0] = S.path_buf[0..entry.shell_override.len :0];
                argv_slice = S.argv_storage[0..1];
            }
        }
        const new_pane = ctx.allocator.create(Pane) catch return;
        new_pane.* = Pane.spawnOpts(ctx.allocator, rows, ctx.grid_cols, argv_slice, null, ctx.applied_scrollback_lines, .{ .shell = shell }) catch |err| {
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
    }

    event_loop.updateGridOffsets(ctx);
    const pane = ctx.tab_mgr.activePane();
    pane.engine.state.theme_colors = publish.themeToEngineColors(ctx.theme);
    pane.engine.state.dirty.markAll(pane.engine.state.ring.screen_rows);
    event_loop.switchActiveTab(ctx);
    event_loop.saveLayoutToDaemon(ctx);
    logging.info("shell-picker", "opened new tab with {s}", .{entry.label});
}

// ── Rendering ──

const Element = attyx.overlay_ui.Element;
const panel_mod = attyx.overlay_panel;

fn renderAndPublish(ctx: *WinCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    const theme = publish.overlayThemeFromTheme(ctx.theme);

    // Build menu items from shell entries.
    var menu_items: [max_entries]Element.MenuItem = undefined;
    for (g_entries[0..g_entry_count], 0..) |entry, i| {
        menu_items[i] = .{ .label = entry.label };
    }

    const menu = Element{ .menu = .{
        .items = menu_items[0..g_entry_count],
        .selected = g_selected,
        .selected_style = .{ .bg = theme.selected_bg, .fg = theme.selected_fg },
    } };

    const result = panel_mod.renderPanel(
        ctx.allocator,
        .{
            .title = "Select Shell",
            .width = .{ .cells = 30 },
            .height = .{ .cells = g_entry_count + 4 },
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
