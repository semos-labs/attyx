const std = @import("std");
const Allocator = std.mem.Allocator;
const redaction = @import("redaction.zig");
const payload_mod = @import("payload.zig");

// ---------------------------------------------------------------------------
// Structured request input — the ONLY way to build an AI request
// ---------------------------------------------------------------------------

pub const AIRequestInput = union(enum) {
    general: GeneralInput,
    explain: ExplainInput,
    generate: GenerateInput,
    fix: FixInput,
    rewrite: RewriteInput,
    edit: EditInput,
};

pub const GeneralInput = struct {
    command: ?[]const u8 = null,
    selection: ?[]const u8 = null,
    scrollback_excerpt: ?[]const u8 = null,
    edit_prompt: ?[]const u8 = null,
    shell: ?[]const u8 = null,
};

pub const ExplainInput = struct {
    command: []const u8,
};

pub const GenerateInput = struct {
    intent: []const u8,
    shell: ?[]const u8 = null,
};

pub const FixInput = struct {
    command: []const u8,
    exit_code: u8,
    output: []const u8,
    shell: ?[]const u8 = null,
};

pub const RewriteInput = struct {
    command: []const u8,
    user_request: []const u8,
};

pub const EditInput = struct {
    selection: []const u8,
    intent: []const u8,
    shell: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// PreparedRequest — opaque wrapper, only produced by prepareRequest()
// ---------------------------------------------------------------------------

pub const PreparedRequest = struct {
    /// The serialized, redacted JSON body. Owned by this struct.
    body: []u8,
    report: payload_mod.PayloadReport,
    has_sensitive_content: bool,

    pub fn deinit(self: *PreparedRequest, allocator: Allocator) void {
        allocator.free(self.body);
    }

    /// Access the request body bytes. Only spawnSseStream should call this.
    pub fn bodySlice(self: *const PreparedRequest) []const u8 {
        return self.body;
    }
};

// ---------------------------------------------------------------------------
// Gateway — the single entry point for all AI requests
// ---------------------------------------------------------------------------

/// Prepare a safe AI request. Redacts sensitive content from any output/text
/// fields. Returns an opaque PreparedRequest that can be passed to the
/// streaming layer.
///
/// This is the ONLY sanctioned way to build request bodies.
/// Do NOT call serializeXxxRequest directly from feature code.
pub fn prepareRequest(allocator: Allocator, input: AIRequestInput) !PreparedRequest {
    return switch (input) {
        .general => |g| prepareGeneral(allocator, g),
        .explain => |e| prepareExplain(allocator, e),
        .generate => |g| prepareGenerate(allocator, g),
        .fix => |f| prepareFix(allocator, f),
        .rewrite => |r| prepareRewrite(allocator, r),
        .edit => |e| prepareEdit(allocator, e),
    };
}

// ---------------------------------------------------------------------------
// Per-mode preparation (redact + serialize)
// ---------------------------------------------------------------------------

fn prepareGeneral(allocator: Allocator, input: GeneralInput) !PreparedRequest {
    var report = payload_mod.PayloadReport{};
    var has_sensitive = false;

    // Redact scrollback excerpt
    var safe_scrollback: ?[]u8 = null;
    defer if (safe_scrollback) |s| allocator.free(s);
    if (input.scrollback_excerpt) |exc| {
        const limited = payload_mod.limitText(exc, 50, 16_000);
        var result = try redaction.redactText(allocator, limited);
        if (result.finding_count > 0) {
            has_sensitive = true;
            mergeFindings(&report, &result);
        }
        if (limited.len < exc.len) report.truncated = true;
        safe_scrollback = result.text;
    }

    // Redact selection if present
    var safe_selection: ?[]u8 = null;
    defer if (safe_selection) |s| allocator.free(s);
    if (input.selection) |sel| {
        var result = try redaction.redactText(allocator, sel);
        if (result.finding_count > 0) {
            has_sensitive = true;
            mergeFindings(&report, &result);
        }
        safe_selection = result.text;
    }

    const body = try serializeGeneralJson(
        allocator,
        input.command,
        safe_selection orelse input.selection,
        safe_scrollback orelse input.scrollback_excerpt,
        input.edit_prompt,
        input.shell,
    );

    report.bytes_after = body.len;

    return .{
        .body = body,
        .report = report,
        .has_sensitive_content = has_sensitive,
    };
}

fn prepareExplain(allocator: Allocator, input: ExplainInput) !PreparedRequest {
    // Explain is command-only, no output to redact
    const ai_config = @import("../overlay/ai_config.zig");
    const body = try ai_config.serializeExplainRequest(allocator, input.command);
    return .{
        .body = body,
        .report = .{},
        .has_sensitive_content = false,
    };
}

fn prepareGenerate(allocator: Allocator, input: GenerateInput) !PreparedRequest {
    // Generate is intent-only, no output to redact
    const ai_config = @import("../overlay/ai_config.zig");
    const body = try ai_config.serializeGenerateRequest(allocator, input.intent, input.shell);
    return .{
        .body = body,
        .report = .{},
        .has_sensitive_content = false,
    };
}

fn prepareFix(allocator: Allocator, input: FixInput) !PreparedRequest {
    var report = payload_mod.PayloadReport{};
    report.bytes_before = input.output.len;

    // Limit + redact output
    const limited = payload_mod.limitText(input.output, 50, 16_000);
    if (limited.len < input.output.len) report.truncated = true;

    var redact_result = try redaction.redactText(allocator, limited);
    defer allocator.free(redact_result.text);
    mergeFindings(&report, &redact_result);

    const has_sensitive = redact_result.finding_count > 0;

    const ai_config = @import("../overlay/ai_config.zig");
    const body = try ai_config.serializeFixRequest(
        allocator,
        input.command,
        input.exit_code,
        redact_result.text,
        input.shell,
    );

    report.bytes_after = body.len;

    return .{
        .body = body,
        .report = report,
        .has_sensitive_content = has_sensitive,
    };
}

fn prepareRewrite(allocator: Allocator, input: RewriteInput) !PreparedRequest {
    // Rewrite is command + user_request, no terminal output
    const ai_config = @import("../overlay/ai_config.zig");
    const body = try ai_config.serializeRewriteRequest(allocator, input.command, input.user_request);
    return .{
        .body = body,
        .report = .{},
        .has_sensitive_content = false,
    };
}

fn prepareEdit(allocator: Allocator, input: EditInput) !PreparedRequest {
    var report = payload_mod.PayloadReport{};

    // Redact selection text
    var redact_result = try redaction.redactText(allocator, input.selection);
    defer allocator.free(redact_result.text);
    mergeFindings(&report, &redact_result);

    const has_sensitive = redact_result.finding_count > 0;

    // Build an edit-style JSON body with redacted selection
    const body = try serializeEditJson(allocator, redact_result.text, input.intent, input.shell);
    report.bytes_after = body.len;

    return .{
        .body = body,
        .report = report,
        .has_sensitive_content = has_sensitive,
    };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn mergeFindings(report: *payload_mod.PayloadReport, result: *const redaction.RedactionResult) void {
    for (result.findings[0..result.finding_count]) |f| {
        if (report.finding_count < redaction.max_findings) {
            report.findings[report.finding_count] = f;
            report.finding_count += 1;
        }
    }
}

/// Check if a mode sends terminal output / selection content (needs review).
pub fn needsReview(input: AIRequestInput) bool {
    return switch (input) {
        .fix => true,
        .general => |g| g.scrollback_excerpt != null or g.selection != null,
        .edit => true,
        .explain, .generate, .rewrite => false,
    };
}

// ---------------------------------------------------------------------------
// JSON serializers for modes that need custom redacted serialization
// ---------------------------------------------------------------------------

fn serializeGeneralJson(
    allocator: Allocator,
    command: ?[]const u8,
    selection: ?[]const u8,
    scrollback: ?[]const u8,
    edit_prompt: ?[]const u8,
    shell: ?[]const u8,
) ![]u8 {
    // Delegate to existing serializer via a synthetic bundle-like approach
    // We rebuild the JSON manually here to keep the gateway self-contained
    const ai_config = @import("../overlay/ai_config.zig");
    _ = ai_config;

    var list: std.ArrayList(u8) = .{};
    errdefer list.deinit(allocator);
    const w = list.writer(allocator);

    try w.writeAll("{");
    try writeJsonKV(w, "action", "summarize_output");

    try w.writeAll(",\"context\":{");
    var fields: u8 = 0;

    if (command) |cmd| {
        if (fields > 0) try w.writeByte(',');
        try writeJsonKV(w, "command", cmd);
        fields += 1;
    }
    if (selection) |sel| {
        if (fields > 0) try w.writeByte(',');
        try writeJsonKV(w, "selection", sel);
        fields += 1;
    }
    if (scrollback) |sb| {
        if (fields > 0) try w.writeByte(',');
        try writeJsonKV(w, "stdout_tail", sb);
        fields += 1;
    }
    if (edit_prompt) |ep| {
        if (fields > 0) try w.writeByte(',');
        try writeJsonKV(w, "intent", ep);
        fields += 1;
    }
    if (fields > 0) try w.writeByte(',');
    try writeJsonKV(w, "os", comptime osString());
    fields += 1;
    if (shell) |s| {
        try w.writeByte(',');
        try writeJsonKV(w, "shell", s);
    }
    try w.writeByte('}');

    // client + options
    try writeClientAndOptions(w);
    try w.writeByte('}');

    return list.toOwnedSlice(allocator);
}

fn serializeEditJson(allocator: Allocator, selection: []const u8, intent: []const u8, shell: ?[]const u8) ![]u8 {
    var list: std.ArrayList(u8) = .{};
    errdefer list.deinit(allocator);
    const w = list.writer(allocator);

    try w.writeAll("{");
    try writeJsonKV(w, "action", "edit_selection");

    try w.writeAll(",\"context\":{");
    try writeJsonKV(w, "selection", selection);
    try w.writeByte(',');
    try writeJsonKV(w, "intent", intent);
    try w.writeByte(',');
    try writeJsonKV(w, "os", comptime osString());
    if (shell) |s| {
        try w.writeByte(',');
        try writeJsonKV(w, "shell", s);
    }
    try w.writeByte('}');

    try writeClientAndOptions(w);
    try w.writeByte('}');

    return list.toOwnedSlice(allocator);
}

fn writeJsonKV(writer: anytype, key: []const u8, value: []const u8) !void {
    try writeJsonString(writer, key);
    try writer.writeByte(':');
    try writeJsonString(writer, value);
}

fn writeClientAndOptions(writer: anytype) !void {
    try writer.writeAll(",\"client\":{");
    try writeJsonKV(writer, "app", "attyx");
    try writer.writeByte(',');
    try writeJsonKV(writer, "version", "0.1.0");
    try writer.writeByte(',');
    try writeJsonKV(writer, "platform", comptime osString());
    try writer.writeAll("},\"options\":{");
    try writeJsonKV(writer, "verbosity", "normal");
    try writer.writeByte('}');
}

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

fn osString() []const u8 {
    return switch (@import("builtin").os.tag) {
        .macos => "macos",
        .linux => "linux",
        else => "unknown",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "prepareRequest: explain has no sensitive content" {
    const alloc = std.testing.allocator;
    var req = try prepareRequest(alloc, .{ .explain = .{ .command = "ls -la" } });
    defer req.deinit(alloc);
    try std.testing.expect(!req.has_sensitive_content);
    try std.testing.expect(req.bodySlice().len > 0);
    try std.testing.expectEqual(@as(u8, 0), req.report.finding_count);
}

test "prepareRequest: generate has no sensitive content" {
    const alloc = std.testing.allocator;
    var req = try prepareRequest(alloc, .{ .generate = .{ .intent = "list files", .shell = "zsh" } });
    defer req.deinit(alloc);
    try std.testing.expect(!req.has_sensitive_content);
}

test "prepareRequest: fix redacts output secrets" {
    const alloc = std.testing.allocator;
    var req = try prepareRequest(alloc, .{ .fix = .{
        .command = "env",
        .exit_code = 1,
        .output = "PATH=/usr/bin\nDB_PASSWORD=hunter2\nfailed",
        .shell = "bash",
    } });
    defer req.deinit(alloc);
    try std.testing.expect(req.has_sensitive_content);
    try std.testing.expect(req.report.finding_count > 0);
    // Body should NOT contain the raw password
    try std.testing.expect(std.mem.indexOf(u8, req.bodySlice(), "hunter2") == null);
}

test "prepareRequest: rewrite has no output" {
    const alloc = std.testing.allocator;
    var req = try prepareRequest(alloc, .{ .rewrite = .{
        .command = "ls -la",
        .user_request = "add color",
    } });
    defer req.deinit(alloc);
    try std.testing.expect(!req.has_sensitive_content);
}

test "prepareRequest: general with scrollback redacts" {
    const alloc = std.testing.allocator;
    var req = try prepareRequest(alloc, .{ .general = .{
        .command = "env",
        .scrollback_excerpt = "TOKEN=secret123abc\nother line",
        .shell = "zsh",
    } });
    defer req.deinit(alloc);
    try std.testing.expect(req.has_sensitive_content);
    try std.testing.expect(std.mem.indexOf(u8, req.bodySlice(), "secret123abc") == null);
}

test "needsReview: output-aware modes" {
    try std.testing.expect(needsReview(.{ .fix = .{ .command = "x", .exit_code = 1, .output = "y" } }));
    try std.testing.expect(needsReview(.{ .general = .{ .scrollback_excerpt = "data" } }));
    try std.testing.expect(needsReview(.{ .edit = .{ .selection = "x", .intent = "y" } }));
    try std.testing.expect(!needsReview(.{ .explain = .{ .command = "ls" } }));
    try std.testing.expect(!needsReview(.{ .generate = .{ .intent = "list" } }));
    try std.testing.expect(!needsReview(.{ .rewrite = .{ .command = "ls", .user_request = "add color" } }));
}

test "prepareRequest: fix truncates long output" {
    const alloc = std.testing.allocator;
    var big_buf: [20000]u8 = undefined;
    @memset(&big_buf, 'x');
    var i: usize = 49;
    while (i < big_buf.len) : (i += 50) big_buf[i] = '\n';
    var req = try prepareRequest(alloc, .{ .fix = .{
        .command = "test",
        .exit_code = 1,
        .output = &big_buf,
        .shell = "bash",
    } });
    defer req.deinit(alloc);
    try std.testing.expect(req.report.truncated);
}
