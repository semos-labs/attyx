const std = @import("std");
const ai_auth = @import("attyx").overlay_ai_auth;

pub fn doLogin(allocator: std.mem.Allocator, base_url: []const u8) !void {
    const stdout = std.fs.File.stdout();

    // Load existing tokens for refresh
    var store = ai_auth.TokenStore.load(allocator) catch ai_auth.TokenStore.init(allocator);
    defer store.deinit();

    // Try refresh first if we have a refresh token
    if (store.refresh_token) |rt| {
        if (ai_auth.doRefresh(allocator, base_url, rt)) |result| {
            defer allocator.free(result.access);
            defer allocator.free(result.refresh);
            try store.update(result.access, result.refresh);
            try store.save();
            stdout.writeAll("Already authenticated.\n") catch {};
            return;
        } else |_| {
            // Refresh failed, fall through to device flow
        }
    }

    // Device authorization flow
    var start = try ai_auth.doDeviceStart(allocator, base_url);
    defer start.deinit(allocator);

    var msg_buf: [512]u8 = undefined;
    const verify_url = start.verification_url orelse base_url;
    const msg = std.fmt.bufPrint(&msg_buf,
        \\
        \\Open {s}
        \\Enter code: {s}
        \\
        \\Waiting for authorization...
    , .{ verify_url, start.user_code }) catch "Visit the website and enter your code\n";
    stdout.writeAll(msg) catch {};

    // Poll until authorized or timeout
    var attempts: u16 = 0;
    while (attempts < 180) : (attempts += 1) {
        std.Thread.sleep(5_000_000_000); // 5s

        const poll = ai_auth.doDevicePoll(allocator, base_url, start.device_code) catch |err| {
            if (err == error.DevicePending) {
                stdout.writeAll(".") catch {};
                continue;
            }
            if (err == error.RateLimited) {
                std.Thread.sleep(5_000_000_000);
                continue;
            }
            if (err == error.DeviceExpired) {
                stdout.writeAll("\nDevice code expired.\n") catch {};
                return err;
            }
            return err;
        };
        defer allocator.free(poll.access);
        defer allocator.free(poll.refresh);

        try store.update(poll.access, poll.refresh);
        try store.save();
        stdout.writeAll("\nAuthenticated successfully.\n") catch {};
        return;
    }

    stdout.writeAll("\nAuthorization timed out.\n") catch {};
    return error.DeviceExpired;
}

pub fn doDevice(allocator: std.mem.Allocator, base_url: []const u8) !void {
    const stdout = std.fs.File.stdout();

    // Load tokens
    var store = ai_auth.TokenStore.load(allocator) catch ai_auth.TokenStore.init(allocator);
    defer store.deinit();

    const access_token = store.access_token orelse {
        stdout.writeAll("Not authenticated. Run `attyx login` to sign in.\n") catch {};
        return;
    };

    // Try refresh if needed — access tokens are short-lived (15min)
    if (store.refresh_token) |rt| {
        if (ai_auth.doRefresh(allocator, base_url, rt)) |result| {
            defer allocator.free(result.access);
            defer allocator.free(result.refresh);
            store.update(result.access, result.refresh) catch {};
            store.save() catch {};
        } else |_| {}
    }

    // Re-read in case refresh updated it
    const token = store.access_token orelse access_token;

    // GET /v1/me
    var me_url_buf: [512]u8 = undefined;
    const me_url = std.fmt.bufPrint(&me_url_buf, "{s}/v1/me", .{base_url}) catch return error.BufferOverflow;
    const me_resp = ai_auth.httpGet(allocator, me_url, token) catch {
        stdout.writeAll("Could not reach server. Check your connection.\n") catch {};
        return;
    };
    defer allocator.free(me_resp.body);

    if (me_resp.status == 401) {
        stdout.writeAll("Session expired. Run `attyx login` to re-authenticate.\n") catch {};
        return;
    }
    if (me_resp.status != 200) {
        stdout.writeAll("Unexpected server error. Try again later.\n") catch {};
        return;
    }

    // GET /v1/sessions
    var sess_url_buf: [512]u8 = undefined;
    const sess_url = std.fmt.bufPrint(&sess_url_buf, "{s}/v1/sessions", .{base_url}) catch return error.BufferOverflow;
    const sess_resp = ai_auth.httpGet(allocator, sess_url, token) catch {
        stdout.writeAll("Could not reach server. Check your connection.\n") catch {};
        return;
    };
    defer allocator.free(sess_resp.body);

    // Parse /v1/me fields
    const email = ai_auth.extractJsonString(me_resp.body, "email") orelse "(unknown)";
    const plan = ai_auth.extractJsonString(me_resp.body, "plan_id") orelse "(none)";
    const sub_status = ai_auth.extractJsonString(me_resp.body, "subscription_status") orelse "(none)";

    // Print account info
    stdout.writeAll("\nAccount\n") catch {};
    printField(stdout, "  Email", email);
    printField(stdout, "  Plan", plan);
    printField(stdout, "  Status", sub_status);

    // Parse sessions — find current session
    if (sess_resp.status == 200) {
        stdout.writeAll("\nCurrent session\n") catch {};
        // Find the session with "is_current":true
        if (findCurrentSession(sess_resp.body)) |session| {
            const device_name = ai_auth.extractJsonString(session, "device_name") orelse "(unknown)";
            const platform = ai_auth.extractJsonString(session, "platform") orelse "(unknown)";
            const ip = ai_auth.extractJsonString(session, "ip_address") orelse "(unknown)";
            const created = ai_auth.extractJsonString(session, "created_at") orelse "(unknown)";
            const last_used = ai_auth.extractJsonString(session, "last_used_at") orelse "(unknown)";
            printField(stdout, "  Device", device_name);
            printField(stdout, "  Platform", platform);
            printField(stdout, "  IP", ip);
            printField(stdout, "  Created", created);
            printField(stdout, "  Last used", last_used);
        } else {
            stdout.writeAll("  (could not find current session)\n") catch {};
        }
    }

    stdout.writeAll("\n") catch {};
}

pub fn doKillDaemon() void {
    const stdout = std.fs.File.stdout();
    var path_buf: [256]u8 = undefined;
    const socket_path = getSocketPath(&path_buf) orelse {
        stdout.writeAll("error: HOME not set\n") catch {};
        return;
    };

    // Try to connect and get the daemon's PID
    const fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch {
        stdout.writeAll("No daemon running.\n") catch {};
        std.fs.deleteFileAbsolute(socket_path) catch {};
        return;
    };
    defer std.posix.close(fd);

    const addr = std.net.Address.initUnix(socket_path) catch {
        stdout.writeAll("No daemon running.\n") catch {};
        std.fs.deleteFileAbsolute(socket_path) catch {};
        return;
    };
    std.posix.connect(fd, &addr.any, addr.getOsSockLen()) catch {
        stdout.writeAll("No daemon running (stale socket removed).\n") catch {};
        std.fs.deleteFileAbsolute(socket_path) catch {};
        return;
    };

    // Get peer PID via platform-specific socket option
    const pid = getPeerPid(fd);
    if (pid) |p| {
        std.posix.kill(p, std.posix.SIG.TERM) catch {};
        // Wait briefly for daemon to exit and clean up
        std.posix.nanosleep(0, 100_000_000);
        stdout.writeAll("Daemon killed.\n") catch {};
    } else {
        stdout.writeAll("Connected but could not determine daemon PID.\n") catch {};
    }

    // Remove socket file (daemon's defer may have already done this)
    std.fs.deleteFileAbsolute(socket_path) catch {};
}

fn getPeerPid(fd: std.posix.fd_t) ?std.posix.pid_t {
    if (comptime @import("builtin").os.tag == .macos) {
        // macOS: SOL_LOCAL=0, LOCAL_PEERPID=2
        var pid: c_int = 0;
        var len: std.posix.socklen_t = @sizeOf(c_int);
        const rc = std.c.getsockopt(fd, 0, 2, @ptrCast(&pid), &len);
        if (rc == 0 and pid > 0) return @intCast(pid);
    } else if (comptime @import("builtin").os.tag == .linux) {
        // Linux: SOL_SOCKET=1, SO_PEERCRED=17
        const Ucred = extern struct { pid: c_int, uid: c_uint, gid: c_uint };
        var cred: Ucred = undefined;
        var len: std.posix.socklen_t = @sizeOf(Ucred);
        const rc = std.c.getsockopt(fd, 1, 17, @ptrCast(&cred), &len);
        if (rc == 0 and cred.pid > 0) return @intCast(cred.pid);
    }
    return null;
}

pub fn doUninstall() void {
    const stdout = std.fs.File.stdout();
    const home = std.posix.getenv("HOME") orelse {
        stdout.writeAll("error: HOME not set\n") catch {};
        return;
    };

    const targets = [_]struct { dir: []const u8, file: []const u8 }{
        .{ .dir = ".config/attyx", .file = "" },                                    // config + auth tokens
        .{ .dir = ".local/share/applications", .file = "attyx.desktop" },            // desktop entry
        .{ .dir = ".local/share/icons/hicolor/256x256/apps", .file = "attyx.png" },  // icon
    };

    for (targets) |t| {
        var path_buf: [512]u8 = undefined;
        if (t.file.len == 0) {
            // Remove entire directory
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, t.dir }) catch continue;
            std.fs.cwd().deleteTree(path) catch |err| {
                if (err != error.FileNotFound) {
                    var err_buf: [512]u8 = undefined;
                    const err_msg = std.fmt.bufPrint(&err_buf, "  warning: could not remove {s}: {s}\n", .{ path, @errorName(err) }) catch continue;
                    stdout.writeAll(err_msg) catch {};
                }
                continue;
            };
            var msg_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "  removed {s}\n", .{path}) catch continue;
            stdout.writeAll(msg) catch {};
        } else {
            // Remove single file
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}", .{ home, t.dir, t.file }) catch continue;
            std.fs.cwd().deleteFile(path) catch |err| {
                if (err != error.FileNotFound) {
                    var err_buf: [512]u8 = undefined;
                    const err_msg = std.fmt.bufPrint(&err_buf, "  warning: could not remove {s}: {s}\n", .{ path, @errorName(err) }) catch continue;
                    stdout.writeAll(err_msg) catch {};
                }
                continue;
            };
            var msg_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "  removed {s}\n", .{path}) catch continue;
            stdout.writeAll(msg) catch {};
        }
    }

    stdout.writeAll("\nAttyx data cleaned up. You can now run `brew uninstall attyx`.\n") catch {};
}

pub fn printField(stdout: std.fs.File, label: []const u8, value: []const u8) void {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}: {s}\n", .{ label, value }) catch return;
    stdout.writeAll(line) catch {};
}

// ── Socket path (must match session_connect.zig) ──

fn getSocketPath(buf: *[256]u8) ?[]const u8 {
    const suffix = if (comptime @import("builtin").mode == .Debug) "-dev" else "";
    if (std.posix.getenv("XDG_STATE_HOME")) |sh| {
        if (sh.len > 0)
            return std.fmt.bufPrint(buf, "{s}/attyx/sessions{s}.sock", .{ sh, suffix }) catch null;
    }
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/state/attyx/sessions{s}.sock", .{ home, suffix }) catch null;
}

/// Find the JSON object substring containing "is_current":true
pub fn findCurrentSession(json: []const u8) ?[]const u8 {
    // Find "is_current":true and work backwards to the enclosing {
    const marker = "\"is_current\":true";
    const alt_marker = "\"is_current\": true";
    const pos = std.mem.indexOf(u8, json, marker) orelse
        std.mem.indexOf(u8, json, alt_marker) orelse return null;

    // Walk backwards to find the opening { for this session object
    var depth: i32 = 0;
    var start = pos;
    while (start > 0) {
        start -= 1;
        if (json[start] == '}') depth += 1;
        if (json[start] == '{') {
            if (depth == 0) break;
            depth -= 1;
        }
    }

    // Walk forwards from pos to find the closing }
    var end = pos;
    depth = 0;
    while (end < json.len) {
        if (json[end] == '{') depth += 1;
        if (json[end] == '}') {
            depth -= 1;
            if (depth < 0) {
                return json[start .. end + 1];
            }
        }
        end += 1;
    }

    return null;
}
