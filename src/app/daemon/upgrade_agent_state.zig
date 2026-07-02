const std = @import("std");
const DaemonPane = @import("pane.zig").DaemonPane;
const attyx_actions = @import("attyx").actions;
const AgentStatus = attyx_actions.AgentStatus;
const AgentUsage = attyx_actions.AgentUsage;

const UsageBits = struct {
    const input: u16 = 1 << 0;
    const output: u16 = 1 << 1;
    const cache_read: u16 = 1 << 2;
    const cache_write: u16 = 1 << 3;
    const reasoning: u16 = 1 << 4;
    const context_used: u16 = 1 << 5;
    const context_max: u16 = 1 << 6;
    const cost: u16 = 1 << 7;
};

pub const RestoredState = struct {
    status: AgentStatus = .none,
    message: []const u8 = &.{},
    usage: AgentUsage = .{},
};

pub fn serialize(w: anytype, p: *DaemonPane) !void {
    const eng = p.engine orelse {
        try w.writeByte(@intFromEnum(AgentStatus.none));
        try w.writeInt(u16, 0, .little);
        try serializeUsage(w, .{});
        return;
    };
    try w.writeByte(@intFromEnum(eng.state.agent_status));
    const msg = eng.state.agentMsg();
    const msg_len = @min(msg.len, std.math.maxInt(u16));
    try w.writeInt(u16, @intCast(msg_len), .little);
    try w.writeAll(msg[0..msg_len]);
    try serializeUsage(w, eng.state.agentUsage());
}

pub fn deserialize(r: anytype, has_effort: bool) !RestoredState {
    const status = AgentStatus.fromU8(try r.*.readByte());
    const msg_len = try r.*.readU16();
    const msg = try r.*.readSlice(msg_len);
    const usage = try deserializeUsage(r, has_effort);
    return .{ .status = status, .message = msg, .usage = usage };
}

pub fn apply(pane: *DaemonPane, restored: RestoredState) void {
    const eng = pane.engine orelse return;
    if (restored.status != .none) {
        eng.state.setAgentStatus(restored.status, restored.message);
        eng.state.agent_status_changed = false;
    }
    eng.state.setAgentUsage(restored.usage);
    eng.state.agent_usage_changed = false;
    if (restored.usage.output_tokens) |out| {
        eng.state.agent_out_cumulative = out;
        eng.state.agent_out_last_raw = out;
    }
}

fn serializeUsage(w: anytype, u: AgentUsage) !void {
    var bits: u16 = 0;
    if (u.input_tokens != null) bits |= UsageBits.input;
    if (u.output_tokens != null) bits |= UsageBits.output;
    if (u.cache_read_tokens != null) bits |= UsageBits.cache_read;
    if (u.cache_write_tokens != null) bits |= UsageBits.cache_write;
    if (u.reasoning_tokens != null) bits |= UsageBits.reasoning;
    if (u.context_used != null) bits |= UsageBits.context_used;
    if (u.context_max != null) bits |= UsageBits.context_max;
    if (u.cost_usd != null) bits |= UsageBits.cost;

    try w.writeInt(u16, bits, .little);
    if (u.input_tokens) |v| try w.writeInt(u64, v, .little);
    if (u.output_tokens) |v| try w.writeInt(u64, v, .little);
    if (u.cache_read_tokens) |v| try w.writeInt(u64, v, .little);
    if (u.cache_write_tokens) |v| try w.writeInt(u64, v, .little);
    if (u.reasoning_tokens) |v| try w.writeInt(u64, v, .little);
    if (u.context_used) |v| try w.writeInt(u64, v, .little);
    if (u.context_max) |v| try w.writeInt(u64, v, .little);
    if (u.cost_usd) |v| try w.writeInt(u64, @bitCast(v), .little);
    try w.writeByte(if (u.cost_is_estimate) 1 else 0);
    try writeOptionalString(w, u.model);
    try writeOptionalString(w, u.effort);
    try writeOptionalString(w, u.transcript_path);
}

fn deserializeUsage(r: anytype, has_effort: bool) !AgentUsage {
    const bits = try r.*.readU16();
    var u = AgentUsage{};
    if ((bits & UsageBits.input) != 0) u.input_tokens = try r.*.readU64();
    if ((bits & UsageBits.output) != 0) u.output_tokens = try r.*.readU64();
    if ((bits & UsageBits.cache_read) != 0) u.cache_read_tokens = try r.*.readU64();
    if ((bits & UsageBits.cache_write) != 0) u.cache_write_tokens = try r.*.readU64();
    if ((bits & UsageBits.reasoning) != 0) u.reasoning_tokens = try r.*.readU64();
    if ((bits & UsageBits.context_used) != 0) u.context_used = try r.*.readU64();
    if ((bits & UsageBits.context_max) != 0) u.context_max = try r.*.readU64();
    if ((bits & UsageBits.cost) != 0) u.cost_usd = @bitCast(try r.*.readU64());
    u.cost_is_estimate = (try r.*.readByte()) != 0;
    u.model = try readOptionalString(r);
    if (has_effort) u.effort = try readOptionalString(r);
    u.transcript_path = try readOptionalString(r);
    return u;
}

fn writeOptionalString(w: anytype, maybe_s: ?[]const u8) !void {
    const s = maybe_s orelse &.{};
    const n = @min(s.len, std.math.maxInt(u16));
    try w.writeInt(u16, @intCast(n), .little);
    try w.writeAll(s[0..n]);
}

fn readOptionalString(r: anytype) !?[]const u8 {
    const len = try r.*.readU16();
    if (len == 0) return null;
    return try r.*.readSlice(len);
}
