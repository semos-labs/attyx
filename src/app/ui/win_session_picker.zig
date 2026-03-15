/// Windows session picker overlay — wires the cross-platform
/// SessionPickerState + panel renderer + FinderState to WinCtx.
const std = @import("std");
const attyx = @import("attyx");
const overlay_mod = attyx.overlay_mod;
const FinderState = attyx.finder.FinderState;

const ws = @import("../windows_stubs.zig");
const publish = @import("publish.zig");
const c = publish.c;
const win_search = @import("win_search.zig");
const event_loop = @import("event_loop_windows.zig");
const WinCtx = event_loop.WinCtx;
const session_win = @import("../session_windows.zig");

const picker_state_mod = attyx.overlay_session_picker;
const SessionPickerState = picker_state_mod.SessionPickerState;
const SessionEntry = picker_state_mod.SessionEntry;
const picker_panel = attyx.overlay_session_picker_panel;
const logging = @import("../../logging/log.zig");

var g_picker_state: ?SessionPickerState = null;
var g_finder_state: ?FinderState = null;

pub fn openSessionPicker(ctx: *WinCtx) void {
    logging.info("session", "openSessionPicker called, has_mgr={}", .{ctx.session_mgr != null});
    const smgr = ctx.session_mgr orelse {
        logging.warn("session", "session_mgr is null, aborting", .{});
        return;
    };

    const panel_h = @as(u16, @intCast(@max(3, ctx.grid_rows))) / 2;
    const visible = if (panel_h > 4) @as(u8, @intCast(panel_h - 4)) else 3;

    var state = SessionPickerState{};
    state.visible_rows = visible;

    // Build entries from WinSessionManager
    var entries: [session_win.max_sessions]SessionEntry = undefined;
    var count: u8 = 0;
    for (0..session_win.max_sessions) |i| {
        if (smgr.sessions[i]) |*s| {
            var entry = SessionEntry{
                .id = s.id,
                .alive = s.alive,
                .name_len = s.name_len,
            };
            @memcpy(entry.name[0..s.name_len], s.name[0..s.name_len]);
            entries[count] = entry;
            count += 1;
        }
    }
    state.load(&entries, count, smgr.activeSession().id);

    g_picker_state = state;
    @atomicStore(i32, &ws.g_session_picker_active, 1, .seq_cst);

    // Init filesystem finder
    if (g_finder_state) |*f| {
        f.deinit();
        g_finder_state = null;
    }
    g_finder_state = FinderState.init(
        ctx.allocator,
        ctx.finder_root,
        ctx.finder_depth,
        ctx.finder_show_hidden,
    ) catch null;

    renderAndPublish(ctx);
}

pub fn consumeInput(ctx: *WinCtx) bool {
    var state = &(g_picker_state orelse return false);
    var consumed = false;

    while (true) {
        const r = @atomicLoad(u32, &ws.picker_char_read, .seq_cst);
        const w = @atomicLoad(u32, &ws.picker_char_write, .seq_cst);
        if (r == w) break;
        const cp = ws.picker_char_ring[r % 32];
        @atomicStore(u32, &ws.picker_char_read, r +% 1, .seq_cst);
        consumed = true;
        const action = state.handleChar(cp);
        if (processAction(ctx, action)) return true;
    }

    while (true) {
        const r = @atomicLoad(u32, &ws.picker_cmd_read, .seq_cst);
        const w = @atomicLoad(u32, &ws.picker_cmd_write, .seq_cst);
        if (r == w) break;
        const cmd = ws.picker_cmd_ring[r % 16];
        @atomicStore(u32, &ws.picker_cmd_read, r +% 1, .seq_cst);
        consumed = true;
        const action = state.handleCmd(cmd);
        if (processAction(ctx, action)) return true;
    }

    if (consumed) {
        // Update finder with current filter text
        if (g_finder_state) |*finder| {
            finder.updateQuery(state.filter_buf[0..state.filter_len]);
            pushFinderResults(state, finder);
        }
        renderAndPublish(ctx);
    }
    return consumed;
}

/// Tick the finder — call from the event loop to process directory walking.
pub fn tickFinder(ctx: *WinCtx) void {
    const state = &(g_picker_state orelse return);
    const finder = &(g_finder_state orelse return);

    if (finder.walking_done) return;
    finder.tick() catch return;

    // If we have an active query, push updated results
    if (state.filter_len > 0) {
        const old_count = state.fs_count;
        pushFinderResults(state, finder);
        if (state.fs_count != old_count) {
            renderAndPublish(ctx);
        }
    }
}

fn pushFinderResults(state: *SessionPickerState, finder: *FinderState) void {
    if (state.filter_len == 0) {
        state.fs_count = 0;
        return;
    }

    const max_fs = picker_state_mod.max_fs_results;
    const result_indices = finder.getResults(0, max_fs * 3);

    var paths: [max_fs][]const u8 = undefined;
    var scores: [max_fs]i32 = undefined;
    var out: usize = 0;

    for (result_indices, 0..) |idx, i| {
        if (out >= max_fs) break;
        const path = finder.getPath(idx);

        // Deduplicate: skip if basename matches any existing session name
        const basename = if (std.mem.lastIndexOfAny(u8, path, "/\\")) |sep|
            path[sep + 1 ..]
        else
            path;
        if (matchesExistingSession(state, basename)) continue;

        paths[out] = path;
        scores[out] = finder.getScore(@intCast(i));
        out += 1;
    }

    state.updateFsResults(paths[0..out], scores[0..out]);
}

fn matchesExistingSession(state: *const SessionPickerState, basename: []const u8) bool {
    if (basename.len == 0) return false;
    for (0..state.entry_count) |i| {
        if (std.mem.eql(u8, state.entries[i].getName(), basename)) return true;
    }
    return false;
}

fn processAction(ctx: *WinCtx, action: picker_state_mod.PickerAction) bool {
    const smgr = ctx.session_mgr orelse return false;
    switch (action) {
        .none => return false,
        .close => {
            close(ctx);
            return true;
        },
        .switch_session => |sid| {
            close(ctx);
            _ = smgr.switchTo(sid) catch return true;
            event_loop.switchSession(ctx);
            return true;
        },
        .switch_to_default => {
            close(ctx);
            return true;
        },
        .create_session => {
            close(ctx);
            const ws_stubs = @import("../windows_stubs.zig");
            const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - ws_stubs.g_grid_top_offset - ws_stubs.g_grid_bottom_offset));
            const name = nameFromCwd(ctx);
            const sid = smgr.createSession(name, pty_rows, ctx.grid_cols, ctx.theme, ctx.applied_scrollback_lines) catch return true;
            _ = smgr.switchTo(sid) catch {};
            event_loop.switchSession(ctx);
            return true;
        },
        .create_session_at => |rel_path| {
            // Build absolute path from finder root + relative path
            const finder = &(g_finder_state orelse {
                close(ctx);
                return true;
            });
            const root = finder.getRootPath();
            var abs_buf: [512]u8 = undefined;
            const sep: []const u8 = if (comptime @import("builtin").os.tag == .windows) "\\" else "/";
            const abs_path = std.fmt.bufPrint(&abs_buf, "{s}{s}{s}", .{ root, sep, rel_path }) catch {
                close(ctx);
                return true;
            };
            // Extract name from the path
            const name = if (std.mem.lastIndexOfAny(u8, abs_path, "/\\")) |i|
                abs_path[i + 1 ..]
            else
                abs_path;

            close(ctx);
            const ws_stubs = @import("../windows_stubs.zig");
            const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - ws_stubs.g_grid_top_offset - ws_stubs.g_grid_bottom_offset));
            const sid = smgr.createSession(
                if (name.len > 0) name else "new",
                pty_rows,
                ctx.grid_cols,
                ctx.theme,
                ctx.applied_scrollback_lines,
            ) catch return true;
            _ = smgr.switchTo(sid) catch {};
            event_loop.switchSession(ctx);
            return true;
        },
        .kill_session => |sid| {
            smgr.kill(sid) catch {};
            refreshEntries(ctx);
            if (g_picker_state) |*s| renderAndPublishState(ctx, s);
            return false;
        },
        .rename_session => |rs| {
            smgr.rename(rs.id, rs.name) catch {};
            refreshEntries(ctx);
            if (g_picker_state) |*s| renderAndPublishState(ctx, s);
            return false;
        },
    }
}

fn refreshEntries(ctx: *WinCtx) void {
    const smgr = ctx.session_mgr orelse return;
    const state = &(g_picker_state orelse return);
    var entries: [session_win.max_sessions]SessionEntry = undefined;
    var count: u8 = 0;
    for (0..session_win.max_sessions) |i| {
        if (smgr.sessions[i]) |*s| {
            var entry = SessionEntry{
                .id = s.id,
                .alive = s.alive,
                .name_len = s.name_len,
            };
            @memcpy(entry.name[0..s.name_len], s.name[0..s.name_len]);
            entries[count] = entry;
            count += 1;
        }
    }
    state.load(&entries, count, smgr.activeSession().id);
}

pub fn close(ctx: *WinCtx) void {
    if (g_finder_state) |*f| {
        f.deinit();
        g_finder_state = null;
    }
    g_picker_state = null;
    @atomicStore(i32, &ws.g_session_picker_active, 0, .seq_cst);
    if (ctx.overlay_mgr) |mgr| mgr.hide(.session_picker);
    win_search.publishOverlays(ctx);
}

fn renderAndPublish(ctx: *WinCtx) void {
    const state = &(g_picker_state orelse return);
    renderAndPublishState(ctx, state);
}

fn renderAndPublishState(ctx: *WinCtx, state: *const SessionPickerState) void {
    const mgr = ctx.overlay_mgr orelse return;

    const result = picker_panel.renderSessionPicker(
        ctx.allocator,
        state,
        ctx.grid_cols,
        ctx.grid_rows,
        .{},
        publish.overlayThemeFromTheme(ctx.theme),
    ) catch return;

    if (result.width == 0 or result.height == 0) return;

    mgr.setContent(
        .session_picker,
        result.col,
        result.row,
        result.width,
        result.height,
        result.cells,
    ) catch {};
    mgr.show(.session_picker);
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.session_picker)].backdrop_alpha = 100;
    ctx.allocator.free(result.cells);

    win_search.publishOverlays(ctx);
}

/// Derive session name from active pane's working directory.
fn nameFromCwd(ctx: *WinCtx) []const u8 {
    const wd = ctx.tab_mgr.activePane().engine.state.working_directory orelse return "new";
    return lastPathComponent(wd);
}

/// Extract the last component from a path (handles / and \ separators, strips file:// URIs).
fn lastPathComponent(path: []const u8) []const u8 {
    var p = path;
    if (std.mem.startsWith(u8, p, "file://")) {
        p = p["file://".len..];
        if (std.mem.indexOfScalar(u8, p, '/')) |i| p = p[i..];
    }
    const trimmed = std.mem.trimRight(u8, p, "/\\");
    if (trimmed.len == 0) return "new";
    if (std.mem.lastIndexOfAny(u8, trimmed, "/\\")) |i| return trimmed[i + 1 ..];
    return trimmed;
}

pub fn relayout(ctx: *WinCtx) void {
    const state = &(g_picker_state orelse return);

    const panel_h = @as(u16, @intCast(@max(3, ctx.grid_rows))) / 2;
    state.visible_rows = if (panel_h > 4) @as(u8, @intCast(panel_h - 4)) else 3;
    state.adjustScroll();

    renderAndPublishState(ctx, state);
}
