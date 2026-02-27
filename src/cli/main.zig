const std = @import("std");
const build_options = @import("build_options");
const ai_auth = @import("ai_auth");

const base_url: []const u8 = if (std.mem.eql(u8, build_options.env, "production"))
    "https://app.semos.sh"
else
    "http://localhost:8085";

const usage =
    \\Usage: attyx <command>
    \\
    \\Commands:
    \\  login       Authenticate with Attyx AI services
    \\  device      Show device and account info
    \\
    \\Options:
    \\  --help, -h  Show this help message
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var iter = std.process.args();
    _ = iter.next(); // skip argv[0]

    const subcommand = iter.next();

    if (subcommand) |cmd| {
        if (std.mem.eql(u8, cmd, "login")) {
            doLogin(allocator) catch |err| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "error: login failed: {s}\n", .{@errorName(err)}) catch "error: login failed\n";
                std.fs.File.stderr().writeAll(msg) catch {};
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, cmd, "device")) {
            doDevice(allocator) catch |err| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "error: {s}\n", .{@errorName(err)}) catch "error: failed to get device info\n";
                std.fs.File.stderr().writeAll(msg) catch {};
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
            std.fs.File.stdout().writeAll(usage) catch {};
        } else {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "attyx: unknown command '{s}'\n\n", .{cmd}) catch "attyx: unknown command\n\n";
            std.fs.File.stderr().writeAll(msg) catch {};
            std.fs.File.stdout().writeAll(usage) catch {};
            std.process.exit(1);
        }
    } else {
        std.fs.File.stdout().writeAll(usage) catch {};
    }
}

fn doLogin(allocator: std.mem.Allocator) !void {
    const stdout = std.fs.File.stdout();

    stdout.writeAll("Connecting to " ++ base_url ++ "...\n") catch {};

    // Load existing tokens for refresh
    var store = ai_auth.TokenStore.load(allocator) catch ai_auth.TokenStore.init(allocator);
    defer store.deinit();

    // Try refresh first if we have a refresh token
    if (store.refresh_token) |rt| {
        stdout.writeAll("Refreshing authentication...\n") catch {};
        if (ai_auth.doRefresh(allocator, base_url, rt)) |result| {
            defer allocator.free(result.access);
            defer allocator.free(result.refresh);
            try store.update(result.access, result.refresh);
            try store.save();
            stdout.writeAll("Authenticated successfully.\n") catch {};
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

fn doDevice(allocator: std.mem.Allocator) !void {
    const stdout = std.fs.File.stdout();

    // Load tokens
    var store = ai_auth.TokenStore.load(allocator) catch ai_auth.TokenStore.init(allocator);
    defer store.deinit();

    const access_token = store.access_token orelse {
        stdout.writeAll("Not logged in. Run `attyx login` first.\n") catch {};
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
    const me_resp = ai_auth.httpGet(allocator, me_url, token) catch |err| {
        std.debug.print("failed to reach {s}/v1/me: {s}\n", .{ base_url, @errorName(err) });
        return err;
    };
    defer allocator.free(me_resp.body);

    if (me_resp.status == 401) {
        stdout.writeAll("Session expired. Run `attyx login` to re-authenticate.\n") catch {};
        return;
    }
    if (me_resp.status != 200) {
        std.debug.print("/v1/me: HTTP {d}: {s}\n", .{ me_resp.status, me_resp.body });
        return error.RequestFailed;
    }

    // GET /v1/sessions
    var sess_url_buf: [512]u8 = undefined;
    const sess_url = std.fmt.bufPrint(&sess_url_buf, "{s}/v1/sessions", .{base_url}) catch return error.BufferOverflow;
    const sess_resp = ai_auth.httpGet(allocator, sess_url, token) catch |err| {
        std.debug.print("failed to reach {s}/v1/sessions: {s}\n", .{ base_url, @errorName(err) });
        return err;
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

fn printField(stdout: std.fs.File, label: []const u8, value: []const u8) void {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}: {s}\n", .{ label, value }) catch return;
    stdout.writeAll(line) catch {};
}

/// Find the JSON object substring containing "is_current":true
fn findCurrentSession(json: []const u8) ?[]const u8 {
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
