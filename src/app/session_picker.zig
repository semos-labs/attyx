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
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

const TIOCGWINSZ: c_ulong = 0x40087468; // macOS

const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

fn getTermRows() u16 {
    var ws: Winsize = .{ .ws_row = 0, .ws_col = 0, .ws_xpixel = 0, .ws_ypixel = 0 };
    if (ioctl(STDERR_FD, TIOCGWINSZ, &ws) == 0 and ws.ws_row > 0) {
        return ws.ws_row;
    }
    return 24; // fallback
}

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

    // Read configurable icons from env (set by parent via config)
    const icon_filter = std.posix.getenv("ATTYX_ICON_FILTER") orelse ">";
    const icon_session = std.posix.getenv("ATTYX_ICON_SESSION") orelse "";
    const icon_new = std.posix.getenv("ATTYX_ICON_NEW") orelse "+";
    const icon_active = std.posix.getenv("ATTYX_ICON_ACTIVE") orelse "(active)";

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

    // Show cursor and apply configured cursor style (DECSCUSR)
    writeStderr("\x1b[?25h");
    {
        const style = std.posix.getenv("ATTYX_CURSOR_STYLE") orelse "1";
        var seq_buf: [8]u8 = undefined;
        const seq = std.fmt.bufPrint(&seq_buf, "\x1b[{s} q", .{style}) catch "\x1b[1 q";
        writeStderr(seq);
    }

    // Main loop state
    var selected: u8 = 0;
    var scroll_offset: u8 = 0;
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

    const term_rows = getTermRows();
    scroll_offset = adjustScroll(selected, scroll_offset, filtered_count +| 1, term_rows);
    render(&entries, entry_count, &filtered_indices, filtered_count, selected, scroll_offset, term_rows, filter_buf[0..filter_len], current_session_id, icon_filter, icon_session, icon_new, icon_active);

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

        scroll_offset = adjustScroll(selected, scroll_offset, filtered_count +| 1, term_rows);
        render(&entries, entry_count, &filtered_indices, filtered_count, selected, scroll_offset, term_rows, filter_buf[0..filter_len], current_session_id, icon_filter, icon_session, icon_new, icon_active);
    }
}

/// Compute visible list rows: term_rows minus filter (row 1) and footer (last row).
fn listCapacity(term_rows: u16) u8 {
    if (term_rows <= 2) return 1;
    return @intCast(@min(term_rows - 2, 255));
}

/// Adjust scroll_offset so `selected` is visible within the viewport.
fn adjustScroll(selected: u8, current_offset: u8, total_count: u8, term_rows: u16) u8 {
    const cap = listCapacity(term_rows);
    var offset = current_offset;
    // Ensure selected is not above the visible window
    if (selected < offset) {
        offset = selected;
    }
    // Ensure selected is not below the visible window
    if (selected >= offset +| cap) {
        offset = selected -| (cap -| 1);
    }
    // Clamp so we don't scroll past the end
    if (total_count > cap) {
        const max_offset = total_count - cap;
        if (offset > max_offset) offset = max_offset;
    } else {
        offset = 0;
    }
    return offset;
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
    scroll_offset: u8,
    term_rows: u16,
    filter: []const u8,
    current_session_id: ?u32,
    icon_filter: []const u8,
    icon_session: []const u8,
    icon_new: []const u8,
    icon_active: []const u8,
) void {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    // Clear screen and move home
    pos += writeSlice(&buf, pos, "\x1b[2J\x1b[H");

    // Row 1: filter line — icon left-aligned, filter text starts at col 5
    // (same column as session names after "    " or "  • ")
    pos += writeSlice(&buf, pos, "  \x1b[90m");
    pos += writeSlice(&buf, pos, icon_filter);
    pos += writeSlice(&buf, pos, "\x1b[0m");
    // Pad so text starts at col 5: we've used 2 + icon_width cols so far
    const icon_width = displayWidth(icon_filter);
    const used = 2 + icon_width;
    if (used < 4) {
        const pad_needed = 4 - used;
        const spaces = "    "; // 4 spaces max
        pos += writeSlice(&buf, pos, spaces[0..pad_needed]);
    } else {
        pos += writeSlice(&buf, pos, " "); // at least one space separator
    }
    if (filter.len > 0) {
        pos += writeSlice(&buf, pos, filter);
    } else {
        pos += writeSlice(&buf, pos, "\x1b[90mfilter...\x1b[0m");
    }
    pos += writeSlice(&buf, pos, "\r\n");

    // Visible window of list items (sessions + "New session")
    const total_items: u8 = filtered_count +| 1; // +1 for "New session"
    const cap = listCapacity(term_rows);
    const vis_end: u8 = @intCast(@min(@as(u16, scroll_offset) + cap, total_items));

    // rows_used tracks how many rows we've emitted (filter = 1, each item = +1)
    var rows_used: u16 = 1; // filter line already emitted

    for (scroll_offset..vis_end) |item_idx| {
        if (item_idx < filtered_count) {
            // Session entry
            const e = &entries[filtered_indices[item_idx]];
            const is_selected = (item_idx == selected);
            const is_current = if (current_session_id) |cid| e.id == cid else false;

            if (is_selected) {
                pos += writeSlice(&buf, pos, "  \x1b[35m\xe2\x80\xa2\x1b[0m "); // • magenta
            } else {
                pos += writeSlice(&buf, pos, "    ");
            }

            if (icon_session.len > 0) {
                pos += writeSlice(&buf, pos, "\x1b[90m");
                pos += writeSlice(&buf, pos, icon_session);
                pos += writeSlice(&buf, pos, "\x1b[0m ");
            }

            if (is_current) {
                pos += writeSlice(&buf, pos, "\x1b[1m");
                pos += writeSlice(&buf, pos, e.getName());
                pos += writeSlice(&buf, pos, "\x1b[0m");
                pos += writeSlice(&buf, pos, " \x1b[90m");
                pos += writeSlice(&buf, pos, icon_active);
                pos += writeSlice(&buf, pos, "\x1b[0m");
            } else if (!e.alive) {
                pos += writeSlice(&buf, pos, "\x1b[90m");
                pos += writeSlice(&buf, pos, e.getName());
                pos += writeSlice(&buf, pos, "\x1b[0m");
            } else {
                pos += writeSlice(&buf, pos, e.getName());
            }
        } else {
            // "New session" entry (last item)
            if (item_idx == selected) {
                pos += writeSlice(&buf, pos, "  \x1b[35m\xe2\x80\xa2\x1b[0m "); // • magenta
            } else {
                pos += writeSlice(&buf, pos, "    ");
            }
            pos += writeSlice(&buf, pos, "\x1b[90m");
            pos += writeSlice(&buf, pos, icon_new);
            pos += writeSlice(&buf, pos, "\x1b[0m New session");
        }
        pos += writeSlice(&buf, pos, "\r\n");
        rows_used += 1;
    }

    // Pad with empty lines so footer lands on the last row
    while (rows_used + 1 < term_rows) {
        pos += writeSlice(&buf, pos, "\r\n");
        rows_used += 1;
    }

    // Footer on last row (no trailing \r\n)
    pos += writeSlice(&buf, pos, "  \x1b[90m\xe2\x86\x91\xe2\x86\x93 navigate \xe2\x80\xa2 esc close \xe2\x80\xa2 enter select \xe2\x80\xa2 del kill\x1b[0m");

    // Position cursor on filter line (row 1)
    // Text starts at col 5 (matching session name indent), cursor after last char
    var cursor_buf: [16]u8 = undefined;
    const cursor_col = 5 + filter.len + 1; // col 5 (text start) + filter length + 1 (CUP 1-based)
    const cursor_seq = std.fmt.bufPrint(&cursor_buf, "\x1b[1;{d}H", .{cursor_col}) catch "";
    pos += writeSlice(&buf, pos, cursor_seq);

    _ = posix.write(STDERR_FD, buf[0..pos]) catch {};
}

/// Count display width of a UTF-8 string (1 cell per codepoint).
fn displayWidth(s: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const byte = s[i];
        if (byte < 0x80) {
            width += 1;
            i += 1;
        } else if (byte < 0xC0) {
            i += 1; // continuation byte
        } else if (byte < 0xE0) {
            width += 1;
            i += 2;
        } else if (byte < 0xF0) {
            width += 1;
            i += 3;
        } else {
            width += 1;
            i += 4;
        }
    }
    return width;
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
