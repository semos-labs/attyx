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

        // ── Not yet supported on Windows ──
        .tab_create_wait, .split_vertical_wait, .split_horizontal_wait => {
            sendError(cmd, "--wait not yet supported on Windows");
        },
        .popup => sendError(cmd, "popup not yet supported on Windows"),
        .theme_set => sendError(cmd, "theme_set not yet supported on Windows"),
        .session_list, .session_create, .session_kill,
        .session_switch, .session_rename,
        => sendError(cmd, "sessions not yet supported on Windows"),
        .session_envelope => sendError(cmd, "unexpected session envelope"),
        .tab_rename_targeted, .pane_rotate_targeted, .pane_zoom_targeted => {
            sendError(cmd, "targeted operation not yet supported");
        },
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

pub fn sendError(cmd: *queue.IpcCommand, err_msg: []const u8) void {
    if (cmd.response_fd == queue.invalid_fd) return;
    defer protocol.closeFd(cmd.response_fd);
    var buf: [protocol.header_size + 512]u8 = undefined;
    const resp = protocol.encodeMessage(&buf, .err, err_msg) catch return;
    protocol.writeAll(cmd.response_fd, resp) catch {};
}
