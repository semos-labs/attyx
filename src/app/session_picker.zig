/// Session picker — standalone TUI for the `attyx _session-picker` subcommand.
///
/// Runs inside a popup PTY. Renders to stderr (displayed by popup), reads
/// keyboard from stdin, and writes the selected action to stdout (captured
/// by the parent process).
///
/// Output format: "switch <id>", "create <cwd>", "kill <id>"
const std = @import("std");
const posix = std.posix;
const protocol = @import("daemon/protocol.zig");
const conn = @import("session_connect.zig");

extern "c" fn tcgetattr(fd: c_int, termios: *Termios) c_int;
extern "c" fn tcsetattr(fd: c_int, actions: c_int, termios: *const Termios) c_int;
extern "c" fn isatty(fd: c_int) c_int;

const TCSANOW: c_int = 0;
const STDIN_FD: posix.fd_t = 0;
const STDERR_FD: posix.fd_t = 2;
const STDOUT_FD: posix.fd_t = 1;

// Minimal termios for raw mode (platform-specific sizes handled by extern)
const Termios = extern struct {
    c_iflag: u64 = 0,
    c_oflag: u64 = 0,
    c_cflag: u64 = 0,
    c_lflag: u64 = 0,
    _pad: [256]u8 = .{0} ** 256,
};

const ICANON: u64 = 0x00000100;
const ECHO: u64 = 0x00000008;
const ISIG: u64 = 0x00000080;

const Entry = struct {
    id: u32,
    name: [64]u8 = undefined,
    name_len: u8 = 0,
    alive: bool = false,

    fn getName(self: *const Entry) []const u8 {
        return self.name[0..self.name_len];
    }
};

const max_entries = 32;

pub fn run(allocator: std.mem.Allocator) !void {
    _ = allocator;

    // Connect to daemon
    const sock_fd = conn.connectToSocket() catch {
        writeStderr("Error: cannot connect to session daemon\r\n");
        std.process.exit(1);
    };
    defer posix.close(sock_fd);

    // Fetch session list (blocking)
    var entries: [max_entries]Entry = undefined;
    var entry_count: u8 = 0;
    {
        var hdr: [protocol.header_size]u8 = undefined;
        protocol.encodeHeader(&hdr, .list, 0);
        _ = posix.write(sock_fd, &hdr) catch {
            writeStderr("Error: cannot send list request\r\n");
            std.process.exit(1);
        };

        // Wait for response
        var read_buf: [4096]u8 = undefined;
        var read_len: usize = 0;
        var timeout: u32 = 0;
        while (timeout < 3000) {
            var fds = [1]posix.pollfd{.{ .fd = sock_fd, .events = 0x0001, .revents = 0 }};
            _ = posix.poll(&fds, 100) catch break;
            if (fds[0].revents & 0x0001 != 0) {
                const n = posix.read(sock_fd, read_buf[read_len..]) catch break;
                if (n == 0) break;
                read_len += n;
                if (read_len >= protocol.header_size) {
                    const h = protocol.decodeHeader(read_buf[0..protocol.header_size]) catch break;
                    const total = protocol.header_size + h.payload_len;
                    if (read_len >= total and h.msg_type == .session_list) {
                        const payload = read_buf[protocol.header_size..total];
                        var decoded: [max_entries]protocol.DecodedListEntry = undefined;
                        const count = protocol.decodeSessionList(payload, &decoded) catch break;
                        entry_count = @intCast(@min(count, max_entries));
                        for (0..entry_count) |i| {
                            entries[i].id = decoded[i].id;
                            entries[i].alive = decoded[i].alive;
                            const nlen: u8 = @intCast(@min(decoded[i].name.len, 64));
                            @memcpy(entries[i].name[0..nlen], decoded[i].name[0..nlen]);
                            entries[i].name_len = nlen;
                        }
                        break;
                    }
                }
            }
            timeout += 100;
        }
    }

    // Get current session ID from env
    const current_session_id: ?u32 = blk: {
        const env_val = std.posix.getenv("ATTYX_SESSION_ID") orelse break :blk null;
        break :blk std.fmt.parseInt(u32, env_val, 10) catch null;
    };

    // Get current working directory for "create" action
    var cwd_buf: [4096]u8 = undefined;
    const cwd = std.posix.getenv("ATTYX_PICKER_CWD") orelse (std.posix.getcwd(&cwd_buf) catch "/tmp");

    // Enter raw mode on stdin
    var orig_termios: Termios = .{};
    const is_tty = isatty(STDIN_FD) != 0;
    if (is_tty) {
        _ = tcgetattr(STDIN_FD, &orig_termios);
        var raw = orig_termios;
        raw.c_lflag &= ~(ICANON | ECHO | ISIG);
        _ = tcsetattr(STDIN_FD, TCSANOW, &raw);
    }
    defer if (is_tty) {
        _ = tcsetattr(STDIN_FD, TCSANOW, &orig_termios);
    };

    // Hide cursor
    writeStderr("\x1b[?25l");
    defer writeStderr("\x1b[?25h");

    // Main loop state
    var selected: u8 = 0;
    var filter_buf: [64]u8 = .{0} ** 64;
    var filter_len: u8 = 0;
    var filtered_indices: [max_entries]u8 = undefined;
    var filtered_count: u8 = 0;

    // The list shows: [filtered sessions...] + "+ New session" at the end.
    // total_count = filtered_count + 1 (the "new" entry is always present).

    // Initial filter
    filtered_count = applyFilter(&entries, entry_count, filter_buf[0..filter_len], &filtered_indices);
    if (filtered_count > 0) selected = 0;

    // Pre-select first non-current alive session
    for (0..filtered_count) |i| {
        const e = &entries[filtered_indices[i]];
        if (e.alive and (current_session_id == null or e.id != current_session_id.?)) {
            selected = @intCast(i);
            break;
        }
    }

    render(&entries, entry_count, &filtered_indices, filtered_count, selected, filter_buf[0..filter_len], current_session_id);

    while (true) {
        var key_buf: [16]u8 = undefined;
        const n = posix.read(STDIN_FD, &key_buf) catch break;
        if (n == 0) break;

        const key = key_buf[0..n];
        const total_count: u8 = filtered_count + 1; // +1 for "New session"

        if (key.len == 1) {
            switch (key[0]) {
                0x1b => { // Esc
                    std.process.exit(1);
                },
                0x0d, 0x0a => { // Enter
                    if (selected == filtered_count) {
                        // "New session" entry
                        outputCreateAction(cwd);
                        std.process.exit(0);
                    } else if (filtered_count > 0 and selected < filtered_count) {
                        const e = &entries[filtered_indices[selected]];
                        outputAction("switch", e.id, null);
                        std.process.exit(0);
                    }
                },
                0x0e => { // Ctrl-N — create (fallback)
                    outputCreateAction(cwd);
                    std.process.exit(0);
                },
                0x04 => { // Ctrl-D — kill (fallback)
                    if (filtered_count > 0 and selected < filtered_count) {
                        const e = &entries[filtered_indices[selected]];
                        outputAction("kill", e.id, null);
                        std.process.exit(0);
                    }
                },
                0x7f, 0x08 => { // Backspace
                    if (filter_len > 0) {
                        filter_len -= 1;
                        filtered_count = applyFilter(&entries, entry_count, filter_buf[0..filter_len], &filtered_indices);
                        selected = 0;
                    }
                },
                0x15 => { // Ctrl-U — clear filter
                    filter_len = 0;
                    filtered_count = applyFilter(&entries, entry_count, filter_buf[0..filter_len], &filtered_indices);
                    selected = 0;
                },
                else => {
                    // Printable character — add to filter
                    if (key[0] >= 0x20 and key[0] < 0x7f and filter_len < 63) {
                        filter_buf[filter_len] = key[0];
                        filter_len += 1;
                        filtered_count = applyFilter(&entries, entry_count, filter_buf[0..filter_len], &filtered_indices);
                        selected = 0;
                    }
                },
            }
        } else if (key.len == 3 and key[0] == 0x1b and key[1] == '[') {
            switch (key[2]) {
                'A' => { // Up
                    if (total_count > 0) {
                        selected = if (selected == 0) total_count - 1 else selected - 1;
                    }
                },
                'B' => { // Down
                    if (total_count > 0) {
                        selected = if (selected + 1 >= total_count) 0 else selected + 1;
                    }
                },
                else => {},
            }
        } else if (key.len == 4 and key[0] == 0x1b and key[1] == '[' and key[2] == '3' and key[3] == '~') {
            // Delete key — kill selected session
            if (filtered_count > 0 and selected < filtered_count) {
                const e = &entries[filtered_indices[selected]];
                outputAction("kill", e.id, null);
                std.process.exit(0);
            }
        } else if (key.len >= 2 and key[0] == 0x1b) {
            // Esc + something — treat as Esc
            std.process.exit(1);
        }

        render(&entries, entry_count, &filtered_indices, filtered_count, selected, filter_buf[0..filter_len], current_session_id);
    }
}

fn applyFilter(entries: *const [max_entries]Entry, count: u8, filter: []const u8, out: *[max_entries]u8) u8 {
    var n: u8 = 0;
    for (0..count) |i| {
        if (filter.len == 0 or fuzzyMatch(entries[i].getName(), filter)) {
            out[n] = @intCast(i);
            n += 1;
        }
    }
    return n;
}

fn fuzzyMatch(name: []const u8, query: []const u8) bool {
    // Case-insensitive substring match
    if (query.len > name.len) return false;
    for (0..name.len - query.len + 1) |start| {
        var matched = true;
        for (0..query.len) |j| {
            if (toLower(name[start + j]) != toLower(query[j])) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn toLower(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

fn render(
    entries: *const [max_entries]Entry,
    _: u8,
    filtered_indices: *const [max_entries]u8,
    filtered_count: u8,
    selected: u8,
    filter: []const u8,
    current_session_id: ?u32,
) void {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    // Clear screen and move home
    pos += writeSlice(&buf, pos, "\x1b[2J\x1b[H");

    // Title / filter line
    if (filter.len > 0) {
        pos += writeSlice(&buf, pos, "  \x1b[90m\xe2\x9a\xa1\x1b[0m "); // ⚡
        pos += writeSlice(&buf, pos, filter);
        pos += writeSlice(&buf, pos, "\x1b[90m\xe2\x96\x8f\x1b[0m"); // ▏ cursor
    } else {
        pos += writeSlice(&buf, pos, "  \x1b[90m\xe2\x9a\xa1 Pick a sesh\x1b[0m");
    }
    pos += writeSlice(&buf, pos, "\r\n");

    // Session entries
    for (0..filtered_count) |i| {
        const e = &entries[filtered_indices[i]];
        const is_selected = (i == selected);
        const is_current = if (current_session_id) |cid| e.id == cid else false;

        // Selection bullet or indent
        if (is_selected) {
            pos += writeSlice(&buf, pos, "  \x1b[35m\xe2\x80\xa2\x1b[0m "); // • magenta
        } else {
            pos += writeSlice(&buf, pos, "    ");
        }

        // Window icon
        pos += writeSlice(&buf, pos, "\x1b[90m\xe2\x8a\x9e\x1b[0m "); // ⊞ dim

        // Session name — bold if current, dim if dead
        if (is_current) {
            pos += writeSlice(&buf, pos, "\x1b[1m");
            pos += writeSlice(&buf, pos, e.getName());
            pos += writeSlice(&buf, pos, "\x1b[0m");
            pos += writeSlice(&buf, pos, " \x1b[90m(active)\x1b[0m");
        } else if (!e.alive) {
            pos += writeSlice(&buf, pos, "\x1b[90m");
            pos += writeSlice(&buf, pos, e.getName());
            pos += writeSlice(&buf, pos, "\x1b[0m");
        } else {
            pos += writeSlice(&buf, pos, e.getName());
        }

        pos += writeSlice(&buf, pos, "\r\n");
    }

    // "+ New session" entry (always last)
    if (selected == filtered_count) {
        pos += writeSlice(&buf, pos, "  \x1b[35m\xe2\x80\xa2\x1b[0m "); // • magenta
    } else {
        pos += writeSlice(&buf, pos, "    ");
    }
    pos += writeSlice(&buf, pos, "\x1b[90m+\x1b[0m New session\r\n");

    // Footer
    pos += writeSlice(&buf, pos, "\r\n  \x1b[90m\xe2\x86\x91\xe2\x86\x93 navigate \xe2\x80\xa2 esc close \xe2\x80\xa2 enter select \xe2\x80\xa2 del kill\x1b[0m\r\n");

    _ = posix.write(STDERR_FD, buf[0..pos]) catch {};
}

fn writeSlice(buf: *[4096]u8, pos: usize, data: []const u8) usize {
    const len = @min(data.len, buf.len - pos);
    @memcpy(buf[pos .. pos + len], data[0..len]);
    return len;
}

/// Marker prefix (Unit Separator, 0x1F) so the parent can locate the picker's
/// output even when shell init scripts prepend noise to the stdout pipe.
const marker = "\x1f";

fn outputAction(action: []const u8, id: u32, _: ?void) void {
    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{s}{s} {d}", .{ marker, action, id }) catch return;
    _ = posix.write(STDOUT_FD, text) catch {};
}

fn outputCreateAction(cwd: []const u8) void {
    _ = posix.write(STDOUT_FD, marker) catch {};
    _ = posix.write(STDOUT_FD, "create ") catch {};
    _ = posix.write(STDOUT_FD, cwd) catch {};
}

fn writeStderr(data: []const u8) void {
    _ = posix.write(STDERR_FD, data) catch {};
}
