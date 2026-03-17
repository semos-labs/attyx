// Attyx — Windows IPC command handler
//
// Handles IPC commands using WinCtx instead of PtyThreadCtx.
// Supports dispatch-based commands, send_keys, and queries.

const std = @import("std");
const protocol = @import("protocol.zig");
const queue = @import("queue.zig");
const keybinds = @import("../config/keybinds.zig");
const Action = keybinds.Action;
const split_layout_mod = @import("../app/split_layout.zig");
const event_loop = @import("../app/ui/event_loop_windows.zig");
const WinCtx = event_loop.WinCtx;
const Pane = @import("../app/pane.zig").Pane;
const session_win = @import("../app/session_windows.zig");

extern fn attyx_dispatch_action(action_raw: u8) u8;
extern fn attyx_send_input(bytes: [*]const u8, len: c_int) void;

pub fn handle(cmd: *queue.IpcCommand, ctx: *WinCtx) void {
    const msg_type = std.meta.intToEnum(protocol.MessageType, cmd.msg_type) catch {
        sendError(cmd, "unknown command");
        return;
    };

    switch (msg_type) {
        // ── Tab commands ──
        .tab_create => handleTabCreate(cmd, ctx),
        .tab_close => { dispatch(.tab_close); sendOk(cmd, ""); },
        .tab_close_targeted => handleTabCloseTargeted(cmd, ctx),
        .tab_next => { dispatch(.tab_next); sendOk(cmd, ""); },
        .tab_prev => { dispatch(.tab_prev); sendOk(cmd, ""); },
        .tab_select => {
            if (cmd.payload_len >= 1) {
                const idx = cmd.payload[0];
                if (idx >= 1 and idx <= 9) {
                    const av = @intFromEnum(Action.tab_select_1) + idx - 1;
                    dispatch(@enumFromInt(av));
                }
            }
            sendOk(cmd, "");
        },
        .tab_move_left => { dispatch(.tab_move_left); sendOk(cmd, ""); },
        .tab_move_right => { dispatch(.tab_move_right); sendOk(cmd, ""); },
        .tab_rename => {
            if (cmd.payload_len > 0) {
                ctx.tab_mgr.activePane().setCustomTitle(cmd.payload[0..cmd.payload_len]);
            }
            sendOk(cmd, "");
        },

        // ── Split / pane ──
        .split_vertical => handleSplit(cmd, ctx, .vertical),
        .split_horizontal => handleSplit(cmd, ctx, .horizontal),
        .pane_close => { dispatch(.pane_close); sendOk(cmd, ""); },
        .pane_close_targeted => handlePaneCloseTargeted(cmd, ctx),
        .pane_rotate => { dispatch(.pane_rotate); sendOk(cmd, ""); },
        .pane_zoom_toggle => { dispatch(.pane_zoom_toggle); sendOk(cmd, ""); },

        // ── Focus ──
        .focus_up => { dispatch(.pane_focus_up); sendOk(cmd, ""); },
        .focus_down => { dispatch(.pane_focus_down); sendOk(cmd, ""); },
        .focus_left => { dispatch(.pane_focus_left); sendOk(cmd, ""); },
        .focus_right => { dispatch(.pane_focus_right); sendOk(cmd, ""); },

        // ── Scroll ──
        .scroll_to_top => { dispatch(.scroll_to_top); sendOk(cmd, ""); },
        .scroll_to_bottom => { dispatch(.scroll_to_bottom); sendOk(cmd, ""); },
        .scroll_page_up => { dispatch(.scroll_page_up); sendOk(cmd, ""); },
        .scroll_page_down => { dispatch(.scroll_page_down); sendOk(cmd, ""); },

        // ── Config ──
        .config_reload => { dispatch(.config_reload); sendOk(cmd, ""); },

        // ── Text / IO ──
        .send_keys, .send_text => {
            if (cmd.payload_len > 0) {
                attyx_send_input(cmd.payload[0..cmd.payload_len].ptr, @intCast(cmd.payload_len));
            }
            sendOk(cmd, "");
        },
        .send_keys_pane, .send_text_pane => {
            if (cmd.payload_len < 5) {
                sendError(cmd, "missing pane ID or text");
                return;
            }
            const pane_id = std.mem.readInt(u32, cmd.payload[0..4], .little);
            const text = cmd.payload[4..cmd.payload_len];
            const pane = ctx.tab_mgr.findPaneById(pane_id) orelse {
                sendError(cmd, "pane not found");
                return;
            };
            _ = pane.pty.writeToPty(text) catch {};
            sendOk(cmd, "");
        },
        .get_text => {
            writeScreenText(cmd, ctx.tab_mgr.activePane());
        },
        .get_text_pane => {
            if (cmd.payload_len < 4) {
                sendError(cmd, "missing pane ID");
                return;
            }
            const pane_id = std.mem.readInt(u32, cmd.payload[0..4], .little);
            const pane = ctx.tab_mgr.findPaneById(pane_id) orelse {
                sendError(cmd, "pane not found");
                return;
            };
            writeScreenText(cmd, pane);
        },

        // ── Query ──
        .list => buildList(cmd, ctx),
        .list_tabs => buildTabList(cmd, ctx),
        .list_splits => buildSplitList(cmd, ctx),

        // ── Wait variants (hold response until process exits) ──
        .tab_create_wait => {
            if (cmd.payload_len > 0)
                handleWaitCreate(cmd, ctx, .tab)
            else
                sendError(cmd, "--wait requires --cmd");
        },
        .split_vertical_wait => {
            if (cmd.payload_len > 0)
                handleWaitCreate(cmd, ctx, .split_v)
            else
                sendError(cmd, "--wait requires --cmd");
        },
        .split_horizontal_wait => {
            if (cmd.payload_len > 0)
                handleWaitCreate(cmd, ctx, .split_h)
            else
                sendError(cmd, "--wait requires --cmd");
        },
        .popup => handlePopup(cmd, ctx),
        .theme_set => handleThemeSet(cmd, ctx),
        .session_list => handleSessionList(cmd, ctx),
        .session_create => handleSessionCreate(cmd, ctx),
        .session_kill => handleSessionKill(cmd, ctx),
        .session_switch => handleSessionSwitch(cmd, ctx),
        .session_rename => handleSessionRename(cmd, ctx),
        .session_envelope => sendError(cmd, "unexpected session envelope"),
        .tab_rename_targeted => handleTabRenameTargeted(cmd, ctx),
        .pane_rotate_targeted => handlePaneRotateTargeted(cmd, ctx),
        .pane_zoom_targeted => handlePaneZoomTargeted(cmd, ctx),
        .success, .err, .exit_code => sendError(cmd, "unexpected message type"),
    }
}

fn dispatch(action: Action) void {
    _ = attyx_dispatch_action(@intFromEnum(action));
}

fn handleTabCreate(cmd: *queue.IpcCommand, ctx: *WinCtx) void {
    const rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - @import("../app/windows_stubs.zig").g_grid_top_offset - @import("../app/windows_stubs.zig").g_grid_bottom_offset));
    ctx.tab_mgr.addTab(rows, ctx.grid_cols, null, ctx.applied_scrollback_lines) catch {
        sendError(cmd, "failed to create tab");
        return;
    };
    event_loop.updateGridOffsets(ctx);
    const publish = @import("../app/ui/publish.zig");
    ctx.tab_mgr.activePane().engine.state.theme_colors = publish.themeToEngineColors(ctx.theme);
    event_loop.switchActiveTab(ctx);
    // Return the new pane's IPC ID
    var id_buf: [16]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{ctx.tab_mgr.activePane().ipc_id}) catch "";
    sendOk(cmd, id_str);
}

fn handleSplit(cmd: *queue.IpcCommand, ctx: *WinCtx, dir: split_layout_mod.Direction) void {
    const ws = @import("../app/windows_stubs.zig");
    const layout = ctx.tab_mgr.activeLayout();
    const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - ws.g_grid_top_offset - ws.g_grid_bottom_offset));
    const publish = @import("../app/ui/publish.zig");

    const new_pane = ctx.allocator.create(Pane) catch {
        sendError(cmd, "failed to create pane");
        return;
    };
    new_pane.* = Pane.spawn(ctx.allocator, pty_rows, ctx.grid_cols, null, null, ctx.applied_scrollback_lines) catch {
        ctx.allocator.destroy(new_pane);
        sendError(cmd, "failed to spawn pane");
        return;
    };
    ctx.tab_mgr.assignIpcId(new_pane);
    new_pane.engine.state.theme_colors = publish.themeToEngineColors(ctx.theme);
    layout.splitPaneWith(dir, new_pane) catch {
        new_pane.deinit();
        ctx.allocator.destroy(new_pane);
        sendError(cmd, "failed to split");
        return;
    };
    layout.layout(pty_rows, ctx.grid_cols);
    event_loop.switchActiveTab(ctx);

    var id_buf: [16]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{new_pane.ipc_id}) catch "";
    sendOk(cmd, id_str);
}

fn handleWaitCreate(cmd: *queue.IpcCommand, ctx: *WinCtx, mode: enum { tab, split_v, split_h }) void {
    const command = cmd.payload[0..cmd.payload_len];
    const ws = @import("../app/windows_stubs.zig");
    const publish = @import("../app/ui/publish.zig");
    const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - ws.g_grid_top_offset - ws.g_grid_bottom_offset));

    // Build "pwsh.exe -NoProfile -Command <command>" argv (fallback to cmd.exe /c)
    const shell_info = resolveShellForCommand(ctx.allocator) orelse {
        sendError(cmd, "out of memory");
        return;
    };
    defer ctx.allocator.free(shell_info.shell_z);
    defer ctx.allocator.free(shell_info.flag_z);
    const cmd_z = ctx.allocator.dupeZ(u8, command) catch {
        sendError(cmd, "out of memory");
        return;
    };
    defer ctx.allocator.free(cmd_z);
    const argv = [3][:0]const u8{ shell_info.shell_z, shell_info.flag_z, cmd_z };

    // Spawn pane with command
    const pane = ctx.allocator.create(Pane) catch {
        sendError(cmd, "out of memory");
        return;
    };
    pane.* = Pane.spawn(ctx.allocator, pty_rows, ctx.grid_cols, &argv, null, ctx.applied_scrollback_lines) catch {
        ctx.allocator.destroy(pane);
        sendError(cmd, "failed to spawn pane");
        return;
    };
    ctx.tab_mgr.assignIpcId(pane);
    pane.engine.state.theme_colors = publish.themeToEngineColors(ctx.theme);

    switch (mode) {
        .tab => {
            ctx.tab_mgr.addTabWithPane(pane, pty_rows, ctx.grid_cols) catch {
                pane.deinit();
                ctx.allocator.destroy(pane);
                sendError(cmd, "failed to create tab");
                return;
            };
            event_loop.updateGridOffsets(ctx);
            event_loop.switchActiveTab(ctx);
        },
        .split_v, .split_h => {
            const dir: split_layout_mod.Direction = if (mode == .split_v) .vertical else .horizontal;
            const layout = ctx.tab_mgr.activeLayout();
            layout.splitPaneWith(dir, pane) catch {
                pane.deinit();
                ctx.allocator.destroy(pane);
                sendError(cmd, "failed to split");
                return;
            };
            layout.layout(pty_rows, ctx.grid_cols);
            event_loop.switchActiveTab(ctx);
        },
    }

    // Transfer response_fd ownership to the pane — response sent on exit.
    pane.ipc_wait_fd = cmd.response_fd;
    cmd.response_fd = queue.invalid_fd; // prevent sendOk/sendError from closing it
}

fn handleTabCloseTargeted(cmd: *queue.IpcCommand, ctx: *WinCtx) void {
    if (cmd.payload_len < 1) { sendError(cmd, "missing tab index"); return; }
    const idx = cmd.payload[0];
    if (idx == 0 or idx > ctx.tab_mgr.count) { sendError(cmd, "invalid tab index"); return; }
    ctx.tab_mgr.closeTab(idx - 1);
    if (ctx.tab_mgr.count == 0) {
        @import("../app/ui/publish.zig").c.attyx_request_quit();
    } else {
        event_loop.updateGridOffsets(ctx);
        event_loop.switchActiveTab(ctx);
    }
    sendOk(cmd, "");
}

fn handlePaneCloseTargeted(cmd: *queue.IpcCommand, ctx: *WinCtx) void {
    if (cmd.payload_len < 4) { sendError(cmd, "missing pane ID"); return; }
    const pane_id = std.mem.readInt(u32, cmd.payload[0..4], .little);
    const ws = @import("../app/windows_stubs.zig");
    const found = ctx.tab_mgr.findPaneWithLayout(pane_id) orelse {
        sendError(cmd, "pane not found");
        return;
    };
    // Find which tab index this layout belongs to
    const tab_idx: u8 = for (0..ctx.tab_mgr.count) |i| {
        if (ctx.tab_mgr.tabs[i]) |*tab_layout| {
            if (tab_layout == found.layout) break @as(u8, @intCast(i));
        }
    } else ctx.tab_mgr.active;

    if (found.layout.pane_count <= 1) {
        ctx.tab_mgr.closeTab(tab_idx);
        if (ctx.tab_mgr.count == 0) {
            @import("../app/ui/publish.zig").c.attyx_request_quit();
        } else {
            event_loop.updateGridOffsets(ctx);
            event_loop.switchActiveTab(ctx);
        }
    } else {
        _ = found.layout.closePaneAt(found.pool_idx, ctx.allocator);
        const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - ws.g_grid_top_offset - ws.g_grid_bottom_offset));
        found.layout.layout(pty_rows, ctx.grid_cols);
        if (tab_idx == ctx.tab_mgr.active) event_loop.switchActiveTab(ctx);
    }
    sendOk(cmd, "");
}

// ── Query builders ──

fn resolveTitle(pane: *Pane) []const u8 {
    return pane.getCustomTitle() orelse
        pane.engine.state.title orelse
        "shell";
}

fn buildList(cmd: *queue.IpcCommand, ctx: *WinCtx) void {
    var buf: [8192]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();
    const mgr = ctx.tab_mgr;
    for (0..mgr.count) |i| {
        const layout = &(mgr.tabs[i] orelse continue);
        const is_active = (i == mgr.active);
        const title = resolveTitle(layout.focusedPane());
        w.print("{d}\t{s}", .{ i + 1, title }) catch break;
        if (is_active) w.writeAll("\t*") catch break;
        w.print("\tpane:{d}", .{layout.focusedPane().ipc_id}) catch break;
        if (layout.pane_count > 1) w.print("\t{d} panes", .{layout.pane_count}) catch break;
        if (layout.isZoomed()) w.writeAll("\tzoomed") catch break;
        w.writeAll("\n") catch break;
        if (layout.pane_count > 1) {
            var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
            const lc = layout.collectLeaves(&leaves);
            for (leaves[0..lc]) |leaf| {
                const pt = resolveTitle(leaf.pane);
                w.print("  {d}\t{s}", .{ leaf.pane.ipc_id, pt }) catch break;
                if (leaf.index == layout.focused) w.writeAll("\t*") catch break;
                w.print("\t{d}x{d}", .{ leaf.rect.cols, leaf.rect.rows }) catch break;
                w.writeAll("\n") catch break;
            }
        }
    }
    sendOk(cmd, stream.getWritten());
}

fn buildTabList(cmd: *queue.IpcCommand, ctx: *WinCtx) void {
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();
    const mgr = ctx.tab_mgr;
    for (0..mgr.count) |i| {
        const layout = &(mgr.tabs[i] orelse continue);
        const title = resolveTitle(layout.focusedPane());
        w.print("{d}\t{s}", .{ i + 1, title }) catch break;
        if (i == mgr.active) w.writeAll("\t*") catch break;
        if (layout.pane_count > 1) w.print("\t{d} panes", .{layout.pane_count}) catch break;
        if (layout.isZoomed()) w.writeAll("\tzoomed") catch break;
        w.writeAll("\n") catch break;
    }
    sendOk(cmd, stream.getWritten());
}

fn buildSplitList(cmd: *queue.IpcCommand, ctx: *WinCtx) void {
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();
    const mgr = ctx.tab_mgr;
    const layout = &(mgr.tabs[mgr.active] orelse { sendOk(cmd, ""); return; });
    var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
    const lc = layout.collectLeaves(&leaves);
    for (leaves[0..lc]) |leaf| {
        const title = resolveTitle(leaf.pane);
        w.print("{d}\t{s}", .{ leaf.pane.ipc_id, title }) catch break;
        if (leaf.index == layout.focused) w.writeAll("\t*") catch break;
        w.print("\t{d}x{d}", .{ leaf.rect.cols, leaf.rect.rows }) catch break;
        w.writeAll("\n") catch break;
    }
    sendOk(cmd, stream.getWritten());
}

fn writeScreenText(cmd: *queue.IpcCommand, pane: *Pane) void {
    const ring = &pane.engine.state.ring;
    const rows = ring.screen_rows;
    const cols = ring.cols;
    var buf: [32768]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();
    for (0..rows) |r| {
        const row_cells = ring.getScreenRow(r);
        var last: usize = cols;
        while (last > 0 and row_cells[last - 1].char == ' ') last -= 1;
        for (row_cells[0..last]) |cell| {
            var cp_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cell.char, &cp_buf) catch continue;
            w.writeAll(cp_buf[0..len]) catch break;
        }
        w.writeAll("\n") catch break;
    }
    sendOk(cmd, stream.getWritten());
}

// ── Session commands ──

fn getSessionMgr(cmd: *queue.IpcCommand, ctx: *WinCtx) ?*session_win.WinSessionManager {
    if (ctx.session_mgr) |smgr| return smgr;
    sendError(cmd, "sessions not enabled");
    return null;
}

fn handleSessionList(cmd: *queue.IpcCommand, ctx: *WinCtx) void {
    const smgr = getSessionMgr(cmd, ctx) orelse return;
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();

    for (0..session_win.max_sessions) |i| {
        if (smgr.sessions[i]) |*s| {
            const active = (i == smgr.active);
            w.print("{d}\t{s}", .{ s.id, s.getName() }) catch break;
            if (active) w.writeAll("\t*") catch break;
            w.print("\t{d} panes", .{s.paneCount()}) catch break;
            w.writeAll("\n") catch break;
        }
    }
    sendOk(cmd, stream.getWritten());
}

fn handleSessionCreate(cmd: *queue.IpcCommand, ctx: *WinCtx) void {
    const smgr = getSessionMgr(cmd, ctx) orelse return;
    // Payload: [flags:u8][cwd_len:u16 LE][cwd...][name...]
    var background: bool = false;
    var name: []const u8 = "new";
    const payload_len: usize = cmd.payload_len;
    if (payload_len >= 3) {
        const cwd_len: usize = std.mem.readInt(u16, cmd.payload[1..3], .little);
        if (3 + cwd_len <= payload_len) {
            background = (cmd.payload[0] & 0x01) != 0;
            const cwd_end = 3 + cwd_len;
            const cwd = cmd.payload[3..cwd_end];
            if (cwd_end < payload_len) {
                name = cmd.payload[cwd_end..payload_len];
            }
            // Derive name from CWD if empty
            if (name.len == 0 and cwd.len > 0) {
                const trimmed = std.mem.trimRight(u8, cwd, "/\\");
                if (std.mem.lastIndexOfAny(u8, trimmed, "/\\")) |sep| {
                    name = trimmed[sep + 1 ..];
                } else {
                    name = trimmed;
                }
            }
        } else {
            name = cmd.payload[0..payload_len];
        }
    } else if (payload_len > 0) {
        name = cmd.payload[0..payload_len];
    }
    // Fall back to active pane's working directory for the name
    if (name.len == 0) {
        if (ctx.tab_mgr.activePane().engine.state.working_directory) |wd| {
            name = lastPathComponent(wd);
        }
    }
    if (name.len == 0) name = "new";

    const ws = @import("../app/windows_stubs.zig");
    const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - ws.g_grid_top_offset - ws.g_grid_bottom_offset));
    const sid = smgr.createSession(name, pty_rows, ctx.grid_cols, ctx.theme, ctx.applied_scrollback_lines) catch {
        sendError(cmd, "failed to create session");
        return;
    };

    if (!background) {
        _ = smgr.switchTo(sid) catch {};
        event_loop.switchSession(ctx);
    }

    var id_buf: [16]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{sid}) catch "";
    sendOk(cmd, id_str);
}

fn handleSessionKill(cmd: *queue.IpcCommand, ctx: *WinCtx) void {
    const smgr = getSessionMgr(cmd, ctx) orelse return;
    if (cmd.payload_len < 4) {
        sendError(cmd, "missing session id");
        return;
    }
    const sid = std.mem.readInt(u32, cmd.payload[0..4], .little);
    smgr.kill(sid) catch |err| {
        switch (err) {
            error.CannotKillLastSession => sendError(cmd, "cannot kill last session"),
            error.SessionNotFound => sendError(cmd, "session not found"),
        }
        return;
    };
    // If the killed session was active, we already switched — update ctx
    event_loop.switchSession(ctx);
    sendOk(cmd, "");
}

fn handleSessionSwitch(cmd: *queue.IpcCommand, ctx: *WinCtx) void {
    const smgr = getSessionMgr(cmd, ctx) orelse return;
    if (cmd.payload_len < 4) {
        sendError(cmd, "missing session id");
        return;
    }
    const sid = std.mem.readInt(u32, cmd.payload[0..4], .little);
    _ = smgr.switchTo(sid) catch {
        sendError(cmd, "session not found");
        return;
    };
    event_loop.switchSession(ctx);
    sendOk(cmd, "");
}

fn handleSessionRename(cmd: *queue.IpcCommand, ctx: *WinCtx) void {
    const smgr = getSessionMgr(cmd, ctx) orelse return;
    if (cmd.payload_len < 5) {
        sendError(cmd, "missing session id or name");
        return;
    }
    var sid = std.mem.readInt(u32, cmd.payload[0..4], .little);
    if (sid == 0) {
        sid = smgr.activeSession().id;
    }
    const new_name = cmd.payload[4..cmd.payload_len];
    smgr.rename(sid, new_name) catch {
        sendError(cmd, "session not found");
        return;
    };
    sendOk(cmd, "");
}

/// Extract last path component, stripping file:// URI prefix if present.
fn lastPathComponent(path: []const u8) []const u8 {
    var p = path;
    if (std.mem.startsWith(u8, p, "file://")) {
        p = p["file://".len..];
        if (std.mem.indexOfScalar(u8, p, '/')) |i| p = p[i..];
    }
    const trimmed = std.mem.trimRight(u8, p, "/\\");
    if (trimmed.len == 0) return "";
    if (std.mem.lastIndexOfAny(u8, trimmed, "/\\")) |i| return trimmed[i + 1 ..];
    return trimmed;
}

// ── Popup ──

fn handlePopup(cmd: *queue.IpcCommand, ctx: *WinCtx) void {
    if (cmd.payload_len < 4) {
        sendError(cmd, "missing popup command");
        return;
    }
    const width_pct = cmd.payload[0];
    const height_pct = cmd.payload[1];
    const border_raw = cmd.payload[2];
    const command = cmd.payload[3..cmd.payload_len];
    const popup_mod = @import("../app/popup.zig");
    const ws = @import("../app/windows_stubs.zig");
    const publish = @import("../app/ui/publish.zig");

    const border_style: popup_mod.BorderStyle = switch (border_raw) {
        0 => .single, 1 => .double, 2 => .rounded, 3 => .heavy, 4 => .none,
        else => .rounded,
    };

    // Close existing popup if any
    if (ctx.popup_state != null) {
        @import("../app/ui/win_popup.zig").closePopup(ctx);
    }

    const cfg_idx: u8 = if (ctx.popup_config_count < 32) ctx.popup_config_count else 31;
    ctx.popup_configs[cfg_idx] = popup_mod.PopupConfig{
        .command = command,
        .width_pct = if (width_pct >= 1 and width_pct <= 100) width_pct else 80,
        .height_pct = if (height_pct >= 1 and height_pct <= 100) height_pct else 80,
        .border_style = border_style,
        .border_fg = .{ 128, 128, 128 },
    };
    const cfg = ctx.popup_configs[cfg_idx];

    var ps = ctx.allocator.create(popup_mod.PopupState) catch {
        sendError(cmd, "failed to allocate popup");
        return;
    };
    ps.* = popup_mod.PopupState.spawn(ctx.allocator, cfg, ctx.grid_cols, ctx.grid_rows, null, null) catch {
        ctx.allocator.destroy(ps);
        sendError(cmd, "failed to spawn popup");
        return;
    };
    ps.pane.engine.state.theme_colors = publish.themeToEngineColors(ctx.theme);
    ps.config_index = cfg_idx;
    ctx.popup_state = ps;
    ws.g_popup_pty_handle = ps.pane.pty.pipe_in_write;
    ws.g_popup_engine = &ps.pane.engine;
    const c = publish.c;
    @atomicStore(i32, @as(*i32, @ptrCast(@volatileCast(&c.g_popup_active))), 1, .seq_cst);
    ps.publishCells(ctx.theme, cfg);
    sendOk(cmd, "");
}

// ── Theme set ──

fn handleThemeSet(cmd: *queue.IpcCommand, ctx: *WinCtx) void {
    if (cmd.payload_len > 0) {
        const name = cmd.payload[0..cmd.payload_len];
        ctx.theme.* = ctx.theme_registry.resolve(name);
        const publish = @import("../app/ui/publish.zig");
        publish.publishTheme(ctx.theme);
        // Update all pane engines with new theme colors
        const tc = publish.themeToEngineColors(ctx.theme);
        for (&ctx.tab_mgr.tabs) |*slot| {
            if (slot.*) |*layout| {
                for (&layout.pool) |*node| {
                    if (node.tag == .leaf) {
                        if (node.pane) |pane| {
                            pane.engine.state.theme_colors = tc;
                        }
                    }
                }
            }
        }
        if (ctx.popup_state) |ps| {
            ps.pane.engine.state.theme_colors = tc;
        }
    }
    sendOk(cmd, "");
}

// ── Targeted operations ──

fn handleTabRenameTargeted(cmd: *queue.IpcCommand, ctx: *WinCtx) void {
    if (cmd.payload_len < 2) {
        sendError(cmd, "missing tab index or name");
        return;
    }
    const ti = cmd.payload[0];
    if (ti >= ctx.tab_mgr.count) {
        sendError(cmd, "tab not found");
        return;
    }
    const layout = &(ctx.tab_mgr.tabs[ti] orelse {
        sendError(cmd, "tab not found");
        return;
    });
    const name = cmd.payload[1..cmd.payload_len];
    layout.focusedPane().setCustomTitle(name);
    sendOk(cmd, "");
}

fn handlePaneZoomTargeted(cmd: *queue.IpcCommand, ctx: *WinCtx) void {
    if (cmd.payload_len < 4) {
        sendError(cmd, "missing pane ID");
        return;
    }
    const pane_id = std.mem.readInt(u32, cmd.payload[0..4], .little);
    const found = ctx.tab_mgr.findPaneWithLayout(pane_id) orelse {
        sendError(cmd, "pane not found");
        return;
    };
    const prev_focused = found.layout.focused;
    found.layout.focused = found.pool_idx;
    found.layout.toggleZoom();
    if (!found.layout.isZoomed() and prev_focused != found.pool_idx) {
        found.layout.focused = prev_focused;
    }
    const ws = @import("../app/windows_stubs.zig");
    const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - ws.g_grid_top_offset - ws.g_grid_bottom_offset));
    if (found.layout.isZoomed()) {
        found.layout.focusedPane().resize(pty_rows, ctx.grid_cols);
    } else {
        found.layout.layout(pty_rows, ctx.grid_cols);
    }
    event_loop.switchActiveTab(ctx);
    sendOk(cmd, "");
}

fn handlePaneRotateTargeted(cmd: *queue.IpcCommand, ctx: *WinCtx) void {
    const layout = if (cmd.payload_len >= 4) blk: {
        const pane_id = std.mem.readInt(u32, cmd.payload[0..4], .little);
        const found = ctx.tab_mgr.findPaneWithLayout(pane_id) orelse {
            sendError(cmd, "pane not found");
            return;
        };
        break :blk found.layout;
    } else ctx.tab_mgr.activeLayout();

    layout.rotatePanes();
    const ws = @import("../app/windows_stubs.zig");
    const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - ws.g_grid_top_offset - ws.g_grid_bottom_offset));
    layout.layout(pty_rows, ctx.grid_cols);
    event_loop.switchActiveTab(ctx);
    sendOk(cmd, "");
}

// ── Response helpers ──

pub fn sendOk(cmd: *queue.IpcCommand, payload: []const u8) void {
    if (cmd.response_fd == queue.invalid_fd) return;
    defer protocol.closeFd(cmd.response_fd);
    var buf: [protocol.header_size + 4096]u8 = undefined;
    const msg = protocol.encodeSuccess(&buf, payload) catch {
        var hdr: [protocol.header_size]u8 = undefined;
        protocol.encodeHeader(&hdr, .success, @intCast(payload.len));
        protocol.writeAll(cmd.response_fd, &hdr) catch return;
        protocol.writeAll(cmd.response_fd, payload) catch {};
        return;
    };
    protocol.writeAll(cmd.response_fd, msg) catch {};
}

const ShellForCommand = struct {
    shell_z: [:0]u8,
    flag_z: [:0]u8,
};

/// Find PowerShell (pwsh.exe or powershell.exe) for running --cmd commands.
/// Falls back to cmd.exe /c if PowerShell is not found.
fn resolveShellForCommand(allocator: std.mem.Allocator) ?ShellForCommand {
    // Try pwsh.exe first (PS 7+), then powershell.exe (PS 5.1)
    const windows = std.os.windows;
    const SearchPathW = struct {
        extern "kernel32" fn SearchPathW(
            lpPath: ?[*:0]const u16,
            lpFileName: [*:0]const u16,
            lpExtension: ?[*:0]const u16,
            nBufferLength: windows.DWORD,
            lpBuffer: [*]u16,
            lpFilePart: ?*?[*]u16,
        ) callconv(.winapi) windows.DWORD;
    }.SearchPathW;

    const shells = [_]struct { name: [*:0]const u16, flag: []const u8 }{
        .{ .name = std.unicode.utf8ToUtf16LeStringLiteral("pwsh.exe"), .flag = "-NoProfile\x00-Command" },
        .{ .name = std.unicode.utf8ToUtf16LeStringLiteral("powershell.exe"), .flag = "-NoProfile\x00-Command" },
    };

    for (shells) |entry| {
        var path_buf: [1024]u16 = undefined;
        var file_part: ?[*]u16 = null;
        const len = SearchPathW(null, entry.name, null, @intCast(path_buf.len), &path_buf, &file_part);
        if (len > 0 and len < path_buf.len) {
            // Convert wide path to UTF-8
            var utf8_buf: [1024]u8 = undefined;
            var utf8_len: usize = 0;
            for (0..len) |i| {
                const cp: u21 = path_buf[i];
                const n = std.unicode.utf8Encode(cp, utf8_buf[utf8_len..]) catch break;
                utf8_len += n;
            }
            const shell_z = allocator.dupeZ(u8, utf8_buf[0..utf8_len]) catch return null;
            const flag_z = allocator.dupeZ(u8, "-Command") catch {
                allocator.free(shell_z);
                return null;
            };
            return .{ .shell_z = shell_z, .flag_z = flag_z };
        }
    }

    // Fallback to cmd.exe
    const shell_z = allocator.dupeZ(u8, "cmd.exe") catch return null;
    const flag_z = allocator.dupeZ(u8, "/c") catch {
        allocator.free(shell_z);
        return null;
    };
    return .{ .shell_z = shell_z, .flag_z = flag_z };
}

pub fn sendError(cmd: *queue.IpcCommand, err_msg: []const u8) void {
    if (cmd.response_fd == queue.invalid_fd) return;
    defer protocol.closeFd(cmd.response_fd);
    var buf: [protocol.header_size + 512]u8 = undefined;
    const resp = protocol.encodeMessage(&buf, .err, err_msg) catch return;
    protocol.writeAll(cmd.response_fd, resp) catch {};
}
