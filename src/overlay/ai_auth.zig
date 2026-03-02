const std = @import("std");

// ---------------------------------------------------------------------------
// Token persistence
// ---------------------------------------------------------------------------

pub const TokenStore = struct {
    access_token: ?[]u8 = null,
    refresh_token: ?[]u8 = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TokenStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TokenStore) void {
        if (self.access_token) |t| self.allocator.free(t);
        if (self.refresh_token) |t| self.allocator.free(t);
        self.access_token = null;
        self.refresh_token = null;
    }

    pub fn hasAccessToken(self: *const TokenStore) bool {
        return self.access_token != null;
    }

    pub fn hasRefreshToken(self: *const TokenStore) bool {
        return self.refresh_token != null;
    }

    /// Replace stored tokens with new values. Takes ownership via duplication.
    pub fn update(self: *TokenStore, access: []const u8, refresh: []const u8) !void {
        const new_access = try self.allocator.dupe(u8, access);
        errdefer self.allocator.free(new_access);
        const new_refresh = try self.allocator.dupe(u8, refresh);

        if (self.access_token) |old| self.allocator.free(old);
        if (self.refresh_token) |old| self.allocator.free(old);
        self.access_token = new_access;
        self.refresh_token = new_refresh;
    }

    /// Load tokens from ~/.config/attyx/auth.json.
    pub fn load(allocator: std.mem.Allocator) !TokenStore {
        var store = TokenStore.init(allocator);
        errdefer store.deinit();

        const path = try authFilePath(allocator);
        defer allocator.free(path);

        const content = std.fs.cwd().readFileAlloc(allocator, path, 16_384) catch |err| switch (err) {
            error.FileNotFound => return store,
            else => return err,
        };
        defer allocator.free(content);

        // Minimal JSON parsing for {"access_token":"...","refresh_token":"..."}
        if (extractJsonString(content, "access_token")) |at| {
            store.access_token = try allocator.dupe(u8, at);
        }
        if (extractJsonString(content, "refresh_token")) |rt| {
            store.refresh_token = try allocator.dupe(u8, rt);
        }

        return store;
    }

    /// Save tokens to ~/.config/attyx/auth.json with 0600 permissions.
    pub fn save(self: *const TokenStore) !void {
        const path = try authFilePath(self.allocator);
        defer self.allocator.free(path);

        // Ensure directory exists
        const dir_end = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.InvalidPath;
        const dir_path = path[0..dir_end];
        std.fs.cwd().makePath(dir_path) catch {};

        var buf: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const w = stream.writer();

        w.writeAll("{") catch return error.BufferOverflow;
        if (self.access_token) |at| {
            w.writeAll("\"access_token\":\"") catch return error.BufferOverflow;
            w.writeAll(at) catch return error.BufferOverflow;
            w.writeAll("\"") catch return error.BufferOverflow;
            if (self.refresh_token != null) w.writeAll(",") catch return error.BufferOverflow;
        }
        if (self.refresh_token) |rt| {
            w.writeAll("\"refresh_token\":\"") catch return error.BufferOverflow;
            w.writeAll(rt) catch return error.BufferOverflow;
            w.writeAll("\"") catch return error.BufferOverflow;
        }
        w.writeAll("}\n") catch return error.BufferOverflow;

        const data = buf[0..stream.pos];
        const file = try std.fs.cwd().createFile(path, .{ .mode = 0o600 });
        defer file.close();
        try file.writeAll(data);
    }
};

fn authFilePath(allocator: std.mem.Allocator) ![]u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    const config_base = std.posix.getenv("XDG_CONFIG_HOME") orelse "";
    if (config_base.len > 0) {
        return std.fmt.allocPrint(allocator, "{s}/attyx/auth.json", .{config_base});
    }
    return std.fmt.allocPrint(allocator, "{s}/.config/attyx/auth.json", .{home});
}

// ---------------------------------------------------------------------------
// Auth status + thread
// ---------------------------------------------------------------------------

pub const AuthStatus = enum(u8) {
    idle = 0,
    refreshing = 1,
    device_starting = 2,
    device_show_code = 3,
    device_polling = 4,
    authenticated = 5,
    failed = 6,
};

pub const AuthThread = struct {
    status: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(AuthStatus.idle)),
    cancel: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    // Device code (written by auth thread, read by PTY thread)
    user_code: [10]u8 = .{0} ** 10,
    user_code_len: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    // Result tokens (written by auth thread, read by PTY thread)
    access_token_buf: [2048]u8 = undefined,
    access_token_len: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),
    refresh_token_buf: [256]u8 = undefined,
    refresh_token_len: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),

    // Error
    error_msg: [256]u8 = .{0} ** 256,
    error_msg_len: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),

    thread: ?std.Thread = null,

    pub fn init() AuthThread {
        return .{};
    }

    pub fn getStatus(self: *const AuthThread) AuthStatus {
        return @enumFromInt(self.status.load(.acquire));
    }

    pub fn getUserCode(self: *const AuthThread) []const u8 {
        const len = self.user_code_len.load(.acquire);
        return self.user_code[0..len];
    }

    pub fn getAccessToken(self: *const AuthThread) []const u8 {
        const len = self.access_token_len.load(.acquire);
        return self.access_token_buf[0..len];
    }

    pub fn getRefreshToken(self: *const AuthThread) []const u8 {
        const len = self.refresh_token_len.load(.acquire);
        return self.refresh_token_buf[0..len];
    }

    pub fn getErrorMsg(self: *const AuthThread) []const u8 {
        const len = self.error_msg_len.load(.acquire);
        return self.error_msg[0..len];
    }

    pub fn startAuth(self: *AuthThread, allocator: std.mem.Allocator, base_url: []const u8, refresh_token: ?[]const u8) !void {
        if (self.thread != null) return;
        self.cancel.store(0, .release);
        self.status.store(@intFromEnum(AuthStatus.idle), .release);
        self.error_msg_len.store(0, .release);
        self.access_token_len.store(0, .release);
        self.refresh_token_len.store(0, .release);
        self.user_code_len.store(0, .release);

        // Copy parameters for the thread
        const url_copy = try allocator.dupe(u8, base_url);
        const rt_copy: ?[]u8 = if (refresh_token) |rt| try allocator.dupe(u8, rt) else null;

        self.thread = try std.Thread.spawn(.{}, authWorker, .{ self, allocator, url_copy, rt_copy });
    }

    pub fn requestCancel(self: *AuthThread) void {
        self.cancel.store(1, .release);
    }

    pub fn tryJoin(self: *AuthThread) bool {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
            return true;
        }
        return false;
    }

    fn setStatus(self: *AuthThread, s: AuthStatus) void {
        self.status.store(@intFromEnum(s), .release);
    }

    fn setError(self: *AuthThread, msg: []const u8) void {
        const len: u16 = @intCast(@min(msg.len, self.error_msg.len));
        @memcpy(self.error_msg[0..len], msg[0..len]);
        self.error_msg_len.store(len, .release);
        self.setStatus(.failed);
    }

    fn isCanceled(self: *AuthThread) bool {
        return self.cancel.load(.acquire) != 0;
    }
};

fn authWorker(self: *AuthThread, allocator: std.mem.Allocator, base_url: []u8, refresh_token: ?[]u8) void {
    defer allocator.free(base_url);
    defer if (refresh_token) |rt| allocator.free(rt);

    // Step 1: Try refresh if we have a refresh token
    if (refresh_token) |rt| {
        if (self.isCanceled()) return;
        self.setStatus(.refreshing);

        if (doRefresh(allocator, base_url, rt)) |result| {
            defer allocator.free(result.access);
            defer allocator.free(result.refresh);
            writeTokenResult(self, result.access, result.refresh);
            self.setStatus(.authenticated);
            return;
        } else |_| {
            // Refresh failed, fall through to device flow
        }
    }

    if (self.isCanceled()) return;

    // Step 2: Device flow
    self.setStatus(.device_starting);

    var start_result = doDeviceStart(allocator, base_url) catch {
        self.setError("Failed to start device authorization");
        return;
    };
    defer allocator.free(start_result.device_code);
    if (start_result.verification_url) |v| allocator.free(v);

    // Write user_code to shared buffer
    const uc_len: u8 = @intCast(@min(start_result.user_code.len, 10));
    @memcpy(self.user_code[0..uc_len], start_result.user_code[0..uc_len]);
    self.user_code_len.store(uc_len, .release);
    allocator.free(start_result.user_code);
    self.setStatus(.device_show_code);

    if (self.isCanceled()) return;

    // Step 3: Poll loop
    self.setStatus(.device_polling);
    var attempts: u16 = 0;
    const max_attempts: u16 = 180; // 15min / 5s = 180

    while (attempts < max_attempts) : (attempts += 1) {
        if (self.isCanceled()) return;

        // Sleep 5 seconds (check cancel every 500ms)
        var sleep_count: u8 = 0;
        while (sleep_count < 10) : (sleep_count += 1) {
            if (self.isCanceled()) return;
            std.Thread.sleep(500_000_000); // 500ms
        }

        if (self.isCanceled()) return;

        const poll_result = doDevicePoll(allocator, base_url, start_result.device_code) catch |err| {
            if (err == error.DevicePending) continue;
            if (err == error.DeviceExpired) {
                self.setError("Device code expired");
                return;
            }
            if (err == error.RateLimited) {
                std.Thread.sleep(5_000_000_000);
                continue;
            }
            self.setError("Device poll failed");
            return;
        };
        defer allocator.free(poll_result.access);
        defer allocator.free(poll_result.refresh);

        writeTokenResult(self, poll_result.access, poll_result.refresh);
        self.setStatus(.authenticated);
        return;
    }

    self.setError("Device authorization timed out");
}

fn writeTokenResult(self: *AuthThread, access: []const u8, refresh: []const u8) void {
    const at_len: u16 = @intCast(@min(access.len, self.access_token_buf.len));
    @memcpy(self.access_token_buf[0..at_len], access[0..at_len]);
    self.access_token_len.store(at_len, .release);

    const rt_len: u16 = @intCast(@min(refresh.len, self.refresh_token_buf.len));
    @memcpy(self.refresh_token_buf[0..rt_len], refresh[0..rt_len]);
    self.refresh_token_len.store(rt_len, .release);
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

pub const TokenPair = struct { access: []u8, refresh: []u8 };
pub const DeviceStartResult = struct {
    device_code: []u8,
    user_code: []u8,
    verification_url: ?[]u8 = null,

    pub fn deinit(self: *DeviceStartResult, allocator: std.mem.Allocator) void {
        allocator.free(self.device_code);
        allocator.free(self.user_code);
        if (self.verification_url) |v| allocator.free(v);
    }
};

pub fn doRefresh(allocator: std.mem.Allocator, base_url: []const u8, refresh_token: []const u8) !TokenPair {
    var body_buf: [512]u8 = undefined;
    var body_stream = std.io.fixedBufferStream(&body_buf);
    const bw = body_stream.writer();
    bw.writeAll("{\"refresh_token\":\"") catch return error.BufferOverflow;
    bw.writeAll(refresh_token) catch return error.BufferOverflow;
    bw.writeAll("\"}") catch return error.BufferOverflow;

    const body = body_buf[0..body_stream.pos];

    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/v1/auth/refresh", .{base_url}) catch return error.BufferOverflow;

    const response = try httpPost(allocator, url, body, null);
    defer allocator.free(response.body);

    if (response.status != 200) {
        return error.RefreshFailed;
    }

    const access = try extractAndDupe(allocator, response.body, "access_token");
    errdefer allocator.free(access);
    const refresh = try extractAndDupe(allocator, response.body, "refresh_token");
    return .{ .access = access, .refresh = refresh };
}

pub fn doDeviceStart(allocator: std.mem.Allocator, base_url: []const u8) !DeviceStartResult {
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/v1/auth/device/start", .{base_url}) catch return error.BufferOverflow;

    const platform = comptime switch (@import("builtin").os.tag) {
        .macos => "darwin",
        .linux => "linux",
        else => "unknown",
    };
    const body = "{\"device_name\":\"attyx-terminal\",\"platform\":\"" ++ platform ++ "\"}";

    const response = try httpPost(allocator, url, body, null);
    defer allocator.free(response.body);

    if (response.status != 200) {
        logHttpError("auth/device/start", response.status, response.body);
        return error.DeviceStartFailed;
    }

    const device_code = try extractAndDupe(allocator, response.body, "device_code");
    errdefer allocator.free(device_code);
    const user_code = try extractAndDupe(allocator, response.body, "user_code");
    errdefer allocator.free(user_code);
    const verification_url = extractAndDupe(allocator, response.body, "verification_uri_complete") catch null;
    return .{ .device_code = device_code, .user_code = user_code, .verification_url = verification_url };
}

pub fn doDevicePoll(allocator: std.mem.Allocator, base_url: []const u8, device_code: []const u8) !TokenPair {
    var body_buf: [512]u8 = undefined;
    var body_stream = std.io.fixedBufferStream(&body_buf);
    const bw = body_stream.writer();
    bw.writeAll("{\"device_code\":\"") catch return error.BufferOverflow;
    bw.writeAll(device_code) catch return error.BufferOverflow;
    bw.writeAll("\"}") catch return error.BufferOverflow;

    const body = body_buf[0..body_stream.pos];

    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/v1/auth/device/poll", .{base_url}) catch return error.BufferOverflow;

    const response = try httpPost(allocator, url, body, null);
    defer allocator.free(response.body);

    if (response.status == 202) return error.DevicePending;
    if (response.status == 429) return error.RateLimited;
    if (response.status == 401 or response.status == 404) return error.DeviceExpired;
    if (response.status != 200) {
        logHttpError("auth/device/poll", response.status, response.body);
        return error.DevicePollFailed;
    }

    const access = try extractAndDupe(allocator, response.body, "access_token");
    errdefer allocator.free(access);
    const refresh = try extractAndDupe(allocator, response.body, "refresh_token");
    return .{ .access = access, .refresh = refresh };
}

fn logHttpError(endpoint: []const u8, status: u16, body: []const u8) void {
    const truncated = if (body.len > 512) body[0..512] else body;
    std.debug.print("{s}: HTTP {d}: {s}\n", .{ endpoint, status, truncated });
}

pub const HttpResponse = struct { status: u16, body: []u8 };

pub fn httpGet(allocator: std.mem.Allocator, url: []const u8, bearer: ?[]const u8) !HttpResponse {
    const uri = try std.Uri.parse(url);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var auth_buf: [2100]u8 = undefined;
    const auth_val: ?[]const u8 = if (bearer) |token| blk: {
        break :blk std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch null;
    } else null;

    var auth_header: [1]std.http.Header = undefined;
    const extra_headers: []const std.http.Header = if (auth_val) |av| blk: {
        auth_header[0] = .{ .name = "Authorization", .value = av };
        break :blk &auth_header;
    } else &.{};

    var req = try client.request(.GET, uri, .{
        .keep_alive = false,
        .extra_headers = extra_headers,
    });
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buf: [0]u8 = .{};
    var response = try req.receiveHead(&redirect_buf);
    const status: u16 = @intFromEnum(response.head.status);

    var transfer_buf: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    const resp_body = reader.allocRemaining(allocator, .limited(256_000)) catch |err| switch (err) {
        error.StreamTooLong => return error.ResponseTooLarge,
        error.ReadFailed => return error.ReadFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };

    return .{ .status = status, .body = resp_body };
}

fn httpPost(allocator: std.mem.Allocator, url: []const u8, body: []const u8, bearer: ?[]const u8) !HttpResponse {
    const uri = try std.Uri.parse(url);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Build auth header value on stack
    var auth_buf: [2100]u8 = undefined;
    const auth_val: ?[]const u8 = if (bearer) |token| blk: {
        break :blk std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch null;
    } else null;

    // Build extra headers
    var auth_header: [1]std.http.Header = undefined;
    const extra_headers: []const std.http.Header = if (auth_val) |av| blk: {
        auth_header[0] = .{ .name = "Authorization", .value = av };
        break :blk &auth_header;
    } else &.{};

    var req = try client.request(.POST, uri, .{
        .keep_alive = false,
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
        .extra_headers = extra_headers,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    var bw = try req.sendBodyUnflushed(&.{});
    try bw.writer.writeAll(body);
    try bw.end();
    try req.connection.?.flush();

    var redirect_buf: [0]u8 = .{};
    var response = try req.receiveHead(&redirect_buf);
    const status: u16 = @intFromEnum(response.head.status);

    // Read response body
    var transfer_buf: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    const resp_body = reader.allocRemaining(allocator, .limited(256_000)) catch |err| switch (err) {
        error.StreamTooLong => return error.ResponseTooLarge,
        error.ReadFailed => return error.ReadFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };

    return .{ .status = status, .body = resp_body };
}

// ---------------------------------------------------------------------------
// Minimal JSON field extraction
// ---------------------------------------------------------------------------

/// Extract a string value for a given key from JSON. Returns a slice into `json`.
pub fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Search for "key":" pattern
    var pos: usize = 0;
    while (pos + key.len + 4 < json.len) {
        if (json[pos] == '"') {
            const key_start = pos + 1;
            if (key_start + key.len < json.len and
                std.mem.eql(u8, json[key_start .. key_start + key.len], key) and
                json[key_start + key.len] == '"')
            {
                // Found the key, now find the value
                var vpos = key_start + key.len + 1;
                // Skip whitespace and colon
                while (vpos < json.len and (json[vpos] == ' ' or json[vpos] == ':')) vpos += 1;
                if (vpos < json.len and json[vpos] == '"') {
                    const val_start = vpos + 1;
                    var val_end = val_start;
                    while (val_end < json.len and json[val_end] != '"') {
                        if (json[val_end] == '\\') val_end += 1; // skip escaped char
                        val_end += 1;
                    }
                    return json[val_start..val_end];
                }
            }
        }
        pos += 1;
    }
    return null;
}

fn extractAndDupe(allocator: std.mem.Allocator, json: []const u8, key: []const u8) ![]u8 {
    const val = extractJsonString(json, key) orelse return error.MissingField;
    return allocator.dupe(u8, val);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "TokenStore: init and deinit" {
    var store = TokenStore.init(std.testing.allocator);
    defer store.deinit();
    try std.testing.expect(!store.hasAccessToken());
    try std.testing.expect(!store.hasRefreshToken());
}

test "TokenStore: update and read" {
    var store = TokenStore.init(std.testing.allocator);
    defer store.deinit();

    try store.update("access123", "refresh456");
    try std.testing.expect(store.hasAccessToken());
    try std.testing.expect(store.hasRefreshToken());
    try std.testing.expectEqualStrings("access123", store.access_token.?);
    try std.testing.expectEqualStrings("refresh456", store.refresh_token.?);

    // Update again — old values freed
    try store.update("new_access", "new_refresh");
    try std.testing.expectEqualStrings("new_access", store.access_token.?);
    try std.testing.expectEqualStrings("new_refresh", store.refresh_token.?);
}

test "extractJsonString: basic extraction" {
    const json = "{\"access_token\":\"abc123\",\"refresh_token\":\"def456\"}";
    try std.testing.expectEqualStrings("abc123", extractJsonString(json, "access_token").?);
    try std.testing.expectEqualStrings("def456", extractJsonString(json, "refresh_token").?);
    try std.testing.expect(extractJsonString(json, "missing") == null);
}

test "extractJsonString: with spaces" {
    const json = "{ \"access_token\" : \"tok123\" }";
    try std.testing.expectEqualStrings("tok123", extractJsonString(json, "access_token").?);
}

test "AuthThread: init state" {
    var auth = AuthThread.init();
    try std.testing.expectEqual(AuthStatus.idle, auth.getStatus());
    try std.testing.expectEqual(@as(usize, 0), auth.getUserCode().len);
    try std.testing.expectEqual(@as(usize, 0), auth.getAccessToken().len);
}

test "AuthThread: cancel flag" {
    var auth = AuthThread.init();
    try std.testing.expect(!auth.isCanceled());
    auth.requestCancel();
    try std.testing.expect(auth.isCanceled());
}
