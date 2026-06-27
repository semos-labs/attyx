const std = @import("std");
const TerminalState = @import("state.zig").TerminalState;
const AgentStatus = @import("actions.zig").AgentStatus;
const AgentUsage = @import("actions.zig").AgentUsage;
const key_encode = @import("key_encode.zig");

pub fn startHyperlink(self: *TerminalState, uri: []const u8) void {
    if (uri.len == 0) {
        self.pen_link_id = 0;
        return;
    }
    const alloc = self.ring.allocator;
    const uri_copy = alloc.dupe(u8, uri) catch return;
    self.link_uris.append(alloc, uri_copy) catch {
        alloc.free(uri_copy);
        return;
    };
    self.pen_link_id = self.next_link_id;
    self.next_link_id += 1;
}

pub fn endHyperlink(self: *TerminalState) void {
    self.pen_link_id = 0;
}

pub fn setTitle(self: *TerminalState, title_slice: []const u8) void {
    const alloc = self.ring.allocator;
    // Detect whether the title actually changed before replacing.
    const changed = if (self.title) |old|
        old.len != title_slice.len or !std.mem.eql(u8, old, title_slice)
    else
        title_slice.len > 0;

    if (self.title) |old| alloc.free(old);
    if (title_slice.len == 0) {
        self.title = null;
    } else {
        self.title = alloc.dupe(u8, title_slice) catch null;
    }
    if (changed) self.title_changed = true;
}

pub fn setCwd(self: *TerminalState, uri: []const u8) void {
    const alloc = self.ring.allocator;
    if (self.working_directory) |old| alloc.free(old);
    if (uri.len == 0) {
        self.working_directory = null;
        return;
    }
    self.working_directory = alloc.dupe(u8, uri) catch null;
}

pub fn setShellPath(self: *TerminalState, path: []const u8) void {
    const alloc = self.ring.allocator;
    if (self.shell_path) |old| alloc.free(old);
    if (path.len == 0) {
        self.shell_path = null;
        return;
    }
    self.shell_path = alloc.dupe(u8, path) catch null;
}

/// OSC 7337;agent-status — record the agent's reported run state and an optional
/// message preview. Sets the dirty flag only on a real status transition so the
/// daemon/app can cheaply poll for changes (mirrors the title_changed pattern).
pub fn setAgentStatus(self: *TerminalState, status: AgentStatus, message: []const u8) void {
    const n = @min(message.len, self.agent_msg_buf.len);
    @memcpy(self.agent_msg_buf[0..n], message[0..n]);
    self.agent_msg_len = @intCast(n);
    if (self.agent_status != status) {
        self.agent_status = status;
        self.agent_status_changed = true;
    }
    // Session ended → clear usage so a dead agent shows no stale spend.
    if (status == .none) {
        self.agent_usage = .{};
        self.agent_model_len = 0;
        self.agent_transcript_len = 0;
        self.agent_out_last_raw = 0;
        self.agent_out_cumulative = 0;
        self.agent_usage_changed = true;
    }
}

/// Apply a usage update parsed straight from the agent's OSC (the authoritative
/// path — the engine that reads the agent's PTY). Folds the agent's reported
/// output-token figure into a session-cumulative total before storing, then
/// delegates to `setAgentUsage`. Propagated updates (daemon→window grid-sync)
/// call `setAgentUsage` directly and must NOT come through here, or the already-
/// cumulative value would be accumulated twice.
pub fn applyAgentUsageOsc(self: *TerminalState, u: AgentUsage) void {
    var adjusted = u;
    if (u.output_tokens) |cur| {
        // Sum positive deltas; a drop means the agent's window shrank
        // (compaction — tokens we already counted), so rebase without
        // subtracting. Monotonic-source agents (Codex/opencode/Pi) pass through
        // unchanged since cur only ever rises.
        if (cur >= self.agent_out_last_raw) {
            self.agent_out_cumulative += cur - self.agent_out_last_raw;
        }
        self.agent_out_last_raw = cur;
        adjusted.output_tokens = self.agent_out_cumulative;
    }
    self.setAgentUsage(adjusted);
}

/// The message preview attached to the current agent status (may be empty).
pub fn agentMsg(self: *const TerminalState) []const u8 {
    return self.agent_msg_buf[0..self.agent_msg_len];
}

/// Merge an agent-usage update into the current record. Non-null fields
/// overwrite; absent fields keep their prior value (cumulative/sticky), so a
/// partial update (e.g. a later `cost=`-only emit) never wipes earlier counts.
pub fn setAgentUsage(self: *TerminalState, u: AgentUsage) void {
    if (u.input_tokens) |v| self.agent_usage.input_tokens = v;
    if (u.output_tokens) |v| self.agent_usage.output_tokens = v;
    if (u.cache_read_tokens) |v| self.agent_usage.cache_read_tokens = v;
    if (u.cache_write_tokens) |v| self.agent_usage.cache_write_tokens = v;
    if (u.reasoning_tokens) |v| self.agent_usage.reasoning_tokens = v;
    if (u.context_used) |v| self.agent_usage.context_used = v;
    if (u.context_max) |v| self.agent_usage.context_max = v;
    if (u.cost_usd) |v| {
        self.agent_usage.cost_usd = v;
        self.agent_usage.cost_is_estimate = u.cost_is_estimate;
    }
    if (u.model) |m| {
        const n = @min(m.len, self.agent_model_buf.len);
        @memcpy(self.agent_model_buf[0..n], m[0..n]);
        self.agent_model_len = @intCast(n);
    }
    if (u.transcript_path) |t| {
        const n = @min(t.len, self.agent_transcript_buf.len);
        @memcpy(self.agent_transcript_buf[0..n], t[0..n]);
        self.agent_transcript_len = @intCast(n);
    }
    self.agent_usage_changed = true;
}

/// The current usage record, with `model` and `transcript_path` sliced from the
/// fixed buffers.
pub fn agentUsage(self: *const TerminalState) AgentUsage {
    var u = self.agent_usage;
    u.model = if (self.agent_model_len > 0) self.agent_model_buf[0..self.agent_model_len] else null;
    u.transcript_path = if (self.agent_transcript_len > 0) self.agent_transcript_buf[0..self.agent_transcript_len] else null;
    return u;
}

/// Infer an agent status transition from user input. Agent harnesses emit no
/// hook on interrupt or when an input prompt is answered, so we derive these
/// from the bytes the user sends to the pane:
///   - interrupt (lone ESC / Ctrl-C) while working or waiting → idle (aborted)
///   - any real answer while blocked on input → working (the agent resumes)
/// Navigation keys (ESC-prefixed sequences) and input in idle/none states are
/// left alone — the agent's own hooks drive those. Called on the pane's
/// authoritative engine: the keyboard path (local) and the daemon's pane_input
/// handler (grid-sync, which then broadcasts the change to clients).
pub fn applyAgentInputTransition(self: *TerminalState, bytes: []const u8) void {
    if (bytes.len == 0) return;
    const interrupt = key_encode.isInterruptSequence(bytes);
    switch (self.agent_status) {
        .working => if (interrupt) self.setAgentStatus(.idle, ""),
        .input => {
            if (interrupt) {
                self.setAgentStatus(.idle, ""); // Ctrl-C/Esc cancels the prompt
            } else if (bytes[0] != 0x1b) {
                // A real answer (digit, Enter, text) — not a navigation key —
                // unblocks the agent, which is now working again.
                self.setAgentStatus(.working, "");
            }
        },
        else => {},
    }
}

/// Handle OSC 7339;xyron:{json} event.
/// Dispatches by event type: ipc_ready, cwd_changed, etc.
pub fn handleXyronEvent(self: *TerminalState, json: []const u8) void {
    // ipc_ready: extract socket path
    if (std.mem.indexOf(u8, json, "\"ipc_ready\"") != null) {
        if (extractJsonStr(json, "socket")) |path| {
            const alloc = self.ring.allocator;
            if (self.xyron_ipc_socket) |old| alloc.free(old);
            self.xyron_ipc_socket = alloc.dupe(u8, path) catch null;
        }
        return;
    }
    // cwd_changed: update working directory
    if (std.mem.indexOf(u8, json, "\"cwd_changed\"") != null) {
        if (extractJsonStr(json, "new_cwd")) |cwd| {
            // Convert to file:// URI for statusbar compatibility
            var uri_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
            const uri = std.fmt.bufPrint(&uri_buf, "file://localhost{s}", .{cwd}) catch return;
            self.setCwd(uri);
        }
        return;
    }
}

/// Extract a string value from JSON by key. Minimal parser — no escapes.
fn extractJsonStr(json: []const u8, key: []const u8) ?[]const u8 {
    // Look for "key":"value"
    var buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":\"", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, json, needle) orelse return null;
    const start = idx + needle.len;
    if (start >= json.len) return null;
    const end = std.mem.indexOfScalar(u8, json[start..], '"') orelse return null;
    const val = json[start..][0..end];
    if (val.len == 0) return null;
    return val;
}

test "applyAgentInputTransition infers interrupt and prompt-answer transitions" {
    const testing = std.testing;
    var st = try TerminalState.init(testing.allocator, 24, 80, 100);
    defer st.deinit();

    // working + ordinary input (Enter) → still working
    st.setAgentStatus(.working, "");
    st.applyAgentInputTransition("\r");
    try testing.expectEqual(AgentStatus.working, st.agent_status);

    // working + Ctrl-C → idle (interrupt)
    st.applyAgentInputTransition("\x03");
    try testing.expectEqual(AgentStatus.idle, st.agent_status);

    // input + a real answer (digit) → working (the reported fix)
    st.setAgentStatus(.input, "");
    st.applyAgentInputTransition("2");
    try testing.expectEqual(AgentStatus.working, st.agent_status);

    // input + a navigation key (arrow) → still input, not a premature flip
    st.setAgentStatus(.input, "");
    st.applyAgentInputTransition("\x1b[B");
    try testing.expectEqual(AgentStatus.input, st.agent_status);

    // input + Esc → idle (cancel the prompt)
    st.applyAgentInputTransition("\x1b");
    try testing.expectEqual(AgentStatus.idle, st.agent_status);

    // idle + input → unchanged; the agent's UserPromptSubmit hook drives idle→working
    st.setAgentStatus(.idle, "");
    st.applyAgentInputTransition("hello");
    try testing.expectEqual(AgentStatus.idle, st.agent_status);
}

test "setAgentUsage merges sticky and .none clears it" {
    const testing = std.testing;
    var st = try TerminalState.init(testing.allocator, 24, 80, 100);
    defer st.deinit();

    st.setAgentUsage(.{ .input_tokens = 100, .output_tokens = 200, .model = "opus-4.6" });
    var u = st.agentUsage();
    try testing.expectEqual(@as(?u64, 100), u.input_tokens);
    try testing.expectEqual(@as(?u64, 200), u.output_tokens);
    try testing.expectEqualStrings("opus-4.6", u.model.?);

    // Partial update: only cost — earlier in/out and model survive.
    st.setAgentUsage(.{ .cost_usd = 0.42 });
    u = st.agentUsage();
    try testing.expectEqual(@as(?u64, 100), u.input_tokens);
    try testing.expectEqual(@as(?f64, 0.42), u.cost_usd);
    try testing.expectEqualStrings("opus-4.6", u.model.?);

    // Session end clears usage.
    st.setAgentStatus(.none, "");
    u = st.agentUsage();
    try testing.expectEqual(@as(?u64, null), u.input_tokens);
    try testing.expectEqual(@as(?f64, null), u.cost_usd);
    try testing.expectEqual(@as(?[]const u8, null), u.model);
}

test "applyAgentUsageOsc accumulates output across context-window drops" {
    const testing = std.testing;
    var st = try TerminalState.init(testing.allocator, 24, 80, 100);
    defer st.deinit();

    // Window grows: out is the raw figure.
    st.applyAgentUsageOsc(.{ .output_tokens = 1000 });
    try testing.expectEqual(@as(?u64, 1000), st.agentUsage().output_tokens);
    st.applyAgentUsageOsc(.{ .output_tokens = 1200 });
    try testing.expectEqual(@as(?u64, 1200), st.agentUsage().output_tokens);

    // Compaction drops the window to 300 — cumulative must NOT go backward.
    st.applyAgentUsageOsc(.{ .output_tokens = 300 });
    try testing.expectEqual(@as(?u64, 1200), st.agentUsage().output_tokens);

    // New output after compaction adds on top (300 → 500 = +200).
    st.applyAgentUsageOsc(.{ .output_tokens = 500 });
    try testing.expectEqual(@as(?u64, 1400), st.agentUsage().output_tokens);

    // .none resets the accumulator so the next agent starts clean.
    st.setAgentStatus(.none, "");
    st.applyAgentUsageOsc(.{ .output_tokens = 50 });
    try testing.expectEqual(@as(?u64, 50), st.agentUsage().output_tokens);
}

test "over-long model truncates into the fixed buffer" {
    const testing = std.testing;
    var st = try TerminalState.init(testing.allocator, 24, 80, 100);
    defer st.deinit();
    const long = "m" ** 200;
    st.setAgentUsage(.{ .model = long });
    try testing.expectEqual(@as(usize, 64), st.agentUsage().model.?.len);
}
