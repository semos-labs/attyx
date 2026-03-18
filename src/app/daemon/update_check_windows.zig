/// Windows auto-update checker.
///
/// Periodically fetches the appcast XML, finds the enclosure matching
/// os="windows" + current arch, compares versions, and downloads the
/// new binary to the staging path (upgrade.exe) for the hot upgrade
/// machinery to pick up.
const std = @import("std");
const builtin = @import("builtin");
const attyx = @import("attyx");
const session_connect = @import("../session_connect.zig");

const windows = std.os.windows;
const HANDLE = windows.HANDLE;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;

// ── WinHTTP API ──

const HINTERNET = *opaque {};
const WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY: DWORD = 4;
const WINHTTP_FLAG_SECURE: DWORD = 0x00800000;
const WINHTTP_NO_REFERER = null;
const WINHTTP_DEFAULT_ACCEPT_TYPES = null;

extern "winhttp" fn WinHttpOpen(
    pszAgent: ?[*:0]const u16,
    dwAccessType: DWORD,
    pszProxy: ?[*:0]const u16,
    pszProxyBypass: ?[*:0]const u16,
    dwFlags: DWORD,
) callconv(.winapi) ?HINTERNET;

extern "winhttp" fn WinHttpConnect(
    hSession: HINTERNET,
    pswzServerName: [*:0]const u16,
    nServerPort: u16,
    dwReserved: DWORD,
) callconv(.winapi) ?HINTERNET;

extern "winhttp" fn WinHttpOpenRequest(
    hConnect: HINTERNET,
    pwszVerb: ?[*:0]const u16,
    pwszObjectName: ?[*:0]const u16,
    pwszVersion: ?[*:0]const u16,
    pwszReferrer: ?[*:0]const u16,
    ppwszAcceptTypes: ?*const ?[*:0]const u16,
    dwFlags: DWORD,
) callconv(.winapi) ?HINTERNET;

extern "winhttp" fn WinHttpSendRequest(
    hRequest: HINTERNET,
    lpszHeaders: ?[*:0]const u16,
    dwHeadersLength: DWORD,
    lpOptional: ?*anyopaque,
    dwOptionalLength: DWORD,
    dwTotalLength: DWORD,
    dwContext: usize,
) callconv(.winapi) BOOL;

extern "winhttp" fn WinHttpReceiveResponse(
    hRequest: HINTERNET,
    lpReserved: ?*anyopaque,
) callconv(.winapi) BOOL;

extern "winhttp" fn WinHttpReadData(
    hRequest: HINTERNET,
    lpBuffer: [*]u8,
    dwNumberOfBytesToRead: DWORD,
    lpdwNumberOfBytesRead: *DWORD,
) callconv(.winapi) BOOL;

extern "winhttp" fn WinHttpCloseHandle(hInternet: HINTERNET) callconv(.winapi) BOOL;

// ── Public API ──

const appcast_host = "semos.sh";
const appcast_path = "/appcast.xml";
const target_os = "windows";
const target_arch = if (builtin.cpu.arch == .aarch64) "arm64" else "x86_64";

/// Check for updates and download if newer version available.
/// Called periodically from the daemon loop. Non-blocking — runs
/// synchronously but with WinHTTP timeouts.
pub fn checkAndDownload() void {
    // Fetch appcast XML.
    var xml_buf: [32768]u8 = undefined;
    const xml_len = fetchAppcast(&xml_buf) orelse return;
    const xml = xml_buf[0..xml_len];

    // Find matching enclosure.
    const match = findEnclosure(xml) orelse return;

    // Compare versions.
    if (!isNewer(match.version, attyx.version)) return;

    updateLog("new version available");

    // Download the binary to staging path.
    downloadToStaging(match.url) catch {
        updateLog("download failed");
    };
}

// ── Appcast parsing ──

const EnclosureMatch = struct {
    url: []const u8,
    version: []const u8,
};

/// Find the first <enclosure> with os="windows" and arch matching current.
fn findEnclosure(xml: []const u8) ?EnclosureMatch {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, xml, pos, "<enclosure")) |enc_start| {
        // Find closing: "/>" (self-closing) or ">" (open tag)
        const sc_end = std.mem.indexOfPos(u8, xml, enc_start, "/>");
        const gt_end = std.mem.indexOfPos(u8, xml, enc_start, ">");
        const enc_end = sc_end orelse gt_end orelse break;
        const tag_end = if (sc_end != null and sc_end.? == enc_end) enc_end + 2 else enc_end + 1;
        const tag = xml[enc_start..@min(tag_end, xml.len)];

        // Check os and arch attributes.
        if (findAttr(tag, "os")) |os| {
            if (!std.mem.eql(u8, os, target_os)) {
                pos = tag_end;
                continue;
            }
        }
        if (findAttr(tag, "arch")) |arch| {
            if (!std.mem.eql(u8, arch, target_arch)) {
                pos = tag_end;
                continue;
            }
        }

        // Extract url and version.
        const url = findAttr(tag, "url") orelse {
            pos = tag_end;
            continue;
        };
        const version = findAttr(tag, "sparkle:version") orelse
            findAttr(tag, "version") orelse {
            pos = tag_end;
            continue;
        };

        return .{ .url = url, .version = version };
    }
    return null;
}

/// Extract the value of an XML attribute from a tag string.
/// e.g. findAttr(`<enclosure url="https://..." os="windows">`, "os") => "windows"
fn findAttr(tag: []const u8, name: []const u8) ?[]const u8 {
    // Search for: name="value" or name='value'
    var search_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "{s}=\"", .{name}) catch return null;
    const attr_start = std.mem.indexOf(u8, tag, needle) orelse return null;
    const val_start = attr_start + needle.len;
    const val_end = std.mem.indexOfScalarPos(u8, tag, val_start, '"') orelse return null;
    return tag[val_start..val_end];
}

// ── Version comparison ──

/// Returns true if `remote` is newer than `local`.
/// Compares numeric major.minor.patch components.
fn isNewer(remote: []const u8, local: []const u8) bool {
    const r = parseVersion(remote);
    const l = parseVersion(local);
    if (r[0] != l[0]) return r[0] > l[0];
    if (r[1] != l[1]) return r[1] > l[1];
    return r[2] > l[2];
}

fn parseVersion(v: []const u8) [3]u32 {
    var result = [3]u32{ 0, 0, 0 };
    var part: usize = 0;
    for (v) |ch| {
        if (ch == '.') {
            part += 1;
            if (part >= 3) break;
        } else if (ch >= '0' and ch <= '9') {
            result[part] = result[part] * 10 + (ch - '0');
        } else if (ch == '-') break; // stop at -rc1, -beta, etc.
    }
    return result;
}

// ── HTTP ──

fn fetchAppcast(buf: *[32768]u8) ?usize {
    return httpGet(appcast_host, appcast_path, buf);
}

fn downloadToStaging(url: []const u8) !void {
    // Parse URL: https://host/path
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return error.InvalidUrl;
    const host_start = scheme_end + 3;
    const path_start = std.mem.indexOfScalarPos(u8, url, host_start, '/') orelse return error.InvalidUrl;
    const host = url[host_start..path_start];
    const path = url[path_start..];

    // Get staging path.
    var path_buf: [256]u8 = undefined;
    const staging = session_connect.statePath(&path_buf, "upgrade{s}.exe") orelse return error.NoStatePath;

    // Open tmp file.
    var tmp_buf: [260]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{staging}) catch return error.PathTooLong;
    const file = std.fs.createFileAbsolute(tmp_path, .{}) catch return error.CreateFileFailed;
    defer file.close();

    // Download via WinHTTP in chunks.
    const agent = comptime toUtf16("Attyx-Updater/1.0");
    const session = WinHttpOpen(&agent, WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, null, null, 0) orelse return error.WinHttpOpenFailed;
    defer _ = WinHttpCloseHandle(session);

    var host_wide: [256:0]u16 = undefined;
    const host_wlen = std.unicode.utf8ToUtf16Le(&host_wide, host) catch return error.EncodeFailed;
    host_wide[host_wlen] = 0;

    const conn = WinHttpConnect(session, host_wide[0..host_wlen :0], 443, 0) orelse return error.ConnectFailed;
    defer _ = WinHttpCloseHandle(conn);

    var path_wide: [2048:0]u16 = undefined;
    const path_wlen = std.unicode.utf8ToUtf16Le(&path_wide, path) catch return error.EncodeFailed;
    path_wide[path_wlen] = 0;

    const get = comptime toUtf16("GET");
    const req = WinHttpOpenRequest(conn, &get, path_wide[0..path_wlen :0], null, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE) orelse return error.RequestFailed;
    defer _ = WinHttpCloseHandle(req);

    if (WinHttpSendRequest(req, null, 0, null, 0, 0, 0) == 0) return error.SendFailed;
    if (WinHttpReceiveResponse(req, null) == 0) return error.ReceiveFailed;

    // Read response body to file.
    var chunk: [65536]u8 = undefined;
    while (true) {
        var bytes_read: DWORD = 0;
        if (WinHttpReadData(req, &chunk, chunk.len, &bytes_read) == 0) break;
        if (bytes_read == 0) break;
        file.writeAll(chunk[0..bytes_read]) catch return error.WriteFailed;
    }

    // Atomic move: tmp → staging.
    file.close();
    std.fs.renameAbsolute(tmp_path, staging) catch {
        std.fs.deleteFileAbsolute(tmp_path) catch {};
        return error.RenameFailed;
    };

    updateLog("update downloaded to staging");
}

fn httpGet(host: []const u8, path: []const u8, buf: *[32768]u8) ?usize {
    const agent = comptime toUtf16("Attyx-Updater/1.0");
    const session = WinHttpOpen(&agent, WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, null, null, 0) orelse return null;
    defer _ = WinHttpCloseHandle(session);

    var host_wide: [256:0]u16 = undefined;
    const host_wlen = std.unicode.utf8ToUtf16Le(&host_wide, host) catch return null;
    host_wide[host_wlen] = 0;

    const conn = WinHttpConnect(session, host_wide[0..host_wlen :0], 443, 0) orelse return null;
    defer _ = WinHttpCloseHandle(conn);

    var path_wide: [512:0]u16 = undefined;
    const path_wlen = std.unicode.utf8ToUtf16Le(&path_wide, path) catch return null;
    path_wide[path_wlen] = 0;

    const get = comptime toUtf16("GET");
    const req = WinHttpOpenRequest(conn, &get, path_wide[0..path_wlen :0], null, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE) orelse return null;
    defer _ = WinHttpCloseHandle(req);

    if (WinHttpSendRequest(req, null, 0, null, 0, 0, 0) == 0) return null;
    if (WinHttpReceiveResponse(req, null) == 0) return null;

    var total: usize = 0;
    while (total < buf.len) {
        var bytes_read: DWORD = 0;
        if (WinHttpReadData(req, buf[total..].ptr, @intCast(buf.len - total), &bytes_read) == 0) break;
        if (bytes_read == 0) break;
        total += bytes_read;
    }
    if (total == 0) return null;
    return total;
}

// ── Helpers ──

fn toUtf16(comptime s: []const u8) [s.len:0]u16 {
    comptime {
        var r: [s.len:0]u16 = undefined;
        for (s, 0..) |c, i| r[i] = c;
        return r;
    }
}

fn updateLog(msg: []const u8) void {
    var path_buf: [256]u8 = undefined;
    const path = session_connect.statePath(&path_buf, "daemon-debug{s}.log") orelse return;
    const file = std.fs.createFileAbsolute(path, .{ .truncate = false }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch {};
    file.writeAll("[update] ") catch {};
    file.writeAll(msg) catch {};
    file.writeAll("\n") catch {};
}

// ── Tests ──

test "parseVersion basic" {
    const v = parseVersion("1.2.3");
    try std.testing.expectEqual(@as(u32, 1), v[0]);
    try std.testing.expectEqual(@as(u32, 2), v[1]);
    try std.testing.expectEqual(@as(u32, 3), v[2]);
}

test "parseVersion with rc suffix" {
    const v = parseVersion("0.2.48-rc1");
    try std.testing.expectEqual(@as(u32, 0), v[0]);
    try std.testing.expectEqual(@as(u32, 2), v[1]);
    try std.testing.expectEqual(@as(u32, 48), v[2]);
}

test "isNewer" {
    try std.testing.expect(isNewer("0.2.48", "0.2.47"));
    try std.testing.expect(!isNewer("0.2.47", "0.2.47"));
    try std.testing.expect(!isNewer("0.2.46", "0.2.47"));
    try std.testing.expect(isNewer("1.0.0", "0.99.99"));
}

test "findAttr" {
    const tag = "<enclosure url=\"https://example.com/file.exe\" os=\"windows\" arch=\"arm64\" />";
    try std.testing.expectEqualStrings("windows", findAttr(tag, "os").?);
    try std.testing.expectEqualStrings("arm64", findAttr(tag, "arch").?);
    try std.testing.expectEqualStrings("https://example.com/file.exe", findAttr(tag, "url").?);
    try std.testing.expect(findAttr(tag, "missing") == null);
}

test "findEnclosure" {
    const xml =
        \\<item>
        \\  <enclosure url="https://mac.zip" os="macos" arch="arm64" sparkle:version="0.2.48" />
        \\  <enclosure url="https://win.exe" os="windows" arch="arm64" sparkle:version="0.2.48" />
        \\</item>
    ;
    if (comptime builtin.cpu.arch == .aarch64) {
        const m = findEnclosure(xml).?;
        try std.testing.expectEqualStrings("https://win.exe", m.url);
        try std.testing.expectEqualStrings("0.2.48", m.version);
    }
}
