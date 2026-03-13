/// Minimal TOML in-place editing — set a key within a section while
/// preserving the rest of the file structure.
const std = @import("std");

/// Set a key within a TOML section, preserving file structure.
/// If `[section]` exists and contains `key = ...`, replace that line.
/// If `[section]` exists but has no `key`, insert after the section header.
/// If `[section]` doesn't exist, append `[section]\nnew_line\n`.
pub fn setSectionKey(allocator: std.mem.Allocator, content: []const u8, section: []const u8, key: []const u8, new_line: []const u8) ![]u8 {
    var section_header_end: ?usize = null;
    var key_line_start: ?usize = null;
    var key_line_end: usize = 0;
    var in_section = false;

    var start: usize = 0;
    while (start < content.len) {
        const rest = content[start..];
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const end = if (nl) |n| start + n else content.len;
        const line = content[start..end];
        const trimmed = std.mem.trimLeft(u8, line, " \t");

        if (trimmed.len > 0 and trimmed[0] == '[') {
            const close = std.mem.indexOfScalar(u8, trimmed, ']');
            if (close) |ci| {
                const sec_name = std.mem.trim(u8, trimmed[1..ci], " \t");
                if (std.mem.eql(u8, sec_name, section)) {
                    in_section = true;
                    section_header_end = if (nl != null) end + 1 else end;
                } else {
                    in_section = false;
                }
            }
        } else if (in_section and key_line_start == null) {
            if (std.mem.startsWith(u8, trimmed, key)) {
                const after_key = trimmed[key.len..];
                const after_trim = std.mem.trimLeft(u8, after_key, " \t");
                if (after_trim.len > 0 and after_trim[0] == '=') {
                    key_line_start = start;
                    key_line_end = end;
                }
            }
        }
        start = if (nl != null) end + 1 else content.len;
    }

    if (key_line_start) |ks| {
        const before = content[0..ks];
        const after = if (key_line_end < content.len) content[key_line_end..] else "";
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ before, new_line, after });
    } else if (section_header_end) |she| {
        const before = content[0..she];
        const after = content[she..];
        return std.fmt.allocPrint(allocator, "{s}{s}\n{s}", .{ before, new_line, after });
    } else {
        if (content.len > 0 and content[content.len - 1] != '\n') {
            return std.fmt.allocPrint(allocator, "{s}\n\n[{s}]\n{s}\n", .{ content, section, new_line });
        }
        return std.fmt.allocPrint(allocator, "{s}\n[{s}]\n{s}\n", .{ content, section, new_line });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "replace existing key" {
    const alloc = std.testing.allocator;
    const input = "[font]\nsize = 14\n\n[theme]\nname = \"default\"\n\n[cursor]\nshape = \"block\"\n";
    const result = try setSectionKey(alloc, input, "theme", "name", "name = \"dracula\"");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("[font]\nsize = 14\n\n[theme]\nname = \"dracula\"\n\n[cursor]\nshape = \"block\"\n", result);
}

test "section exists, key missing" {
    const alloc = std.testing.allocator;
    const input = "[theme]\nbackground = \"#000\"\n";
    const result = try setSectionKey(alloc, input, "theme", "name", "name = \"nord\"");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("[theme]\nname = \"nord\"\nbackground = \"#000\"\n", result);
}

test "no section at all" {
    const alloc = std.testing.allocator;
    const input = "[font]\nsize = 14\n";
    const result = try setSectionKey(alloc, input, "theme", "name", "name = \"gruvbox\"");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("[font]\nsize = 14\n\n[theme]\nname = \"gruvbox\"\n", result);
}

test "empty file" {
    const alloc = std.testing.allocator;
    const result = try setSectionKey(alloc, "", "theme", "name", "name = \"monokai\"");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("\n[theme]\nname = \"monokai\"\n", result);
}
