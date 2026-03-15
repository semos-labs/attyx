// Windows session manager.
//
// Each session wraps a TabManager with its own tabs and panes.
// Switching sessions swaps which TabManager is active in WinCtx.
// When a daemon SessionClient is available, new sessions are created
// through the daemon for persistence across process restarts.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const TabManager = @import("tab_manager.zig").TabManager;
const Pane = @import("pane.zig").Pane;
const publish = @import("ui/publish.zig");
const theme_registry_mod = @import("../theme/registry.zig");
const Theme = theme_registry_mod.Theme;
const logging = @import("../logging/log.zig");
const SessionClient = @import("session_client.zig").SessionClient;
const conn = @import("session_connect.zig");

pub const max_sessions = 32;

pub const WinSession = struct {
    id: u32,
    name: [64]u8 = .{0} ** 64,
    name_len: u8 = 0,
    tab_mgr: *TabManager,
    alive: bool = true,

    pub fn getName(self: *const WinSession) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn setName(self: *WinSession, new_name: []const u8) void {
        const len: u8 = @intCast(@min(new_name.len, 64));
        @memcpy(self.name[0..len], new_name[0..len]);
        self.name_len = len;
    }

    pub fn paneCount(self: *const WinSession) u8 {
        var total: u8 = 0;
        for (0..self.tab_mgr.count) |i| {
            if (self.tab_mgr.tabs[i]) |*layout| {
                total +|= layout.pane_count;
            }
        }
        return total;
    }
};

pub const WinSessionManager = struct {
    sessions: [max_sessions]?WinSession = .{null} ** max_sessions,
    count: u8 = 0,
    active: u8 = 0,
    next_id: u32 = 1,
    allocator: Allocator,
    scrollback_lines: u32 = 5000,
    session_client: ?*SessionClient = null,

    /// Initialize with an existing TabManager as session 1.
    pub fn init(allocator: Allocator, initial_tab_mgr: *TabManager, name: []const u8) WinSessionManager {
        var mgr = WinSessionManager{
            .allocator = allocator,
        };
        var session = WinSession{
            .id = mgr.next_id,
            .tab_mgr = initial_tab_mgr,
        };
        session.setName(if (name.len > 0) name else "default");
        mgr.sessions[0] = session;
        mgr.count = 1;
        mgr.next_id = 2;
        return mgr;
    }

    /// Get the active session.
    pub fn activeSession(self: *WinSessionManager) *WinSession {
        return &(self.sessions[self.active] orelse unreachable);
    }

    /// Get the active TabManager.
    pub fn activeTabMgr(self: *WinSessionManager) *TabManager {
        return self.activeSession().tab_mgr;
    }

    /// Create a new session. Routes through daemon when available.
    pub fn createSession(
        self: *WinSessionManager,
        name: []const u8,
        rows: u16,
        cols: u16,
        theme: *Theme,
        scrollback: u32,
    ) !u32 {
        // Find empty slot
        const slot = for (0..max_sessions) |i| {
            if (self.sessions[i] == null) break @as(u8, @intCast(i));
        } else return error.TooManySessions;

        // Spawn initial pane (always local — needed for Engine)
        const pane = try self.allocator.create(Pane);
        errdefer self.allocator.destroy(pane);
        pane.* = try Pane.spawn(self.allocator, rows, cols, null, null, scrollback);
        pane.engine.state.theme_colors = publish.themeToEngineColors(theme);

        // If daemon is available, create session there and get daemon pane ID
        if (self.session_client) |sc| {
            if (sc.createSession(name, rows, cols, "", "")) |daemon_sid| {
                sc.attach(daemon_sid, rows, cols) catch {};
                if (sc.waitForAttach(5000)) |resp| {
                    if (resp.pane_count > 0) pane.daemon_pane_id = resp.pane_ids[0];
                    conn.saveLastSession(daemon_sid);
                } else |_| {}
                // Send focus_panes so daemon streams output
                if (pane.daemon_pane_id) |dpid| {
                    sc.sendFocusPanes(&.{dpid}) catch {};
                }
            } else |err| {
                logging.warn("session", "daemon create failed, using local: {}", .{err});
            }
        }

        // Create TabManager
        const tab_mgr = try self.allocator.create(TabManager);
        errdefer self.allocator.destroy(tab_mgr);
        tab_mgr.* = TabManager.init(self.allocator, pane);

        const sid = self.next_id;
        var session = WinSession{
            .id = sid,
            .tab_mgr = tab_mgr,
        };
        session.setName(if (name.len > 0) name else "new");
        self.sessions[slot] = session;
        self.count += 1;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;

        logging.info("session", "created session {d} \"{s}\"", .{ sid, session.getName() });
        return sid;
    }

    /// Switch to a session by ID. Returns the slot index.
    pub fn switchTo(self: *WinSessionManager, sid: u32) !u8 {
        for (0..max_sessions) |i| {
            if (self.sessions[i]) |*s| {
                if (s.id == sid) {
                    self.active = @intCast(i);
                    // Attach daemon to the new session
                    if (self.session_client) |sc| {
                        const rows: u16 = @intCast(s.tab_mgr.activePane().engine.state.ring.screen_rows);
                        const cols: u16 = @intCast(s.tab_mgr.activePane().engine.state.ring.cols);
                        sc.attach(sid, rows, cols) catch {};
                        _ = sc.waitForAttach(2000) catch {};
                        conn.saveLastSession(sid);
                    }
                    logging.info("session", "switched to session {d} \"{s}\"", .{ sid, s.getName() });
                    return @intCast(i);
                }
            }
        }
        return error.SessionNotFound;
    }

    /// Kill a session by ID. Cannot kill the last session.
    pub fn kill(self: *WinSessionManager, sid: u32) !void {
        if (self.count <= 1) return error.CannotKillLastSession;

        for (0..max_sessions) |i| {
            if (self.sessions[i]) |*s| {
                if (s.id == sid) {
                    logging.info("session", "killing session {d} \"{s}\"", .{ sid, s.getName() });
                    // Kill daemon session if connected
                    if (self.session_client) |sc| sc.killSession(sid) catch {};
                    s.tab_mgr.deinit();
                    self.allocator.destroy(s.tab_mgr);
                    self.sessions[i] = null;
                    self.count -= 1;

                    // If we killed the active session, switch to the next available
                    if (self.active == @as(u8, @intCast(i))) {
                        self.active = self.findFirstAlive() orelse 0;
                    }
                    return;
                }
            }
        }
        return error.SessionNotFound;
    }

    /// Rename a session by ID.
    pub fn rename(self: *WinSessionManager, sid: u32, new_name: []const u8) !void {
        for (0..max_sessions) |i| {
            if (self.sessions[i]) |*s| {
                if (s.id == sid) {
                    s.setName(new_name);
                    // Rename daemon session if connected
                    if (self.session_client) |sc| sc.renameSession(sid, new_name) catch {};
                    logging.info("session", "renamed session {d} to \"{s}\"", .{ sid, s.getName() });
                    return;
                }
            }
        }
        return error.SessionNotFound;
    }

    /// Find first non-null session slot.
    fn findFirstAlive(self: *WinSessionManager) ?u8 {
        for (0..max_sessions) |i| {
            if (self.sessions[i] != null) return @intCast(i);
        }
        return null;
    }

    /// Get the currently active session ID.
    pub fn activeId(self: *WinSessionManager) u32 {
        return self.activeSession().id;
    }

    pub fn deinit(self: *WinSessionManager) void {
        for (0..max_sessions) |i| {
            if (self.sessions[i]) |*s| {
                s.tab_mgr.deinit();
                self.allocator.destroy(s.tab_mgr);
                self.sessions[i] = null;
            }
        }
    }
};

/// Derive a session name from the process's current working directory.
/// Returns the last path component (e.g. "C:\Users\nick\Projects\foo" → "foo").
pub fn cwdSessionName() ?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.process.getCwd(&buf) catch return null;
    const trimmed = std.mem.trimRight(u8, cwd, "/\\");
    if (trimmed.len == 0) return null;
    if (std.mem.lastIndexOfAny(u8, trimmed, "/\\")) |i| {
        const name = trimmed[i + 1 ..];
        return if (name.len > 0) name else null;
    }
    return trimmed;
}
