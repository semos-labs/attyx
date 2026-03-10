// Attyx — IPC client
//
// Discovers a running Attyx instance's control socket, connects, sends a
// request, reads a response, and prints it to stdout. Used by CLI subcommands
// like `attyx tab create`, `attyx focus left`, etc.

const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol.zig");
const session_connect = @import("../app/session_connect.zig");

const max_response = 65536;

pub const ClientError = error{
    NoInstance,
    ConnectionRefused,
    SocketError,
    ResponseTooLarge,
    InvalidResponse,
};

/// Discover the control socket path for a running instance.
/// Globs ~/.local/state/attyx/ctl-*.sock and picks the most recent.
/// If `target_pid` is set, use that specific PID.
pub fn discoverSocket(buf: *[256]u8, target_pid: ?u32) ?[]const u8 {
    if (target_pid) |pid| {
        return formatSocketPath(buf, pid);
    }
    // Check ATTYX_PID env var (set automatically inside Attyx panes)
    if (std.posix.getenv("ATTYX_PID")) |pid_str| {
        if (std.fmt.parseInt(u32, pid_str, 10)) |pid| {
            return formatSocketPath(buf, pid);
        } else |_| {}
    }
    // Scan state dir for ctl-*.sock files
    const suffix = if (comptime @import("builtin").mode == .Debug) "-dev" else "";
    var dir_buf: [256]u8 = undefined;
    const dir_path = session_connect.stateDir(&dir_buf) orelse return null;

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return null;
    defer dir.close();

    var best_pid: ?u32 = null;
    var best_mtime: i128 = 0;

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        const name = entry.name;
        // Match ctl-<pid>.sock or ctl-<pid>-dev.sock
        if (!std.mem.startsWith(u8, name, "ctl-")) continue;
        const rest = name[4..];
        // Find the dash before suffix or dot before .sock
        const end = if (suffix.len > 0)
            std.mem.indexOf(u8, rest, suffix) orelse continue
        else
            std.mem.indexOf(u8, rest, ".sock") orelse continue;
        const pid_str = rest[0..end];
        const pid = std.fmt.parseInt(u32, pid_str, 10) catch continue;
        // Check suffix matches
        const after_pid = rest[end..];
        var expected_suffix_buf: [64]u8 = undefined;
        const expected_suffix = std.fmt.bufPrint(&expected_suffix_buf, "{s}.sock", .{suffix}) catch continue;
        if (!std.mem.eql(u8, after_pid, expected_suffix)) continue;

        // Get mtime to pick most recent
        const stat = dir.statFile(name) catch continue;
        const mtime = stat.mtime;
        if (best_pid == null or mtime > best_mtime) {
            best_pid = pid;
            best_mtime = mtime;
        }
    }

    if (best_pid) |pid| {
        return formatSocketPath(buf, pid);
    }
    return null;
}

fn formatSocketPath(buf: *[256]u8, pid: u32) ?[]const u8 {
    const suffix = if (comptime @import("builtin").mode == .Debug) "-dev" else "";
    var dir_buf: [256]u8 = undefined;
    const dir = session_connect.stateDir(&dir_buf) orelse return null;
    return std.fmt.bufPrint(buf, "{s}ctl-{d}{s}.sock", .{ dir, pid, suffix }) catch null;
}

/// Connect to the control socket, send a request, read response, return payload.
/// The response is written into `response_buf`. Returns the response slice (type + payload).
pub fn sendCommand(
    socket_path: []const u8,
    request: []const u8,
    response_buf: []u8,
) !struct { msg_type: protocol.MessageType, payload: []const u8 } {
    // Connect
    const fd = try connectUnix(socket_path);
    defer posix.close(fd);

    // Send request
    protocol.writeAll(fd, request) catch return error.SocketError;

    // Read response header
    var hdr: [protocol.header_size]u8 = undefined;
    protocol.readExact(fd, &hdr) catch return error.InvalidResponse;
    const h = protocol.decodeHeader(&hdr) catch return error.InvalidResponse;

    if (h.payload_len > response_buf.len) return error.ResponseTooLarge;

    // Read payload
    if (h.payload_len > 0) {
        protocol.readExact(fd, response_buf[0..h.payload_len]) catch return error.InvalidResponse;
    }

    return .{
        .msg_type = h.msg_type,
        .payload = response_buf[0..h.payload_len],
    };
}

fn connectUnix(path: []const u8) !posix.fd_t {
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);

    const addr = std.net.Address.initUnix(path) catch return error.NameTooLong;

    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch |err| switch (err) {
        error.ConnectionRefused => {
            // Connection refused — do not unlink the socket here to avoid
            // accidentally deleting a live instance's control socket during
            // transient failures (startup race, backlog, etc.).
            return error.ConnectionRefused;
        },
        else => return err,
    };

    return fd;
}

/// Run the IPC client: discover socket, send command, print response.
/// Called from main.zig for IPC subcommands.
pub fn run(args: []const [:0]const u8) void {
    const cli_ipc = @import("../config/cli_ipc.zig");
    const parsed = cli_ipc.parse(args) orelse {
        // parse() already printed usage/error
        std.process.exit(1);
    };

    // Build the request message
    var req_buf: [protocol.header_size + 4096]u8 = undefined;
    const request = buildRequest(&req_buf, parsed) catch {
        writeStderr("error: failed to build request\n");
        std.process.exit(1);
    };

    // Discover socket
    var sock_buf: [256]u8 = undefined;
    const socket_path = discoverSocket(&sock_buf, parsed.target_pid) orelse {
        writeStderr("error: no running Attyx instance found\n");
        std.process.exit(1);
    };

    // Send and receive
    var resp_buf: [max_response]u8 = undefined;
    const resp = sendCommand(socket_path, request, &resp_buf) catch |err| {
        switch (err) {
            error.ConnectionRefused => writeStderr("error: no running Attyx instance found\n"),
            else => writeStderr("error: failed to communicate with Attyx instance\n"),
        }
        std.process.exit(1);
    };

    // Print response
    const stdout = std.fs.File.stdout();
    switch (resp.msg_type) {
        .success => {
            if (resp.payload.len > 0) {
                if (parsed.json_output) {
                    // JSON mode: pass through raw payload
                    stdout.writeAll(resp.payload) catch {};
                    stdout.writeAll("\n") catch {};
                } else {
                    // Plain text mode: payload is already plain text from handler
                    stdout.writeAll(resp.payload) catch {};
                    // Add newline if payload doesn't end with one
                    if (resp.payload[resp.payload.len - 1] != '\n') {
                        stdout.writeAll("\n") catch {};
                    }
                }
            }
        },
        .err => {
            if (parsed.json_output) {
                // JSON error format — escape payload for valid JSON string
                const stderr = std.fs.File.stderr();
                stderr.writeAll("{\"error\":\"") catch {};
                writeJsonEscaped(stderr, resp.payload);
                stderr.writeAll("\"}\n") catch {};
            } else {
                writeStderr("error: ");
                std.fs.File.stderr().writeAll(resp.payload) catch {};
                std.fs.File.stderr().writeAll("\n") catch {};
            }
            std.process.exit(1);
        },
        else => {
            writeStderr("error: unexpected response type\n");
            std.process.exit(1);
        },
    }
}

fn buildRequest(buf: []u8, parsed: @import("../config/cli_ipc.zig").IpcRequest) ![]u8 {
    return switch (parsed.command) {
        .tab_create => protocol.encodeMessage(buf, .tab_create, parsed.text_arg),
        .tab_close => protocol.encodeMessage(buf, .tab_close, ""),
        .tab_next => protocol.encodeMessage(buf, .tab_next, ""),
        .tab_prev => protocol.encodeMessage(buf, .tab_prev, ""),
        .tab_select => protocol.encodeMessage(buf, .tab_select, &.{parsed.index_arg}),
        .tab_move_left => protocol.encodeMessage(buf, .tab_move_left, ""),
        .tab_move_right => protocol.encodeMessage(buf, .tab_move_right, ""),
        .tab_rename => protocol.encodeMessage(buf, .tab_rename, parsed.text_arg),
        .split_vertical => protocol.encodeMessage(buf, .split_vertical, parsed.text_arg),
        .split_horizontal => protocol.encodeMessage(buf, .split_horizontal, parsed.text_arg),
        .split_close => protocol.encodeMessage(buf, .pane_close, ""),
        .split_rotate => protocol.encodeMessage(buf, .pane_rotate, ""),
        .split_zoom => protocol.encodeMessage(buf, .pane_zoom_toggle, ""),
        .focus_up => protocol.encodeMessage(buf, .focus_up, ""),
        .focus_down => protocol.encodeMessage(buf, .focus_down, ""),
        .focus_left => protocol.encodeMessage(buf, .focus_left, ""),
        .focus_right => protocol.encodeMessage(buf, .focus_right, ""),
        .send_keys => protocol.encodeMessage(buf, .send_keys, parsed.text_arg),
        .send_text => protocol.encodeMessage(buf, .send_text, parsed.text_arg),
        .get_text => protocol.encodeMessage(buf, .get_text, ""),
        .config_reload => protocol.encodeMessage(buf, .config_reload, ""),
        .theme_set => protocol.encodeMessage(buf, .theme_set, parsed.text_arg),
        .scroll_to_top => protocol.encodeMessage(buf, .scroll_to_top, ""),
        .scroll_to_bottom => protocol.encodeMessage(buf, .scroll_to_bottom, ""),
        .scroll_page_up => protocol.encodeMessage(buf, .scroll_page_up, ""),
        .scroll_page_down => protocol.encodeMessage(buf, .scroll_page_down, ""),
        .list => protocol.encodeMessage(buf, .list, ""),
        .list_tabs => protocol.encodeMessage(buf, .list_tabs, ""),
        .list_splits => protocol.encodeMessage(buf, .list_splits, ""),
        .popup => blk: {
            // Payload: [width_pct:u8][height_pct:u8][border_style:u8][command...]
            // Clamp command to max_payload - 3 bytes for the option header
            const queue_mod = @import("queue.zig");
            const max_cmd = queue_mod.max_payload - 3;
            var payload_buf: [queue_mod.max_payload]u8 = undefined;
            payload_buf[0] = parsed.width_pct;
            payload_buf[1] = parsed.height_pct;
            payload_buf[2] = parsed.border_style;
            const cmd_len = @min(parsed.text_arg.len, max_cmd);
            @memcpy(payload_buf[3 .. 3 + cmd_len], parsed.text_arg[0..cmd_len]);
            break :blk protocol.encodeMessage(buf, .popup, payload_buf[0 .. 3 + cmd_len]);
        },
        .session_list => protocol.encodeMessage(buf, .session_list, ""),
        .session_create => protocol.encodeMessage(buf, .session_create, ""),
        .session_kill => blk: {
            var payload: [4]u8 = undefined;
            std.mem.writeInt(u32, &payload, parsed.session_id_arg, .little);
            break :blk protocol.encodeMessage(buf, .session_kill, &payload);
        },
        .session_switch => blk: {
            var payload: [4]u8 = undefined;
            std.mem.writeInt(u32, &payload, parsed.session_id_arg, .little);
            break :blk protocol.encodeMessage(buf, .session_switch, &payload);
        },
        .session_rename => protocol.encodeSessionRename(buf, parsed.session_id_arg, parsed.text_arg),
    };
}

fn writeStderr(msg: []const u8) void {
    std.fs.File.stderr().writeAll(msg) catch {};
}

/// Write a string with JSON escaping (quotes, backslashes, control chars).
fn writeJsonEscaped(file: std.fs.File, s: []const u8) void {
    for (s) |ch| {
        switch (ch) {
            '"' => file.writeAll("\\\"") catch return,
            '\\' => file.writeAll("\\\\") catch return,
            '\n' => file.writeAll("\\n") catch return,
            '\r' => file.writeAll("\\r") catch return,
            '\t' => file.writeAll("\\t") catch return,
            else => {
                if (ch < 0x20) {
                    var buf: [6]u8 = undefined;
                    _ = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch}) catch return;
                    file.writeAll(&buf) catch return;
                } else {
                    file.writeAll(&.{ch}) catch return;
                }
            },
        }
    }
}
