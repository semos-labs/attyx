const std = @import("std");
const attyx = @import("attyx");
const tab_manager = @import("tab_manager.zig");

/// Per-tab agent status for the status dot. Driven solely by the agent's own
/// lifecycle hooks (OSC 7337;agent-status) — see agent_integration.zig. The
/// colors live in tab_bar.zig: idle=green, running=orange, waiting=purple.
pub const AgentStatus = enum(u2) {
    none,
    idle,
    running,
    waiting,
};

pub const AgentStatuses = [tab_manager.max_tabs]AgentStatus;

/// Map a hook-reported (term-layer) status onto the renderer's status enum.
pub fn fromHookStatus(s: attyx.actions.AgentStatus) AgentStatus {
    return switch (s) {
        .none => .none,
        .idle => .idle,
        .working => .running,
        .input => .waiting,
    };
}

test "fromHookStatus maps every term status to a render status" {
    try std.testing.expectEqual(AgentStatus.none, fromHookStatus(.none));
    try std.testing.expectEqual(AgentStatus.idle, fromHookStatus(.idle));
    try std.testing.expectEqual(AgentStatus.running, fromHookStatus(.working));
    try std.testing.expectEqual(AgentStatus.waiting, fromHookStatus(.input));
}
