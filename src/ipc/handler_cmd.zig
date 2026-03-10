// Attyx — IPC command handler: --cmd support for tab/split creation
//
// Handles `tab create --cmd`, `run`, and `split --cmd` in both local and session modes.

const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol.zig");
const queue = @import("queue.zig");
const terminal = @import("../app/terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const split_layout_mod = @import("../app/split_layout.zig");
const publish = @import("../app/ui/publish.zig");
const actions = @import("../app/ui/actions.zig");
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
        sendOk(cmd, "");
    }
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

    // Set theme colors on newly created pane
    const new_pane = if (layout.pool[layout.focused].pane) |pane| pane else null;
    if (new_pane) |pane| {
        pane.engine.state.theme_colors = publish.themeToEngineColors(&ctx.active_theme);
    }
    const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
    layout.layout(pty_rows, ctx.grid_cols);

    const split_actions = @import("../app/ui/split_actions.zig");
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
        sendOk(cmd, "");
    }
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
