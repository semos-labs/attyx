// Attyx — MCP server (stdio transport)
//
// Speaks the Model Context Protocol over stdin/stdout (newline-delimited
// JSON-RPC 2.0) and bridges every tools/call into an IPC request against the
// running Attyx instance. Configure an MCP client (e.g. Claude Desktop) with:
//   { "command": "attyx", "args": ["mcp"] }
//
// Only the methods that matter are implemented: initialize, tools/list,
// tools/call. Notifications get no response. No auth — stdio is owned by the
// trusted parent process.

const std = @import("std");
const protocol = @import("protocol.zig");
const client = @import("client.zig");
const mcp_tools = @import("mcp_tools.zig");
const version = @import("attyx").version;

const protocol_version = "2024-11-05";
const max_response = 65536;

const init_result = "{\"protocolVersion\":\"" ++ protocol_version ++
    "\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"attyx\",\"version\":\"" ++
    version ++ "\"}}";

pub fn run(gpa: std.mem.Allocator) void {
    const stdin = std.fs.File.stdin();
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(gpa);

    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = stdin.read(&chunk) catch break;
        if (n == 0) break; // EOF — client closed stdin
        buf.appendSlice(gpa, chunk[0..n]) catch break;

        // Process every complete (newline-terminated) message in the buffer.
        while (std.mem.indexOfScalar(u8, buf.items, '\n')) |nl| {
            const line = std.mem.trim(u8, buf.items[0..nl], " \t\r");
            if (line.len > 0) handleLineStdio(gpa, line);
            const remaining = buf.items.len - (nl + 1);
            std.mem.copyForwards(u8, buf.items[0..remaining], buf.items[nl + 1 ..]);
            buf.shrinkRetainingCapacity(remaining);
        }
    }
}

fn handleLineStdio(gpa: std.mem.Allocator, line: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    if (handleMessage(arena_state.allocator(), line)) |resp| {
        writeRaw(resp);
        writeRaw("\n");
    }
}

/// Process one JSON-RPC message and return the response (without a trailing
/// newline) allocated in `a`, or null when no reply is warranted (a
/// notification, or non-object input). Shared by the stdio server and the
/// in-app HTTP server.
pub fn handleMessage(a: std.mem.Allocator, line: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, a, line, .{}) catch
        return respondError(a, null, -32700, "parse error");
    if (parsed.value != .object) return null;
    const root = parsed.value.object;

    const method_v = root.get("method") orelse return null;
    if (method_v != .string) return null;
    const method = method_v.string;
    const id = root.get("id"); // absent → notification, no response

    if (std.mem.eql(u8, method, "initialize")) {
        return respond(a, id, init_result);
    } else if (std.mem.eql(u8, method, "tools/list")) {
        return respond(a, id, "{\"tools\":" ++ mcp_tools.TOOLS_JSON ++ "}");
    } else if (std.mem.eql(u8, method, "tools/call")) {
        return handleToolCall(a, root.get("params"), id);
    } else if (std.mem.startsWith(u8, method, "notifications/")) {
        return null; // notifications expect no reply
    } else if (id != null) {
        return respondError(a, id, -32601, "method not found");
    }
    return null;
}

fn handleToolCall(a: std.mem.Allocator, params_opt: ?std.json.Value, id: ?std.json.Value) []const u8 {
    const params = params_opt orelse return respondError(a, id, -32602, "missing params");
    if (params != .object) return respondError(a, id, -32602, "invalid params");

    const name_v = params.object.get("name") orelse return respondError(a, id, -32602, "missing tool name");
    if (name_v != .string) return respondError(a, id, -32602, "invalid tool name");

    const args: ?std.json.ObjectMap = if (params.object.get("arguments")) |v|
        (if (v == .object) v.object else null)
    else
        null;

    const req = mcp_tools.fill(name_v.string, args) orelse
        return respondError(a, id, -32602, "unknown tool or missing required argument");

    const out = callIpc(a, req);
    const text_json = std.json.Stringify.valueAlloc(a, std.json.Value{ .string = out.text }, .{}) catch "\"\"";
    const result = std.fmt.allocPrint(
        a,
        "{{\"content\":[{{\"type\":\"text\",\"text\":{s}}}],\"isError\":{s}}}",
        .{ text_json, if (out.is_error) "true" else "false" },
    ) catch return respondError(a, id, -32603, "internal error");
    return respond(a, id, result);
}

const CallOut = struct { is_error: bool, text: []const u8 };

/// Send one IPC request to the running instance and interpret the response.
/// Mirrors the relevant parts of client.run (minus stdout/exit semantics).
fn callIpc(a: std.mem.Allocator, req: @import("../config/cli_ipc.zig").IpcRequest) CallOut {
    var sock_buf: [256]u8 = undefined;
    const socket_path = client.discoverSocket(&sock_buf, req.target_pid) orelse
        return .{ .is_error = true, .text = "no running Attyx instance found" };

    var req_buf: [protocol.header_size + 4096]u8 = undefined;
    var request = client.buildRequest(&req_buf, req) catch
        return .{ .is_error = true, .text = "failed to build request" };

    var env_buf: [protocol.header_size + 5 + 4096]u8 = undefined;
    if (req.target_session != 0) {
        request = client.wrapSessionEnvelope(&env_buf, request, req.target_session) catch
            return .{ .is_error = true, .text = "failed to build session envelope" };
    }

    // get-text --lines can return far more than max_response; heap-allocate.
    var stack_buf: [max_response]u8 = undefined;
    var heap_buf: ?[]u8 = null;
    defer if (heap_buf) |b| std.heap.page_allocator.free(b);
    const resp_buf: []u8 = if (req.command == .get_text and req.lines > 0) blk: {
        const b = std.heap.page_allocator.alloc(u8, 8 * 1024 * 1024) catch
            return .{ .is_error = true, .text = "out of memory for response buffer" };
        heap_buf = b;
        break :blk b;
    } else stack_buf[0..];

    const resp = client.sendCommand(socket_path, request, resp_buf) catch
        return .{ .is_error = true, .text = "failed to communicate with Attyx instance" };

    return switch (resp.msg_type) {
        .success => .{ .is_error = false, .text = a.dupe(u8, resp.payload) catch "" },
        .err => .{ .is_error = true, .text = a.dupe(u8, resp.payload) catch "error" },
        .exit_code => blk: {
            const code: u8 = if (resp.payload.len > 0) resp.payload[0] else 1;
            const body = if (resp.payload.len > 1) resp.payload[1..] else "";
            break :blk .{
                .is_error = code != 0,
                .text = std.fmt.allocPrint(a, "exit_code={d}\n{s}", .{ code, body }) catch "",
            };
        },
        else => .{ .is_error = true, .text = "unexpected response type" },
    };
}

// ---------------------------------------------------------------------------
// JSON-RPC envelope writers
// ---------------------------------------------------------------------------

fn respond(a: std.mem.Allocator, id: ?std.json.Value, result_json: []const u8) []const u8 {
    return std.fmt.allocPrint(
        a,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}",
        .{ idStr(a, id), result_json },
    ) catch "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"oom\"}}";
}

fn respondError(a: std.mem.Allocator, id: ?std.json.Value, code: i32, msg: []const u8) []const u8 {
    const msg_json = std.json.Stringify.valueAlloc(a, std.json.Value{ .string = msg }, .{}) catch "\"error\"";
    return std.fmt.allocPrint(
        a,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":{s}}}}}",
        .{ idStr(a, id), code, msg_json },
    ) catch "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"oom\"}}";
}

fn idStr(a: std.mem.Allocator, id: ?std.json.Value) []const u8 {
    const v = id orelse return "null";
    return std.json.Stringify.valueAlloc(a, v, .{}) catch "null";
}

fn writeRaw(s: []const u8) void {
    std.fs.File.stdout().writeAll(s) catch {};
}

test {
    _ = mcp_tools;
}
