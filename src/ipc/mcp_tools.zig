// Attyx — MCP tool table
//
// One MCP tool per IPC command. `TOOLS_JSON` is the static `tools/list`
// payload (hand-written JSON schemas); `fill()` maps a tool name + its
// JSON arguments into an `IpcRequest` that client.buildRequest already knows
// how to encode. This is the single place that knows the tool surface.
//
// watch_agents is intentionally omitted: MCP tool calls are request/response,
// so streaming doesn't fit. Clients poll list_agents instead.
// ponytail: poll list_agents; add MCP notifications if push latency matters.

const std = @import("std");
const builtin = @import("builtin");
const cli_ipc = @import("../config/cli_ipc.zig");
const IpcRequest = cli_ipc.IpcRequest;

/// The complete `tools/list` result array. Static — the surface never changes
/// at runtime, so there's no reason to build it dynamically. Written one tool
/// per source line for readability, then flattened to a single line at comptime
/// (the MCP stdio transport is newline-delimited, so the payload must not
/// contain raw newlines — none of the schemas embed any).
const TOOLS_RAW =
    \\[
    \\{"name":"list","description":"List the full session/tab/pane tree of the running Attyx instance.","inputSchema":{"type":"object","properties":{"session":{"type":"integer","description":"Target session id (omit for current)."}}}},
    \\{"name":"list_tabs","description":"List tabs in the current (or targeted) session.","inputSchema":{"type":"object","properties":{"session":{"type":"integer"}}}},
    \\{"name":"list_panes","description":"List panes (splits) with their stable IPC ids.","inputSchema":{"type":"object","properties":{"session":{"type":"integer"}}}},
    \\{"name":"list_agents","description":"List AI agents running in panes with status and usage. Returns JSON: each agent has pane_id, tab_id, session, pid, state (idle|working|input), message, and a usage object with input_tokens, output_tokens, context_used, context_max (context window size), cost_usd, cost_is_estimate, and model. Unknown usage fields are omitted (absent = unknown, not zero).","inputSchema":{"type":"object","properties":{"pane":{"type":"integer","description":"Restrict to one pane id."},"session":{"type":"integer"}}}},
    \\{"name":"get_text","description":"Capture visible screen text of a pane. With 'lines', captures that many trailing rows from scrollback.","inputSchema":{"type":"object","properties":{"pane":{"type":"integer","description":"Pane id (omit for focused pane)."},"lines":{"type":"integer","description":"Trailing rows to capture (omit for visible screen)."},"session":{"type":"integer"}}}},
    \\{"name":"send_keys","description":"Send keystrokes/text to a pane. Supports C-style escapes (\\n, \\t, \\x03) and named keys like {Enter} {Down}.","inputSchema":{"type":"object","properties":{"text":{"type":"string"},"pane":{"type":"integer","description":"Pane id (omit for focused pane)."},"session":{"type":"integer"}},"required":["text"]}},
    \\{"name":"send_image","description":"Attach an image to a pane as if a file were dragged/pasted into the terminal (e.g. to give Claude Code a screenshot). Provide either 'path' (an image file already on disk) or 'data' (base64-encoded image bytes, materialized to a temp file). The image's file path is injected as a bracketed paste; Enter is NOT pressed.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"Absolute path to an image file on disk."},"data":{"type":"string","description":"Base64-encoded image bytes (used when no path is available)."},"filename":{"type":"string","description":"Optional original filename; its extension names the temp file when using 'data'."},"pane":{"type":"integer","description":"Pane id (omit for focused pane)."},"session":{"type":"integer"}}}},
    \\{"name":"focus","description":"Move keyboard focus between panes.","inputSchema":{"type":"object","properties":{"direction":{"type":"string","enum":["up","down","left","right"]},"session":{"type":"integer"}},"required":["direction"]}},
    \\{"name":"scroll","description":"Scroll the focused pane.","inputSchema":{"type":"object","properties":{"to":{"type":"string","enum":["top","bottom","page_up","page_down"]},"session":{"type":"integer"}},"required":["to"]}},
    \\{"name":"tab_create","description":"Open a new tab, optionally running a command. With wait=true, blocks until the command exits and returns its exit code + output.","inputSchema":{"type":"object","properties":{"command":{"type":"string"},"wait":{"type":"boolean"},"session":{"type":"integer"}}}},
    \\{"name":"tab_close","description":"Close a tab (1-based number) or the active tab if omitted.","inputSchema":{"type":"object","properties":{"tab":{"type":"integer","description":"1-based tab number."},"session":{"type":"integer"}}}},
    \\{"name":"tab_select","description":"Switch to a tab by 1-based index (1-9).","inputSchema":{"type":"object","properties":{"index":{"type":"integer","minimum":1,"maximum":9},"session":{"type":"integer"}},"required":["index"]}},
    \\{"name":"tab_switch","description":"Switch to the next or previous tab.","inputSchema":{"type":"object","properties":{"direction":{"type":"string","enum":["next","prev"]},"session":{"type":"integer"}},"required":["direction"]}},
    \\{"name":"tab_move","description":"Move the active tab left or right in the tab bar.","inputSchema":{"type":"object","properties":{"direction":{"type":"string","enum":["left","right"]},"session":{"type":"integer"}},"required":["direction"]}},
    \\{"name":"tab_rename","description":"Rename a tab (1-based number) or the active tab if omitted.","inputSchema":{"type":"object","properties":{"name":{"type":"string"},"tab":{"type":"integer"},"session":{"type":"integer"}},"required":["name"]}},
    \\{"name":"split","description":"Split the focused pane, optionally running a command. With wait=true, blocks until the command exits.","inputSchema":{"type":"object","properties":{"direction":{"type":"string","enum":["vertical","horizontal"]},"command":{"type":"string"},"wait":{"type":"boolean"},"session":{"type":"integer"}},"required":["direction"]}},
    \\{"name":"split_close","description":"Close a pane by id, or the focused pane if omitted.","inputSchema":{"type":"object","properties":{"pane":{"type":"integer"},"session":{"type":"integer"}}}},
    \\{"name":"split_rotate","description":"Rotate pane layout.","inputSchema":{"type":"object","properties":{"pane":{"type":"integer"},"session":{"type":"integer"}}}},
    \\{"name":"split_zoom","description":"Toggle zoom (maximize) for a pane.","inputSchema":{"type":"object","properties":{"pane":{"type":"integer"},"session":{"type":"integer"}}}},
    \\{"name":"theme_set","description":"Switch the active color theme by name.","inputSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}},
    \\{"name":"config_reload","description":"Reload the Attyx config from disk.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"popup","description":"Open a floating popup pane running a command.","inputSchema":{"type":"object","properties":{"command":{"type":"string"},"width":{"type":"integer","description":"Width percent 1-100."},"height":{"type":"integer","description":"Height percent 1-100."},"border":{"type":"string","enum":["single","double","rounded","heavy","none"]},"session":{"type":"integer"}},"required":["command"]}},
    \\{"name":"session_list","description":"List all sessions.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"session_create","description":"Create a session. With background=true it is created without switching to it.","inputSchema":{"type":"object","properties":{"name":{"type":"string"},"cwd":{"type":"string","description":"Working directory."},"background":{"type":"boolean"}}}},
    \\{"name":"session_kill","description":"Kill a session by id.","inputSchema":{"type":"object","properties":{"session_id":{"type":"integer"}},"required":["session_id"]}},
    \\{"name":"session_switch","description":"Switch the active window to a session by id.","inputSchema":{"type":"object","properties":{"session_id":{"type":"integer"}},"required":["session_id"]}},
    \\{"name":"session_rename","description":"Rename a session (id), or the current session if id omitted.","inputSchema":{"type":"object","properties":{"session_id":{"type":"integer"},"name":{"type":"string"}},"required":["name"]}}
    \\]
;

/// TOOLS_RAW with newlines stripped, so it's a single transport line.
pub const TOOLS_JSON = blk: {
    @setEvalBranchQuota(50000);
    var arr: [TOOLS_RAW.len]u8 = undefined;
    var n: usize = 0;
    for (TOOLS_RAW) |c| if (c != '\n') {
        arr[n] = c;
        n += 1;
    };
    const flat = arr[0..n].*;
    break :blk flat;
};

fn getStr(args: ?std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const a = args orelse return null;
    const v = a.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn getInt(args: ?std.json.ObjectMap, key: []const u8) ?i64 {
    const a = args orelse return null;
    const v = a.get(key) orelse return null;
    return if (v == .integer) v.integer else null;
}

fn getBool(args: ?std.json.ObjectMap, key: []const u8) bool {
    const a = args orelse return false;
    const v = a.get(key) orelse return false;
    return v == .bool and v.bool;
}

fn u32Of(args: ?std.json.ObjectMap, key: []const u8) u32 {
    const n = getInt(args, key) orelse return 0;
    return if (n < 0) 0 else @intCast(n);
}

/// Map a tool name + its JSON arguments object to an IpcRequest.
/// Returns null for an unknown tool or a missing required argument.
pub fn fill(name: []const u8, args: ?std.json.ObjectMap) ?IpcRequest {
    const eql = std.mem.eql;
    var r = IpcRequest{
        .command = undefined,
        .target_session = u32Of(args, "session"),
        .pane_id = u32Of(args, "pane"),
    };

    if (eql(u8, name, "list")) {
        r.command = .list;
    } else if (eql(u8, name, "list_tabs")) {
        r.command = .list_tabs;
    } else if (eql(u8, name, "list_panes")) {
        r.command = .list_splits;
    } else if (eql(u8, name, "list_agents")) {
        r.command = .list_agents;
        r.json_output = true;
    } else if (eql(u8, name, "get_text")) {
        r.command = .get_text;
        r.lines = u32Of(args, "lines");
    } else if (eql(u8, name, "send_keys")) {
        r.command = .send_keys;
        r.text_arg = getStr(args, "text") orelse return null;
    } else if (eql(u8, name, "focus")) {
        const d = getStr(args, "direction") orelse return null;
        r.command = if (eql(u8, d, "up")) .focus_up else if (eql(u8, d, "down")) .focus_down else if (eql(u8, d, "left")) .focus_left else if (eql(u8, d, "right")) .focus_right else return null;
    } else if (eql(u8, name, "scroll")) {
        const t = getStr(args, "to") orelse return null;
        r.command = if (eql(u8, t, "top")) .scroll_to_top else if (eql(u8, t, "bottom")) .scroll_to_bottom else if (eql(u8, t, "page_up")) .scroll_page_up else if (eql(u8, t, "page_down")) .scroll_page_down else return null;
    } else if (eql(u8, name, "tab_create")) {
        r.command = .tab_create;
        r.text_arg = getStr(args, "command") orelse "";
        r.wait = getBool(args, "wait");
    } else if (eql(u8, name, "tab_close")) {
        r.command = .tab_close;
        if (getInt(args, "tab")) |t| {
            if (t < 1) return null;
            r.tab_idx = @intCast(t - 1);
        }
    } else if (eql(u8, name, "tab_select")) {
        const idx = getInt(args, "index") orelse return null;
        if (idx < 1 or idx > 9) return null;
        r.command = .tab_select;
        r.index_arg = @intCast(idx);
    } else if (eql(u8, name, "tab_switch")) {
        const d = getStr(args, "direction") orelse return null;
        r.command = if (eql(u8, d, "next")) .tab_next else if (eql(u8, d, "prev")) .tab_prev else return null;
    } else if (eql(u8, name, "tab_move")) {
        const d = getStr(args, "direction") orelse return null;
        r.command = if (eql(u8, d, "left")) .tab_move_left else if (eql(u8, d, "right")) .tab_move_right else return null;
    } else if (eql(u8, name, "tab_rename")) {
        r.command = .tab_rename;
        r.text_arg = getStr(args, "name") orelse return null;
        if (getInt(args, "tab")) |t| {
            if (t < 1) return null;
            r.tab_idx = @intCast(t - 1);
        }
    } else if (eql(u8, name, "split")) {
        const d = getStr(args, "direction") orelse return null;
        r.command = if (eql(u8, d, "vertical")) .split_vertical else if (eql(u8, d, "horizontal")) .split_horizontal else return null;
        r.text_arg = getStr(args, "command") orelse "";
        r.wait = getBool(args, "wait");
    } else if (eql(u8, name, "split_close")) {
        r.command = .split_close;
    } else if (eql(u8, name, "split_rotate")) {
        r.command = .split_rotate;
    } else if (eql(u8, name, "split_zoom")) {
        r.command = .split_zoom;
    } else if (eql(u8, name, "theme_set")) {
        r.command = .theme_set;
        r.text_arg = getStr(args, "name") orelse return null;
    } else if (eql(u8, name, "config_reload")) {
        r.command = .config_reload;
    } else if (eql(u8, name, "popup")) {
        r.command = .popup;
        r.text_arg = getStr(args, "command") orelse return null;
        if (getInt(args, "width")) |w| if (w >= 1 and w <= 100) {
            r.width_pct = @intCast(w);
        };
        if (getInt(args, "height")) |h| if (h >= 1 and h <= 100) {
            r.height_pct = @intCast(h);
        };
        if (getStr(args, "border")) |b| {
            r.border_style = if (eql(u8, b, "single")) 0 else if (eql(u8, b, "double")) 1 else if (eql(u8, b, "rounded")) 2 else if (eql(u8, b, "heavy")) 3 else if (eql(u8, b, "none")) 4 else 2;
        }
    } else if (eql(u8, name, "session_list")) {
        r.command = .session_list;
    } else if (eql(u8, name, "session_create")) {
        r.command = .session_create;
        r.text_arg = getStr(args, "name") orelse "";
        r.cwd_arg = getStr(args, "cwd") orelse "";
        r.background = getBool(args, "background");
    } else if (eql(u8, name, "session_kill")) {
        r.command = .session_kill;
        r.session_id_arg = u32Of(args, "session_id");
    } else if (eql(u8, name, "session_switch")) {
        r.command = .session_switch;
        r.session_id_arg = u32Of(args, "session_id");
    } else if (eql(u8, name, "session_rename")) {
        r.command = .session_rename;
        r.session_id_arg = u32Of(args, "session_id");
        r.text_arg = getStr(args, "name") orelse return null;
    } else {
        return null;
    }

    return r;
}

// ---------------------------------------------------------------------------
// send_image: resolve a `path` or materialize base64 `data` to a temp file.
// Kept separate from fill() because it needs an allocator + filesystem access,
// which fill() (a pure name→request mapper) deliberately avoids.
// ---------------------------------------------------------------------------

pub const ImageError = error{ MissingSource, DecodeFailed, WriteFailed };

/// Build a send_image request. With `path`, the existing file is used as-is.
/// With base64 `data`, the bytes are decoded and written to a temp file whose
/// path is returned. The request's text_arg (the path) is allocated in `a`.
pub fn fillSendImage(a: std.mem.Allocator, args: ?std.json.ObjectMap) ImageError!IpcRequest {
    var r = IpcRequest{
        .command = .send_image,
        .target_session = u32Of(args, "session"),
        .pane_id = u32Of(args, "pane"),
    };

    if (getStr(args, "path")) |p| {
        if (p.len == 0) return error.MissingSource;
        r.text_arg = a.dupe(u8, p) catch return error.WriteFailed;
        return r;
    }

    const data = getStr(args, "data") orelse return error.MissingSource;
    r.text_arg = try materializeBase64(a, data, getStr(args, "filename"));
    return r;
}

/// Decode base64 image bytes (tolerating embedded whitespace) and write them to
/// a uniquely-named temp file, returning its absolute path (allocated in `a`).
fn materializeBase64(a: std.mem.Allocator, data: []const u8, filename: ?[]const u8) ImageError![]const u8 {
    // Strip whitespace some encoders insert (line-wrapped base64) before decode.
    const clean = a.alloc(u8, data.len) catch return error.WriteFailed;
    var cn: usize = 0;
    for (data) |c| {
        if (c == '\n' or c == '\r' or c == ' ' or c == '\t') continue;
        clean[cn] = c;
        cn += 1;
    }
    const src = clean[0..cn];

    const decoder = std.base64.standard.Decoder;
    const n = decoder.calcSizeForSlice(src) catch return error.DecodeFailed;
    const bytes = a.alloc(u8, n) catch return error.WriteFailed;
    decoder.decode(bytes, src) catch return error.DecodeFailed;

    const ext = extOf(filename);
    var rnd: [8]u8 = undefined;
    std.crypto.random.bytes(&rnd);
    const hex = std.fmt.bytesToHex(rnd, .lower);
    const sep: []const u8 = if (builtin.os.tag == .windows) "\\" else "/";
    const path = std.fmt.allocPrint(a, "{s}{s}attyx-img-{s}{s}", .{
        tmpDir(a), sep, &hex, ext,
    }) catch return error.WriteFailed;

    const file = std.fs.createFileAbsolute(path, .{}) catch return error.WriteFailed;
    defer file.close();
    file.writeAll(bytes) catch return error.WriteFailed;
    return path;
}

/// Temp dir for materialized images. Uses getEnvVarOwned (not posix.getenv,
/// which is a compile error on Windows) — the returned slice is request-scoped,
/// like the path it's spliced into. Falls back to the platform default.
fn tmpDir(a: std.mem.Allocator) []const u8 {
    if (builtin.os.tag == .windows)
        return std.process.getEnvVarOwned(a, "TEMP") catch "C:\\Windows\\Temp";
    return std.process.getEnvVarOwned(a, "TMPDIR") catch "/tmp";
}

/// Pick a file extension (including the dot) from the original filename, or
/// default to .png. Claude Code keys image detection off the path's extension.
fn extOf(filename: ?[]const u8) []const u8 {
    const f = filename orelse return ".png";
    const dot = std.mem.lastIndexOfScalar(u8, f, '.') orelse return ".png";
    const ext = f[dot..];
    if (ext.len < 2 or ext.len > 6) return ".png";
    return ext;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn argsFrom(a: std.mem.Allocator, json: []const u8) std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, json, .{}) catch unreachable;
}

test "fill maps send_keys with text and pane" {
    var p = argsFrom(std.testing.allocator, "{\"text\":\"hi\",\"pane\":3}");
    defer p.deinit();
    const r = fill("send_keys", p.value.object).?;
    try std.testing.expectEqual(cli_ipc.IpcCommand.send_keys, r.command);
    try std.testing.expectEqualStrings("hi", r.text_arg);
    try std.testing.expectEqual(@as(u32, 3), r.pane_id);
}

test "fill maps focus direction" {
    var p = argsFrom(std.testing.allocator, "{\"direction\":\"left\"}");
    defer p.deinit();
    const r = fill("focus", p.value.object).?;
    try std.testing.expectEqual(cli_ipc.IpcCommand.focus_left, r.command);
}

test "fill rejects send_keys without text" {
    var p = argsFrom(std.testing.allocator, "{}");
    defer p.deinit();
    try std.testing.expect(fill("send_keys", p.value.object) == null);
}

test "fill rejects unknown tool" {
    try std.testing.expect(fill("nope", null) == null);
}

test "fillSendImage with path passes it through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = argsFrom(arena.allocator(), "{\"path\":\"/tmp/shot.png\",\"pane\":4}");
    defer p.deinit();
    const r = try fillSendImage(arena.allocator(), p.value.object);
    try std.testing.expectEqual(cli_ipc.IpcCommand.send_image, r.command);
    try std.testing.expectEqualStrings("/tmp/shot.png", r.text_arg);
    try std.testing.expectEqual(@as(u32, 4), r.pane_id);
}

test "fillSendImage decodes base64 data to a temp file" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // "hi" base64-encoded is "aGk=".
    var p = argsFrom(arena.allocator(), "{\"data\":\"aGk=\",\"filename\":\"a.jpg\"}");
    defer p.deinit();
    const r = try fillSendImage(arena.allocator(), p.value.object);
    try std.testing.expectEqual(cli_ipc.IpcCommand.send_image, r.command);
    try std.testing.expect(std.mem.endsWith(u8, r.text_arg, ".jpg"));
    defer std.fs.deleteFileAbsolute(r.text_arg) catch {};
    const contents = try std.fs.cwd().readFileAlloc(arena.allocator(), r.text_arg, 64);
    try std.testing.expectEqualStrings("hi", contents);
}

test "fillSendImage without path or data errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = argsFrom(arena.allocator(), "{}");
    defer p.deinit();
    try std.testing.expectError(error.MissingSource, fillSendImage(arena.allocator(), p.value.object));
}

test "extOf falls back to png" {
    try std.testing.expectEqualStrings(".png", extOf(null));
    try std.testing.expectEqualStrings(".png", extOf("noext"));
    try std.testing.expectEqualStrings(".jpeg", extOf("shot.jpeg"));
}

test "fill tab_close converts 1-based to 0-based index" {
    var p = argsFrom(std.testing.allocator, "{\"tab\":3}");
    defer p.deinit();
    const r = fill("tab_close", p.value.object).?;
    try std.testing.expectEqual(@as(u8, 2), r.tab_idx);
}

test "fill tab_close without tab keeps active sentinel" {
    const r = fill("tab_close", null).?;
    try std.testing.expectEqual(@as(u8, 0xFF), r.tab_idx);
}
