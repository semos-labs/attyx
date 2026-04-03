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
/// Dispatches by event type: ipc_ready, cwd_changed, etc.
pub fn handleXyronEvent(self: *TerminalState, json: []const u8) void {
    // ipc_ready: extract socket path
    if (std.mem.indexOf(u8, json, "\"ipc_ready\"") != null) {
        if (extractJsonStr(json, "socket")) |path| {
            const alloc = self.ring.allocator;
            if (self.xyron_ipc_socket) |old| alloc.free(old);
            self.xyron_ipc_socket = alloc.dupe(u8, path) catch null;
        }
        return;
    }
    // cwd_changed: update working directory
    if (std.mem.indexOf(u8, json, "\"cwd_changed\"") != null) {
        if (extractJsonStr(json, "new_cwd")) |cwd| {
            // Convert to file:// URI for statusbar compatibility
            var uri_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
            const uri = std.fmt.bufPrint(&uri_buf, "file://localhost{s}", .{cwd}) catch return;
            self.setCwd(uri);
        }
        return;
    }
}

/// Extract a string value from JSON by key. Minimal parser — no escapes.
fn extractJsonStr(json: []const u8, key: []const u8) ?[]const u8 {
    // Look for "key":"value"
    var buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":\"", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, json, needle) orelse return null;
    const start = idx + needle.len;
    if (start >= json.len) return null;
    const end = std.mem.indexOfScalar(u8, json[start..], '"') orelse return null;
    const val = json[start..][0..end];
    if (val.len == 0) return null;
    return val;
}
