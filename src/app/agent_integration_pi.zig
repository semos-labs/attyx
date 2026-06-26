//! Pi (pi.dev coding agent) agent-status integration.
//!
//! Like opencode, Pi reports run state through a TypeScript extension on its
//! event bus rather than JSON lifecycle hooks. We drop that extension into Pi's
//! documented global auto-discovery dir (`~/.pi/agent/extensions/*.ts`), which
//! loads it on every launch with no config patching — the stable contract, so
//! unlike opencode there's no belt-and-suspenders settings registration.
//!
//! Pi has no distinct permission/approval event (approvals surface as inline
//! `ctx.ui.confirm` prompts inside a tool_call handler, not an observable
//! lifecycle event), so there's no "input" state — the dot registers idle on
//! launch, working during a turn, idle after, none on shutdown. Same honest
//! limitation as Codex, which lacks a notify event.
//!
//! The extension is written via the emitter (which self-gates on ATTYX_PID), so
//! it's a no-op when Pi runs outside attyx.
const std = @import("std");
const ai = @import("agent_integration.zig");

/// Write the extension into Pi's global auto-discovery dir. Best-effort; a no-op
/// if Pi isn't set up. `emitter_path` is the absolute attyx-agent-status path.
pub fn install(a: std.mem.Allocator, home: []const u8, emitter_path: []const u8, telemetry: bool) void {
    const pi_dir = std.fmt.allocPrint(a, "{s}/.pi", .{home}) catch return;
    // Only act if Pi is actually set up (don't create ~/.pi speculatively).
    var d = std.fs.cwd().openDir(pi_dir, .{}) catch return;
    d.close();

    const ext_dir = std.fmt.allocPrint(a, "{s}/agent/extensions", .{pi_dir}) catch return;
    ai.mkdirp(a, ext_dir);
    const ext_path = std.fmt.allocPrint(a, "{s}/attyx-status.ts", .{ext_dir}) catch return;
    const ext = std.fmt.allocPrint(a, extension_fmt, .{ emitter_path, if (telemetry) "true" else "false" }) catch return;
    ai.writeAtomic(a, ext_path, ext, 0o644);
}

// ---------------------------------------------------------------------------
// Extension template
// ---------------------------------------------------------------------------

/// Pi extension. `{s}` is the absolute emitter path. The factory body runs once
/// when Pi loads the extension at launch (env, incl. ATTYX_PID/ATTYX_TTY, is
/// inherited), so we emit idle there to register the agent immediately. Then:
/// session_start → idle, agent_start/tool_call → working, agent_end → idle,
/// session_shutdown → none. Runs the emitter via Node's child_process so it
/// self-gates and targets the pane tty.
const extension_fmt =
    \\// Attyx agent status extension — reports Pi's run state to the terminal via
    \\// the attyx emitter. No-op outside attyx (emitter self-gates on ATTYX_PID).
    \\import {{ spawnSync }} from "node:child_process";
    \\const EMIT = "{s}";
    \\const TELEMETRY = {s};
    \\function emit(state) {{
    \\  try {{ spawnSync(EMIT, [state], {{ stdio: "ignore" }}); }} catch (e) {{}}
    \\}}
    \\// Per-message token/cost is cumulative-summed: message_end fires once per
    \\// finalized message (not streamed), so plain addition is correct. Context
    \\// (used/max) is a live snapshot from ctx.getContextUsage(); model from ctx.
    \\let totIn = 0, totOut = 0, totCr = 0, totCw = 0, totCost = 0;
    \\function emitUsage(ctx, message) {{
    \\  if (!TELEMETRY) return;
    \\  const u = message && message.usage;
    \\  if (!u) return;
    \\  totIn += u.input || 0; totOut += u.output || 0;
    \\  totCr += u.cacheRead || 0; totCw += u.cacheWrite || 0;
    \\  if (u.cost && typeof u.cost.total === "number") totCost += u.cost.total;
    \\  const kv = ["in=" + totIn, "out=" + totOut, "cr=" + totCr, "cw=" + totCw, "cost=" + totCost];
    \\  try {{
    \\    const cu = ctx && ctx.getContextUsage && ctx.getContextUsage();
    \\    if (cu) {{
    \\      if (cu.tokens != null) kv.push("ctx=" + cu.tokens);
    \\      if (cu.contextWindow) kv.push("ctxmax=" + cu.contextWindow);
    \\    }}
    \\    const model = ctx && ctx.model && ctx.model.id;
    \\    if (model) kv.push("model=" + model);
    \\  }} catch (e) {{}}
    \\  try {{ spawnSync(EMIT, ["usage", kv.join(";")], {{ stdio: "ignore" }}); }} catch (e) {{}}
    \\}}
    \\export default function (pi) {{
    \\  // Runs once at extension load (Pi launch) — register the agent as
    \\  // present-and-idle immediately, before any activity event.
    \\  emit("idle");
    \\  pi.on("session_start", async () => emit("idle"));
    \\  pi.on("agent_start", async () => emit("working"));
    \\  pi.on("tool_call", async () => emit("working"));
    \\  pi.on("agent_end", async () => emit("idle"));
    \\  pi.on("message_end", async (event, ctx) => {{
    \\    try {{ if (event && event.message && event.message.role === "assistant") emitUsage(ctx, event.message); }} catch (e) {{}}
    \\  }});
    \\  pi.on("session_shutdown", async () => emit("none"));
    \\}}
    \\
;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "extension template embeds the emitter path and maps key events" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ext = try std.fmt.allocPrint(a, extension_fmt, .{ "/E/attyx-agent-status", "true" });
    try testing.expect(std.mem.indexOf(u8, ext, "const EMIT = \"/E/attyx-agent-status\"") != null);
    try testing.expect(std.mem.indexOf(u8, ext, "const TELEMETRY = true") != null);
    try testing.expect(std.mem.indexOf(u8, ext, "session_start") != null);
    try testing.expect(std.mem.indexOf(u8, ext, "agent_start") != null);
    try testing.expect(std.mem.indexOf(u8, ext, "tool_call") != null);
    try testing.expect(std.mem.indexOf(u8, ext, "agent_end") != null);
    try testing.expect(std.mem.indexOf(u8, ext, "session_shutdown") != null);
    try testing.expect(std.mem.indexOf(u8, ext, "emit(\"working\")") != null);
    try testing.expect(std.mem.indexOf(u8, ext, "emit(\"none\")") != null);
    // Usage enrichment: getContextUsage + message_end mapping.
    try testing.expect(std.mem.indexOf(u8, ext, "getContextUsage") != null);
    try testing.expect(std.mem.indexOf(u8, ext, "message_end") != null);
    try testing.expect(std.mem.indexOf(u8, ext, "function emitUsage") != null);
    try testing.expect(std.mem.indexOf(u8, ext, "spawnSync(EMIT, [\"usage\"") != null);
}

test "install writes the extension only when ~/.pi exists" {
    const home = "/tmp/attyx_pi_install_test";
    std.fs.cwd().deleteTree(home) catch {};
    defer std.fs.cwd().deleteTree(home) catch {};

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // No ~/.pi → no-op (don't create it speculatively).
    install(a, home, "/E/attyx-agent-status", true);
    try testing.expect(std.fs.cwd().openDir(home, .{}) == error.FileNotFound);

    // ~/.pi present → extension written to the auto-discovery dir.
    try std.fs.cwd().makePath(home ++ "/.pi");
    install(a, home, "/E/attyx-agent-status", true);
    const ext = ai.readFile(a, home ++ "/.pi/agent/extensions/attyx-status.ts") orelse return error.NoExtension;
    try testing.expect(std.mem.indexOf(u8, ext, "/E/attyx-agent-status") != null);
    try testing.expect(std.mem.indexOf(u8, ext, "session_shutdown") != null);
}
