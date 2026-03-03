const std = @import("std");
const ai_auth = @import("ai_auth.zig");
const ai_stream = @import("ai_stream.zig");

const SseThread = ai_stream.SseThread;

// ---------------------------------------------------------------------------
// Final-response formatting (extracted from ai_stream.zig)
// ---------------------------------------------------------------------------

pub fn formatFinalResponse(self: *SseThread, data: []const u8) void {
    // Edit/rewrite response: edited_text or rewritten_command → push raw replacement + \0 + summary
    if (ai_auth.extractJsonString(data, "edited_text") orelse ai_auth.extractJsonString(data, "rewritten_command")) |replacement| {
        _ = self.delta_ring.push(replacement);
        _ = self.delta_ring.push(&[_]u8{0}); // null separator
        if (ai_auth.extractJsonString(data, "summary")) |s| {
            _ = self.delta_ring.push(s);
        }
        return;
    }

    // Generate response: "command" field present without "summary" (general responses have summary)
    if (ai_auth.extractJsonString(data, "command")) |cmd| {
        if (ai_auth.extractJsonString(data, "summary") == null) {
            _ = self.delta_ring.push(cmd);
            _ = self.delta_ring.push(&[_]u8{0}); // null separator
            if (ai_auth.extractJsonString(data, "notes")) |n| {
                _ = self.delta_ring.push(n);
            }
            return;
        }
    }

    // Explain response: breakdown array present → push summary \0 breakdown_lines \0 notes
    if (findJsonArrayStart(data, "breakdown") != null) {
        if (ai_auth.extractJsonString(data, "summary")) |s| {
            _ = self.delta_ring.push(s);
        }
        _ = self.delta_ring.push(&[_]u8{0}); // separator after summary
        pushExplainBreakdown(self, data);
        _ = self.delta_ring.push(&[_]u8{0}); // separator after breakdown
        if (ai_auth.extractJsonString(data, "notes")) |n| {
            _ = self.delta_ring.push(n);
        }
        return;
    }

    if (ai_auth.extractJsonString(data, "summary")) |summary| {
        _ = self.delta_ring.push(summary);
        _ = self.delta_ring.push("\n");
    }
    if (ai_auth.extractJsonString(data, "explanation")) |explanation| {
        _ = self.delta_ring.push("\n");
        _ = self.delta_ring.push(explanation);
        _ = self.delta_ring.push("\n");
    }
    pushJsonStringArray(self, data, "highlights", "Highlights");
    pushJsonStringArray(self, data, "causes", "Causes");
    pushJsonStringArray(self, data, "key_points", "Key Points");
    pushJsonStringArray(self, data, "errors", "Errors");
    pushJsonStringArray(self, data, "warnings", "Warnings");
    pushJsonStringArray(self, data, "next_steps", "Next Steps");
    pushJsonStringArray(self, data, "notes", "Notes");
    pushJsonCommandArray(self, data);
}

pub fn findJsonArrayStart(json: []const u8, key: []const u8) ?usize {
    var pos: usize = 0;
    while (pos + key.len + 4 < json.len) : (pos += 1) {
        if (json[pos] == '"' and
            pos + 1 + key.len < json.len and
            std.mem.eql(u8, json[pos + 1 .. pos + 1 + key.len], key) and
            json[pos + 1 + key.len] == '"')
        {
            var vpos = pos + 2 + key.len;
            while (vpos < json.len and (json[vpos] == ' ' or json[vpos] == ':')) vpos += 1;
            if (vpos < json.len and json[vpos] == '[') return vpos + 1;
        }
    }
    return null;
}

fn pushJsonStringArray(self: *SseThread, json: []const u8, key: []const u8, header: []const u8) void {
    const start = findJsonArrayStart(json, key) orelse return;
    var header_pushed = false;
    var i = start;
    while (i < json.len) {
        if (json[i] == ']') break;
        if (json[i] == '"') {
            const s = i + 1;
            var e = s;
            while (e < json.len and json[e] != '"') {
                if (json[e] == '\\') e += 1;
                e += 1;
            }
            if (e > s) {
                if (!header_pushed) {
                    _ = self.delta_ring.push("\n");
                    _ = self.delta_ring.push(header);
                    _ = self.delta_ring.push(":\n");
                    header_pushed = true;
                }
                _ = self.delta_ring.push("- ");
                _ = self.delta_ring.push(json[s..e]);
                _ = self.delta_ring.push("\n");
            }
            i = e + 1;
        } else i += 1;
    }
}

fn pushJsonCommandArray(self: *SseThread, json: []const u8) void {
    const start = findJsonArrayStart(json, "commands") orelse return;
    var header_pushed = false;
    var i = start;
    while (i < json.len) {
        if (json[i] == ']') break;
        if (json[i] == '{') {
            var depth: usize = 1;
            var e = i + 1;
            while (e < json.len and depth > 0) : (e += 1) {
                if (json[e] == '{') depth += 1 else if (json[e] == '}') depth -= 1;
            }
            const obj = json[i..e];
            if (ai_auth.extractJsonString(obj, "command")) |cmd| {
                if (!header_pushed) {
                    _ = self.delta_ring.push("\nCommands:\n");
                    header_pushed = true;
                }
                _ = self.delta_ring.push("```\n");
                _ = self.delta_ring.push(cmd);
                _ = self.delta_ring.push("\n```\n");
                if (ai_auth.extractJsonString(obj, "risk")) |risk| {
                    _ = self.delta_ring.push("Risk: ");
                    _ = self.delta_ring.push(risk);
                    _ = self.delta_ring.push("\n");
                }
            }
            i = e;
        } else i += 1;
    }
}

/// Push explain breakdown items: iterate breakdown array objects, extract
/// "segment" and "explanation", push each as "segment — explanation\n".
fn pushExplainBreakdown(self: *SseThread, json: []const u8) void {
    const start = findJsonArrayStart(json, "breakdown") orelse return;
    var i = start;
    while (i < json.len) {
        if (json[i] == ']') break;
        if (json[i] == '{') {
            var depth: usize = 1;
            var e = i + 1;
            while (e < json.len and depth > 0) : (e += 1) {
                if (json[e] == '{') depth += 1 else if (json[e] == '}') depth -= 1;
            }
            const obj = json[i..e];
            if (ai_auth.extractJsonString(obj, "segment")) |seg| {
                _ = self.delta_ring.push(seg);
                if (ai_auth.extractJsonString(obj, "explanation")) |expl| {
                    _ = self.delta_ring.push(" \xe2\x80\x94 ");
                    _ = self.delta_ring.push(expl);
                }
                _ = self.delta_ring.push("\n");
            }
            i = e;
        } else i += 1;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "formatFinalResponse: explain response" {
    var sse = SseThread.init();
    const json = "{\"data\":{\"summary\":\"Lists files\",\"breakdown\":[{\"segment\":\"ls\",\"explanation\":\"list directory\"},{\"segment\":\"-la\",\"explanation\":\"long format, all\"}],\"notes\":\"Common command\"}}";
    formatFinalResponse(&sse, json);
    var out: [512]u8 = undefined;
    const drained = sse.delta_ring.drain(&out);
    // Find null separators
    const sep1 = std.mem.indexOfScalar(u8, drained, 0) orelse unreachable;
    try std.testing.expectEqualStrings("Lists files", drained[0..sep1]);
    const rest = drained[sep1 + 1 ..];
    const sep2 = std.mem.indexOfScalar(u8, rest, 0) orelse unreachable;
    const breakdown = rest[0..sep2];
    try std.testing.expect(std.mem.indexOf(u8, breakdown, "ls") != null);
    try std.testing.expect(std.mem.indexOf(u8, breakdown, "list directory") != null);
    const notes = rest[sep2 + 1 ..];
    try std.testing.expectEqualStrings("Common command", notes);
}

test "formatFinalResponse: explain without notes" {
    var sse = SseThread.init();
    const json = "{\"data\":{\"summary\":\"Prints text\",\"breakdown\":[{\"segment\":\"echo\",\"explanation\":\"print\"}]}}";
    formatFinalResponse(&sse, json);
    var out: [512]u8 = undefined;
    const drained = sse.delta_ring.drain(&out);
    const sep1 = std.mem.indexOfScalar(u8, drained, 0) orelse unreachable;
    try std.testing.expectEqualStrings("Prints text", drained[0..sep1]);
    const rest = drained[sep1 + 1 ..];
    const sep2 = std.mem.indexOfScalar(u8, rest, 0) orelse unreachable;
    // Notes section should be empty
    try std.testing.expectEqual(rest.len, sep2 + 1);
}

test "formatFinalResponse: generate response" {
    var sse = SseThread.init();
    const json = "{\"data\":{\"command\":\"docker ps -a\",\"notes\":\"Lists all containers\"}}";
    formatFinalResponse(&sse, json);
    var out: [512]u8 = undefined;
    const drained = sse.delta_ring.drain(&out);
    const sep = std.mem.indexOfScalar(u8, drained, 0) orelse unreachable;
    try std.testing.expectEqualStrings("docker ps -a", drained[0..sep]);
    const notes = drained[sep + 1 ..];
    try std.testing.expectEqualStrings("Lists all containers", notes);
}

test "formatFinalResponse: generate without notes" {
    var sse = SseThread.init();
    const json = "{\"data\":{\"command\":\"ls -la\"}}";
    formatFinalResponse(&sse, json);
    var out: [512]u8 = undefined;
    const drained = sse.delta_ring.drain(&out);
    const sep = std.mem.indexOfScalar(u8, drained, 0) orelse unreachable;
    try std.testing.expectEqualStrings("ls -la", drained[0..sep]);
    // Notes section should be empty
    try std.testing.expectEqual(drained.len, sep + 1);
}
