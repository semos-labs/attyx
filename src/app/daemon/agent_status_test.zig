//! Tests for agent status (OSC 7337;agent-status) propagation across the
//! daemon ↔ client boundary in grid-sync mode.
//!
//! In grid-sync mode the client's engine is passive — it never sees the raw
//! OSC bytes — so the daemon must ship the agent status explicitly. The dirty
//! flag broadcast in the poll loop only fires on a *transition*, and only to
//! clients already focused on the pane. That leaves the focus handler to
//! re-ship the durable `agent_status` whenever a pane becomes newly active,
//! so the tab indicator survives a session switch (which re-focuses panes)
//! and shows up on first focus of a pane whose status fired before the
//! client's focus round-tripped.
const std = @import("std");
const posix = std.posix;
const testing = std.testing;
const protocol = @import("protocol.zig");
const harness = @import("test_harness.zig");
const setup = harness.setup;
const teardown = harness.teardown;
const TestClient = harness.TestClient;

// `.working` is enum value 2 (none, idle, working, input).
const status_working: u8 = 2;

test "daemon: agent status re-shipped when a pane becomes newly active" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "agent-status", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const created = try client.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);

    // Grid-sync so the focus handler takes the snapshot path (the byte-replay
    // path doesn't ship status — there the client's engine sees the OSC bytes).
    const hp = try protocol.encodeHello(&buf, "test", protocol.Capabilities.GRID_SYNC);
    try client.send(.hello, hp);
    _ = try client.expect(.hello_ack, 5000);

    const ap = try protocol.encodeAttach(&buf, sid, 24, 80);
    try client.send(.attach, ap);
    const attached = try client.expect(.attached, 5000);
    const v2 = try protocol.decodeAttachedV2(attached);
    const pane_a = v2.pane_ids[0];

    // Activate pane A (deferred-spawn until first pane_resize) and focus it.
    const rp_a = try protocol.encodePaneResize(&buf, pane_a, 24, 80);
    try client.send(.pane_resize, rp_a);
    const fp_a = try protocol.encodeFocusPanes(&buf, &.{pane_a});
    try client.send(.focus_panes, fp_a);
    posix.nanosleep(0, 400_000_000);
    client.read_len = 0;

    // A second pane to focus away to, so pane A can later go newly-active again.
    const pp = try protocol.encodeCreatePane(&buf, 24, 80, "/tmp");
    try client.send(.create_pane, pp);
    const pane_created = try client.expect(.pane_created, 5000);
    const pane_b = try protocol.decodePaneCreated(pane_created);

    // Drive an OSC 7337 agent-status out of pane A's PTY so the daemon-side
    // engine records the durable status (printf interprets the octal escapes).
    const ip = try protocol.encodePaneInput(
        &buf,
        pane_a,
        "printf '\\033]7337;agent-status;claude;working\\007'\n",
    );
    try client.send(.pane_input, ip);
    posix.nanosleep(0, 300_000_000);
    client.read_len = 0;

    // Focus away to B, then back to A. The re-focus marks A newly active,
    // which must re-ship its durable status — the session-switch path.
    const fp_b = try protocol.encodeFocusPanes(&buf, &.{pane_b});
    try client.send(.focus_panes, fp_b);
    posix.nanosleep(0, 150_000_000);
    client.read_len = 0;

    const fp_back = try protocol.encodeFocusPanes(&buf, &.{pane_a});
    try client.send(.focus_panes, fp_back);

    // Look for the status among the focus burst (snapshot/title/cwd/status);
    // expect() skips past the other message types.
    const payload = try client.expect(.pane_agent_status, 4000);
    const msg = try protocol.decodePaneAgentStatus(payload);
    try testing.expectEqual(@as(u32, pane_a), msg.pane_id);
    try testing.expectEqual(status_working, msg.status);
}
