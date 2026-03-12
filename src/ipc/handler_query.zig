// Attyx — IPC command handler: query/list builders
//
// Builds response payloads for list, list-tabs, list-splits, get-text,
// and session commands.

const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol.zig");
const queue = @import("queue.zig");
const terminal = @import("../app/terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const split_layout_mod = @import("../app/split_layout.zig");
const platform = @import("../platform/platform.zig");
const publish = @import("../app/ui/publish.zig");

const handler = @import("handler.zig");
const sendOk = handler.sendOk;
const sendError = handler.sendError;

fn resolveTitle(pane: anytype, name_buf: *[256]u8) []const u8 {
    return pane.getCustomTitle() orelse
        pane.engine.state.title orelse
        platform.getForegroundProcessName(pane.pty.master, name_buf) orelse
        pane.getDaemonProcName() orelse
        "shell";
}

pub fn buildList(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
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
        // Always show the focused pane's IPC ID on the tab line
        w.print("\tpane:{d}", .{layout.focusedPane().ipc_id}) catch break;
        if (layout.pane_count > 1) {
            w.print("\t{d} panes", .{layout.pane_count}) catch break;
        }
        if (layout.isZoomed()) w.writeAll("\tzoomed") catch break;
        w.writeAll("\n") catch break;

        // If multiple panes, list them indented
        if (layout.pane_count > 1) {
            var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
            const lc = layout.collectLeaves(&leaves);
            for (leaves[0..lc]) |leaf| {
                var pane_name_buf: [256]u8 = undefined;
                const pane_title = resolveTitle(leaf.pane, &pane_name_buf);
                const focused = (leaf.index == layout.focused);
                w.print("  {d}\t{s}", .{ leaf.pane.ipc_id, pane_title }) catch break;
                if (focused) w.writeAll("\t*") catch break;
                w.print("\t{d}x{d}", .{ leaf.rect.cols, leaf.rect.rows }) catch break;
                w.writeAll("\n") catch break;
            }
        }
    }

    sendOk(cmd, stream.getWritten());
}

pub fn buildTabList(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
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

pub fn buildSplitList(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();

    const mgr = ctx.tab_mgr;
    const layout = &(mgr.tabs[mgr.active] orelse {
        sendOk(cmd, "");
        return;
    });

    var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
    const lc = layout.collectLeaves(&leaves);
    for (leaves[0..lc]) |leaf| {
        var name_buf: [256]u8 = undefined;
        const title = resolveTitle(leaf.pane, &name_buf);
        const focused = (leaf.index == layout.focused);

        w.print("{d}\t{s}", .{ leaf.pane.ipc_id, title }) catch break;
        if (focused) w.writeAll("\t*") catch break;
        w.print("\t{d}x{d}", .{ leaf.rect.cols, leaf.rect.rows }) catch break;
        w.writeAll("\n") catch break;
    }

    sendOk(cmd, stream.getWritten());
}

pub fn buildGetText(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
    const pane = ctx.tab_mgr.activePane();
    writeScreenText(cmd, pane);
}

pub fn buildGetTextPane(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
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
}

fn writeScreenText(cmd: *queue.IpcCommand, pane: anytype) void {
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

pub fn handleSessionList(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
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

pub fn handleSessionCreate(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
    const sc = ctx.session_client orelse {
        sendError(cmd, "sessions not enabled");
        return;
    };
    // Payload: [flags:u8][cwd_len:u16 LE][cwd...][name...]
    // flags bit 0 = background
    const background = cmd.payload_len > 0 and (cmd.payload[0] & 0x01) != 0;
    var cwd: []const u8 = "";
    var name: []const u8 = "new";
    if (cmd.payload_len >= 3) {
        const cwd_len = std.mem.readInt(u16, cmd.payload[1..3], .little);
        const cwd_end = @min(@as(usize, 3) + cwd_len, cmd.payload_len);
        cwd = cmd.payload[3..cwd_end];
        if (cwd_end < cmd.payload_len) {
            name = cmd.payload[cwd_end..cmd.payload_len];
        }
    }
    if (name.len == 0) {
        if (cwd.len > 0) {
            // Derive name from last path component: ~/Projects/glyph → "glyph"
            const trimmed = std.mem.trimRight(u8, cwd, "/");
            if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |i| {
                name = trimmed[i + 1 ..];
            } else {
                name = trimmed;
            }
        }
        if (name.len == 0) name = "new";
    }
    const rows = ctx.grid_rows;
    const cols = ctx.grid_cols;
    const sid = sc.createSession(name, rows, cols, cwd, "") catch {
        sendError(cmd, "failed to create session");
        return;
    };

    // By default, switch to the new session (unless --background)
    if (!background) {
        sc.attach(sid, rows, cols) catch {
            // Session was created but attach failed — report success with the ID anyway
        };
    }

    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    stream.writer().print("{d}", .{sid}) catch {};
    sendOk(cmd, stream.getWritten());
}

pub fn handleSessionKill(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
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

pub fn handleSessionSwitch(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
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

pub fn handleSessionRename(cmd: *queue.IpcCommand, ctx: *PtyThreadCtx) void {
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
