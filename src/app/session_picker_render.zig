/// Rendering logic for the session picker TUI.
const std = @import("std");
const posix = std.posix;
const picker = @import("session_picker.zig");

const Entry = picker.Entry;
const max_entries = picker.max_entries;
const STDERR_FD: posix.fd_t = 2;

pub fn render(
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
    icon_recent: []const u8,
    confirm_kill: ?u8,
    renaming: ?u8,
    rename_text: []const u8,
) void {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    // Clear screen and move home
    pos += writeSlice(&buf, pos, "\x1b[2J\x1b[H");

    // Top padding (1 empty row)
    pos += writeSlice(&buf, pos, "\r\n");

    // Row 2: filter line — icon left-aligned, filter text starts at col 5
    pos += writeSlice(&buf, pos, "  \x1b[90m");
    pos += writeSlice(&buf, pos, icon_filter);
    pos += writeSlice(&buf, pos, "\x1b[0m");
    const icon_width = displayWidth(icon_filter);
    const used = 2 + icon_width;
    if (used < 4) {
        const pad_needed = 4 - used;
        const spaces = "    ";
        pos += writeSlice(&buf, pos, spaces[0..pad_needed]);
    } else {
        pos += writeSlice(&buf, pos, " ");
    }
    if (filter.len > 0) {
        pos += writeSlice(&buf, pos, filter);
    } else {
        pos += writeSlice(&buf, pos, "\x1b[90mfilter...\x1b[0m");
    }
    pos += writeSlice(&buf, pos, "\r\n");

    // Visible window of list items (sessions + "New session")
    const total_items: u8 = filtered_count +| 1;
    const cap = picker.listCapacity(term_rows);
    const vis_end: u8 = @intCast(@min(@as(u16, scroll_offset) + cap, total_items));

    var rows_used: u16 = 2; // top pad + filter

    for (scroll_offset..vis_end) |item_idx| {
        if (item_idx < filtered_count) {
            const e = &entries[filtered_indices[item_idx]];
            const is_selected = (item_idx == selected);
            const is_current = if (current_session_id) |cid| e.id == cid else false;

            if (is_selected) {
                pos += writeSlice(&buf, pos, "  \x1b[35m\xe2\x80\xa2\x1b[0m ");
            } else {
                pos += writeSlice(&buf, pos, "    ");
            }

            // Icon: active > recent > session
            const icon = if (is_current and icon_active.len > 0)
                icon_active
            else if (!e.alive and icon_recent.len > 0)
                icon_recent
            else
                icon_session;
            if (icon.len > 0) {
                pos += writeSlice(&buf, pos, "\x1b[90m");
                pos += writeSlice(&buf, pos, icon);
                pos += writeSlice(&buf, pos, "\x1b[0m ");
            }

            if (!e.alive) {
                pos += writeSlice(&buf, pos, "\x1b[90m");
                pos += writeSlice(&buf, pos, e.getName());
                pos += writeSlice(&buf, pos, "\x1b[0m");
            } else if (is_current) {
                pos += writeSlice(&buf, pos, "\x1b[1m");
                pos += writeSlice(&buf, pos, e.getName());
                pos += writeSlice(&buf, pos, "\x1b[0m");
            } else {
                pos += writeSlice(&buf, pos, e.getName());
            }
        } else {
            if (item_idx == selected) {
                pos += writeSlice(&buf, pos, "  \x1b[35m\xe2\x80\xa2\x1b[0m ");
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

    // Pad with empty lines so footer lands on the second-to-last row
    while (rows_used + 2 < term_rows) {
        pos += writeSlice(&buf, pos, "\r\n");
        rows_used += 1;
    }

    // Footer (second-to-last row, bottom padding row follows)
    if (renaming != null) {
        pos += writeSlice(&buf, pos, "  \x1b[33mRename:\x1b[0m ");
        pos += writeSlice(&buf, pos, rename_text);

        var cursor_buf2: [16]u8 = undefined;
        const rename_col = 2 + 7 + 1 + rename_text.len + 1; // "  " + "Rename:" + " " + text + 1-based
        const footer_row = if (term_rows >= 2) term_rows - 1 else term_rows;
        const cursor_seq2 = std.fmt.bufPrint(&cursor_buf2, "\x1b[{d};{d}H", .{ footer_row, rename_col }) catch "";
        pos += writeSlice(&buf, pos, cursor_seq2);
        pos += writeSlice(&buf, pos, "\x1b[?25h");
    } else if (confirm_kill) |ck| {
        if (ck < filtered_count) {
            const e = &entries[filtered_indices[ck]];
            pos += writeSlice(&buf, pos, "  \x1b[31mKill\x1b[0m \"\x1b[1m");
            pos += writeSlice(&buf, pos, e.getName());
            pos += writeSlice(&buf, pos, "\x1b[0m\"? \x1b[90my to confirm\x1b[0m");
        }
        pos += writeSlice(&buf, pos, "\x1b[?25l");
    } else {
        pos += writeSlice(&buf, pos, "  \x1b[90m\xe2\x86\x91\xe2\x86\x93 navigate \xe2\x80\xa2 enter select \xe2\x80\xa2 ^R rename \xe2\x80\xa2 ^X delete \xe2\x80\xa2 ^C close\x1b[0m");

        var cursor_buf: [16]u8 = undefined;
        const cursor_col = 5 + filter.len + 1;
        const cursor_seq = std.fmt.bufPrint(&cursor_buf, "\x1b[2;{d}H", .{cursor_col}) catch "";
        pos += writeSlice(&buf, pos, cursor_seq);
        pos += writeSlice(&buf, pos, "\x1b[?25h");
    }

    _ = posix.write(STDERR_FD, buf[0..pos]) catch {};
}

/// Count display width of a UTF-8 string (1 cell per codepoint).
pub fn displayWidth(s: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const byte = s[i];
        if (byte < 0x80) {
            width += 1;
            i += 1;
        } else if (byte < 0xC0) {
            i += 1;
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
