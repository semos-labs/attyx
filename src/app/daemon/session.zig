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
    layout_data: [4096]u8 = undefined,
    layout_len: u16 = 0,
    alive: bool = true,

    /// Session working directory — used as default CWD for new panes.
    cwd: [1024]u8 = .{0} ** 1024,
    cwd_len: u16 = 0,

    /// Session shell program — used as default shell for new panes.
    shell: [256]u8 = .{0} ** 256,
    shell_len: u16 = 0,

    /// Backward-compat: the original "rows/cols" for the initial pane / session-level resize.
    rows: u16,
    cols: u16,

    /// Spawn a session with one initial pane. Pane ID is assigned by the caller
    /// (global counter) to ensure uniqueness across sessions.
    pub fn spawn(
        allocator: std.mem.Allocator,
        id: u32,
        name: []const u8,
        rows: u16,
        cols: u16,
        replay_capacity: usize,
        cwd: ?[*:0]const u8,
        initial_pane_id: u32,
        shell: ?[*:0]const u8,
    ) !DaemonSession {
        var session = DaemonSession{
            .id = id,
            .rows = rows,
            .cols = cols,
        };
        const nlen = @min(name.len, 64);
        @memcpy(session.name[0..nlen], name[0..nlen]);
        session.name_len = @intCast(nlen);

        // Store session CWD so new panes inherit it.
        if (cwd) |c| {
            const cwd_slice = std.mem.sliceTo(c, 0);
            const clen = @min(cwd_slice.len, 1024);
            @memcpy(session.cwd[0..clen], cwd_slice[0..clen]);
            session.cwd_len = @intCast(clen);
        }

        // Store session shell so new panes inherit it.
        if (shell) |s| {
            const shell_slice = std.mem.sliceTo(s, 0);
            const slen = @min(shell_slice.len, 256);
            @memcpy(session.shell[0..slen], shell_slice[0..slen]);
            session.shell_len = @intCast(slen);
        }

        // Defer the actual fork/exec until the client supplies real
        // window dims (via the first pane_resize). The shell's first
        // prompt then renders at the actual width — no 80-col-wrapped
        // grid getting shipped via grid-sync.
        session.panes[0] = try DaemonPane.spawnDeferred(allocator, initial_pane_id, rows, cols, replay_capacity, cwd, shell, null, false);
        session.pane_count = 1;
        return session;
    }

    /// Add a new pane with a caller-assigned ID (globally unique).
    /// Uses the provided CWD if given, otherwise falls back to session CWD.
    /// If cmd_override is set, spawns `$SHELL -c '<cmd>'` instead of the session shell.
    pub fn addPaneWithId(
        self: *DaemonSession,
        allocator: std.mem.Allocator,
        pane_id: u32,
        rows: u16,
        cols: u16,
        replay_capacity: usize,
        cwd_override: ?[*:0]const u8,
        shell_override: ?[*:0]const u8,
        cmd_override: ?[*:0]const u8,
        capture_stdout: bool,
    ) !u32 {
        const slot_idx = for (&self.panes, 0..) |*slot, i| {
            if (slot.* == null) break i;
        } else return error.TooManyPanes;
        const cwd: ?[*:0]const u8 = cwd_override orelse if (self.cwd_len > 0) @as([*:0]const u8, self.cwd[0..self.cwd_len :0]) else null;
        const shell: ?[*:0]const u8 = shell_override orelse if (self.shell_len > 0) @as([*:0]const u8, self.shell[0..self.shell_len :0]) else null;
        self.panes[slot_idx] = try DaemonPane.spawn(allocator, pane_id, rows, cols, replay_capacity, cwd, shell, cmd_override, capture_stdout);
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
        // Skip deferred panes: their first activation must happen via an
        // explicit pane_resize message carrying the real window dims, not
        // via attach-time defaults (which would re-introduce the cold-
        // launch wrap by spawning the shell at 80×24).
        if (pane.deferred != null) return;
        try pane.resize(rows, cols);
    }

    /// Check all panes for exit and return the first exit code found (if any).
    /// Marks session dead when all panes have exited.
    pub fn checkExit(self: *DaemonSession) ?u8 {
        var first_code: ?u8 = null;
        for (&self.panes) |*slot| {
            if (slot.*) |*p| {
                if (p.alive) {
                    if (p.checkExit()) |code| {
                        if (first_code == null) first_code = code;
                    }
                }
            }
        }
        if (first_code != null) {
            var any_alive = false;
            for (self.panes) |slot| {
                if (slot) |p| {
                    if (p.alive) { any_alive = true; break; }
                }
            }
            if (!any_alive) self.alive = false;
        }
        return first_code;
    }

    /// Kill all panes but preserve session metadata (name, layout, CWD).
    /// The session becomes a "recent" entry that can be revived on attach.
    pub fn killAllPanes(self: *DaemonSession) void {
        for (&self.panes) |*slot| {
            if (slot.*) |*p| {
                p.deinit();
                slot.* = null;
            }
        }
        self.pane_count = 0;
        self.alive = false;
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
