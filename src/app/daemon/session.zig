const std = @import("std");
const posix = std.posix;
const Pty = @import("../pty.zig").Pty;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;
const DaemonPane = @import("pane.zig").DaemonPane;

pub const max_panes_per_session = 32;

/// A daemon-managed session containing one or more panes (each with its own PTY).
/// Stores a layout blob that the client uses to reconstruct tab/split structure.
pub const DaemonSession = struct {
    id: u32,
    name: [64]u8 = .{0} ** 64,
    name_len: u8 = 0,
    panes: [max_panes_per_session]?DaemonPane = .{null} ** max_panes_per_session,
    pane_count: u8 = 0,
    next_pane_id: u32 = 1,
    layout_data: [4096]u8 = undefined,
    layout_len: u16 = 0,
    alive: bool = true,

    /// Backward-compat: the original "rows/cols" for the initial pane / session-level resize.
    rows: u16,
    cols: u16,

    /// Spawn a session with one initial pane.
    pub fn spawn(
        allocator: std.mem.Allocator,
        id: u32,
        name: []const u8,
        rows: u16,
        cols: u16,
        replay_capacity: usize,
    ) !DaemonSession {
        var session = DaemonSession{
            .id = id,
            .rows = rows,
            .cols = cols,
        };
        const nlen = @min(name.len, 64);
        @memcpy(session.name[0..nlen], name[0..nlen]);
        session.name_len = @intCast(nlen);

        // Create initial pane (backward compat with V1 protocol)
        const pane_id = session.next_pane_id;
        session.next_pane_id += 1;
        session.panes[0] = try DaemonPane.spawn(allocator, pane_id, rows, cols, replay_capacity);
        session.pane_count = 1;
        return session;
    }

    /// Add a new pane to the session. Returns the new pane's ID.
    pub fn addPane(
        self: *DaemonSession,
        allocator: std.mem.Allocator,
        rows: u16,
        cols: u16,
        replay_capacity: usize,
    ) !u32 {
        const slot_idx = for (&self.panes, 0..) |*slot, i| {
            if (slot.* == null) break i;
        } else return error.TooManyPanes;

        const pane_id = self.next_pane_id;
        self.next_pane_id += 1;
        self.panes[slot_idx] = try DaemonPane.spawn(allocator, pane_id, rows, cols, replay_capacity);
        self.pane_count += 1;
        return pane_id;
    }

    /// Remove a pane by ID. Returns true if found and removed.
    pub fn removePane(self: *DaemonSession, pane_id: u32) bool {
        for (&self.panes) |*slot| {
            if (slot.*) |*p| {
                if (p.id == pane_id) {
                    p.deinit();
                    slot.* = null;
                    self.pane_count -= 1;
                    if (self.pane_count == 0) self.alive = false;
                    return true;
                }
            }
        }
        return false;
    }

    /// Find a pane by ID.
    pub fn findPane(self: *DaemonSession, pane_id: u32) ?*DaemonPane {
        for (&self.panes) |*slot| {
            if (slot.*) |*p| {
                if (p.id == pane_id) return p;
            }
        }
        return null;
    }

    /// Get the first pane (backward compat for V1 protocol).
    pub fn firstPane(self: *DaemonSession) ?*DaemonPane {
        for (&self.panes) |*slot| {
            if (slot.*) |*p| return p;
        }
        return null;
    }

    /// Collect all pane IDs into a buffer. Returns count.
    pub fn collectPaneIds(self: *const DaemonSession, out: *[max_panes_per_session]u32) u8 {
        var count: u8 = 0;
        for (self.panes) |slot| {
            if (slot) |p| {
                out[count] = p.id;
                count += 1;
            }
        }
        return count;
    }

    // Backward-compat delegators to first pane (used during V1→V2 transition)

    pub fn readPty(self: *DaemonSession, buf: []u8) !usize {
        const pane = self.firstPane() orelse return error.NoPanes;
        return pane.readPty(buf);
    }

    pub fn writeInput(self: *DaemonSession, bytes: []const u8) !void {
        const pane = self.firstPane() orelse return error.NoPanes;
        try pane.writeInput(bytes);
    }

    pub fn resize(self: *DaemonSession, rows: u16, cols: u16) !void {
        self.rows = rows;
        self.cols = cols;
        const pane = self.firstPane() orelse return error.NoPanes;
        try pane.resize(rows, cols);
    }

    pub fn checkExit(self: *DaemonSession) ?u8 {
        const pane = self.firstPane() orelse return null;
        const code = pane.checkExit();
        if (code != null) {
            // Check if ALL panes are dead
            var any_alive = false;
            for (self.panes) |slot| {
                if (slot) |p| {
                    if (p.alive) { any_alive = true; break; }
                }
            }
            if (!any_alive) self.alive = false;
        }
        return code;
    }

    pub fn getName(self: *const DaemonSession) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn deinit(self: *DaemonSession) void {
        for (&self.panes) |*slot| {
            if (slot.*) |*p| {
                p.deinit();
                slot.* = null;
            }
        }
        self.pane_count = 0;
        self.* = undefined;
    }
};
