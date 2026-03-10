// Attyx — IPC command handler
//
// Maps IPC commands to dispatch actions, tab_manager calls, etc.
// Called by the PTY thread when draining the IPC command queue.

const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol.zig");
const queue = @import("queue.zig");
const keybinds = @import("../config/keybinds.zig");
const Action = keybinds.Action;
const terminal = @import("../app/terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const split_layout_mod = @import("../app/split_layout.zig");
const platform = @import("../platform/platform.zig");
const publish = @import("../app/ui/publish.zig");
const SessionClient = @import("../app/session_client.zig");
const popup_mod = @import("../app/popup.zig");
const actions = @import("../app/ui/actions.zig");
const statusbar = @import("../app/statusbar.zig");

/// Process one IPC command. Writes response to cmd.response_fd, then
/// signals the server thread via the done flag.
pub fn handle(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
    const msg_type = std.meta.intToEnum(protocol.MessageType, cmd.msg_type) catch {
        sendError(cmd, "unknown command");
        return;
    };

    switch (msg_type) {
        // ── Tab commands → dispatch actions ──
        // ── Tab commands → dispatch actions (silent success) ──
        .tab_create => {
            dispatchAction(.tab_new);
            sendOk(cmd, "");
        },
        .tab_close => {
            dispatchAction(.tab_close);
            sendOk(cmd, "");
        },
        .tab_next => {
            dispatchAction(.tab_next);
            sendOk(cmd, "");
        },
        .tab_prev => {
            dispatchAction(.tab_prev);
            sendOk(cmd, "");
        },
        .tab_select => {
            if (cmd.payload_len >= 1) {
                const idx = cmd.payload[0];
                if (idx >= 1 and idx <= 9) {
                    const action_val = @intFromEnum(Action.tab_select_1) + idx - 1;
                    const action: Action = @enumFromInt(action_val);
                    dispatchAction(action);
                }
            }
            sendOk(cmd, "");
        },
        .tab_move_left => {
            dispatchAction(.tab_move_left);
            sendOk(cmd, "");
        },
        .tab_move_right => {
            dispatchAction(.tab_move_right);
            sendOk(cmd, "");
        },
        .tab_rename => {
            if (cmd.payload_len > 0) {
                const name = cmd.payload[0..cmd.payload_len];
                ctx.tab_mgr.activePane().setCustomTitle(name);
            }
            sendOk(cmd, "");
        },

        // ── Split / pane commands (silent success) ──
        .split_vertical => {
            dispatchAction(.split_vertical);
            sendOk(cmd, "");
        },
        .split_horizontal => {
            dispatchAction(.split_horizontal);
            sendOk(cmd, "");
        },
        .pane_close => {
            dispatchAction(.pane_close);
            sendOk(cmd, "");
        },
        .pane_rotate => {
            dispatchAction(.pane_rotate);
            sendOk(cmd, "");
        },
        .pane_zoom_toggle => {
            dispatchAction(.pane_zoom_toggle);
            sendOk(cmd, "");
        },

        // ── Focus commands (silent success) ──
        .focus_up => {
            dispatchAction(.pane_focus_up);
            sendOk(cmd, "");
        },
        .focus_down => {
            dispatchAction(.pane_focus_down);
            sendOk(cmd, "");
        },
        .focus_left => {
            dispatchAction(.pane_focus_left);
            sendOk(cmd, "");
        },
        .focus_right => {
            dispatchAction(.pane_focus_right);
            sendOk(cmd, "");
        },

        // ── Scroll (silent success) ──
        .scroll_to_top => {
            dispatchAction(.scroll_to_top);
            sendOk(cmd, "");
        },
        .scroll_to_bottom => {
            dispatchAction(.scroll_to_bottom);
            sendOk(cmd, "");
        },
        .scroll_page_up => {
            dispatchAction(.scroll_page_up);
            sendOk(cmd, "");
        },
        .scroll_page_down => {
            dispatchAction(.scroll_page_down);
            sendOk(cmd, "");
        },

        // ── Config (silent success) ──
        .config_reload => {
            dispatchAction(.config_reload);
            sendOk(cmd, "");
        },
        .theme_set => {
            if (cmd.payload_len > 0) {
                const name = cmd.payload[0..cmd.payload_len];
                ctx.active_theme = ctx.theme_registry.resolve(name);
                publish.publishTheme(&ctx.active_theme);
                publish.publishThemeToEngines(ctx);
                publish.publishThemeToDaemon(ctx);
            }
            sendOk(cmd, "");
        },

        // ── Text / IO ──
        .send_keys, .send_text => {
            if (cmd.payload_len > 0) {
                const text = cmd.payload[0..cmd.payload_len];
                sendInputToActivePty(text);
            }
            sendOk(cmd, "");
        },
        .get_text => {
            buildGetText(cmd, ctx);
        },

        // ── Popup ──
        .popup => handlePopup(cmd, ctx),

        // ── Query ──
        .list => buildList(cmd, ctx),
        .list_tabs => buildTabList(cmd, ctx),
        .list_splits => buildSplitList(cmd, ctx),

        // ── Session commands ──
        .session_list => handleSessionList(cmd, ctx),
        .session_create => handleSessionCreate(cmd, ctx),
        .session_kill => handleSessionKill(cmd, ctx),
        .session_switch => handleSessionSwitch(cmd, ctx),
        .session_rename => handleSessionRename(cmd, ctx),

        // ── Responses (should not be received by server) ──
        .success, .err => {
            sendError(cmd, "unexpected message type");
        },
    }
}

// ---------------------------------------------------------------------------
// Dispatch helper — calls the existing attyx_dispatch_action export
// ---------------------------------------------------------------------------

extern fn attyx_dispatch_action(action_raw: u8) u8;

fn dispatchAction(action: Action) void {
    _ = attyx_dispatch_action(@intFromEnum(action));
}

// ---------------------------------------------------------------------------
// Send input to active PTY
// ---------------------------------------------------------------------------

extern fn attyx_send_input(bytes: [*]const u8, len: c_int) void;

fn sendInputToActivePty(text: []const u8) void {
    attyx_send_input(text.ptr, @intCast(text.len));
}

// ---------------------------------------------------------------------------
// List: build tab/pane tree
// ---------------------------------------------------------------------------

fn resolveTitle(pane: anytype, name_buf: *[256]u8) []const u8 {
    return pane.getCustomTitle() orelse
        pane.engine.state.title orelse
        platform.getForegroundProcessName(pane.pty.master, name_buf) orelse
        pane.getDaemonProcName() orelse
        "shell";
}

fn buildList(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
    var buf: [8192]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();

    const mgr = ctx.tab_mgr;
    for (0..mgr.count) |i| {
        const layout = &(mgr.tabs[i] orelse continue);
        const is_active = (i == mgr.active);

        var name_buf: [256]u8 = undefined;
        const title = resolveTitle(layout.focusedPane(), &name_buf);

        w.print("{d}\t{s}", .{ i + 1, title }) catch break;
        if (is_active) w.writeAll("\t*") catch break;
        if (layout.pane_count > 1) {
            w.print("\t{d} panes", .{layout.pane_count}) catch break;
        }
        if (layout.isZoomed()) w.writeAll("\tzoomed") catch break;
        w.writeAll("\n") catch break;

        // If multiple panes, list them indented
        if (layout.pane_count > 1) {
            var leaves: [8]split_layout_mod.LeafEntry = undefined;
            const lc = layout.collectLeaves(&leaves);
            for (leaves[0..lc]) |leaf| {
                var pane_name_buf: [256]u8 = undefined;
                const pane_title = resolveTitle(leaf.pane, &pane_name_buf);
                const focused = (leaf.index == layout.focused);
                w.print("  {d}.{d}\t{s}", .{ i + 1, leaf.index, pane_title }) catch break;
                if (focused) w.writeAll("\t*") catch break;
                w.print("\t{d}x{d}", .{ leaf.rect.cols, leaf.rect.rows }) catch break;
                w.writeAll("\n") catch break;
            }
        }
    }

    sendOk(cmd, stream.getWritten());
}

fn buildTabList(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();

    const mgr = ctx.tab_mgr;
    for (0..mgr.count) |i| {
        const layout = &(mgr.tabs[i] orelse continue);
        const is_active = (i == mgr.active);

        var name_buf: [256]u8 = undefined;
        const title = resolveTitle(layout.focusedPane(), &name_buf);

        w.print("{d}\t{s}", .{ i + 1, title }) catch break;
        if (is_active) w.writeAll("\t*") catch break;
        if (layout.pane_count > 1) {
            w.print("\t{d} panes", .{layout.pane_count}) catch break;
        }
        if (layout.isZoomed()) w.writeAll("\tzoomed") catch break;
        w.writeAll("\n") catch break;
    }

    sendOk(cmd, stream.getWritten());
}

fn buildSplitList(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();

    const mgr = ctx.tab_mgr;
    const layout = &(mgr.tabs[mgr.active] orelse {
        sendOk(cmd, "");
        return;
    });

    var leaves: [8]split_layout_mod.LeafEntry = undefined;
    const lc = layout.collectLeaves(&leaves);
    for (leaves[0..lc]) |leaf| {
        var name_buf: [256]u8 = undefined;
        const title = resolveTitle(leaf.pane, &name_buf);
        const focused = (leaf.index == layout.focused);

        w.print("{d}\t{s}", .{ leaf.index, title }) catch break;
        if (focused) w.writeAll("\t*") catch break;
        w.print("\t{d}x{d}", .{ leaf.rect.cols, leaf.rect.rows }) catch break;
        w.writeAll("\n") catch break;
    }

    sendOk(cmd, stream.getWritten());
}

// ---------------------------------------------------------------------------
// Popup: open ad-hoc popup terminal
// ---------------------------------------------------------------------------

fn handlePopup(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
    if (cmd.payload_len < 4) {
        sendError(cmd, "missing popup command");
        return;
    }
    // Payload: [width_pct:u8][height_pct:u8][border_style:u8][command...]
    const width_pct = cmd.payload[0];
    const height_pct = cmd.payload[1];
    const border_raw = cmd.payload[2];
    const command = cmd.payload[3..cmd.payload_len];

    const border_style: popup_mod.BorderStyle = switch (border_raw) {
        0 => .single,
        1 => .double,
        2 => .rounded,
        3 => .heavy,
        4 => .none,
        else => .rounded,
    };

    // Close existing popup if any
    if (ctx.popup_state != null) {
        actions.closePopup(ctx);
    }

    // Resolve CWD from focused pane
    var osc7_buf: [statusbar.max_output_len]u8 = undefined;
    const resolved = actions.resolveFocusedCwd(ctx, &osc7_buf);
    defer if (resolved.owned) if (resolved.cwd) |cwd| ctx.allocator.free(cwd);

    // Store ad-hoc config in a spare slot so the event loop can re-publish
    const cfg_idx: u8 = if (ctx.popup_config_count < 32) ctx.popup_config_count else 31;
    ctx.popup_configs[cfg_idx] = popup_mod.PopupConfig{
        .command = command,
        .width_pct = if (width_pct >= 1 and width_pct <= 100) width_pct else 80,
        .height_pct = if (height_pct >= 1 and height_pct <= 100) height_pct else 80,
        .border_style = border_style,
        .border_fg = .{ 128, 128, 128 },
    };
    const cfg = ctx.popup_configs[cfg_idx];

    const main_shell_path = publish.ctxEngine(ctx).state.shell_path;
    var ps = ctx.allocator.create(popup_mod.PopupState) catch {
        sendError(cmd, "failed to allocate popup");
        return;
    };
    ps.* = popup_mod.PopupState.spawn(ctx.allocator, cfg, ctx.grid_cols, ctx.grid_rows, resolved.cwd, main_shell_path) catch {
        ctx.allocator.destroy(ps);
        sendError(cmd, "failed to spawn popup");
        return;
    };
    ps.pane.engine.state.theme_colors = publish.themeToEngineColors(&ctx.active_theme);
    ps.config_index = cfg_idx;
    ctx.popup_state = ps;
    terminal.g_popup_pty_master = ps.pane.pty.master;
    terminal.g_popup_engine = &ps.pane.engine;

    const c = terminal.c;
    @atomicStore(i32, @as(*i32, @ptrCast(@volatileCast(&c.g_popup_active))), 1, .seq_cst);
    ps.publishCells(&ctx.active_theme, cfg);
    ps.publishImagePlacements(cfg);

    sendOk(cmd, "");
}

// ---------------------------------------------------------------------------
// Get text: read visible screen content
// ---------------------------------------------------------------------------

fn buildGetText(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
    const pane = ctx.tab_mgr.activePane();
    const ring = &pane.engine.state.ring;
    const rows = ring.screen_rows;
    const cols = ring.cols;

    // Worst case: 4 bytes per char (UTF-8) + newline per row
    var buf: [32768]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();

    for (0..rows) |r| {
        const row_cells = ring.getScreenRow(r);
        // Find last non-space cell to trim trailing whitespace
        var last: usize = cols;
        while (last > 0 and row_cells[last - 1].char == ' ') last -= 1;

        for (row_cells[0..last]) |cell| {
            var codepoint_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cell.char, &codepoint_buf) catch continue;
            w.writeAll(codepoint_buf[0..len]) catch break;
        }
        w.writeAll("\n") catch break;
    }

    sendOk(cmd, stream.getWritten());
}

// ---------------------------------------------------------------------------
// Session commands
// ---------------------------------------------------------------------------

fn handleSessionList(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
    const sc = ctx.session_client orelse {
        sendError(cmd, "sessions not enabled");
        return;
    };
    sc.requestListSync(3000) catch {
        sendError(cmd, "failed to fetch session list");
        return;
    };
    if (!sc.pending_list_ready) {
        sendError(cmd, "session list timeout");
        return;
    }

    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();

    for (sc.pending_list[0..sc.pending_list_count]) |*entry| {
        const name = entry.getName();
        const active = if (sc.attached_session_id) |aid| aid == entry.id else false;
        w.print("{d}\t{s}", .{ entry.id, name }) catch break;
        if (active) w.writeAll("\t*") catch break;
        if (!entry.alive) w.writeAll("\tdead") catch break;
        w.print("\t{d} panes", .{entry.pane_count}) catch break;
        w.writeAll("\n") catch break;
    }

    sendOk(cmd, stream.getWritten());
}

fn handleSessionCreate(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
    const sc = ctx.session_client orelse {
        sendError(cmd, "sessions not enabled");
        return;
    };
    const name = if (cmd.payload_len > 0) cmd.payload[0..cmd.payload_len] else "new";
    const rows = ctx.grid_rows;
    const cols = ctx.grid_cols;
    const sid = sc.createSession(name, rows, cols, "", "") catch {
        sendError(cmd, "failed to create session");
        return;
    };

    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    stream.writer().print("{d}", .{sid}) catch {};
    sendOk(cmd, stream.getWritten());
}

fn handleSessionKill(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
    const sc = ctx.session_client orelse {
        sendError(cmd, "sessions not enabled");
        return;
    };
    if (cmd.payload_len < 4) {
        sendError(cmd, "missing session id");
        return;
    }
    const sid = std.mem.readInt(u32, cmd.payload[0..4], .little);
    sc.killSession(sid) catch {
        sendError(cmd, "failed to kill session");
        return;
    };
    sendOk(cmd, "");
}

fn handleSessionSwitch(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
    const sc = ctx.session_client orelse {
        sendError(cmd, "sessions not enabled");
        return;
    };
    if (cmd.payload_len < 4) {
        sendError(cmd, "missing session id");
        return;
    }
    const sid = std.mem.readInt(u32, cmd.payload[0..4], .little);
    sc.attach(sid, ctx.grid_rows, ctx.grid_cols) catch {
        sendError(cmd, "failed to switch session");
        return;
    };
    sendOk(cmd, "");
}

fn handleSessionRename(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
    const sc = ctx.session_client orelse {
        sendError(cmd, "sessions not enabled");
        return;
    };
    if (cmd.payload_len < 5) {
        sendError(cmd, "missing session id or name");
        return;
    }
    var sid = std.mem.readInt(u32, cmd.payload[0..4], .little);
    // sid 0 means "current session" — requires an attached daemon session
    if (sid == 0) {
        sid = sc.attached_session_id orelse {
            sendError(cmd, "not attached to a session (use 'session rename <id> <name>')");
            return;
        };
    }
    const name = cmd.payload[4..cmd.payload_len];
    sc.renameSession(sid, name) catch {
        sendError(cmd, "failed to rename session");
        return;
    };
    sendOk(cmd, "");
}

// ---------------------------------------------------------------------------
// Response helpers
// ---------------------------------------------------------------------------

fn sendOk(cmd: *queue.IpcCommand, json: []const u8) void {
    var buf: [protocol.header_size + 4096]u8 = undefined;
    const msg = protocol.encodeSuccess(&buf, json) catch return;
    _ = posix.write(cmd.response_fd, msg) catch {};
    // Signal server thread that we're done
    @atomicStore(i32, &cmd.done, 1, .seq_cst);
}

fn sendError(cmd: *queue.IpcCommand, msg: []const u8) void {
    var buf: [protocol.header_size + 512]u8 = undefined;
    const resp = protocol.encodeErrorResponse(&buf, msg) catch return;
    _ = posix.write(cmd.response_fd, resp) catch {};
    @atomicStore(i32, &cmd.done, 1, .seq_cst);
}
