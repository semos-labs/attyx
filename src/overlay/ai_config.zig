const std = @import("std");
const build_options = @import("build_options");
const context_mod = @import("context.zig");
const InvocationType = context_mod.InvocationType;
const ContextBundle = context_mod.ContextBundle;

// ---------------------------------------------------------------------------
// Backend configuration (build-time, not user-configurable)
// ---------------------------------------------------------------------------

pub const base_url: []const u8 = if (std.mem.eql(u8, build_options.env, "production"))
    "https://app.semos.sh"
else
    "http://localhost:8085";

pub const connect_timeout_ms: u32 = 5_000;
pub const read_timeout_ms: u32 = 60_000;

// ---------------------------------------------------------------------------
// Action mapping
// ---------------------------------------------------------------------------

pub fn actionString(inv: InvocationType) []const u8 {
    return switch (inv) {
        .error_explain => "explain_error",
        .selection_explain => "explain_selection",
        .command_generate => "generate_command",
        .general => "summarize_output",
        .edit_selection => "edit_selection",
        .command_rewrite => "command_rewrite",
        .command_explain => "command_explain",
    };
}

/// Serialize a rewrite-mode request body for POST /v1/ai/execute.
/// Caller owns the returned slice.
pub fn serializeRewriteRequest(allocator: std.mem.Allocator, command: []const u8, user_request: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .{};
    errdefer list.deinit(allocator);
    const w = list.writer(allocator);

    try w.writeAll("{");
    try writeJsonString(w, "mode");
    try w.writeAll(":");
    try writeJsonString(w, "command_rewrite");
    try w.writeAll(",");
    try writeJsonString(w, "command");
    try w.writeAll(":");
    try writeJsonString(w, command);
    try w.writeAll(",");
    try writeJsonString(w, "user_request");
    try w.writeAll(":");
    try writeJsonString(w, user_request);
    try w.writeAll("}");

    return list.toOwnedSlice(allocator);
}

/// Serialize an explain-mode request body for POST /v1/ai/execute.
/// Caller owns the returned slice.
pub fn serializeExplainRequest(allocator: std.mem.Allocator, command: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .{};
    errdefer list.deinit(allocator);
    const w = list.writer(allocator);

    try w.writeAll("{");
    try writeJsonString(w, "action");
    try w.writeAll(":");
    try writeJsonString(w, "command_explain");

    // context object
    try w.writeAll(",");
    try writeJsonString(w, "context");
    try w.writeAll(":{");
    try writeJsonString(w, "command");
    try w.writeAll(":");
    try writeJsonString(w, command);
    try w.writeAll(",");
    try writeJsonString(w, "os");
    try w.writeAll(":");
    try writeJsonString(w, comptime osString());
    try w.writeAll("}");

    // client object
    try w.writeAll(",");
    try writeJsonString(w, "client");
    try w.writeAll(":{");
    try writeJsonString(w, "app");
    try w.writeAll(":");
    try writeJsonString(w, "attyx");
    try w.writeAll(",");
    try writeJsonString(w, "version");
    try w.writeAll(":");
    try writeJsonString(w, "0.1.0");
    try w.writeAll(",");
    try writeJsonString(w, "platform");
    try w.writeAll(":");
    try writeJsonString(w, comptime osString());
    try w.writeAll("}");

    // options
    try w.writeAll(",");
    try writeJsonString(w, "options");
    try w.writeAll(":{");
    try writeJsonString(w, "verbosity");
    try w.writeAll(":");
    try writeJsonString(w, "normal");
    try w.writeAll("}");

    try w.writeAll("}");

    return list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// JSON serialization
// ---------------------------------------------------------------------------

/// Serialize a request body for POST /v1/ai/execute/stream.
/// Caller owns the returned slice.
pub fn serializeRequest(allocator: std.mem.Allocator, bundle: *const ContextBundle) ![]u8 {
    var list: std.ArrayList(u8) = .{};
    errdefer list.deinit(allocator);
    const w = list.writer(allocator);

    try w.writeAll("{");

    // action
    try writeJsonString(w, "action");
    try w.writeAll(":");
    try writeJsonString(w, actionString(bundle.invocation));

    // context object
    try w.writeAll(",");
    try writeJsonString(w, "context");
    try w.writeAll(":{");

    var ctx_fields: u8 = 0;

    // command (cursor_line as proxy)
    if (bundle.cursor_line) |cl| {
        if (ctx_fields > 0) try w.writeAll(",");
        try writeJsonString(w, "command");
        try w.writeAll(":");
        try writeJsonString(w, cl);
        ctx_fields += 1;
    }

    // selection
    if (bundle.selection_text) |sel| {
        if (ctx_fields > 0) try w.writeAll(",");
        try writeJsonString(w, "selection");
        try w.writeAll(":");
        try writeJsonString(w, sel);
        ctx_fields += 1;
    }

    // stdout_tail (scrollback excerpt)
    if (bundle.scrollback_excerpt) |exc| {
        if (ctx_fields > 0) try w.writeAll(",");
        try writeJsonString(w, "stdout_tail");
        try w.writeAll(":");
        try writeJsonString(w, exc);
        ctx_fields += 1;
    }

    // edit intent
    if (bundle.edit_prompt) |ep| {
        if (ctx_fields > 0) try w.writeAll(",");
        try writeJsonString(w, "intent");
        try w.writeAll(":");
        try writeJsonString(w, ep);
        ctx_fields += 1;
    }

    // cwd — not available from terminal state, omit
    // os
    if (ctx_fields > 0) try w.writeAll(",");
    try writeJsonString(w, "os");
    try w.writeAll(":");
    try writeJsonString(w, comptime osString());
    ctx_fields += 1;

    // shell (title as proxy)
    if (bundle.title) |title| {
        if (ctx_fields > 0) try w.writeAll(",");
        try writeJsonString(w, "shell");
        try w.writeAll(":");
        try writeJsonString(w, title);
        ctx_fields += 1;
    }

    try w.writeAll("}"); // end context

    // client object
    try w.writeAll(",");
    try writeJsonString(w, "client");
    try w.writeAll(":{");
    try writeJsonString(w, "app");
    try w.writeAll(":");
    try writeJsonString(w, "attyx");
    try w.writeAll(",");
    try writeJsonString(w, "version");
    try w.writeAll(":");
    try writeJsonString(w, "0.1.0");
    try w.writeAll(",");
    try writeJsonString(w, "platform");
    try w.writeAll(":");
    try writeJsonString(w, comptime osString());
    try w.writeAll("}");

    // options
    try w.writeAll(",");
    try writeJsonString(w, "options");
    try w.writeAll(":{");
    try writeJsonString(w, "verbosity");
    try w.writeAll(":");
    try writeJsonString(w, "normal");
    try w.writeAll("}");

    try w.writeAll("}");

    return list.toOwnedSlice(allocator);
}

fn osString() []const u8 {
    return switch (@import("builtin").os.tag) {
        .macos => "macos",
        .linux => "linux",
        else => "unknown",
    };
}

/// Write a JSON-escaped string (with surrounding quotes) to the writer.
fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try writer.print("\\u{x:0>4}", .{ch});
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
    try writer.writeByte('"');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "actionString mapping" {
    try std.testing.expectEqualStrings("explain_error", actionString(.error_explain));
    try std.testing.expectEqualStrings("explain_selection", actionString(.selection_explain));
    try std.testing.expectEqualStrings("generate_command", actionString(.command_generate));
    try std.testing.expectEqualStrings("summarize_output", actionString(.general));
    try std.testing.expectEqualStrings("edit_selection", actionString(.edit_selection));
    try std.testing.expectEqualStrings("command_rewrite", actionString(.command_rewrite));
}

test "serializeRewriteRequest: basic JSON structure" {
    const alloc = std.testing.allocator;
    const json = try serializeRewriteRequest(alloc, "ls -la", "add color output");
    defer alloc.free(json);

    try std.testing.expect(json.len > 0);
    try std.testing.expectEqual(@as(u8, '{'), json[0]);
    try std.testing.expectEqual(@as(u8, '}'), json[json.len - 1]);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mode\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"command_rewrite\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"command\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ls -la\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"user_request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"add color output\"") != null);
}

test "serializeRequest: basic JSON structure" {
    const alloc = std.testing.allocator;

    var bundle = ContextBundle{
        .invocation = .general,
        .title = "bash",
        .selection_text = null,
        .scrollback_excerpt = "$ ls\nfile.txt",
        .scrollback_line_count = 2,
        .cursor_line = "$ ls -la",
        .grid_cols = 80,
        .grid_rows = 24,
        .alt_active = false,
        .allocator = alloc,
    };

    const json = try serializeRequest(alloc, &bundle);
    defer alloc.free(json);

    // Verify it's valid-looking JSON
    try std.testing.expect(json.len > 0);
    try std.testing.expectEqual(@as(u8, '{'), json[0]);
    try std.testing.expectEqual(@as(u8, '}'), json[json.len - 1]);

    // Check key fields are present
    try std.testing.expect(std.mem.indexOf(u8, json, "\"action\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"summarize_output\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"context\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"command\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"$ ls -la\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"client\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"attyx\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"options\"") != null);
}

test "serializeRequest: escapes special characters" {
    const alloc = std.testing.allocator;

    var bundle = ContextBundle{
        .invocation = .error_explain,
        .title = null,
        .selection_text = "line1\nline2\t\"quoted\"",
        .scrollback_excerpt = null,
        .scrollback_line_count = 0,
        .cursor_line = null,
        .grid_cols = 80,
        .grid_rows = 24,
        .alt_active = false,
        .allocator = alloc,
    };

    const json = try serializeRequest(alloc, &bundle);
    defer alloc.free(json);

    // Escaped newline and tab should be present
    try std.testing.expect(std.mem.indexOf(u8, json, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\\t") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\\\"quoted\\\"") != null);
}

test "serializeRequest: edit mode includes selection and intent" {
    const alloc = std.testing.allocator;

    var bundle = ContextBundle{
        .invocation = .edit_selection,
        .title = null,
        .selection_text = "hello world",
        .scrollback_excerpt = null,
        .scrollback_line_count = 0,
        .cursor_line = null,
        .grid_cols = 80,
        .grid_rows = 24,
        .alt_active = false,
        .edit_prompt = "make it uppercase",
        .allocator = alloc,
    };

    const json = try serializeRequest(alloc, &bundle);
    defer alloc.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"edit_selection\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"selection\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"hello world\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"intent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"make it uppercase\"") != null);
}

test "serializeRequest: null fields omitted" {
    const alloc = std.testing.allocator;

    var bundle = ContextBundle{
        .invocation = .general,
        .title = null,
        .selection_text = null,
        .scrollback_excerpt = null,
        .scrollback_line_count = 0,
        .cursor_line = null,
        .grid_cols = 80,
        .grid_rows = 24,
        .alt_active = false,
        .allocator = alloc,
    };

    const json = try serializeRequest(alloc, &bundle);
    defer alloc.free(json);

    // Fields with null values should not appear
    try std.testing.expect(std.mem.indexOf(u8, json, "\"command\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"selection\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"stdout_tail\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"shell\"") == null);

    // os and client should still be present
    try std.testing.expect(std.mem.indexOf(u8, json, "\"os\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"client\"") != null);
}

test "serializeExplainRequest: JSON structure" {
    const alloc = std.testing.allocator;
    const json = try serializeExplainRequest(alloc, "find . -name '*.zig'");
    defer alloc.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"action\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"command_explain\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"context\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"command\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "find . -name") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"client\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"options\"") != null);
}
