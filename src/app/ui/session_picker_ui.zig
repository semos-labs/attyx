/// Session picker UI integration — wires the overlay-based session picker
/// state machine to the daemon client and overlay manager.
const std = @import("std");
const posix = std.posix;
const logging = @import("../../logging/log.zig");


const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const c = terminal.c;
const publish = @import("publish.zig");
const input = @import("input.zig");
const session_actions = @import("session_actions.zig");
const actions = @import("actions.zig");
const statusbar = @import("../statusbar.zig");

const attyx = @import("attyx");
const picker_state_mod = attyx.overlay_session_picker;
const SessionPickerState = picker_state_mod.SessionPickerState;
const picker_panel = attyx.overlay_session_picker_panel;
const FinderState = attyx.finder.FinderState;

var g_picker_state: ?SessionPickerState = null;
var g_finder_state: ?FinderState = null;
var g_finder_root: []const u8 = "~";
var g_finder_depth: u8 = 4;
var g_finder_show_hidden: bool = false;

pub fn openSessionPicker(ctx: *PtyThreadCtx) void {
    // Close existing popup if any
    if (ctx.popup_state != null) actions.closePopup(ctx);

    // Fetch session list via session client
    const sc = ctx.session_client orelse return;
    sc.requestListSync(2000) catch return;

    // Initialize state
    var state = SessionPickerState{};
    const count = sc.pending_list_count;

    for (0..count) |i| {
        const le = &sc.pending_list[i];
        state.entries[i] = .{
            .id = le.id,
            .name_len = le.name_len,
            .alive = le.alive,
        };
        @memcpy(state.entries[i].name[0..le.name_len], le.name[0..le.name_len]);
    }

    // Compute visible rows from grid
    const panel_h = @as(u16, @intCast(@max(3, ctx.grid_rows))) / 2;
    const visible = if (panel_h > 5) @as(u8, @intCast(panel_h - 5)) else 3;

    state.entry_count = count;
    state.current_session_id = if (sc.attached_session_id) |sid| sid else null;
    state.visible_rows = visible;
    state.applyFilter();

    // Pre-select first non-current alive session
    var found_preselect = false;
    for (0..state.filtered_count) |i| {
        const e = &state.entries[state.filtered_indices[i]];
        if (e.alive and (state.current_session_id == null or e.id != state.current_session_id.?)) {
            state.selected = @intCast(i);
            found_preselect = true;
            break;
        }
    }
    if (!found_preselect) state.selected = 0;
    state.adjustScroll();

    g_picker_state = state;
    @atomicStore(i32, &terminal.g_session_picker_active, 1, .seq_cst);

    // Init finder for filesystem search
    if (g_finder_state != null) {
        g_finder_state.?.deinit();
        g_finder_state = null;
    }
    g_finder_state = FinderState.init(ctx.allocator, g_finder_root, g_finder_depth, g_finder_show_hidden) catch null;

    renderAndPublish(ctx);
    logging.info("session-picker", "opened overlay picker", .{});
}

/// Configure finder parameters (called when config is loaded/reloaded).
pub fn setFinderConfig(root: []const u8, depth: u8, show_hidden: bool) void {
    g_finder_root = root;
    g_finder_depth = depth;
    g_finder_show_hidden = show_hidden;
}

/// Drain picker input rings and process actions. Returns true if any input consumed.
pub fn consumePickerInput(ctx: *PtyThreadCtx) bool {
    const state = &(g_picker_state orelse return false);
    var consumed = false;

    // Drain char ring
    while (true) {
        const r = @atomicLoad(u32, &input.g_picker_char_read, .seq_cst);
        const w = @atomicLoad(u32, &input.g_picker_char_write, .seq_cst);
        if (r == w) break;
        const cp = input.g_picker_char_ring[r % 32];
        @atomicStore(u32, &input.g_picker_char_read, r +% 1, .seq_cst);
        consumed = true;

        const action = state.handleChar(cp);
        if (processAction(ctx, state, action)) return true;
    }

    // Drain cmd ring
    while (true) {
        const r = @atomicLoad(u32, &input.g_picker_cmd_read, .seq_cst);
        const w = @atomicLoad(u32, &input.g_picker_cmd_write, .seq_cst);
        if (r == w) break;
        const cmd = input.g_picker_cmd_ring[r % 16];
        @atomicStore(u32, &input.g_picker_cmd_read, r +% 1, .seq_cst);
        consumed = true;

        const action = state.handleCmd(cmd);
        if (processAction(ctx, state, action)) return true;
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

/// Tick the finder — called from the event loop to process directory walking.
pub fn tickFinder(ctx: *PtyThreadCtx) void {
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
    const query_active = state.filter_len > 0;
    if (!query_active) {
        state.fs_count = 0;
        return;
    }

    const max_fs = picker_state_mod.max_fs_results;
    // Fetch more than we need so we can skip dupes and still fill max_fs
    const fetch_count = max_fs * 3;
    const result_indices = finder.getResults(0, fetch_count);

    var paths: [max_fs][]const u8 = undefined;
    var scores: [max_fs]i32 = undefined;
    var out: usize = 0;

    for (result_indices, 0..) |idx, i| {
        if (out >= max_fs) break;
        const path = finder.getPath(idx);

        // Deduplicate: skip if basename matches any existing session name
        const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep|
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
        const name = state.entries[i].getName();
        if (std.mem.eql(u8, name, basename)) return true;
    }
    return false;
}

/// Process a PickerAction returned by the state machine.
/// Returns true if the picker was closed (caller should stop processing).
fn processAction(ctx: *PtyThreadCtx, state: *SessionPickerState, action: picker_state_mod.PickerAction) bool {
    switch (action) {
        .none => return false,
        .close => {
            closeSessionPicker(ctx);
            return true;
        },
        .switch_session => |id| {
            closeSessionPicker(ctx);
            session_actions.doSessionSwitch(ctx, id);
            return true;
        },
        .switch_to_default => {
            closeSessionPicker(ctx);
            switchToDefaultSession(ctx);
            return true;
        },
        .create_session => {
            closeSessionPicker(ctx);
            var osc7_buf: [statusbar.max_output_len]u8 = undefined;
            const resolved = actions.resolveFocusedCwd(ctx, &osc7_buf);
            defer if (resolved.owned) if (resolved.cwd) |cwd| ctx.allocator.free(cwd);
            session_actions.doSessionCreate(ctx, resolved.cwd orelse "/tmp");
            return true;
        },
        .create_session_at => |rel_path| {
            // Build absolute path from finder root + relative path
            var abs_buf: [512]u8 = undefined;
            const finder = &(g_finder_state orelse {
                closeSessionPicker(ctx);
                return true;
            });
            const root = finder.getRootPath();
            const abs_path = std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ root, rel_path }) catch {
                closeSessionPicker(ctx);
                return true;
            };
            // Copy to allocator since closeSessionPicker will deinit finder
            const path_copy = ctx.allocator.dupe(u8, abs_path) catch {
                closeSessionPicker(ctx);
                return true;
            };
            closeSessionPicker(ctx);
            session_actions.doSessionCreate(ctx, path_copy);
            ctx.allocator.free(path_copy);
            return true;
        },
        .kill_session => |id| {
            const sc = ctx.session_client orelse return false;
            sc.killSession(id) catch {};
            // Re-fetch list and update state
            refreshList(ctx, state);
            renderAndPublish(ctx);
            return false;
        },
        .rename_session => |rs| {
            const sc = ctx.session_client orelse return false;
            sc.renameSession(rs.id, rs.name) catch {};
            // Re-fetch list and update state
            refreshList(ctx, state);
            renderAndPublish(ctx);
            return false;
        },
    }
}

/// Re-fetch session list and update the picker state.
fn refreshList(ctx: *PtyThreadCtx, state: *SessionPickerState) void {
    const sc = ctx.session_client orelse return;
    // Small delay for daemon to process the kill/rename
    var no_fds = [0]posix.pollfd{};
    _ = posix.poll(&no_fds, 50) catch {};
    sc.requestListSync(2000) catch return;
    const count = sc.pending_list_count;
    for (0..count) |i| {
        const le = &sc.pending_list[i];
        state.entries[i] = .{
            .id = le.id,
            .name_len = le.name_len,
            .alive = le.alive,
        };
        @memcpy(state.entries[i].name[0..le.name_len], le.name[0..le.name_len]);
    }
    state.entry_count = count;
    // Re-sort: current → alive → dead (recent).
    const overlay_picker = @import("attyx").overlay_session_picker;
    overlay_picker.sortEntries(state.entries[0..count], state.current_session_id);
    state.applyFilter();
    const total = state.totalCount();
    if (state.selected >= total) {
        state.selected = if (state.filtered_count > 0) state.filtered_count - 1 else 0;
    }
    state.adjustScroll();
}

pub fn closeSessionPicker(ctx: *PtyThreadCtx) void {
    if (g_finder_state) |*finder| {
        finder.deinit();
        g_finder_state = null;
    }
    g_picker_state = null;
    @atomicStore(i32, &terminal.g_session_picker_active, 0, .seq_cst);
    if (ctx.overlay_mgr) |mgr| mgr.hide(.session_picker);
    publish.publishOverlays(ctx);
    logging.info("session-picker", "closed overlay picker", .{});
}

/// Re-render the session picker at the current grid size without publishing.
/// Called from handleResize so the panel re-centers after window size changes.
pub fn relayout(ctx: *PtyThreadCtx) void {
    const state = &(g_picker_state orelse return);
    const mgr = ctx.overlay_mgr orelse return;

    // Recompute visible rows from new grid size
    const panel_h = @as(u16, @intCast(@max(3, ctx.grid_rows))) / 2;
    state.visible_rows = if (panel_h > 5) @as(u8, @intCast(panel_h - 5)) else 3;
    state.adjustScroll();

    const overlay_mod = @import("attyx").overlay_mod;

    const icons = picker_panel.Icons{
        .filter = ctx.session_icon_filter,
        .session = ctx.session_icon_session,
        .new = ctx.session_icon_new,
        .active = ctx.session_icon_active,
        .recent = ctx.session_icon_recent,
        .folder = ctx.session_icon_folder,
    };

    const result = picker_panel.renderSessionPicker(
        ctx.allocator,
        state,
        ctx.grid_cols,
        ctx.grid_rows,
        icons,
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
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.session_picker)].backdrop_alpha = 100;
    ctx.allocator.free(result.cells);
}

/// Switch to the hidden "default" session, creating it if needed.
fn switchToDefaultSession(ctx: *PtyThreadCtx) void {
    const sc = ctx.session_client orelse return;

    // Look for an existing alive "default" session.
    sc.requestListSync(2000) catch return;
    for (sc.pending_list[0..sc.pending_list_count]) |entry| {
        if (entry.alive and std.mem.eql(u8, entry.getName(), "default")) {
            session_actions.doSessionSwitch(ctx, entry.id);
            return;
        }
    }

    // No alive "default" session — create one.
    session_actions.doSessionCreate(ctx, std.posix.getenv("HOME") orelse "/tmp");
    // Rename the newly created session to "default".
    if (sc.attached_session_id) |sid| {
        sc.renameSession(sid, "default") catch {};
    }
}

fn renderAndPublish(ctx: *PtyThreadCtx) void {
    const state = &(g_picker_state orelse return);
    const mgr = ctx.overlay_mgr orelse return;

    const icons = picker_panel.Icons{
        .filter = ctx.session_icon_filter,
        .session = ctx.session_icon_session,
        .new = ctx.session_icon_new,
        .active = ctx.session_icon_active,
        .recent = ctx.session_icon_recent,
        .folder = ctx.session_icon_folder,
    };

    const result = picker_panel.renderSessionPicker(
        ctx.allocator,
        state,
        ctx.grid_cols,
        ctx.grid_rows,
        icons,
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
    mgr.layers[@intFromEnum(@import("attyx").overlay_mod.OverlayId.session_picker)].backdrop_alpha = 100;
    ctx.allocator.free(result.cells);

    publish.publishOverlays(ctx);
}
