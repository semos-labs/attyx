/// Session switcher overlay — lists daemon sessions for switching/creating/killing.
const std = @import("std");
const attyx = @import("attyx");
const overlay = attyx.overlay_mod;
const layout_mod = attyx.overlay_layout;

const terminal = @import("../terminal.zig");
const publish = @import("publish.zig");
const actions = @import("actions.zig");
const SessionClient = @import("../session_client.zig").SessionClient;
const ListEntry = @import("../session_client.zig").ListEntry;
const layout_codec = @import("../layout_codec.zig");
const split_layout_mod = @import("../split_layout.zig");

const OverlayCell = overlay.OverlayCell;
const OverlayStyle = overlay.OverlayStyle;
const Rgb = overlay.Rgb;
const PtyThreadCtx = terminal.PtyThreadCtx;

const max_visible = 16;

// ── Module state ──

var selected: u8 = 0;
var entry_count: u8 = 0;
var entries: [32]ListEntry = undefined;
var list_pending: bool = false;

// Navigation atomics (set by platform input thread, consumed by PTY thread)
pub var g_session_nav: i32 = 0; // +1 = down, -1 = up
pub var g_session_action: i32 = 0; // 1 = switch, 2 = new, 3 = kill

pub fn sessionNavUp() void {
    @atomicStore(i32, &g_session_nav, -1, .seq_cst);
}
pub fn sessionNavDown() void {
    @atomicStore(i32, &g_session_nav, 1, .seq_cst);
}
pub fn sessionAction(action: c_int) void {
    @atomicStore(i32, &g_session_action, action, .seq_cst);
}

/// Toggle session switcher visibility.
pub fn toggle(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    if (mgr.isVisible(.session_switcher)) {
        mgr.hide(.session_switcher);
        terminal.g_session_switcher_active = 0;
    } else {
        // Request fresh session list from daemon
        if (terminal.g_session_client) |sc| {
            sc.requestList() catch {};
            list_pending = true;
        }
        selected = 0;
        mgr.show(.session_switcher);
        terminal.g_session_switcher_active = 1;
        generate(ctx);
    }
    publish.publishOverlays(ctx);
}

/// Process navigation and actions. Called each event loop iteration.
pub fn tick(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    if (!mgr.isVisible(.session_switcher)) return;

    var changed = false;

    // Check for pending session list response
    if (list_pending) {
        if (terminal.g_session_client) |sc| {
            if (sc.pending_list_ready) {
                entry_count = sc.pending_list_count;
                @memcpy(entries[0..entry_count], sc.pending_list[0..entry_count]);
                sc.pending_list_ready = false;
                list_pending = false;
                if (selected >= entry_count and entry_count > 0) selected = entry_count - 1;
                changed = true;
            }
        }
    }

    // Process up/down navigation
    const nav = @atomicRmw(i32, &g_session_nav, .Xchg, 0, .seq_cst);
    if (nav != 0 and entry_count > 0) {
        if (nav > 0) {
            selected = if (selected + 1 >= entry_count) 0 else selected + 1;
        } else {
            selected = if (selected == 0) entry_count - 1 else selected - 1;
        }
        changed = true;
    }

    // Process actions: 1=switch, 2=new, 3=kill
    const action = @atomicRmw(i32, &g_session_action, .Xchg, 0, .seq_cst);
    if (action != 0) {
        switch (action) {
            1 => doSwitch(ctx, mgr),
            2 => doNew(ctx),
            3 => doKill(),
            else => {},
        }
        changed = true;
    }

    if (changed) {
        generate(ctx);
        publish.publishOverlays(ctx);
    }
}

fn doSwitch(ctx: *PtyThreadCtx, mgr: *overlay.OverlayManager) void {
    if (entry_count == 0 or selected >= entry_count) return;
    const sc = ctx.session_client orelse return;
    const entry = &entries[selected];
    const rows: u16 = @intCast(@max(1, ctx.grid_rows));

    // Save current layout to daemon
    var layout_buf: [4096]u8 = undefined;
    const layout_len = ctx.tab_mgr.serializeLayout(&layout_buf) catch 0;
    if (layout_len > 0) {
        sc.sendSaveLayout(layout_buf[0..layout_len]) catch {};
    }

    // Detach from current session
    sc.detach() catch {};

    // Teardown current tabs (deinit all panes/engines)
    ctx.tab_mgr.reset();

    // Attach to new session
    sc.attach(entry.id, rows, ctx.grid_cols) catch return;

    // Wait for V2 attached response with layout + pane IDs
    const attach_result = sc.waitForAttach(3000) catch return;

    // Reconstruct tabs from layout blob (if daemon had a saved layout)
    if (sc.layout_len > 0) {
        if (layout_codec.deserialize(sc.layout_buf[0..sc.layout_len])) |info| {
            ctx.tab_mgr.reconstructFromLayout(&info, rows, ctx.grid_cols) catch {};
        } else |_| {}
    }

    // Fallback: if no tabs reconstructed, create a single-pane tab
    if (ctx.tab_mgr.count == 0 and attach_result.pane_count > 0) {
        const pane = ctx.tab_mgr.allocator.create(@import("../pane.zig").Pane) catch return;
        pane.* = @import("../pane.zig").Pane.initDaemonBacked(
            ctx.tab_mgr.allocator,
            rows,
            ctx.grid_cols,
        ) catch {
            ctx.tab_mgr.allocator.destroy(pane);
            return;
        };
        pane.daemon_pane_id = attach_result.pane_ids[0];
        ctx.tab_mgr.tabs[0] = split_layout_mod.SplitLayout.init(pane);
        ctx.tab_mgr.count = 1;
        ctx.tab_mgr.active = 0;
    }

    // Update active daemon pane ID for input routing
    if (ctx.tab_mgr.count > 0) {
        const ap = ctx.tab_mgr.activePane();
        terminal.g_active_daemon_pane_id = ap.daemon_pane_id orelse 0;
    }

    // Reset focus tracking — all panes are fresh after session switch.
    ctx.last_focus_count = 0;
    // Send focus_panes so daemon sends replay for the active tab
    actions.sendActiveFocusPanes(ctx);

    mgr.hide(.session_switcher);
    terminal.g_session_switcher_active = 0;
}

fn doNew(ctx: *PtyThreadCtx) void {
    const sc = terminal.g_session_client orelse return;
    const rows: u16 = @intCast(@max(1, ctx.grid_rows));
    _ = sc.createSession("shell", rows, ctx.grid_cols) catch return;
    sc.requestList() catch {};
    list_pending = true;
}

fn doKill() void {
    if (entry_count == 0 or selected >= entry_count) return;
    const sc = terminal.g_session_client orelse return;
    sc.killSession(entries[selected].id) catch return;
    sc.requestList() catch {};
    list_pending = true;
}

/// Dismiss the switcher (called from overlay Esc handler).
pub fn dismiss(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    if (mgr.isVisible(.session_switcher)) {
        mgr.hide(.session_switcher);
        terminal.g_session_switcher_active = 0;
        publish.publishOverlays(ctx);
    }
}

// ── Rendering ──

const style = OverlayStyle{
    .fg = .{ .r = 220, .g = 220, .b = 230 },
    .bg = .{ .r = 30, .g = 30, .b = 40 },
    .bg_alpha = 240,
    .border = true,
    .border_color = .{ .r = 80, .g = 80, .b = 120 },
};

const sel_bg = Rgb{ .r = 55, .g = 55, .b = 90 };
const sel_fg = Rgb{ .r = 255, .g = 255, .b = 255 };
const alive_fg = Rgb{ .r = 100, .g = 200, .b = 100 };
const dead_fg = Rgb{ .r = 180, .g = 80, .b = 80 };

fn generate(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    if (!mgr.isVisible(.session_switcher)) return;

    const no_sessions = terminal.g_session_client == null;
    var line_bufs: [max_visible + 1][48]u8 = undefined;
    var lines: [max_visible + 1][]const u8 = undefined;
    var line_count: usize = 0;

    if (no_sessions) {
        lines[0] = "Sessions not enabled";
        line_count = 1;
    } else if (entry_count == 0) {
        lines[0] = "No sessions (press n to create)";
        line_count = 1;
    } else {
        const visible = @min(entry_count, max_visible);
        for (0..visible) |i| {
            const e = &entries[i];
            const name = e.getName();
            const status: []const u8 = if (e.alive) "running" else "exited";
            const marker: []const u8 = if (i == selected) ">" else " ";
            const attached: []const u8 = blk: {
                if (terminal.g_session_client) |sc| {
                    if (sc.attached_session_id) |aid| {
                        if (aid == e.id) break :blk " *";
                    }
                }
                break :blk "  ";
            };
            lines[i] = std.fmt.bufPrint(&line_bufs[i], "{s} {s}{s}  ({s})", .{ marker, name, attached, status }) catch "???";
            line_count += 1;
        }
    }

    // Build card using layoutDebugCard
    const result = layout_mod.layoutDebugCard(
        ctx.allocator,
        "Sessions",
        lines[0..line_count],
        style,
    ) catch return;

    // Highlight selected row
    if (!no_sessions and entry_count > 0) {
        const sel_row: usize = @as(usize, selected) + 1; // +1 for top border
        for (1..result.width - 1) |col| {
            const idx = sel_row * @as(usize, result.width) + col;
            if (idx < result.cells.len) {
                result.cells[idx].bg = sel_bg;
                result.cells[idx].fg = sel_fg;
            }
        }
        // Color the status indicator
        for (0..line_count) |i| {
            const row: usize = i + 1;
            const e = &entries[i];
            const fg_color = if (e.alive) alive_fg else dead_fg;
            // Find the '(' marking start of status
            for (1..result.width - 1) |col| {
                const idx = row * @as(usize, result.width) + col;
                if (idx < result.cells.len and result.cells[idx].char == '(') {
                    // Color from '(' to ')' inclusive
                    var c2 = col;
                    while (c2 < result.width - 1) : (c2 += 1) {
                        const idx2 = row * @as(usize, result.width) + c2;
                        if (idx2 < result.cells.len) {
                            result.cells[idx2].fg = fg_color;
                            if (result.cells[idx2].char == ')') break;
                        }
                    }
                    break;
                }
            }
        }
    }

    // Center the card
    const col: u16 = if (ctx.grid_cols > result.width) (ctx.grid_cols - result.width) / 2 else 0;
    const row: u16 = if (ctx.grid_rows > result.height) ctx.grid_rows / 4 else 0;

    mgr.setContent(.session_switcher, col, row, result.width, result.height, result.cells) catch {
        ctx.allocator.free(result.cells);
        return;
    };
    ctx.allocator.free(result.cells);
}
