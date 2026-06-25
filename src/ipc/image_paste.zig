// Attyx — image drag/paste payload builder
//
// Builds the exact byte sequence that dropping an image file onto a pane
// produces: the shell-quoted file path, optionally wrapped in bracketed-paste
// markers. This mirrors the native drag-and-drop handler (macos_input_ime.m)
// so a path injected over IPC is indistinguishable from a real drop — which is
// how TUIs like Claude Code pick up an image attachment.
//
// Pure and allocation-free: takes a caller buffer, returns a slice of it.

const std = @import("std");
const builtin = @import("builtin");
const input = @import("attyx").input;

pub const Error = error{BufferTooSmall};

/// Shell-quote a file path so it survives as a single token. POSIX wraps in
/// single quotes, escaping embedded quotes as '\''; Windows wraps in double
/// quotes (image paths rarely contain a literal '"', so no escaping is done).
pub fn quotePath(path: []const u8, out: []u8) Error![]const u8 {
    const q: u8 = if (builtin.os.tag == .windows) '"' else '\'';
    var n: usize = 0;
    if (n >= out.len) return error.BufferTooSmall;
    out[n] = q;
    n += 1;
    if (builtin.os.tag == .windows) {
        if (n + path.len > out.len) return error.BufferTooSmall;
        @memcpy(out[n..][0..path.len], path);
        n += path.len;
    } else {
        for (path) |c| {
            if (c == '\'') {
                const esc = "'\\''"; // ' -> '\''
                if (n + esc.len > out.len) return error.BufferTooSmall;
                @memcpy(out[n..][0..esc.len], esc);
                n += esc.len;
            } else {
                if (n >= out.len) return error.BufferTooSmall;
                out[n] = c;
                n += 1;
            }
        }
    }
    if (n >= out.len) return error.BufferTooSmall;
    out[n] = q;
    n += 1;
    return out[0..n];
}

/// Build the full injection payload: the quoted path, wrapped in bracketed
/// paste when the target pane has it enabled. Writes into `out`.
pub fn buildPaste(bracketed: bool, path: []const u8, out: []u8) Error![]const u8 {
    var qbuf: [2 * std.fs.max_path_bytes + 2]u8 = undefined;
    const quoted = try quotePath(path, &qbuf);
    return input.wrapPaste(bracketed, quoted, out);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "quotePath wraps a plain path" {
    var buf: [256]u8 = undefined;
    const q = try quotePath("/tmp/shot.png", &buf);
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("\"/tmp/shot.png\"", q);
    } else {
        try std.testing.expectEqualStrings("'/tmp/shot.png'", q);
    }
}

test "quotePath escapes embedded single quote (posix)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var buf: [256]u8 = undefined;
    const q = try quotePath("/tmp/it's.png", &buf);
    try std.testing.expectEqualStrings("'/tmp/it'\\''s.png'", q);
}

test "buildPaste wraps in bracketed paste when enabled" {
    var buf: [256]u8 = undefined;
    const b = try buildPaste(true, "/a/b.png", &buf);
    const q: u8 = if (builtin.os.tag == .windows) '"' else '\'';
    var expected: [256]u8 = undefined;
    const e = std.fmt.bufPrint(&expected, "\x1b[200~{c}/a/b.png{c}\x1b[201~", .{ q, q }) catch unreachable;
    try std.testing.expectEqualStrings(e, b);
}

test "buildPaste omits markers when bracketed paste disabled" {
    var buf: [256]u8 = undefined;
    const b = try buildPaste(false, "/a/b.png", &buf);
    const q: u8 = if (builtin.os.tag == .windows) '"' else '\'';
    var expected: [256]u8 = undefined;
    const e = std.fmt.bufPrint(&expected, "{c}/a/b.png{c}", .{ q, q }) catch unreachable;
    try std.testing.expectEqualStrings(e, b);
}

test "quotePath reports BufferTooSmall" {
    var buf: [4]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, quotePath("/too/long/path", &buf));
}
