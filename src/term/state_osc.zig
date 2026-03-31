const std = @import("std");
const TerminalState = @import("state.zig").TerminalState;

pub fn startHyperlink(self: *TerminalState, uri: []const u8) void {
    if (uri.len == 0) {
        self.pen_link_id = 0;
        return;
    }
    const alloc = self.ring.allocator;
    const uri_copy = alloc.dupe(u8, uri) catch return;
    self.link_uris.append(alloc, uri_copy) catch {
        alloc.free(uri_copy);
        return;
    };
    self.pen_link_id = self.next_link_id;
    self.next_link_id += 1;
}

pub fn endHyperlink(self: *TerminalState) void {
    self.pen_link_id = 0;
}

pub fn setTitle(self: *TerminalState, title_slice: []const u8) void {
    const alloc = self.ring.allocator;
    // Detect whether the title actually changed before replacing.
    const changed = if (self.title) |old|
        old.len != title_slice.len or !std.mem.eql(u8, old, title_slice)
    else
        title_slice.len > 0;

    if (self.title) |old| alloc.free(old);
    if (title_slice.len == 0) {
        self.title = null;
    } else {
        self.title = alloc.dupe(u8, title_slice) catch null;
    }
    if (changed) self.title_changed = true;
}

pub fn setCwd(self: *TerminalState, uri: []const u8) void {
    const alloc = self.ring.allocator;
    if (self.working_directory) |old| alloc.free(old);
    if (uri.len == 0) {
        self.working_directory = null;
        return;
    }
    self.working_directory = alloc.dupe(u8, uri) catch null;
}

pub fn setShellPath(self: *TerminalState, path: []const u8) void {
    const alloc = self.ring.allocator;
    if (self.shell_path) |old| alloc.free(old);
    if (path.len == 0) {
        self.shell_path = null;
        return;
    }
    self.shell_path = alloc.dupe(u8, path) catch null;
}

/// Handle OSC 7339;xyron:{json} event.
/// Parses minimal JSON to extract socket path from ipc_ready events.
pub fn handleXyronEvent(self: *TerminalState, json: []const u8) void {
    // Extract "socket":"<path>" from the JSON payload.
    // Minimal parsing — no full JSON parser needed.
    const socket_key = "\"socket\":\"";
    const idx = std.mem.indexOf(u8, json, socket_key) orelse return;
    const path_start = idx + socket_key.len;
    if (path_start >= json.len) return;
    const path_end = std.mem.indexOfScalar(u8, json[path_start..], '"') orelse return;
    const path = json[path_start..][0..path_end];
    if (path.len == 0) return;

    const alloc = self.ring.allocator;
    if (self.xyron_ipc_socket) |old| alloc.free(old);
    self.xyron_ipc_socket = alloc.dupe(u8, path) catch null;
}
