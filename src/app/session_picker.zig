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
const picker_render = @import("session_picker_render.zig");

extern "c" fn tcgetattr(fd: c_int, termios: *Termios) c_int;
extern "c" fn tcsetattr(fd: c_int, actions: c_int, termios: *const Termios) c_int;
extern "c" fn isatty(fd: c_int) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

var g_resized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn sigwinchHandler(_: c_int) callconv(.c) void {
    g_resized.store(true, .release);
}

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

pub const Entry = struct {
    id: u32,
    name: [64]u8 = undefined,
    name_len: u8 = 0,
    alive: bool = false,

    pub fn getName(self: *const Entry) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const max_entries = 32;

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
    fetchSessionList(sock_fd, &entries, &entry_count);

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

    // Handle SIGWINCH for live resize
    const sa = std.posix.Sigaction{
        .handler = .{ .handler = sigwinchHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.WINCH, &sa, null);

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
    var confirm_kill: ?u8 = null; // filtered index of session pending kill confirmation
    var rename_buf: [64]u8 = .{0} ** 64;
    var rename_len: u8 = 0;
    var renaming: ?u8 = null; // filtered index of session being renamed

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

    var term_rows = getTermRows();
    scroll_offset = adjustScroll(selected, scroll_offset, filtered_count +| 1, term_rows);
    picker_render.render(&entries, entry_count, &filtered_indices, filtered_count, selected, scroll_offset, term_rows, filter_buf[0..filter_len], current_session_id, icon_filter, icon_session, icon_new, icon_active, confirm_kill, renaming, rename_buf[0..rename_len]);

    while (true) {
        // Poll stdin with timeout so we can check the SIGWINCH flag.
        var poll_fds = [1]posix.pollfd{.{ .fd = STDIN_FD, .events = 0x0001, .revents = 0 }};
        _ = posix.poll(&poll_fds, 100) catch {};

        // Handle resize (re-render even if no key was pressed)
        if (g_resized.swap(false, .acq_rel)) {
            term_rows = getTermRows();
            scroll_offset = adjustScroll(selected, scroll_offset, filtered_count +| 1, term_rows);
            picker_render.render(&entries, entry_count, &filtered_indices, filtered_count, selected, scroll_offset, term_rows, filter_buf[0..filter_len], current_session_id, icon_filter, icon_session, icon_new, icon_active, confirm_kill, renaming, rename_buf[0..rename_len]);
        }

        if (poll_fds[0].revents & 0x0001 == 0) continue;

        var key_buf: [16]u8 = undefined;
        const n = posix.read(STDIN_FD, &key_buf) catch break;
        if (n == 0) break;

        const key = key_buf[0..n];
        const total_count: u8 = filtered_count + 1; // +1 for "New session"

        // Rename mode: Enter commits, Esc cancels, Backspace deletes, printable appends.
        // Check key[0] regardless of key.len for Enter/Backspace since terminals
        // may deliver Enter as multi-byte (\r\n).
        if (renaming != null) {
            if (key[0] == 0x0d or key[0] == 0x0a) {
                // Enter — commit rename
                if (rename_len > 0) {
                    const ri = renaming.?;
                    if (ri < filtered_count) {
                        const e = &entries[filtered_indices[ri]];
                        sendRename(sock_fd, e.id, rename_buf[0..rename_len]);
                        var no_fds = [0]posix.pollfd{};
                        _ = posix.poll(&no_fds, 50) catch {};
                        fetchSessionList(sock_fd, &entries, &entry_count);
                        filtered_count = applyFilter(&entries, entry_count, filter_buf[0..filter_len], &filtered_indices);
                        const total = filtered_count +| 1;
                        if (selected >= total) selected = if (filtered_count > 0) filtered_count - 1 else 0;
                    }
                }
                renaming = null;
            } else if (key.len == 1 and key[0] == 0x1b) {
                // Esc (single byte only — not escape sequences)
                renaming = null;
            } else if (key[0] == 0x7f or key[0] == 0x08) {
                // Backspace
                if (rename_len > 0) rename_len -= 1;
            } else if (key.len == 1 and key[0] >= 0x20 and key[0] < 0x7f) {
                // Printable character
                if (rename_len < 63) {
                    rename_buf[rename_len] = key[0];
                    rename_len += 1;
                }
            }
            // All other keys consumed (no navigation during rename)
        } else if (confirm_kill != null) {
        // Confirmation mode: y confirms kill, Esc exits picker, anything else cancels
            if (key.len == 1 and (key[0] == 'y' or key[0] == 'Y')) {
                killAndRefresh(sock_fd, &entries, &entry_count, &filtered_count, &filtered_indices, &selected, filtered_count, filter_buf[0..filter_len]);
                confirm_kill = null;
            } else if (key.len == 1 and key[0] == 0x1b) {
                std.process.exit(1);
            } else if (key.len >= 2 and key[0] == 0x1b) {
                std.process.exit(1);
            } else {
                confirm_kill = null;
            }
        } else if (key.len == 1) {
            switch (key[0]) {
                0x1b, 0x03 => { // Esc / Ctrl-C
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
                0x18 => { // Ctrl-X — kill selected session
                    if (filtered_count > 0 and selected < filtered_count) {
                        confirm_kill = selected;
                    }
                },
                0x12 => { // Ctrl-R — rename selected session
                    if (filtered_count > 0 and selected < filtered_count) {
                        const e = &entries[filtered_indices[selected]];
                        const nlen = e.name_len;
                        @memcpy(rename_buf[0..nlen], e.name[0..nlen]);
                        rename_len = nlen;
                        renaming = selected;
                    }
                },
                0x7f, 0x08 => { // Backspace / Delete key
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
            // Forward Delete key — request kill confirmation
            if (filtered_count > 0 and selected < filtered_count) {
                confirm_kill = selected;
            }
        } else if (key.len >= 2 and key[0] == 0x1b) {
            // Esc + something — treat as Esc
            std.process.exit(1);
        }

        term_rows = getTermRows();
        scroll_offset = adjustScroll(selected, scroll_offset, filtered_count +| 1, term_rows);
        picker_render.render(&entries, entry_count, &filtered_indices, filtered_count, selected, scroll_offset, term_rows, filter_buf[0..filter_len], current_session_id, icon_filter, icon_session, icon_new, icon_active, confirm_kill, renaming, rename_buf[0..rename_len]);
    }
}

/// Kill the selected session and refresh the list inline.
fn killAndRefresh(
    sock_fd: posix.fd_t,
    entries: *[max_entries]Entry,
    entry_count: *u8,
    filtered_count: *u8,
    filtered_indices: *[max_entries]u8,
    selected: *u8,
    current_filtered: u8,
    filter: []const u8,
) void {
    if (current_filtered == 0 or selected.* >= current_filtered) return;
    const e = &entries[filtered_indices[selected.*]];
    sendKill(sock_fd, e.id);
    // Give daemon time to process the kill before requesting the list.
    var no_fds = [0]posix.pollfd{};
    _ = posix.poll(&no_fds, 50) catch {};
    fetchSessionList(sock_fd, entries, entry_count);
    filtered_count.* = applyFilter(entries, entry_count.*, filter, filtered_indices);
    const total = filtered_count.* +| 1;
    if (selected.* >= total) selected.* = if (filtered_count.* > 0) filtered_count.* - 1 else 0;
}

/// Compute visible list rows: term_rows minus top pad, filter, bottom pad, and footer.
pub fn listCapacity(term_rows: u16) u8 {
    if (term_rows <= 4) return 1;
    return @intCast(@min(term_rows - 4, 255));
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

/// Fetch session list from daemon over an existing socket.
fn fetchSessionList(sock_fd: posix.fd_t, entries: *[max_entries]Entry, entry_count: *u8) void {
    // Drain any unexpected data sitting in the socket buffer before sending.
    drainSocket(sock_fd);

    var hdr: [protocol.header_size]u8 = undefined;
    protocol.encodeHeader(&hdr, .list, 0);
    _ = posix.write(sock_fd, &hdr) catch return;

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
            // Try to parse messages, skipping non-session_list ones.
            while (read_len >= protocol.header_size) {
                const h = protocol.decodeHeader(read_buf[0..protocol.header_size]) catch {
                    // Corrupt header — skip a byte and retry.
                    shiftBuf(&read_buf, &read_len, 1);
                    continue;
                };
                const total = protocol.header_size + h.payload_len;
                if (read_len < total) break; // need more data
                if (h.msg_type == .session_list) {
                    const payload = read_buf[protocol.header_size..total];
                    var decoded: [max_entries]protocol.DecodedListEntry = undefined;
                    const count = protocol.decodeSessionList(payload, &decoded) catch break;
                    entry_count.* = @intCast(@min(count, max_entries));
                    for (0..entry_count.*) |i| {
                        entries[i].id = decoded[i].id;
                        entries[i].alive = decoded[i].alive;
                        const nlen: u8 = @intCast(@min(decoded[i].name.len, 64));
                        @memcpy(entries[i].name[0..nlen], decoded[i].name[0..nlen]);
                        entries[i].name_len = nlen;
                    }
                    return;
                }
                // Not session_list — skip this message and keep looking.
                shiftBuf(&read_buf, &read_len, total);
            }
        }
        timeout += 100;
    }
}

/// Non-blocking drain of any pending data on the socket.
fn drainSocket(sock_fd: posix.fd_t) void {
    var drain_buf: [4096]u8 = undefined;
    while (true) {
        var fds = [1]posix.pollfd{.{ .fd = sock_fd, .events = 0x0001, .revents = 0 }};
        _ = posix.poll(&fds, 0) catch return;
        if (fds[0].revents & 0x0001 == 0) return;
        const n = posix.read(sock_fd, &drain_buf) catch return;
        if (n == 0) return;
    }
}

/// Shift read_buf left by `amount` bytes, updating read_len.
fn shiftBuf(buf: *[4096]u8, len: *usize, amount: usize) void {
    if (amount >= len.*) {
        len.* = 0;
        return;
    }
    const remaining = len.* - amount;
    std.mem.copyForwards(u8, buf[0..remaining], buf[amount..len.*]);
    len.* = remaining;
}

/// Send a kill command for the given session ID.
fn sendKill(sock_fd: posix.fd_t, session_id: u32) void {
    var payload_buf: [4]u8 = undefined;
    const payload = protocol.encodeKill(&payload_buf, session_id) catch return;
    var msg_buf: [protocol.header_size + 4]u8 = undefined;
    protocol.encodeHeader(msg_buf[0..protocol.header_size], .kill, @intCast(payload.len));
    @memcpy(msg_buf[protocol.header_size..][0..payload.len], payload);
    _ = posix.write(sock_fd, msg_buf[0 .. protocol.header_size + payload.len]) catch {};
}

/// Send a rename command for the given session ID.
fn sendRename(sock_fd: posix.fd_t, session_id: u32, new_name: []const u8) void {
    var payload_buf: [70]u8 = undefined; // 4 + 2 + 64
    const payload = protocol.encodeRename(&payload_buf, session_id, new_name) catch return;
    var msg_buf: [protocol.header_size + 70]u8 = undefined;
    protocol.encodeHeader(msg_buf[0..protocol.header_size], .rename, @intCast(payload.len));
    @memcpy(msg_buf[protocol.header_size..][0..payload.len], payload);
    _ = posix.write(sock_fd, msg_buf[0 .. protocol.header_size + payload.len]) catch {};
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
