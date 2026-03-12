// Attyx — IPC command handler: tab/split creation (both --cmd and plain)
//
// Handles `tab create`, `split v/h`, and their `--cmd` variants
// in both local and session modes. All handlers run synchronously on the
// PTY thread so they can return the new pane index in the response.

const std = @import("std");
const queue = @import("queue.zig");
const terminal = @import("../app/terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const split_layout_mod = @import("../app/split_layout.zig");
const publish = @import("../app/ui/publish.zig");
const actions = @import("../app/ui/actions.zig");
const split_actions = @import("../app/ui/split_actions.zig");
const statusbar = @import("../app/statusbar.zig");
const popup_mod = @import("../app/popup.zig");

const handler = @import("handler.zig");
const sendOk = handler.sendOk;
const sendError = handler.sendError;

pub fn handleTabCreateWithCmd(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx, wait: bool) void {
    const command = cmd.payload[0..cmd.payload_len];
    const rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
    const cols: u16 = ctx.grid_cols;

    var osc7_buf: [statusbar.max_output_len]u8 = undefined;
    const resolved = actions.resolveFocusedCwd(ctx, &osc7_buf);
    defer if (resolved.owned) if (resolved.cwd) |cwd| ctx.allocator.free(cwd);

    if (ctx.sessions_enabled) {
        // Session mode: tell daemon to create pane with the command.
        const sc = ctx.session_client orelse {
            sendError(cmd, "sessions not available");
            return;
        };
        if (wait) {
            // --wait: wrap command so shell exits after it, use capture_stdout
            const wrapped = wrapCommandForWait(ctx.allocator, command) orelse {
                sendError(cmd, "out of memory");
                return;
            };
            defer ctx.allocator.free(wrapped);
            sc.sendCreatePaneWithCmdWait(rows, cols, resolved.cwd orelse "", wrapped) catch {
                sendError(cmd, "failed to send create_pane");
                return;
            };
        } else {
            sc.sendCreatePaneWithCmd(rows, cols, resolved.cwd orelse "", command) catch {
                sendError(cmd, "failed to send create_pane");
                return;
            };
        }
        const pane_id = sc.waitForPaneCreated(5000) catch {
            sendError(cmd, "daemon pane creation failed");
            return;
        };
        const new_pane = ctx.tab_mgr.addDaemonTab(rows, cols, ctx.applied_scrollback_lines) catch {
            sendError(cmd, "failed to create tab");
            return;
        };
        new_pane.daemon_pane_id = pane_id;
    } else {
        // Local mode: build $SHELL -c '<command>' argv.
        const argv = buildShellArgv(ctx, command) orelse {
            sendError(cmd, "out of memory");
            return;
        };
        defer freeShellArgv(ctx, argv);
        const cwd_z: ?[:0]u8 = if (resolved.cwd) |d| ctx.allocator.dupeZ(u8, d) catch null else null;
        defer if (cwd_z) |z| ctx.allocator.free(z);
        if (wait) {
            // --wait: spawn with capture_stdout so stdout pipes back to caller.
            const Pane = @import("../app/pane.zig").Pane;
            const pane = ctx.allocator.create(Pane) catch {
                sendError(cmd, "out of memory");
                return;
            };
            pane.* = Pane.spawnOpts(ctx.allocator, rows, cols, &argv, if (cwd_z) |z| z.ptr else null, ctx.applied_scrollback_lines, .{ .capture_stdout = true }) catch {
                ctx.allocator.destroy(pane);
                sendError(cmd, "failed to create tab");
                return;
            };
            pane.captured_stdout = initCapturedStdout(ctx.allocator);
            ctx.tab_mgr.addTabWithPane(pane, rows, cols) catch {
                pane.deinit();
                ctx.allocator.destroy(pane);
                sendError(cmd, "failed to create tab");
                return;
            };
        } else {
            ctx.tab_mgr.addTabWithArgv(rows, cols, &argv, if (cwd_z) |z| z.ptr else null, ctx.applied_scrollback_lines) catch {
                sendError(cmd, "failed to create tab");
                return;
            };
        }
    }
    publish.updateGridTopOffset(ctx);
    const new_pane = ctx.tab_mgr.activePane();
    new_pane.engine.state.theme_colors = publish.themeToEngineColors(&ctx.active_theme);
    actions.switchActiveTab(ctx);
    actions.saveSessionLayout(ctx);

    if (wait) {
        // Transfer response_fd ownership to the pane — response sent on exit.
        new_pane.ipc_wait_fd = cmd.response_fd;
        cmd.response_fd = -1; // prevent sendOk/sendError from closing it
    } else {
        // Return the new pane's stable IPC ID
        var idx_buf: [16]u8 = undefined;
        var idx_stream = std.io.fixedBufferStream(&idx_buf);
        idx_stream.writer().print("{d}", .{new_pane.ipc_id}) catch {};
        sendOk(cmd, idx_stream.getWritten());
    }
}

/// Plain `tab create` (no --cmd) — synchronous so we can return the index.
/// Mirrors the .tab_new action logic from actions.zig.
pub fn handleTabCreate(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
    const rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
    const cols: u16 = ctx.grid_cols;

    var osc7_buf: [statusbar.max_output_len]u8 = undefined;
    const resolved = actions.resolveFocusedCwd(ctx, &osc7_buf);
    defer if (resolved.owned) if (resolved.cwd) |cwd| ctx.allocator.free(cwd);

    if (ctx.sessions_enabled) {
        const sc = ctx.session_client orelse {
            sendError(cmd, "sessions not available");
            return;
        };
        sc.sendCreatePane(rows, cols, resolved.cwd orelse "") catch {
            sendError(cmd, "failed to send create_pane");
            return;
        };
        const pane_id = sc.waitForPaneCreated(5000) catch {
            sendError(cmd, "daemon pane creation failed");
            return;
        };
        const new_pane = ctx.tab_mgr.addDaemonTab(rows, cols, ctx.applied_scrollback_lines) catch {
            sendError(cmd, "failed to create tab");
            return;
        };
        new_pane.daemon_pane_id = pane_id;
    } else {
        const cwd_z: ?[:0]u8 = if (resolved.cwd) |d| ctx.allocator.dupeZ(u8, d) catch null else null;
        defer if (cwd_z) |z| ctx.allocator.free(z);
        ctx.tab_mgr.addTab(rows, cols, if (cwd_z) |z| z.ptr else null, ctx.applied_scrollback_lines) catch {
            sendError(cmd, "failed to create tab");
            return;
        };
    }

    publish.updateGridTopOffset(ctx);
    const new_pane = ctx.tab_mgr.activePane();
    new_pane.engine.state.theme_colors = publish.themeToEngineColors(&ctx.active_theme);
    actions.switchActiveTab(ctx);
    actions.saveSessionLayout(ctx);

    var idx_buf: [16]u8 = undefined;
    var idx_stream = std.io.fixedBufferStream(&idx_buf);
    idx_stream.writer().print("{d}", .{new_pane.ipc_id}) catch {};
    sendOk(cmd, idx_stream.getWritten());
}

/// Plain `split v/h` (no --cmd) — synchronous so we can return the index.
/// Mirrors the doSplit logic from split_actions.zig.
pub fn handleSplit(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx, dir: split_layout_mod.Direction) void {
    const layout = ctx.tab_mgr.activeLayout();
    const before = layout.pane_count;
    split_actions.doSplit(ctx, layout, dir);

    if (layout.pane_count == before) {
        sendError(cmd, "failed to create split");
        return;
    }

    // Return the new pane's stable IPC ID
    const new_pane = layout.focusedPane();
    var idx_buf: [16]u8 = undefined;
    var idx_stream = std.io.fixedBufferStream(&idx_buf);
    idx_stream.writer().print("{d}", .{new_pane.ipc_id}) catch {};
    sendOk(cmd, idx_stream.getWritten());
}

pub fn handleSplitWithCmd(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx, dir: split_layout_mod.Direction, wait: bool) void {
    const Pane = @import("../app/pane.zig").Pane;
    const command = cmd.payload[0..cmd.payload_len];
    const layout = ctx.tab_mgr.activeLayout();

    var osc7_buf: [statusbar.max_output_len]u8 = undefined;
    const resolved = actions.resolveFocusedCwd(ctx, &osc7_buf);
    defer if (resolved.owned) if (resolved.cwd) |cwd| ctx.allocator.free(cwd);

    if (ctx.sessions_enabled) {
        const sc = ctx.session_client orelse {
            sendError(cmd, "sessions not available");
            return;
        };
        const sz = layout.splitChildSize(dir, layout.pool[layout.focused].rect) orelse {
            sendError(cmd, "pane too small to split");
            return;
        };
        if (wait) {
            const wrapped = wrapCommandForWait(ctx.allocator, command) orelse {
                sendError(cmd, "out of memory");
                return;
            };
            defer ctx.allocator.free(wrapped);
            sc.sendCreatePaneWithCmdWait(sz.rows, sz.cols, resolved.cwd orelse "", wrapped) catch {
                sendError(cmd, "failed to send create_pane");
                return;
            };
        } else {
            sc.sendCreatePaneWithCmd(sz.rows, sz.cols, resolved.cwd orelse "", command) catch {
                sendError(cmd, "failed to send create_pane");
                return;
            };
        }
        const pane_id = sc.waitForPaneCreated(5000) catch {
            sendError(cmd, "daemon pane creation failed");
            return;
        };
        const new_pane = ctx.allocator.create(Pane) catch {
            sendError(cmd, "out of memory");
            return;
        };
        new_pane.* = Pane.initDaemonBacked(ctx.allocator, sz.rows, sz.cols, ctx.applied_scrollback_lines) catch {
            ctx.allocator.destroy(new_pane);
            sendError(cmd, "failed to init pane");
            return;
        };
        new_pane.daemon_pane_id = pane_id;
        ctx.tab_mgr.assignIpcId(new_pane);
        layout.splitPaneWith(dir, new_pane) catch {
            new_pane.deinit();
            ctx.allocator.destroy(new_pane);
            sendError(cmd, "failed to split");
            return;
        };
    } else {
        const argv = buildShellArgv(ctx, command) orelse {
            sendError(cmd, "out of memory");
            return;
        };
        defer freeShellArgv(ctx, argv);
        if (wait) {
            // --wait: spawn with capture_stdout so stdout pipes back to caller.
            const sz = layout.splitChildSize(dir, layout.pool[layout.focused].rect) orelse {
                sendError(cmd, "pane too small to split");
                return;
            };
            const cwd_z: ?[:0]u8 = if (resolved.cwd) |d| ctx.allocator.dupeZ(u8, d) catch null else null;
            defer if (cwd_z) |z| ctx.allocator.free(z);
            const new_split_pane = ctx.allocator.create(Pane) catch {
                sendError(cmd, "out of memory");
                return;
            };
            new_split_pane.* = Pane.spawnOpts(ctx.allocator, sz.rows, sz.cols, &argv, if (cwd_z) |z| z.ptr else null, ctx.applied_scrollback_lines, .{ .capture_stdout = true }) catch {
                ctx.allocator.destroy(new_split_pane);
                sendError(cmd, "failed to create split");
                return;
            };
            new_split_pane.captured_stdout = initCapturedStdout(ctx.allocator);
            ctx.tab_mgr.assignIpcId(new_split_pane);
            layout.splitPaneWith(dir, new_split_pane) catch {
                new_split_pane.deinit();
                ctx.allocator.destroy(new_split_pane);
                sendError(cmd, "failed to split");
                return;
            };
        } else {
            layout.splitPaneResolvedWithArgv(dir, ctx.allocator, &argv, resolved.cwd, ctx.applied_scrollback_lines) catch {
                sendError(cmd, "failed to create split");
                return;
            };
        }
    }

    // Set theme colors and assign IPC ID on newly created pane
    const new_pane = if (layout.pool[layout.focused].pane) |pane| pane else null;
    if (new_pane) |pane| {
        if (pane.ipc_id == 0) ctx.tab_mgr.assignIpcId(pane);
        pane.engine.state.theme_colors = publish.themeToEngineColors(&ctx.active_theme);
    }
    const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
    layout.layout(pty_rows, ctx.grid_cols);

    split_actions.notifyPaneSizes(ctx, layout);
    actions.updateSplitActive(ctx);
    actions.switchActiveTab(ctx);
    actions.saveSessionLayout(ctx);

    if (wait) {
        if (new_pane) |pane| {
            pane.ipc_wait_fd = cmd.response_fd;
            cmd.response_fd = -1;
        } else {
            sendOk(cmd, "");
        }
    } else {
        // Return the new pane's stable IPC ID
        var idx_buf: [16]u8 = undefined;
        var idx_stream = std.io.fixedBufferStream(&idx_buf);
        const created_id: u32 = if (new_pane) |p| p.ipc_id else 0;
        idx_stream.writer().print("{d}", .{created_id}) catch {};
        sendOk(cmd, idx_stream.getWritten());
    }
}

// ---------------------------------------------------------------------------
// Targeted pane/tab operations
// ---------------------------------------------------------------------------

/// Close a specific pane by IPC ID. Payload: [pane_id:u32 LE]
pub fn handlePaneCloseTargeted(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
    if (cmd.payload_len < 4) {
        sendError(cmd, "missing pane ID");
        return;
    }
    const pane_id = std.mem.readInt(u32, cmd.payload[0..4], .little);
    const found = ctx.tab_mgr.findPaneWithLayout(pane_id) orelse {
        sendError(cmd, "pane not found");
        return;
    };

    // Notify daemon before closing
    if (ctx.session_client) |sc| {
        if (found.pane.daemon_pane_id) |dpid| sc.sendClosePane(dpid) catch {};
    }

    // Find which tab this layout belongs to
    const ti = for (0..ctx.tab_mgr.count) |i| {
        if (ctx.tab_mgr.tabs[i]) |*tab_layout| {
            if (tab_layout == found.layout) break @as(u8, @intCast(i));
        }
    } else ctx.tab_mgr.active;

    // Remember the previously focused pane so we can restore focus after close
    const prev_focused_id = if (found.layout.pool[found.layout.focused].pane) |fp| fp.ipc_id else 0;

    const result = found.layout.closePaneAt(found.pool_idx, ctx.allocator);
    if (result == .last_pane) {
        if (ctx.tab_mgr.count <= 1) {
            sendError(cmd, "cannot close last pane");
            return;
        }
        ctx.tab_mgr.closeTab(ti);
        publish.updateGridTopOffset(ctx);
    } else {
        // Restore focus to the previously focused pane if it still exists
        // (closePaneAt restructures the tree, shifting pool indices)
        if (prev_focused_id != 0 and prev_focused_id != pane_id) {
            var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
            const lc = found.layout.collectLeaves(&leaves);
            for (leaves[0..lc]) |leaf| {
                if (leaf.pane.ipc_id == prev_focused_id) {
                    found.layout.focused = leaf.index;
                    break;
                }
            }
        }
        const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
        found.layout.layout(pty_rows, ctx.grid_cols);
        split_actions.notifyPaneSizes(ctx, found.layout);
        actions.updateSplitActive(ctx);
    }
    actions.switchActiveTab(ctx);
    actions.saveSessionLayout(ctx);
    sendOk(cmd, "");
}

/// Close a specific tab by index. Payload: [tab_idx:u8] (0-based)
pub fn handleTabCloseTargeted(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
    if (cmd.payload_len < 1) {
        sendError(cmd, "missing tab index");
        return;
    }
    const ti = cmd.payload[0];
    if (ti >= ctx.tab_mgr.count) {
        sendError(cmd, "tab not found");
        return;
    }
    if (ctx.tab_mgr.count <= 1) {
        sendError(cmd, "cannot close last tab");
        return;
    }

    // Notify daemon for all panes in the tab
    if (ctx.session_client) |sc| {
        if (ctx.tab_mgr.tabs[ti]) |*layout| {
            var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
            const lc = layout.collectLeaves(&leaves);
            for (leaves[0..lc]) |leaf| {
                if (leaf.pane.daemon_pane_id) |dpid| sc.sendClosePane(dpid) catch {};
            }
        }
    }

    ctx.tab_mgr.closeTab(ti);
    publish.updateGridTopOffset(ctx);
    actions.switchActiveTab(ctx);
    actions.saveSessionLayout(ctx);
    sendOk(cmd, "");
}

/// Rename a specific tab's focused pane. Payload: [tab_idx:u8][name...]
pub fn handleTabRenameTargeted(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
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

/// Toggle zoom on a specific pane by IPC ID. Payload: [pane_id:u32 LE]
pub fn handlePaneZoomTargeted(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
    if (cmd.payload_len < 4) {
        sendError(cmd, "missing pane ID");
        return;
    }
    const pane_id = std.mem.readInt(u32, cmd.payload[0..4], .little);
    const found = ctx.tab_mgr.findPaneWithLayout(pane_id) orelse {
        sendError(cmd, "pane not found");
        return;
    };

    // Focus the target pane before toggling zoom (zoom requires focus)
    const prev_focused = found.layout.focused;
    found.layout.focused = found.pool_idx;
    found.layout.toggleZoom();
    // Restore focus if we zoomed a non-focused pane (unzoom always keeps target)
    if (!found.layout.isZoomed() and prev_focused != found.pool_idx) {
        found.layout.focused = prev_focused;
    }
    const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
    if (found.layout.isZoomed()) {
        found.layout.focusedPane().resize(pty_rows, ctx.grid_cols);
    } else {
        found.layout.layout(pty_rows, ctx.grid_cols);
    }
    split_actions.notifyPaneSizes(ctx, found.layout);
    actions.switchActiveTab(ctx);
    sendOk(cmd, "");
}

/// Rotate panes in a tab containing the given pane. Payload: [pane_id:u32 LE]
/// If no pane ID given (payload_len < 4), rotates the active tab.
pub fn handlePaneRotateTargeted(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
    const layout = if (cmd.payload_len >= 4) blk: {
        const pane_id = std.mem.readInt(u32, cmd.payload[0..4], .little);
        const found = ctx.tab_mgr.findPaneWithLayout(pane_id) orelse {
            sendError(cmd, "pane not found");
            return;
        };
        break :blk found.layout;
    } else ctx.tab_mgr.activeLayout();

    layout.rotatePanes();
    const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
    layout.layout(pty_rows, ctx.grid_cols);
    split_actions.notifyPaneSizes(ctx, layout);
    actions.switchActiveTab(ctx);
    sendOk(cmd, "");
}


/// Build $SHELL -c '<command>' argv, with PATH injection from shell integration.
pub fn buildShellArgv(ctx: *PtyThreadCtx, command: []const u8) ?[3][:0]const u8 {
    const shell_env = std.posix.getenv("SHELL") orelse "/bin/sh";
    const shell_z = ctx.allocator.dupeZ(u8, shell_env) catch return null;
    const c_flag = ctx.allocator.dupeZ(u8, "-c") catch {
        ctx.allocator.free(shell_z);
        return null;
    };
    // Inject PATH from shell integration (app bundle may have minimal PATH)
    const shell_path = publish.ctxEngine(ctx).state.shell_path;
    const cmd_z = if (shell_path) |sp| blk: {
        const wrapped = std.fmt.allocPrint(ctx.allocator, "export PATH='{s}'; {s}", .{ sp, command }) catch
            break :blk ctx.allocator.dupeZ(u8, command) catch {
            ctx.allocator.free(c_flag);
            ctx.allocator.free(shell_z);
            return null;
        };
        defer ctx.allocator.free(wrapped);
        break :blk ctx.allocator.dupeZ(u8, wrapped) catch {
            ctx.allocator.free(c_flag);
            ctx.allocator.free(shell_z);
            return null;
        };
    } else ctx.allocator.dupeZ(u8, command) catch {
        ctx.allocator.free(c_flag);
        ctx.allocator.free(shell_z);
        return null;
    };
    return .{ shell_z, c_flag, cmd_z };
}

pub fn freeShellArgv(ctx: *PtyThreadCtx, argv: [3][:0]const u8) void {
    ctx.allocator.free(argv[2]);
    ctx.allocator.free(argv[1]);
    ctx.allocator.free(argv[0]);
}

/// Wrap a command for --wait mode: append "; exit $?" so the shell exits
/// after the command finishes (instead of staying alive at a prompt).
fn wrapCommandForWait(allocator: std.mem.Allocator, command: []const u8) ?[]const u8 {
    return std.fmt.allocPrint(allocator, "{s}; exit $?", .{command}) catch null;
}

fn initCapturedStdout(allocator: std.mem.Allocator) ?*std.ArrayList(u8) {
    const cs = allocator.create(std.ArrayList(u8)) catch return null;
    cs.* = .empty;
    return cs;
}

pub fn handlePopup(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
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
