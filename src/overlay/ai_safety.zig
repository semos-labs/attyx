const std = @import("std");

// ---------------------------------------------------------------------------
// Command safety heuristic analyzer
// ---------------------------------------------------------------------------

pub const RiskLevel = enum(u8) { safe, caution, danger };

pub const max_reasons = 4;
pub const max_suggestions = 2;

pub const SafetyResult = struct {
    risk_level: RiskLevel = .safe,
    reasons: [max_reasons][]const u8 = .{ "", "", "", "" },
    reason_count: u8 = 0,
    suggestions: [max_suggestions][]const u8 = .{ "", "" },
    suggestion_count: u8 = 0,

    fn addReason(self: *SafetyResult, reason: []const u8) void {
        if (self.reason_count < max_reasons) {
            self.reasons[self.reason_count] = reason;
            self.reason_count += 1;
        }
    }

    fn addSuggestion(self: *SafetyResult, suggestion: []const u8) void {
        if (self.suggestion_count < max_suggestions) {
            self.suggestions[self.suggestion_count] = suggestion;
            self.suggestion_count += 1;
        }
    }

    fn escalate(self: *SafetyResult, level: RiskLevel) void {
        if (@intFromEnum(level) > @intFromEnum(self.risk_level)) {
            self.risk_level = level;
        }
    }

    /// Label for the risk level badge.
    pub fn badge(self: *const SafetyResult) []const u8 {
        return switch (self.risk_level) {
            .safe => "Safe",
            .caution => "Caution",
            .danger => "DANGER",
        };
    }
};

/// Analyze a command string for safety risks. Pure heuristic, no allocations.
pub fn analyzeCommand(command: []const u8) SafetyResult {
    var result = SafetyResult{};
    if (command.len == 0) return result;

    // Normalize: work with the raw command bytes
    checkDestructiveDelete(command, &result);
    checkDiskFormat(command, &result);
    checkShutdownReboot(command, &result);
    checkRemoteExec(command, &result);
    checkPermissions(command, &result);
    checkRedirectTruncate(command, &result);
    checkForkBomb(command, &result);
    checkSudo(command, &result);
    checkGitDestructive(command, &result);
    checkContainerInfra(command, &result);
    checkForceOverwrite(command, &result);

    return result;
}

// ---------------------------------------------------------------------------
// Heuristic checks
// ---------------------------------------------------------------------------

fn checkDestructiveDelete(cmd: []const u8, r: *SafetyResult) void {
    // rm -rf with dangerous targets
    if (containsToken(cmd, "rm")) {
        if (contains(cmd, "-rf") or contains(cmd, "-fr") or
            (contains(cmd, "-r") and contains(cmd, "-f")))
        {
            // Check for broad targets: /, ~, *, $, empty var
            if (contains(cmd, " /") or contains(cmd, " ~/") or
                contains(cmd, " ~") or contains(cmd, " *") or
                contains(cmd, "${") or contains(cmd, "$HOME") or
                contains(cmd, "$("))
            {
                r.escalate(.danger);
                r.addReason("rm -rf with broad/variable target path");
                r.addSuggestion("Use rm -ri for interactive confirmation");
                return;
            }
            r.escalate(.caution);
            r.addReason("Recursive force delete (rm -rf)");
        }
    }
}

fn checkDiskFormat(cmd: []const u8, r: *SafetyResult) void {
    if (containsToken(cmd, "mkfs") or containsToken(cmd, "fdisk") or containsToken(cmd, "parted")) {
        r.escalate(.danger);
        r.addReason("Disk formatting/partitioning command");
    }
    if (containsToken(cmd, "dd")) {
        if (contains(cmd, "of=/dev/")) {
            r.escalate(.danger);
            r.addReason("dd writing to block device");
        }
    }
}

fn checkShutdownReboot(cmd: []const u8, r: *SafetyResult) void {
    if (containsToken(cmd, "shutdown") or containsToken(cmd, "reboot") or
        containsToken(cmd, "poweroff") or containsToken(cmd, "halt"))
    {
        r.escalate(.caution);
        r.addReason("System shutdown/reboot command");
    }
}

fn checkRemoteExec(cmd: []const u8, r: *SafetyResult) void {
    // Patterns: curl|sh, wget|sh, curl|bash, bash <(curl...)
    if ((contains(cmd, "curl") or contains(cmd, "wget")) and
        (contains(cmd, "| sh") or contains(cmd, "|sh") or
        contains(cmd, "| bash") or contains(cmd, "|bash") or
        contains(cmd, "| zsh") or contains(cmd, "|zsh")))
    {
        r.escalate(.danger);
        r.addReason("Remote code piped to shell execution");
        r.addSuggestion("Download first, review, then execute");
        return;
    }
    if (contains(cmd, "bash <(curl") or contains(cmd, "bash <(wget") or
        contains(cmd, "sh <(curl") or contains(cmd, "sh <(wget"))
    {
        r.escalate(.danger);
        r.addReason("Remote code via process substitution");
        r.addSuggestion("Download first, review, then execute");
        return;
    }
    if (containsToken(cmd, "python") or containsToken(cmd, "python3")) {
        if (contains(cmd, "-c") and (contains(cmd, "urllib") or contains(cmd, "requests") or contains(cmd, "http"))) {
            r.escalate(.caution);
            r.addReason("Python executing code with network access");
        }
    }
}

fn checkPermissions(cmd: []const u8, r: *SafetyResult) void {
    if (containsToken(cmd, "chmod") or containsToken(cmd, "chown")) {
        if (contains(cmd, "-R") or contains(cmd, "-r") or contains(cmd, "--recursive")) {
            if (contains(cmd, " /") or contains(cmd, " ~/") or contains(cmd, " *")) {
                r.escalate(.danger);
                r.addReason("Recursive permission change on broad path");
                return;
            }
            r.escalate(.caution);
            r.addReason("Recursive permission change");
        }
    }
}

fn checkRedirectTruncate(cmd: []const u8, r: *SafetyResult) void {
    // Look for > (not >>) to sensitive paths
    if (containsRedirect(cmd)) {
        if (contains(cmd, ".ssh/") or contains(cmd, ".bashrc") or
            contains(cmd, ".zshrc") or contains(cmd, ".profile") or
            contains(cmd, "/etc/") or contains(cmd, ".gitconfig"))
        {
            r.escalate(.caution);
            r.addReason("Redirect truncation to config/sensitive file");
        }
    }
}

fn checkForkBomb(cmd: []const u8, r: *SafetyResult) void {
    // Classic bash fork bomb: :(){ :|:& };:
    if (contains(cmd, ":(){ :|:") or contains(cmd, ":(){ : | :") or
        contains(cmd, ".() {") or contains(cmd, "fork") and contains(cmd, "while") and contains(cmd, "true"))
    {
        r.escalate(.danger);
        r.addReason("Potential fork bomb pattern");
    }
}

fn checkSudo(cmd: []const u8, r: *SafetyResult) void {
    if (containsToken(cmd, "sudo")) {
        r.escalate(.caution);
        r.addReason("Running with elevated privileges (sudo)");
    }
}

fn checkGitDestructive(cmd: []const u8, r: *SafetyResult) void {
    if (!containsToken(cmd, "git")) return;
    if (contains(cmd, "reset --hard")) {
        r.escalate(.caution);
        r.addReason("git reset --hard discards uncommitted changes");
    }
    if (contains(cmd, "clean -fd") or contains(cmd, "clean -df") or contains(cmd, "clean -f")) {
        r.escalate(.caution);
        r.addReason("git clean removes untracked files permanently");
    }
    if (contains(cmd, "push --force") or contains(cmd, "push -f")) {
        r.escalate(.caution);
        r.addReason("git force-push can overwrite remote history");
    }
}

fn checkContainerInfra(cmd: []const u8, r: *SafetyResult) void {
    if (containsToken(cmd, "docker") and contains(cmd, "system prune")) {
        r.escalate(.caution);
        r.addReason("docker system prune removes unused data");
    }
    if (containsToken(cmd, "kubectl") and containsToken(cmd, "delete")) {
        r.escalate(.caution);
        r.addReason("kubectl delete removes cluster resources");
    }
    if (containsToken(cmd, "terraform") and containsToken(cmd, "destroy")) {
        r.escalate(.danger);
        r.addReason("terraform destroy removes all managed infrastructure");
    }
}

fn checkForceOverwrite(cmd: []const u8, r: *SafetyResult) void {
    if ((containsToken(cmd, "mv") or containsToken(cmd, "cp")) and contains(cmd, "-f")) {
        if (contains(cmd, " /") or contains(cmd, " ~/") or contains(cmd, " *")) {
            r.escalate(.caution);
            r.addReason("Force move/copy with broad target path");
        }
    }
}

// ---------------------------------------------------------------------------
// String helpers
// ---------------------------------------------------------------------------

/// Check if `haystack` contains `needle` as a substring.
fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    if (needle.len == 0) return true;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Check if `haystack` contains `token` as a whole word (preceded/followed by
/// non-alphanumeric or at string boundary).
fn containsToken(haystack: []const u8, token: []const u8) bool {
    if (token.len > haystack.len) return false;
    var i: usize = 0;
    while (i + token.len <= haystack.len) : (i += 1) {
        if (!std.mem.eql(u8, haystack[i .. i + token.len], token)) continue;
        const before_ok = (i == 0) or !isWordChar(haystack[i - 1]);
        const after_ok = (i + token.len == haystack.len) or !isWordChar(haystack[i + token.len]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

fn isWordChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or ch == '_' or ch == '-';
}

/// Detect `>` redirect that is NOT `>>` (append).
fn containsRedirect(cmd: []const u8) bool {
    var i: usize = 0;
    while (i < cmd.len) : (i += 1) {
        if (cmd[i] == '>') {
            if (i + 1 < cmd.len and cmd[i + 1] == '>') {
                i += 1; // skip >>
                continue;
            }
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "analyzeCommand: safe commands" {
    const r1 = analyzeCommand("ls -la");
    try std.testing.expectEqual(RiskLevel.safe, r1.risk_level);
    try std.testing.expectEqual(@as(u8, 0), r1.reason_count);

    const r2 = analyzeCommand("git status");
    try std.testing.expectEqual(RiskLevel.safe, r2.risk_level);

    const r3 = analyzeCommand("docker ps -a");
    try std.testing.expectEqual(RiskLevel.safe, r3.risk_level);

    const r4 = analyzeCommand("");
    try std.testing.expectEqual(RiskLevel.safe, r4.risk_level);
}

test "analyzeCommand: danger - rm -rf /" {
    const r = analyzeCommand("rm -rf /");
    try std.testing.expectEqual(RiskLevel.danger, r.risk_level);
    try std.testing.expect(r.reason_count > 0);
}

test "analyzeCommand: danger - rm -rf ~" {
    const r = analyzeCommand("rm -rf ~/");
    try std.testing.expectEqual(RiskLevel.danger, r.risk_level);
}

test "analyzeCommand: danger - curl piped to sh" {
    const r = analyzeCommand("curl https://example.com/install.sh | sh");
    try std.testing.expectEqual(RiskLevel.danger, r.risk_level);
    try std.testing.expect(r.reason_count > 0);
    try std.testing.expect(r.suggestion_count > 0);
}

test "analyzeCommand: danger - mkfs" {
    const r = analyzeCommand("mkfs.ext4 /dev/sda1");
    try std.testing.expectEqual(RiskLevel.danger, r.risk_level);
}

test "analyzeCommand: danger - dd to device" {
    const r = analyzeCommand("dd if=image.iso of=/dev/sdb bs=4M");
    try std.testing.expectEqual(RiskLevel.danger, r.risk_level);
}

test "analyzeCommand: danger - terraform destroy" {
    const r = analyzeCommand("terraform destroy -auto-approve");
    try std.testing.expectEqual(RiskLevel.danger, r.risk_level);
}

test "analyzeCommand: danger - fork bomb" {
    const r = analyzeCommand(":(){ :|:& };:");
    try std.testing.expectEqual(RiskLevel.danger, r.risk_level);
}

test "analyzeCommand: danger - recursive chmod broad path" {
    const r = analyzeCommand("chmod -R 777 /");
    try std.testing.expectEqual(RiskLevel.danger, r.risk_level);
}

test "analyzeCommand: caution - sudo" {
    const r = analyzeCommand("sudo apt update");
    try std.testing.expectEqual(RiskLevel.caution, r.risk_level);
    try std.testing.expect(r.reason_count > 0);
}

test "analyzeCommand: caution - git reset --hard" {
    const r = analyzeCommand("git reset --hard HEAD~3");
    try std.testing.expectEqual(RiskLevel.caution, r.risk_level);
}

test "analyzeCommand: caution - git clean -fd" {
    const r = analyzeCommand("git clean -fd");
    try std.testing.expectEqual(RiskLevel.caution, r.risk_level);
}

test "analyzeCommand: caution - git push --force" {
    const r = analyzeCommand("git push --force origin main");
    try std.testing.expectEqual(RiskLevel.caution, r.risk_level);
}

test "analyzeCommand: caution - docker system prune" {
    const r = analyzeCommand("docker system prune -a");
    try std.testing.expectEqual(RiskLevel.caution, r.risk_level);
}

test "analyzeCommand: caution - kubectl delete" {
    const r = analyzeCommand("kubectl delete pods --all");
    try std.testing.expectEqual(RiskLevel.caution, r.risk_level);
}

test "analyzeCommand: caution - redirect to config" {
    const r = analyzeCommand("echo '' > ~/.ssh/config");
    try std.testing.expectEqual(RiskLevel.caution, r.risk_level);
}

test "analyzeCommand: caution - shutdown" {
    const r = analyzeCommand("shutdown -h now");
    try std.testing.expectEqual(RiskLevel.caution, r.risk_level);
}

test "analyzeCommand: danger escalates over caution" {
    // sudo + curl|sh → danger (curl|sh escalates past sudo's caution)
    const r = analyzeCommand("sudo curl https://x.com/s.sh | bash");
    try std.testing.expectEqual(RiskLevel.danger, r.risk_level);
    try std.testing.expect(r.reason_count >= 2);
}

test "containsToken: word boundaries" {
    try std.testing.expect(containsToken("rm -rf /", "rm"));
    try std.testing.expect(!containsToken("firmware update", "rm"));
    try std.testing.expect(containsToken("sudo rm -rf /", "rm"));
    try std.testing.expect(containsToken("git status", "git"));
    try std.testing.expect(!containsToken("digit", "git"));
}

test "containsRedirect: truncation vs append" {
    try std.testing.expect(containsRedirect("echo x > file"));
    try std.testing.expect(!containsRedirect("echo x >> file"));
    try std.testing.expect(containsRedirect("cat > /etc/hosts"));
}

test "badge: label text" {
    const safe_r = SafetyResult{};
    try std.testing.expectEqualStrings("Safe", safe_r.badge());
    var danger_r = SafetyResult{};
    danger_r.risk_level = .danger;
    try std.testing.expectEqualStrings("DANGER", danger_r.badge());
}

test "analyzeCommand: rm without -rf is safe" {
    const r = analyzeCommand("rm file.txt");
    try std.testing.expectEqual(RiskLevel.safe, r.risk_level);
}

test "analyzeCommand: wget piped to bash" {
    const r = analyzeCommand("wget -qO- https://x.com/s.sh | bash");
    try std.testing.expectEqual(RiskLevel.danger, r.risk_level);
}

test "analyzeCommand: process substitution" {
    const r = analyzeCommand("bash <(curl -s https://x.com/install.sh)");
    try std.testing.expectEqual(RiskLevel.danger, r.risk_level);
}
