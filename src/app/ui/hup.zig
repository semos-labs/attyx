const std = @import("std");
const posix = std.posix;

const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const c = terminal.c;
const publish = @import("publish.zig");
const actions = @import("actions.zig");
const Pane = @import("../pane.zig").Pane;

/// Handle POLLHUP on the active focused pane. Closes the pane (or tab)
/// and updates global routing pointers.
pub fn handleActiveHup(
    ctx: *PtyThreadCtx,
    fds: []posix.pollfd,
    fd_panes: []*Pane,
    nfds: usize,
    popup_fd_idx: usize,
) void {
    const focused = ctx.tab_mgr.activePane();
    for (0..nfds) |fi| {
        if (fi == popup_fd_idx) continue;
        if (fd_panes[fi] == focused and fds[fi].revents & 0x0010 != 0) {
            if (focused.childExited()) {
                const lay = ctx.tab_mgr.activeLayout();
                if (lay.pane_count <= 1) {
                    ctx.tab_mgr.closeTab(ctx.tab_mgr.active);
                    if (ctx.tab_mgr.count == 0) {
                        c.attyx_request_quit();
                        break;
                    }
                    publish.updateGridTopOffset(ctx);
                } else {
                    const result = lay.closePane(ctx.allocator);
                    if (result == .last_pane) {
                        ctx.tab_mgr.closeTab(ctx.tab_mgr.active);
                        if (ctx.tab_mgr.count == 0) {
                            c.attyx_request_quit();
                            break;
                        }
                        publish.updateGridTopOffset(ctx);
                    } else {
                        const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - terminal.g_grid_top_offset - terminal.g_grid_bottom_offset));
                        lay.layout(pty_rows, ctx.grid_cols);
                        actions.updateSplitActive(ctx);
                    }
                }
                actions.switchActiveTab(ctx);
            }
            break;
        }
    }
}
