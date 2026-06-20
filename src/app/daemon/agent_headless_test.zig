//! Tests for the headless agent surfaces: `list agents -s N` (list_agents ctl
//! op) and `watch agents -s N` (watch_agents message). Both serve a target
//! session directly from the daemon's own engines, with no window attached —
//! the cross-session path that the window-side handler can't provide.
const std = @import("std");
const posix = std.posix;
const testing = std.testing;
const protocol = @import("protocol.zig");
const harness = @import("test_harness.zig");
const setup = harness.setup;
const teardown = harness.teardown;
const TestClient = harness.TestClient;

/// printf an OSC 7337 agent-status (working) out of the pane's shell.
const agent_osc_cmd = "printf '\\033]7337;agent-status;claude;working\\007'\n";

/// One `list_agents` ctl round-trip. Returns the response body (JSON when
/// `as_json`) copied into `out`. Caller-supplied buffer keeps the slice valid
/// past the client's rolling read buffer.
fn listAgents(client: *TestClient, sid: u32, as_json: bool, out: []u8) ![]const u8 {
    var op_body: [5]u8 = undefined;
    op_body[0] = if (as_json) 1 else 0;
    std.mem.writeInt(u32, op_body[1..5], 0, .little); // pane_filter 0 = all
    var req_buf: [64]u8 = undefined;
    const req = try protocol.encodeCtlRequest(&req_buf, sid, @intFromEnum(protocol.CtlOp.list_agents), &op_body);
    try client.send(.ctl_request, req);
    const resp = try client.expect(.ctl_response, 4000);
    try testing.expect(resp.len >= 1);
    try testing.expectEqual(@as(u8, 0), resp[0]); // status ok
    const body = resp[1..];
    @memcpy(out[0..body.len], body);
    return out[0..body.len];
}

test "list_agents ctl: empty for a session with no agent" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "headless-empty", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const sid = try protocol.decodeCreated(try client.expect(.created, 5000));

    var out: [256]u8 = undefined;
    const body = try listAgents(&client, sid, true, &out);
    try testing.expectEqualStrings("[]", body);
}

test "list_agents and watch_agents stream an active agent" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "headless-agent", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const sid = try protocol.decodeCreated(try client.expect(.created, 5000));

    // Drive the agent OSC over the headless write_input path — this also
    // activates the deferred pane (spawns its PTY + engine), so no attach is
    // needed. op_body: [pane_id:u32 (0 = first)][bytes].
    var in_buf: [128]u8 = undefined;
    std.mem.writeInt(u32, in_buf[0..4], 0, .little);
    @memcpy(in_buf[4..][0..agent_osc_cmd.len], agent_osc_cmd);
    const wreq_body = in_buf[0 .. 4 + agent_osc_cmd.len];
    var wreq_buf: [192]u8 = undefined;
    const wreq = try protocol.encodeCtlRequest(&wreq_buf, sid, @intFromEnum(protocol.CtlOp.write_input), wreq_body);
    try client.send(.ctl_request, wreq);
    _ = try client.expect(.ctl_response, 4000); // write ack

    // Poll list_agents until the daemon's engine has processed the OSC.
    var out: [512]u8 = undefined;
    var found = false;
    var tries: u32 = 0;
    while (tries < 40) : (tries += 1) {
        const body = try listAgents(&client, sid, true, &out);
        if (std.mem.indexOf(u8, body, "\"state\":\"working\"") != null) {
            found = true;
            break;
        }
        posix.nanosleep(0, 100_000_000);
    }
    try testing.expect(found);

    // A fresh watcher must receive the already-active agent as a snapshot
    // agent_event right after parking.
    var watcher = try TestClient.connect(env.path());
    defer watcher.deinit();
    var wbuf: [8]u8 = undefined;
    std.mem.writeInt(u32, wbuf[0..4], sid, .little);
    std.mem.writeInt(u32, wbuf[4..8], 0, .little); // pane_filter 0 = all
    try watcher.send(.watch_agents, &wbuf);
    const event = try watcher.expect(.agent_event, 4000);
    try testing.expect(std.mem.indexOf(u8, event, "\"state\":\"working\"") != null);
}
