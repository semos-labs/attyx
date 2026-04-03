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
const publish = @import("../app/ui/publish.zig");

const handler_cmd = @import("handler_cmd.zig");
const handler_query = @import("handler_query.zig");

/// Process one IPC command. Writes response to cmd.response_fd, then
/// closes it.
pub fn handle(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
    const msg_type = std.meta.intToEnum(protocol.MessageType, cmd.msg_type) catch {
        sendError(cmd, "unknown command");
        return;
    };

    // Session targeting: if a specific session was requested, verify it
    // matches the currently attached session.
    if (cmd.session_id != 0) {
        if (ctx.session_client) |sc| {
            if (sc.attached_session_id) |aid| {
                if (cmd.session_id != aid) {
                    sendError(cmd, "session not attached (use 'attyx session switch' first)");
                    return;
                }
            } else {
                sendError(cmd, "no session attached");
                return;
            }
        } else {
            sendError(cmd, "sessions not enabled");
            return;
        }
    }

    switch (msg_type) {
        // ── Tab commands → dispatch actions (silent success) ──
        .tab_create, .tab_create_wait => {
            if (cmd.payload_len > 0) {
                handler_cmd.handleTabCreateWithCmd(cmd, ctx, msg_type == .tab_create_wait);
            } else if (msg_type == .tab_create_wait) {
                sendError(cmd, "--wait requires --cmd");
            } else {
                handler_cmd.handleTabCreate(cmd, ctx);
            }
        },
        .tab_close => {
            dispatchAction(.tab_close);
            sendOk(cmd, "");
        },
        .tab_close_targeted => handler_cmd.handleTabCloseTargeted(cmd, ctx),
        .tab_rename_targeted => handler_cmd.handleTabRenameTargeted(cmd, ctx),
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
        .split_vertical, .split_vertical_wait => {
            const wait = (msg_type == .split_vertical_wait);
            if (cmd.payload_len > 0) {
                handler_cmd.handleSplitWithCmd(cmd, ctx, .vertical, wait);
            } else if (wait) {
                sendError(cmd, "--wait requires --cmd");
            } else {
                handler_cmd.handleSplit(cmd, ctx, .vertical);
            }
        },
        .split_horizontal, .split_horizontal_wait => {
            const wait = (msg_type == .split_horizontal_wait);
            if (cmd.payload_len > 0) {
                handler_cmd.handleSplitWithCmd(cmd, ctx, .horizontal, wait);
            } else if (wait) {
                sendError(cmd, "--wait requires --cmd");
            } else {
                handler_cmd.handleSplit(cmd, ctx, .horizontal);
            }
        },
        .pane_close => {
            dispatchAction(.pane_close);
            sendOk(cmd, "");
        },
        .pane_close_targeted => handler_cmd.handlePaneCloseTargeted(cmd, ctx),
        .pane_rotate => {
            dispatchAction(.pane_rotate);
            sendOk(cmd, "");
        },
        .pane_rotate_targeted => handler_cmd.handlePaneRotateTargeted(cmd, ctx),
        .pane_zoom_toggle => {
            dispatchAction(.pane_zoom_toggle);
            sendOk(cmd, "");
        },
        .pane_zoom_targeted => handler_cmd.handlePaneZoomTargeted(cmd, ctx),

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

        // ── Text / IO ── (send_text is a deprecated alias, kept for wire compat)
        .send_keys, .send_text => {
            if (cmd.payload_len > 0) {
                const text = cmd.payload[0..cmd.payload_len];
                sendInputToActivePty(text);
            }
            sendOk(cmd, "");
        },
        .send_keys_pane, .send_text_pane => { // send_text_pane is deprecated alias
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
            sendInputToPane(pane, text, ctx);
            sendOk(cmd, "");
        },
        .get_text => handler_query.buildGetText(cmd, ctx),
        .get_text_pane => handler_query.buildGetTextPane(cmd, ctx),

        // ── Popup ──
        .popup => handler_cmd.handlePopup(cmd, ctx),

        // ── Query ──
        .list => handler_query.buildList(cmd, ctx),
        .list_tabs => handler_query.buildTabList(cmd, ctx),
        .list_splits => handler_query.buildSplitList(cmd, ctx),

        // ── Session commands ──
        .session_list => handler_query.handleSessionList(cmd, ctx),
        .session_create => handler_query.handleSessionCreate(cmd, ctx),
        .session_kill => handler_query.handleSessionKill(cmd, ctx),
        .session_switch => handler_query.handleSessionSwitch(cmd, ctx),
        .session_rename => handler_query.handleSessionRename(cmd, ctx),

        // ── Session envelope (already unwrapped by server — should never reach here) ──
        .session_envelope => sendError(cmd, "unexpected session envelope"),

        // ── Xyron overlay events (xyron → attyx via sendToAttyx) ──
        .xyron_overlay_show, .xyron_overlay_update => {
            handleXyronOverlay(cmd, ctx);
        },
        .xyron_overlay_dismiss => {
            handleXyronDismiss(ctx);
            sendOk(cmd, "");
        },

        // ── Responses (should not be received by server) ──
        .success, .err, .exit_code => {
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
// Send input to a specific pane's PTY (by-passes focus requirement)
// ---------------------------------------------------------------------------

const Pane = @import("../app/pane.zig").Pane;

fn sendInputToPane(pane: *Pane, text: []const u8, ctx: *PtyThreadCtx) void {
    // Session mode: route through daemon using pane's daemon_pane_id
    if (ctx.session_client) |sc| {
        if (pane.daemon_pane_id) |dpid| {
            sc.sendPaneInput(dpid, text) catch {};
            return;
        }
    }
    // Local mode: write directly to the pane's PTY master fd
    const fd = pane.pty.master;
    if (fd < 0) return;
    var offset: usize = 0;
    while (offset < text.len) {
        const n = posix.write(fd, text[offset..]) catch |err| {
            if (err == error.WouldBlock) {
                posix.nanosleep(0, 1_000_000);
                continue;
            }
            return;
        };
        offset += n;
    }
}

// ---------------------------------------------------------------------------
// Xyron overlay handlers
// ---------------------------------------------------------------------------

fn handleXyronOverlay(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
    const completion_mod = @import("attyx").overlay_completion;
    const logging = @import("../logging/log.zig");

    const payload = cmd.payload[0..cmd.payload_len];
    // Xyron's TLV payload: selected:i64, scroll:i64, total:i64, visible_count:i64, then candidates
    if (payload.len < 32) { sendOk(cmd, ""); return; }

    var pos: usize = 0;
    const selected = readI64(payload, &pos);
    const scroll_off = readI64(payload, &pos);
    const total = readI64(payload, &pos);
    const visible_count = readI64(payload, &pos);

    const count: u16 = @intCast(@min(@max(visible_count, 0), completion_mod.max_candidates));
    ctx.xyron_completion.count = count;
    for (0..count) |i| {
        const text = readStr(payload, &pos);
        const desc = readStr(payload, &pos);
        const kind = if (pos < payload.len) blk: { const k = payload[pos]; pos += 1; break :blk k; } else 0;

        var cand = &ctx.xyron_completion.candidates[i];
        const tl: u16 = @intCast(@min(text.len, 256));
        @memcpy(cand.text[0..tl], text[0..tl]);
        cand.text_len = tl;
        const dl: u16 = @intCast(@min(desc.len, 80));
        @memcpy(cand.desc[0..dl], desc[0..dl]);
        cand.desc_len = dl;
        cand.kind = kind;
    }
    ctx.xyron_completion.show(
        @intCast(@max(selected, 0)),
        @intCast(@max(scroll_off, 0)),
        @intCast(@max(total, 0)),
    );

    // Render and position at cursor
    if (ctx.overlay_mgr) |mgr| {
        const theme = publish.overlayThemeFromTheme(&ctx.active_theme);
        if (completion_mod.render(ctx.allocator, &ctx.xyron_completion, theme)) |result| {
            if (result.width > 0 and result.height > 0) {
                // Position: below cursor row, at cursor col
                const vp = publish.viewportInfoFromCtx(ctx);
                const cursor_row = vp.cursor_row + @as(u16, @intCast(terminal.g_grid_top_offset));
                const cursor_col = vp.cursor_col;

                // Prefer below cursor; if not enough space, place above
                const row = if (cursor_row + 1 + result.height <= vp.grid_rows)
                    cursor_row + 1
                else if (cursor_row >= result.height)
                    cursor_row - result.height
                else
                    cursor_row + 1; // below anyway, will clip

                // Clamp col so overlay doesn't go off-screen right
                const col = if (cursor_col + result.width > vp.grid_cols)
                    vp.grid_cols -| result.width
                else
                    cursor_col;

                mgr.setContent(.completion, col, row, result.width, result.height, result.cells) catch {};
                mgr.show(.completion);
                ctx.allocator.free(result.cells);
            }
        } else |_| {}
    }
    logging.info("xyron", "overlay show: {d} candidates, selected={d}", .{ count, selected });
    // Force redraw so overlay is published this frame
    @import("../app/ui/actions.zig").g_force_full_redraw = true;
    sendOk(cmd, "");
}

fn handleXyronDismiss(ctx: *PtyThreadCtx) void {
    const logging = @import("../logging/log.zig");
    ctx.xyron_completion.dismiss();
    if (ctx.overlay_mgr) |mgr| mgr.hide(.completion);
    @import("../app/ui/actions.zig").g_force_full_redraw = true;
    logging.info("xyron", "overlay dismissed", .{});
}

fn readI64(data: []const u8, pos: *usize) i64 {
    if (pos.* + 8 > data.len) return 0;
    const v = std.mem.readInt(i64, data[pos.*..][0..8], .little);
    pos.* += 8;
    return v;
}

fn readStr(data: []const u8, pos: *usize) []const u8 {
    if (pos.* + 2 > data.len) return "";
    const len = std.mem.readInt(u16, data[pos.*..][0..2], .little);
    pos.* += 2;
    if (pos.* + len > data.len) return "";
    const s = data[pos.*..][0..len];
    pos.* += len;
    return s;
}

// ---------------------------------------------------------------------------
// Response helpers (pub so handler_cmd/handler_query can use them)
// ---------------------------------------------------------------------------

pub fn sendOk(cmd: *queue.IpcCommand, payload: []const u8) void {
    if (cmd.response_fd == queue.invalid_fd) return;
    defer protocol.closeFd(cmd.response_fd);
    var buf: [protocol.header_size + 4096]u8 = undefined;
    const msg = protocol.encodeSuccess(&buf, payload) catch {
        // Payload too large for stack buffer — write header + payload separately
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
    // Send plain text error — the client formats it for display/JSON
    var buf: [protocol.header_size + 512]u8 = undefined;
    const resp = protocol.encodeMessage(&buf, .err, err_msg) catch return;
    protocol.writeAll(cmd.response_fd, resp) catch {};
}
