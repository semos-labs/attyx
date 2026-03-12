// Attyx — IPC client
//
// Discovers a running Attyx instance's control socket, connects, sends a
// request, reads a response, and prints it to stdout. Used by CLI subcommands
// like `attyx tab create`, `attyx focus left`, etc.

const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol.zig");
const keys = @import("keys.zig");
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
/// Scans ~/.local/state/attyx/ for ctl-*.sock files, matching both
/// -dev and non-dev sockets so release CLI can talk to debug instances
/// and vice versa.
/// If `target_pid` is set, look for that specific PID's socket.
pub fn discoverSocket(buf: *[256]u8, target_pid: ?u32) ?[]const u8 {
    var dir_buf: [256]u8 = undefined;
    const dir_path = session_connect.stateDir(&dir_buf) orelse return null;

    // If a specific PID is requested (--target or ATTYX_PID), try both
    // suffixes for that PID — the instance could be debug or release.
    const pid_hint: ?u32 = target_pid orelse if (std.posix.getenv("ATTYX_PID")) |pid_str|
        std.fmt.parseInt(u32, pid_str, 10) catch null
    else
        null;

    if (pid_hint) |pid| {
        // Try -dev first, then plain — order doesn't matter, just need to find it.
        for ([_][]const u8{ "-dev", "" }) |sfx| {
            const path = std.fmt.bufPrint(buf, "{s}ctl-{d}{s}.sock", .{ dir_path, pid, sfx }) catch continue;
            // Verify the file exists before returning
            std.fs.accessAbsolute(path, .{}) catch continue;
            return path;
        }
    }

    // Scan state dir for ctl-*.sock files — match any suffix.
    // Pick the most recently modified socket.
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return null;
    defer dir.close();

    var best_name_buf: [128]u8 = undefined;
    var best_name_len: usize = 0;
    var best_mtime: i128 = 0;

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        const name = entry.name;
        if (!std.mem.startsWith(u8, name, "ctl-")) continue;
        if (!std.mem.endsWith(u8, name, ".sock")) continue;
        if (name.len > best_name_buf.len) continue;

        const stat = dir.statFile(name) catch continue;
        if (best_name_len == 0 or stat.mtime > best_mtime) {
            @memcpy(best_name_buf[0..name.len], name);
            best_name_len = name.len;
            best_mtime = stat.mtime;
        }
    }

    if (best_name_len > 0) {
        return std.fmt.bufPrint(buf, "{s}{s}", .{
            dir_path,
            best_name_buf[0..best_name_len],
        }) catch null;
    }
    return null;
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

    // Discover socket early — needed for both paths
    var sock_buf: [256]u8 = undefined;
    const socket_path = discoverSocket(&sock_buf, parsed.target_pid) orelse {
        writeStderr("error: no running Attyx instance found\n");
        std.process.exit(1);
    };

    // For send_keys: use token-based sending with inter-key delays
    if (parsed.command == .send_keys) {
        sendKeysTokenized(socket_path, parsed);
        return;
    }

    // Build the request message
    var req_buf: [protocol.header_size + 4096]u8 = undefined;
    var request = buildRequest(&req_buf, parsed) catch {
        writeStderr("error: failed to build request\n");
        std.process.exit(1);
    };

    // Wrap in session envelope if targeting a specific session
    var envelope_buf: [protocol.header_size + 5 + 4096]u8 = undefined;
    if (parsed.target_session != 0) {
        request = wrapSessionEnvelope(&envelope_buf, request, parsed.target_session) catch {
            writeStderr("error: failed to build session envelope\n");
            std.process.exit(1);
        };
    }

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
        .exit_code => {
            // --wait response: [exit_code:u8][captured_stdout...]
            const code: u8 = if (resp.payload.len > 0) resp.payload[0] else 1;
            if (resp.payload.len > 1) {
                stdout.writeAll(resp.payload[1..]) catch {};
            }
            std.process.exit(code);
        },
        else => {
            writeStderr("error: unexpected response type\n");
            std.process.exit(1);
        },
    }
}

/// Send keys using the token iterator. Inserts a 30ms pause after each named
/// key token to let the target TUI process the input and redraw. This prevents
/// race conditions like {Down}{Enter} selecting the wrong menu item.
fn sendKeysTokenized(socket_path: []const u8, parsed: @import("../config/cli_ipc.zig").IpcRequest) void {
    const inter_key_delay_ns: u64 = 30_000_000; // 30ms

    var iter = keys.KeyTokenIter{ .input = parsed.text_arg };
    var tok_buf: [4096]u8 = undefined;
    var sent_any = false;

    while (iter.next(&tok_buf)) |token| {
        const payload = tok_buf[0..token.len];

        // Build and send the IPC message for this token
        var req_buf: [protocol.header_size + 4200]u8 = undefined;
        const request = buildSendKeysRequest(&req_buf, payload, parsed.pane_id, parsed.target_session) catch continue;

        var resp_buf: [max_response]u8 = undefined;
        const resp = sendCommand(socket_path, request, &resp_buf) catch continue;
        if (resp.msg_type == .err) {
            writeStderr("error: ");
            std.fs.File.stderr().writeAll(resp.payload) catch {};
            std.fs.File.stderr().writeAll("\n") catch {};
            std.process.exit(1);
        }

        // Pause after named keys to let the TUI process and redraw
        if (token.is_named_key and sent_any) {
            // We delayed *before* this send via the previous iteration's delay,
            // but we also need to delay *after* this named key for the next token.
        }
        if (token.is_named_key) {
            std.posix.nanosleep(0, inter_key_delay_ns);
        }
        sent_any = true;
    }

    // Handle --wait-stable after all tokens sent
    if (parsed.wait_stable_ms > 0) {
        const stdout = std.fs.File.stdout();
        const stable_text = waitStable(
            socket_path,
            parsed.wait_stable_ms,
            parsed.pane_id,
            parsed.target_session,
        );
        if (stable_text.len > 0) {
            stdout.writeAll(stable_text) catch {};
            if (stable_text[stable_text.len - 1] != '\n') {
                stdout.writeAll("\n") catch {};
            }
        }
    }
}

/// Build a send_keys (or send_keys_pane) request for a single chunk of processed bytes.
fn buildSendKeysRequest(buf: []u8, payload: []const u8, pane_id: u32, target_session: u32) ![]u8 {
    var inner_buf: [protocol.header_size + 4200]u8 = undefined;
    const inner = if (pane_id != 0) blk: {
        var pane_payload: [4100]u8 = undefined;
        std.mem.writeInt(u32, pane_payload[0..4], pane_id, .little);
        const plen = @min(payload.len, pane_payload.len - 4);
        @memcpy(pane_payload[4 .. 4 + plen], payload[0..plen]);
        break :blk try protocol.encodeMessage(&inner_buf, .send_keys_pane, pane_payload[0 .. 4 + plen]);
    } else try protocol.encodeMessage(&inner_buf, .send_keys, payload);

    if (target_session != 0) {
        return wrapSessionEnvelope(buf, inner, target_session);
    }

    @memcpy(buf[0..inner.len], inner);
    return buf[0..inner.len];
}

fn buildRequest(buf: []u8, parsed: @import("../config/cli_ipc.zig").IpcRequest) ![]u8 {
    return switch (parsed.command) {
        .tab_create => protocol.encodeMessage(buf, if (parsed.wait) .tab_create_wait else .tab_create, parsed.text_arg),
        .tab_close => blk: {
            if (parsed.tab_idx != 0xFF) {
                break :blk protocol.encodeMessage(buf, .tab_close_targeted, &.{parsed.tab_idx});
            }
            break :blk protocol.encodeMessage(buf, .tab_close, "");
        },
        .tab_next => protocol.encodeMessage(buf, .tab_next, ""),
        .tab_prev => protocol.encodeMessage(buf, .tab_prev, ""),
        .tab_select => protocol.encodeMessage(buf, .tab_select, &.{parsed.index_arg}),
        .tab_move_left => protocol.encodeMessage(buf, .tab_move_left, ""),
        .tab_move_right => protocol.encodeMessage(buf, .tab_move_right, ""),
        .tab_rename => blk: {
            if (parsed.tab_idx != 0xFF) {
                var payload_buf: [258]u8 = undefined;
                payload_buf[0] = parsed.tab_idx;
                const nlen = @min(parsed.text_arg.len, payload_buf.len - 1);
                @memcpy(payload_buf[1 .. 1 + nlen], parsed.text_arg[0..nlen]);
                break :blk protocol.encodeMessage(buf, .tab_rename_targeted, payload_buf[0 .. 1 + nlen]);
            }
            break :blk protocol.encodeMessage(buf, .tab_rename, parsed.text_arg);
        },
        .split_vertical => protocol.encodeMessage(buf, if (parsed.wait) .split_vertical_wait else .split_vertical, parsed.text_arg),
        .split_horizontal => protocol.encodeMessage(buf, if (parsed.wait) .split_horizontal_wait else .split_horizontal, parsed.text_arg),
        .split_close => blk: {
            if (parsed.pane_id != 0) {
                var payload: [4]u8 = undefined;
                std.mem.writeInt(u32, &payload, parsed.pane_id, .little);
                break :blk protocol.encodeMessage(buf, .pane_close_targeted, &payload);
            }
            break :blk protocol.encodeMessage(buf, .pane_close, "");
        },
        .split_rotate => blk: {
            if (parsed.pane_id != 0) {
                var payload: [4]u8 = undefined;
                std.mem.writeInt(u32, &payload, parsed.pane_id, .little);
                break :blk protocol.encodeMessage(buf, .pane_rotate_targeted, &payload);
            }
            break :blk protocol.encodeMessage(buf, .pane_rotate, "");
        },
        .split_zoom => blk: {
            if (parsed.pane_id != 0) {
                var payload: [4]u8 = undefined;
                std.mem.writeInt(u32, &payload, parsed.pane_id, .little);
                break :blk protocol.encodeMessage(buf, .pane_zoom_targeted, &payload);
            }
            break :blk protocol.encodeMessage(buf, .pane_zoom_toggle, "");
        },
        .focus_up => protocol.encodeMessage(buf, .focus_up, ""),
        .focus_down => protocol.encodeMessage(buf, .focus_down, ""),
        .focus_left => protocol.encodeMessage(buf, .focus_left, ""),
        .focus_right => protocol.encodeMessage(buf, .focus_right, ""),
        .send_keys => blk: {
            // Process C-style escape sequences: \n \t \x03 \\ etc.
            var esc_buf: [4096]u8 = undefined;
            const processed = unescapeKeys(parsed.text_arg, &esc_buf);

            // Pane-targeted variant: prepend [pane_id:u32 LE] to payload
            if (parsed.pane_id != 0) {
                var payload_buf: [4100]u8 = undefined;
                std.mem.writeInt(u32, payload_buf[0..4], parsed.pane_id, .little);
                const plen = @min(processed.len, payload_buf.len - 4);
                @memcpy(payload_buf[4 .. 4 + plen], processed[0..plen]);
                break :blk protocol.encodeMessage(buf, .send_keys_pane, payload_buf[0 .. 4 + plen]);
            }

            break :blk protocol.encodeMessage(buf, .send_keys, processed);
        },
        .get_text => blk: {
            if (parsed.pane_id != 0) {
                var payload: [4]u8 = undefined;
                std.mem.writeInt(u32, &payload, parsed.pane_id, .little);
                break :blk protocol.encodeMessage(buf, .get_text_pane, &payload);
            }
            break :blk protocol.encodeMessage(buf, .get_text, "");
        },
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
        .session_create => blk: {
            // Payload: [flags:u8][cwd_len:u16 LE][cwd...][name...]
            // flags bit 0 = background (don't switch to new session)
            // Reserve 5 bytes for session envelope so total stays within max_payload.
            const queue_mod = @import("queue.zig");
            const header_overhead: usize = 3; // flags + cwd_len
            const envelope_overhead: usize = 5;
            const effective_max: usize = queue_mod.max_payload - envelope_overhead;
            var payload_buf: [queue_mod.max_payload]u8 = undefined;
            payload_buf[0] = if (parsed.background) 0x01 else 0x00;
            const max_cwd: usize = effective_max - header_overhead;
            const cwd_len: u16 = @intCast(@min(parsed.cwd_arg.len, max_cwd));
            std.mem.writeInt(u16, payload_buf[1..3], cwd_len, .little);
            @memcpy(payload_buf[3 .. 3 + cwd_len], parsed.cwd_arg[0..cwd_len]);
            const name_off: usize = header_overhead + cwd_len;
            const name_max: usize = if (effective_max > name_off) effective_max - name_off else 0;
            const name_len: usize = @min(parsed.text_arg.len, name_max);
            @memcpy(payload_buf[name_off .. name_off + name_len], parsed.text_arg[0..name_len]);
            break :blk protocol.encodeMessage(buf, .session_create, payload_buf[0 .. name_off + name_len]);
        },
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

/// Wrap an already-encoded IPC message in a session_envelope.
/// Extracts inner msg_type + payload and re-encodes as:
///   session_envelope([session_id:u32 LE][inner_msg_type:u8][inner_payload...])
fn wrapSessionEnvelope(buf: []u8, inner_msg: []const u8, session_id: u32) ![]u8 {
    if (inner_msg.len < protocol.header_size) return error.BufferTooSmall;
    const inner_type = inner_msg[4];
    const inner_payload = inner_msg[protocol.header_size..];
    const envelope_payload_len = 4 + 1 + inner_payload.len;
    if (buf.len < protocol.header_size + envelope_payload_len) return error.BufferTooSmall;

    protocol.encodeHeader(buf[0..protocol.header_size], .session_envelope, @intCast(envelope_payload_len));
    std.mem.writeInt(u32, buf[protocol.header_size..][0..4], session_id, .little);
    buf[protocol.header_size + 4] = inner_type;
    if (inner_payload.len > 0) {
        @memcpy(buf[protocol.header_size + 5 .. protocol.header_size + 5 + inner_payload.len], inner_payload);
    }
    return buf[0 .. protocol.header_size + envelope_payload_len];
}

/// Delegate to keys.zig for escape processing + named key resolution.
const unescapeKeys = keys.unescapeKeys;

/// Poll get-text until screen content stabilizes for `stable_ms` milliseconds.
/// Returns the final screen text. Hard timeout at 30 seconds.
fn waitStable(socket_path: []const u8, stable_ms: u32, pane_id: u32, target_session: u32) []const u8 {
    const poll_interval_ms: u64 = 50;
    const hard_timeout_ms: u64 = 30_000;
    var elapsed_ms: u64 = 0;
    var stable_since_ms: u64 = 0;
    var prev_hash: u64 = 0;
    var has_prev: bool = false;

    // Static buffers for get-text request and response
    var gt_req_buf: [protocol.header_size + 4096]u8 = undefined;
    var gt_resp_buf: [max_response]u8 = undefined;
    var last_payload: [max_response]u8 = undefined;
    var last_payload_len: usize = 0;

    // Build the get-text request once
    const gt_request = buildGetTextRequest(&gt_req_buf, pane_id, target_session) catch return "";

    while (elapsed_ms < hard_timeout_ms) {
        std.posix.nanosleep(0, @intCast(poll_interval_ms * 1_000_000));
        elapsed_ms += poll_interval_ms;

        const gt_resp = sendCommand(socket_path, gt_request, &gt_resp_buf) catch continue;
        if (gt_resp.msg_type != .success) continue;

        const hash = std.hash.Wyhash.hash(0, gt_resp.payload);

        if (has_prev and hash == prev_hash) {
            stable_since_ms += poll_interval_ms;
            if (stable_since_ms >= stable_ms) {
                // Content stable — return it
                @memcpy(last_payload[0..gt_resp.payload.len], gt_resp.payload);
                last_payload_len = gt_resp.payload.len;
                return last_payload[0..last_payload_len];
            }
        } else {
            stable_since_ms = 0;
            prev_hash = hash;
            has_prev = true;
        }

        // Always save last payload
        @memcpy(last_payload[0..gt_resp.payload.len], gt_resp.payload);
        last_payload_len = gt_resp.payload.len;
    }

    // Hard timeout — return what we have + warning
    writeStderr("warning: --wait-stable timed out after 30s\n");
    return last_payload[0..last_payload_len];
}

/// Build a get-text IPC request, optionally wrapped in a session envelope.
fn buildGetTextRequest(buf: []u8, pane_id: u32, target_session: u32) ![]u8 {
    var inner_buf: [protocol.header_size + 8]u8 = undefined;
    const inner = if (pane_id != 0) blk: {
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u32, &payload, pane_id, .little);
        break :blk try protocol.encodeMessage(&inner_buf, .get_text_pane, &payload);
    } else try protocol.encodeMessage(&inner_buf, .get_text, "");

    if (target_session != 0) {
        // Wrap in session envelope
        const inner_type = inner[4];
        const inner_payload = inner[protocol.header_size..];
        const envelope_payload_len = 4 + 1 + inner_payload.len;
        if (buf.len < protocol.header_size + envelope_payload_len) return error.BufferTooSmall;
        protocol.encodeHeader(buf[0..protocol.header_size], .session_envelope, @intCast(envelope_payload_len));
        std.mem.writeInt(u32, buf[protocol.header_size..][0..4], target_session, .little);
        buf[protocol.header_size + 4] = inner_type;
        if (inner_payload.len > 0) {
            @memcpy(buf[protocol.header_size + 5 .. protocol.header_size + 5 + inner_payload.len], inner_payload);
        }
        return buf[0 .. protocol.header_size + envelope_payload_len];
    }

    @memcpy(buf[0..inner.len], inner);
    return buf[0..inner.len];
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
