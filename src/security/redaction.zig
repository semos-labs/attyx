const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub const FindingType = enum(u8) {
    private_key,
    auth_token,
    api_token,
    env_secret,
    jwt,
    high_entropy,
    url_secret,
};

pub const max_findings = 32;

pub const RedactionResult = struct {
    text: []u8,
    findings: [max_findings]FindingType = undefined,
    finding_count: u8 = 0,

    pub fn deinit(self: *RedactionResult, allocator: Allocator) void {
        allocator.free(self.text);
    }

    pub fn findingSlice(self: *const RedactionResult) []const FindingType {
        return self.findings[0..self.finding_count];
    }

    fn addFinding(self: *RedactionResult, ft: FindingType) void {
        if (self.finding_count < max_findings) {
            self.findings[self.finding_count] = ft;
            self.finding_count += 1;
        }
    }
};

// ---------------------------------------------------------------------------
// Main API
// ---------------------------------------------------------------------------

/// Redact sensitive content from `input`. Returns owned text + findings list.
pub fn redactText(allocator: Allocator, input: []const u8) !RedactionResult {
    var result = RedactionResult{ .text = undefined, .finding_count = 0 };
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    var pos: usize = 0;
    while (pos < input.len) {
        // 1. Private key blocks
        if (matchPrivateKeyBlock(input, pos)) |end| {
            try out.appendSlice(allocator, "[REDACTED_PRIVATE_KEY]");
            result.addFinding(.private_key);
            pos = end;
            continue;
        }

        // Process line-by-line for remaining rules
        const line_end = findLineEnd(input, pos);
        const line = input[pos..line_end];

        if (redactLine(allocator, &out, line, &result)) {
            // line was handled
        } else |_| {
            // on error, pass through raw
            try out.appendSlice(allocator, line);
        }

        pos = line_end;
        if (pos < input.len and input[pos] == '\n') {
            try out.append(allocator, '\n');
            pos += 1;
        }
    }

    result.text = try out.toOwnedSlice(allocator);
    return result;
}

/// Redact a single line into `out`. Returns true if handled.
fn redactLine(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    line: []const u8,
    result: *RedactionResult,
) !void {
    // Try each rule in priority order.
    // We work on the line, building output with replacements.

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, line);

    // 2. Auth headers / bearer tokens
    if (applyAuthRedaction(allocator, &buf)) |found| {
        if (found) result.addFinding(.auth_token);
    } else |_| {}

    // 3. API token patterns
    if (applyApiTokenRedaction(allocator, &buf)) |found| {
        if (found) result.addFinding(.api_token);
    } else |_| {}

    // 4. Env-style secrets
    if (applyEnvSecretRedaction(allocator, &buf)) |found| {
        if (found) result.addFinding(.env_secret);
    } else |_| {}

    // 5. JWT tokens
    if (applyJwtRedaction(allocator, &buf)) |found| {
        if (found) result.addFinding(.jwt);
    } else |_| {}

    // 7. URL query secrets (before high-entropy to avoid double-hit)
    if (applyUrlSecretRedaction(allocator, &buf)) |found| {
        if (found) result.addFinding(.url_secret);
    } else |_| {}

    // 6. High entropy blobs
    if (applyHighEntropyRedaction(allocator, &buf)) |found| {
        if (found) result.addFinding(.high_entropy);
    } else |_| {}

    try out.appendSlice(allocator, buf.items);
}

// ---------------------------------------------------------------------------
// Rule 1: Private key blocks
// ---------------------------------------------------------------------------

fn matchPrivateKeyBlock(input: []const u8, pos: usize) ?usize {
    const markers = [_][]const u8{
        "-----BEGIN RSA PRIVATE KEY-----",
        "-----BEGIN PRIVATE KEY-----",
        "-----BEGIN EC PRIVATE KEY-----",
        "-----BEGIN OPENSSH PRIVATE KEY-----",
        "-----BEGIN DSA PRIVATE KEY-----",
        "-----BEGIN ENCRYPTED PRIVATE KEY-----",
    };
    for (markers) |marker| {
        if (pos + marker.len <= input.len and std.mem.eql(u8, input[pos..][0..marker.len], marker)) {
            // Find matching END marker
            const end_prefix = "-----END ";
            if (std.mem.indexOfPos(u8, input, pos + marker.len, end_prefix)) |end_start| {
                const after_end = findLineEnd(input, end_start);
                // Skip trailing newline
                if (after_end < input.len and input[after_end] == '\n') return after_end + 1;
                return after_end;
            }
            // No end marker — redact to end
            return input.len;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Rule 2: Authorization headers / Bearer tokens
// ---------------------------------------------------------------------------

fn applyAuthRedaction(allocator: Allocator, buf: *std.ArrayList(u8)) !bool {
    const patterns = [_][]const u8{
        "Bearer ",
        "bearer ",
        "Authorization: ",
        "authorization: ",
        "Authorization:",
        "authorization:",
    };
    for (patterns) |pat| {
        if (findSubstring(buf.items, pat)) |idx| {
            const value_start = idx + pat.len;
            const value_end = findTokenEnd(buf.items, value_start);
            if (value_end > value_start) {
                try replaceRange(allocator, buf, value_start, value_end, "[REDACTED_TOKEN]");
                return true;
            }
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Rule 3: Common API token formats
// ---------------------------------------------------------------------------

const api_prefixes = [_][]const u8{
    "AKIA",          // AWS access key
    "ghp_",          // GitHub personal access token
    "gho_",          // GitHub OAuth
    "ghs_",          // GitHub server
    "ghr_",          // GitHub refresh
    "github_pat_",   // GitHub fine-grained PAT
    "sk-",           // OpenAI / Stripe secret key
    "pk_live_",      // Stripe publishable
    "sk_live_",      // Stripe secret
    "pk_test_",      // Stripe test
    "sk_test_",      // Stripe test
    "xoxb-",         // Slack bot
    "xoxp-",         // Slack user
    "xapp-",         // Slack app
    "SG.",           // SendGrid
    "sq0atp-",       // Square
    "AIza",          // Google API key
    "ya29.",         // Google OAuth
    "glpat-",        // GitLab PAT
    "npm_",          // npm token
    "pypi-",         // PyPI token
};

fn applyApiTokenRedaction(allocator: Allocator, buf: *std.ArrayList(u8)) !bool {
    var found = false;
    for (api_prefixes) |prefix| {
        var search_start: usize = 0;
        while (search_start < buf.items.len) {
            if (findSubstring(buf.items[search_start..], prefix)) |rel_idx| {
                const idx = search_start + rel_idx;
                const tok_end = findTokenEnd(buf.items, idx);
                const tok_len = tok_end - idx;
                // Only redact if token looks substantial (>8 chars)
                if (tok_len > 8) {
                    try replaceRange(allocator, buf, idx, tok_end, "[REDACTED_TOKEN]");
                    found = true;
                    search_start = idx + "[REDACTED_TOKEN]".len;
                } else {
                    search_start = tok_end;
                }
            } else break;
        }
    }
    return found;
}

// ---------------------------------------------------------------------------
// Rule 4: Environment-style secrets (KEY=value)
// ---------------------------------------------------------------------------

const secret_keys = [_][]const u8{
    "PASSWORD",
    "PASSWD",
    "SECRET",
    "TOKEN",
    "API_KEY",
    "APIKEY",
    "ACCESS_KEY",
    "PRIVATE_KEY",
    "CREDENTIALS",
    "AUTH",
};

fn applyEnvSecretRedaction(allocator: Allocator, buf: *std.ArrayList(u8)) !bool {
    // Look for patterns like KEY=value or KEY = value
    var found = false;
    for (secret_keys) |key| {
        if (containsCIAt(buf.items, key)) |idx| {
            // Check for '=' after key name
            var eq_pos = idx + key.len;
            // Allow optional chars between key and '=' (e.g. _ACCESS_KEY)
            while (eq_pos < buf.items.len and (isWordChar(buf.items[eq_pos]))) eq_pos += 1;
            // Skip spaces
            while (eq_pos < buf.items.len and buf.items[eq_pos] == ' ') eq_pos += 1;
            if (eq_pos < buf.items.len and buf.items[eq_pos] == '=') {
                var val_start = eq_pos + 1;
                // Skip spaces and optional quotes
                while (val_start < buf.items.len and buf.items[val_start] == ' ') val_start += 1;
                if (val_start < buf.items.len and (buf.items[val_start] == '"' or buf.items[val_start] == '\'')) val_start += 1;
                const val_end = findValueEnd(buf.items, val_start);
                if (val_end > val_start) {
                    try replaceRange(allocator, buf, val_start, val_end, "[REDACTED]");
                    found = true;
                }
            }
        }
    }
    return found;
}

// ---------------------------------------------------------------------------
// Rule 5: JWT tokens (xxx.yyy.zzz)
// ---------------------------------------------------------------------------

fn applyJwtRedaction(allocator: Allocator, buf: *std.ArrayList(u8)) !bool {
    var found = false;
    var i: usize = 0;
    while (i < buf.items.len) {
        if (matchJwt(buf.items, i)) |jwt_end| {
            const jwt_len = jwt_end - i;
            if (jwt_len >= 30) { // JWTs are substantial
                try replaceRange(allocator, buf, i, jwt_end, "[REDACTED_JWT]");
                found = true;
                i += "[REDACTED_JWT]".len;
                continue;
            }
        }
        i += 1;
    }
    return found;
}

fn matchJwt(text: []const u8, pos: usize) ?usize {
    // Three base64url segments separated by dots
    var dots: u8 = 0;
    var seg_len: usize = 0;
    var i = pos;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (isBase64UrlChar(ch)) {
            seg_len += 1;
        } else if (ch == '.' and seg_len > 0) {
            dots += 1;
            seg_len = 0;
            if (dots > 2) break;
        } else {
            break;
        }
    }
    if (dots == 2 and seg_len > 0) return i;
    return null;
}

// ---------------------------------------------------------------------------
// Rule 6: High entropy blobs (long base64/hex sequences)
// ---------------------------------------------------------------------------

const high_entropy_threshold = 64;

fn applyHighEntropyRedaction(allocator: Allocator, buf: *std.ArrayList(u8)) !bool {
    var found = false;
    var i: usize = 0;
    while (i < buf.items.len) {
        if (isBase64Char(buf.items[i])) {
            const start = i;
            while (i < buf.items.len and isBase64Char(buf.items[i])) i += 1;
            if (i - start >= high_entropy_threshold) {
                try replaceRange(allocator, buf, start, i, "[REDACTED_BLOB]");
                found = true;
                i = start + "[REDACTED_BLOB]".len;
                continue;
            }
        } else {
            i += 1;
        }
    }
    return found;
}

// ---------------------------------------------------------------------------
// Rule 7: URL query secrets
// ---------------------------------------------------------------------------

const secret_params = [_][]const u8{
    "token=",
    "api_key=",
    "apikey=",
    "secret=",
    "password=",
    "access_token=",
    "auth=",
    "signature=",
    "sig=",
    "key=",
    "client_secret=",
};

fn applyUrlSecretRedaction(allocator: Allocator, buf: *std.ArrayList(u8)) !bool {
    var found = false;
    for (secret_params) |param| {
        var search_start: usize = 0;
        while (search_start < buf.items.len) {
            if (findCISubstring(buf.items[search_start..], param)) |rel_idx| {
                const idx = search_start + rel_idx;
                // Verify it's in a URL context (preceded by ? or &)
                if (idx > 0 and (buf.items[idx - 1] == '?' or buf.items[idx - 1] == '&')) {
                    const val_start = idx + param.len;
                    var val_end = val_start;
                    while (val_end < buf.items.len and buf.items[val_end] != '&' and
                        buf.items[val_end] != ' ' and buf.items[val_end] != '\n' and
                        buf.items[val_end] != '#') val_end += 1;
                    if (val_end > val_start) {
                        try replaceRange(allocator, buf, val_start, val_end, "[REDACTED]");
                        found = true;
                        search_start = val_start + "[REDACTED]".len;
                        continue;
                    }
                }
                search_start = idx + param.len;
            } else break;
        }
    }
    return found;
}

// ---------------------------------------------------------------------------
// String helpers
// ---------------------------------------------------------------------------

fn findLineEnd(text: []const u8, pos: usize) usize {
    var p = pos;
    while (p < text.len and text[p] != '\n') p += 1;
    return p;
}

fn findSubstring(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i..][0..needle.len], needle)) return i;
    }
    return null;
}

fn findCISubstring(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (eqlCI(haystack[i..][0..needle.len], needle)) return i;
    }
    return null;
}

fn containsCIAt(haystack: []const u8, needle: []const u8) ?usize {
    return findCISubstring(haystack, needle);
}

fn eqlCI(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (toLower(ac) != toLower(bc)) return false;
    }
    return true;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn findTokenEnd(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and text[i] != ' ' and text[i] != '\n' and text[i] != '\r' and
        text[i] != '\t' and text[i] != '"' and text[i] != '\'') i += 1;
    return i;
}

fn findValueEnd(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and text[i] != '\n' and text[i] != '\r' and
        text[i] != ' ' and text[i] != '"' and text[i] != '\'' and
        text[i] != '&' and text[i] != '#') i += 1;
    return i;
}

fn isWordChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or ch == '_';
}

fn isBase64Char(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '+' or c == '/' or c == '=';
}

fn isBase64UrlChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '+' or c == '/' or c == '=';
}

fn isHexChar(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

/// Replace buf[start..end] with `replacement`.
fn replaceRange(allocator: Allocator, buf: *std.ArrayList(u8), start: usize, end: usize, replacement: []const u8) !void {
    const old_len = end - start;
    const new_len = replacement.len;
    if (new_len > old_len) {
        const extra = new_len - old_len;
        try buf.resize(allocator, buf.items.len + extra);
        // Shift tail right
        std.mem.copyBackwards(u8, buf.items[end + extra ..], buf.items[end .. buf.items.len - extra]);
    } else if (new_len < old_len) {
        const shrink = old_len - new_len;
        // Shift tail left
        std.mem.copyForwards(u8, buf.items[start + new_len ..], buf.items[end..]);
        buf.shrinkRetainingCapacity(buf.items.len - shrink);
    }
    @memcpy(buf.items[start..][0..new_len], replacement);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "redact: private key block" {
    const alloc = std.testing.allocator;
    const input = "before\n-----BEGIN RSA PRIVATE KEY-----\nMIIEow...\n-----END RSA PRIVATE KEY-----\nafter";
    var result = try redactText(alloc, input);
    defer result.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "[REDACTED_PRIVATE_KEY]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "MIIEow") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "after") != null);
    try std.testing.expect(result.finding_count > 0);
    try std.testing.expectEqual(FindingType.private_key, result.findings[0]);
}

test "redact: bearer token" {
    const alloc = std.testing.allocator;
    var result = try redactText(alloc, "Authorization: Bearer mySecretToken123");
    defer result.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "mySecretToken123") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "[REDACTED_TOKEN]") != null);
    try std.testing.expect(result.finding_count > 0);
}

test "redact: github token" {
    const alloc = std.testing.allocator;
    var result = try redactText(alloc, "using ghp_abc123def456ghi789jkl0");
    defer result.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "ghp_abc123") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "[REDACTED_TOKEN]") != null);
}

test "redact: AWS AKIA key" {
    const alloc = std.testing.allocator;
    var result = try redactText(alloc, "key=AKIAIOSFODNN7EXAMPLE1");
    defer result.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "AKIAIOSFODNN7EXAMPLE1") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "[REDACTED_TOKEN]") != null);
}

test "redact: env secret PASSWORD=..." {
    const alloc = std.testing.allocator;
    var result = try redactText(alloc, "DB_PASSWORD=supersecret123");
    defer result.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "supersecret123") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "[REDACTED]") != null);
    try std.testing.expect(result.finding_count > 0);
}

test "redact: JWT token" {
    const alloc = std.testing.allocator;
    const jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U";
    var result = try redactText(alloc, jwt);
    defer result.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "eyJhbGci") == null);
    try std.testing.expectEqualStrings("[REDACTED_JWT]", result.text);
}

test "redact: high entropy blob" {
    const alloc = std.testing.allocator;
    var blob: [80]u8 = undefined;
    @memset(&blob, 'A');
    const input_str = "data=" ++ &blob;
    var result = try redactText(alloc, input_str);
    defer result.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "[REDACTED_BLOB]") != null);
}

test "redact: URL query secret" {
    const alloc = std.testing.allocator;
    var result = try redactText(alloc, "https://api.example.com/v1?token=abc123secret&other=ok");
    defer result.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "abc123secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "token=[REDACTED]") != null);
    // & and rest of URL should be preserved
    try std.testing.expect(std.mem.indexOf(u8, result.text, "other=ok") != null);
}

test "redact: safe text passes through" {
    const alloc = std.testing.allocator;
    const input = "total 42\n-rw-r--r-- 1 user user 1234 file.txt\nHello world";
    var result = try redactText(alloc, input);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings(input, result.text);
    try std.testing.expectEqual(@as(u8, 0), result.finding_count);
}

test "redact: mixed content preserves structure" {
    const alloc = std.testing.allocator;
    const input = "line1\nGITHUB_TOKEN=ghp_verysecrettoken123456\nline3";
    var result = try redactText(alloc, input);
    defer result.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "line1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "\nline3") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "ghp_verysecret") == null);
}

test "redact: multiple findings" {
    const alloc = std.testing.allocator;
    const input = "PASSWORD=secret\nAuthorization: Bearer tok123";
    var result = try redactText(alloc, input);
    defer result.deinit(alloc);
    try std.testing.expect(result.finding_count >= 2);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "tok123") == null);
}
