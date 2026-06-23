// Attyx — in-app MCP server (Streamable HTTP transport)
//
// Listens on a TCP port (loopback by default) for as long as the UI runs and
// answers MCP JSON-RPC over HTTP. Clients connect with a URL, e.g.
//   http://127.0.0.1:7333/mcp
// matching how local desktop apps (Figma Dev Mode, JetBrains) expose MCP.
//
// Only the request/response subset of Streamable HTTP is implemented: POST a
// JSON-RPC message, get the JSON-RPC response back as application/json. No SSE
// / GET stream and no session ids — our tools are all request/response.
// ponytail: POST-only; add SSE/GET + Mcp-Session-Id if we ever push notifications.
//
// The JSON-RPC handling itself is shared with the stdio server (mcp.handleMessage).
// callIpc inside it connects to this same process's control socket, so the
// listener just needs the UI's IPC server thread to be up.

const std = @import("std");
const posix = std.posix;
const mcp = @import("mcp.zig");
const logging = @import("../logging/log.zig");

var g_shutdown: i32 = 0;
var listener_fd: posix.fd_t = -1;
var g_thread: ?std.Thread = null;

const max_request = 1024 * 1024; // 1 MiB request cap

/// Start the MCP HTTP listener on host:port and spawn its accept thread.
/// No-op (logs a warning) on bind failure — the UI keeps running regardless.
pub fn start(host: []const u8, port: u16) void {
    const addr = std.net.Address.parseIp(host, port) catch {
        logging.warn("mcp", "invalid mcp host '{s}', not starting", .{host});
        return;
    };

    const fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch |err| {
        logging.warn("mcp", "failed to create socket: {}", .{err});
        return;
    };
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};
    posix.bind(fd, &addr.any, addr.getOsSockLen()) catch |err| {
        logging.warn("mcp", "failed to bind {s}:{d}: {} (port in use?)", .{ host, port, err });
        posix.close(fd);
        return;
    };
    posix.listen(fd, 8) catch |err| {
        logging.warn("mcp", "failed to listen: {}", .{err});
        posix.close(fd);
        return;
    };

    listener_fd = fd;
    g_thread = std.Thread.spawn(.{}, run, .{}) catch |err| {
        logging.warn("mcp", "failed to spawn thread: {}", .{err});
        posix.close(fd);
        listener_fd = -1;
        return;
    };
    logging.info("mcp", "MCP HTTP server on http://{s}:{d}/mcp", .{ host, port });
}

pub fn shutdown() void {
    @atomicStore(i32, &g_shutdown, 1, .seq_cst);
    if (listener_fd != -1) {
        posix.close(listener_fd);
        listener_fd = -1;
    }
    if (g_thread) |t| {
        t.join();
        g_thread = null;
    }
}

fn run() void {
    const fd = listener_fd;
    if (fd == -1) return;
    while (@atomicLoad(i32, &g_shutdown, .seq_cst) == 0) {
        var pfd = [1]posix.pollfd{.{ .fd = fd, .events = 0x0001, .revents = 0 }}; // POLLIN
        const ready = posix.poll(&pfd, 200) catch continue;
        if (ready == 0) continue;
        if (pfd[0].revents & 0x0001 == 0) continue;
        const client_fd = posix.accept(fd, null, null, posix.SOCK.CLOEXEC) catch continue;
        handleConn(client_fd);
    }
}

fn handleConn(fd: posix.fd_t) void {
    defer posix.close(fd);

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const req = readRequest(a, fd) catch {
        writeStatus(fd, "400 Bad Request");
        return;
    };

    // Only POST <path> carries a JSON-RPC message. GET (SSE) is unsupported.
    if (!std.mem.eql(u8, req.method, "POST")) {
        writeStatus(fd, "405 Method Not Allowed");
        return;
    }

    if (mcp.handleMessage(a, req.body)) |resp| {
        writeJson(fd, resp);
    } else {
        // Notification / no reply — 202 Accepted with empty body, per spec.
        writeStatus(fd, "202 Accepted");
    }
}

const Request = struct { method: []const u8, body: []const u8 };

/// Read an HTTP/1.1 request: status line, headers, then Content-Length bytes.
/// Minimal by design — enough for an MCP client POSTing a JSON body.
fn readRequest(a: std.mem.Allocator, fd: posix.fd_t) !Request {
    var buf: std.ArrayList(u8) = .{};
    var chunk: [4096]u8 = undefined;
    var header_end: ?usize = null;

    // Read until we have the full header block (\r\n\r\n).
    while (header_end == null) {
        const n = try posix.read(fd, &chunk);
        if (n == 0) return error.Closed;
        try buf.appendSlice(a, chunk[0..n]);
        if (buf.items.len > max_request) return error.TooLarge;
        header_end = std.mem.indexOf(u8, buf.items, "\r\n\r\n");
    }
    const head = buf.items[0..header_end.?];

    // Method is the first token of the request line.
    const sp = std.mem.indexOfScalar(u8, head, ' ') orelse return error.BadRequest;
    const method = head[0..sp];

    const content_length = parseContentLength(head) orelse 0;
    const body_start = header_end.? + 4;

    // Read any remaining body bytes until we have Content-Length of them.
    while (buf.items.len - body_start < content_length) {
        const n = try posix.read(fd, &chunk);
        if (n == 0) break;
        try buf.appendSlice(a, chunk[0..n]);
        if (buf.items.len > max_request) return error.TooLarge;
    }

    const body_len = @min(content_length, buf.items.len - body_start);
    return .{ .method = method, .body = buf.items[body_start .. body_start + body_len] };
}

fn parseContentLength(head: []const u8) ?usize {
    var it = std.mem.tokenizeSequence(u8, head, "\r\n");
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " ");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            const val = std.mem.trim(u8, line[colon + 1 ..], " ");
            return std.fmt.parseInt(usize, val, 10) catch null;
        }
    }
    return null;
}

fn writeJson(fd: posix.fd_t, body: []const u8) void {
    var hdr_buf: [128]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch return;
    writeAll(fd, hdr);
    writeAll(fd, body);
}

fn writeStatus(fd: posix.fd_t, status: []const u8) void {
    var buf: [128]u8 = undefined;
    const resp = std.fmt.bufPrint(&buf, "HTTP/1.1 {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{status}) catch return;
    writeAll(fd, resp);
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = posix.write(fd, bytes[off..]) catch return;
        if (n == 0) return;
        off += n;
    }
}
