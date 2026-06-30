//! opencode agent-status integration.
//!
//! Unlike Claude/Codex (which expose JSON lifecycle hooks), opencode reports its
//! run state through a JS plugin on its event bus. We write that plugin and make
//! opencode load it two ways, for resilience across opencode versions:
//!
//!   1. Drop it in `~/.config/opencode/plugins/` — the documented auto-load dir.
//!      Note the plural: the older singular `plugin/` no longer loads reliably,
//!      and directory loading itself has shifted between releases.
//!   2. Register it explicitly in `opencode.json(c)` via the `plugin` array using
//!      a `file://` URL — the stable contract, independent of where (or whether)
//!      opencode scans a directory.
//!
//! Loading the same file twice is harmless: the emitter only sets terminal
//! state, and a repeated identical state is a no-op downstream.
//!
//! Config patching is text-level (not parse + re-stringify) so a user's JSONC
//! comments and formatting survive — `std.json` can't round-trip comments. It's
//! idempotent (a substring fast-path) and bails without writing on any
//! unexpected shape, so we never corrupt the user's config.
const std = @import("std");
const ai = @import("agent_integration.zig");

/// Write the plugin and ensure opencode loads it. Best-effort; a no-op if
/// opencode isn't set up. `emitter_path` is the absolute attyx-agent-status path.
pub fn install(a: std.mem.Allocator, home: []const u8, emitter_path: []const u8, telemetry: bool) void {
    const cfg = std.fmt.allocPrint(a, "{s}/.config/opencode", .{home}) catch return;
    // Only act if opencode is configured (don't create ~/.config/opencode).
    var d = std.fs.cwd().openDir(cfg, .{}) catch return;
    d.close();

    // 1. Plugin file in the plural auto-load dir.
    const plugin_dir = std.fmt.allocPrint(a, "{s}/plugins", .{cfg}) catch return;
    ai.mkdirp(a, plugin_dir);
    const plugin_path = std.fmt.allocPrint(a, "{s}/attyx-status.js", .{plugin_dir}) catch return;
    const plugin = std.fmt.allocPrint(a, plugin_fmt, .{ emitter_path, if (telemetry) "true" else "false" }) catch return;
    ai.writeAtomic(a, plugin_path, plugin, 0o644);

    // Remove a stale plugin from older attyx (singular `plugin/`), which would
    // otherwise double-load. Best-effort.
    if (std.fmt.allocPrintSentinel(a, "{s}/plugin/attyx-status.js", .{cfg}, 0)) |stale| {
        std.posix.unlinkZ(stale) catch {};
    } else |_| {}

    // 2. Register the plugin in opencode's config as a belt-and-suspenders
    //    fallback that survives directory-loading changes.
    registerPlugin(a, cfg, plugin_path);
}

/// Add the plugin's `file://` URL to the `plugin` array of whichever config
/// opencode reads (preferring an existing `.jsonc`, then `.json`), creating a
/// minimal `opencode.json` if neither exists.
fn registerPlugin(a: std.mem.Allocator, cfg_dir: []const u8, plugin_path: []const u8) void {
    const file_url = std.fmt.allocPrint(a, "file://{s}", .{plugin_path}) catch return;
    const entry = std.fmt.allocPrint(a, "\"{s}\"", .{file_url}) catch return;

    const jsonc = std.fmt.allocPrint(a, "{s}/opencode.jsonc", .{cfg_dir}) catch return;
    const json = std.fmt.allocPrint(a, "{s}/opencode.json", .{cfg_dir}) catch return;

    if (ai.readFile(a, jsonc)) |content| {
        if (patchConfig(a, content, entry, file_url)) |out| ai.writeAtomic(a, jsonc, out, 0o644);
        return;
    }
    if (ai.readFile(a, json)) |content| {
        if (patchConfig(a, content, entry, file_url)) |out| ai.writeAtomic(a, json, out, 0o644);
        return;
    }
    // No config yet → create a minimal opencode.json.
    const fresh = std.fmt.allocPrint(a, "{{\n  \"plugin\": [{s}]\n}}\n", .{entry}) catch return;
    ai.writeAtomic(a, json, fresh, 0o644);
}

/// Return the patched config text, or null when no write is needed or safe:
/// the plugin is already registered, or the structure is unexpected.
fn patchConfig(a: std.mem.Allocator, content: []const u8, entry: []const u8, file_url: []const u8) ?[]u8 {
    if (std.mem.indexOf(u8, content, file_url) != null) return null; // already registered
    return insertPlugin(a, content, entry);
}

/// Insert `entry` (a quoted JSON string) into the root object's `plugin` array,
/// preserving surrounding text. Returns null on an unexpected shape so the
/// caller leaves the file untouched.
fn insertPlugin(a: std.mem.Allocator, src: []const u8, entry: []const u8) ?[]u8 {
    if (pluginKeyColon(src)) |colon| {
        // `"plugin"` exists — its value must be an array, else bail.
        const open = skipWs(src, colon + 1);
        if (open >= src.len or src[open] != '[') return null;
        const first = skipWs(src, open + 1);
        const empty = first < src.len and src[first] == ']';
        const ins = if (empty)
            entry
        else
            (std.fmt.allocPrint(a, "{s}, ", .{entry}) catch return null);
        return splice(a, src, open + 1, ins);
    }

    // No `plugin` key — add it as the root object's first key.
    const brace = std.mem.indexOfScalar(u8, src, '{') orelse return null;
    const after = skipWs(src, brace + 1);
    const empty_obj = after < src.len and src[after] == '}';
    const ins = if (empty_obj)
        (std.fmt.allocPrint(a, "\n  \"plugin\": [{s}]\n", .{entry}) catch return null)
    else
        (std.fmt.allocPrint(a, "\n  \"plugin\": [{s}],", .{entry}) catch return null);
    return splice(a, src, brace + 1, ins);
}

/// Index of the `:` following the first `"plugin"` used as an object key (only
/// whitespace may sit between the key and its colon), or null.
fn pluginKeyColon(s: []const u8) ?usize {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, s, from, "\"plugin\"")) |kpos| {
        const after = kpos + "\"plugin\"".len;
        const c = skipWs(s, after);
        if (c < s.len and s[c] == ':') return c;
        from = after; // a value or substring named "plugin" — keep looking
    }
    return null;
}

fn skipWs(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            ' ', '\t', '\n', '\r' => {},
            else => break,
        }
    }
    return i;
}

fn splice(a: std.mem.Allocator, src: []const u8, at: usize, ins: []const u8) ?[]u8 {
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ src[0..at], ins, src[at..] }) catch null;
}

// ---------------------------------------------------------------------------
// Plugin template
// ---------------------------------------------------------------------------

/// opencode plugin. `{s}` is the absolute emitter path. The plugin-init body
/// runs once when opencode launches (env, incl. ATTYX_PID/ATTYX_TTY, is
/// inherited), so we emit idle there to register the agent on launch — the
/// reliable startup signal, since session.created delivery to plugins is racy.
/// Thereafter: working is derived from tool.execute.before and assistant
/// message updates; session.idle → idle; permission.asked → input and
/// permission.replied → working (the native resolution signal, so the prompt
/// state clears even without a keystroke for attyx to infer from). Runs the
/// emitter via Node's child_process so the emitter self-gates and targets the
/// pane tty.
const plugin_fmt =
    \\// Attyx agent status plugin — reports opencode's run state to the
    \\// terminal via the attyx emitter. No-op outside attyx (emitter self-gates).
    \\import {{ spawnSync }} from "node:child_process";
    \\import {{ appendFileSync }} from "node:fs";
    \\import {{ tmpdir }} from "node:os";
    \\const EMIT = "{s}";
    \\const TELEMETRY = {s};
    \\function emit(state) {{
    \\  try {{ spawnSync(EMIT, [state], {{ stdio: "ignore" }}); }} catch (e) {{}}
    \\}}
    \\// Transcript: opencode hands us assistant text in `message.part.updated`
    \\// events, so we buffer text parts per message id and, on finalize, append one
    \\// line in Claude's transcript schema to a per-agent file. `agent read` parses
    \\// that schema as-is; the path rides `tx=` on the usage emit below.
    \\const ATTYX_PID = process.env.ATTYX_PID;
    \\const TX = ATTYX_PID ? tmpdir() + "/attyx-tx-" + ATTYX_PID + "-" + process.pid + ".jsonl" : null;
    \\let wrote = false;
    \\const texts = new Map();
    \\function recordTurn(id) {{
    \\  const parts = texts.get(id);
    \\  if (!parts) return;
    \\  const text = [...parts.values()].join("\n");
    \\  texts.delete(id);
    \\  if (!TX || !text) return;
    \\  const line = JSON.stringify({{ type: "assistant", message: {{ content: [{{ type: "text", text }}] }} }}) + "\n";
    \\  try {{ appendFileSync(TX, line); wrote = true; }} catch (e) {{}}
    \\}}
    \\// opencode reports per-message token/cost (incl. its own computed cost); our
    \\// schema is cumulative, so we keep the latest figures per message id (so
    \\// streaming re-updates of the same message overwrite, not double-count) and
    \\// emit the running session sum. Fired only on completed assistant messages.
    \\const usageTotals = new Map();
    \\function emitUsage(m) {{
    \\  const kv = [];
    \\  if (TELEMETRY && m && m.tokens) {{
    \\    const t = m.tokens;
    \\    usageTotals.set(m.id, {{
    \\      in: t.input || 0, out: t.output || 0,
    \\      cr: (t.cache && t.cache.read) || 0, cw: (t.cache && t.cache.write) || 0,
    \\      rsn: t.reasoning || 0, cost: m.cost || 0,
    \\    }});
    \\    const s = {{ in: 0, out: 0, cr: 0, cw: 0, rsn: 0, cost: 0 }};
    \\    for (const v of usageTotals.values()) {{ s.in += v.in; s.out += v.out; s.cr += v.cr; s.cw += v.cw; s.rsn += v.rsn; s.cost += v.cost; }}
    \\    kv.push("in=" + s.in, "out=" + s.out, "cr=" + s.cr, "cw=" + s.cw, "rsn=" + s.rsn, "cost=" + s.cost);
    \\    if (m.modelID) kv.push("model=" + m.modelID);
    \\  }}
    \\  recordTurn(m.id);
    \\  if (TX && wrote) kv.push("tx=" + TX);
    \\  if (kv.length) try {{ spawnSync(EMIT, ["usage", kv.join(";")], {{ stdio: "ignore" }}); }} catch (e) {{}}
    \\}}
    \\const AttyxStatus = async (ctx) => {{
    \\  // Runs once at opencode launch — register the agent as present-and-idle
    \\  // immediately, instead of waiting for the first activity event.
    \\  emit("idle");
    \\  return {{
    \\    event: async ({{ event }}) => {{
    \\      const props = (event && event.properties) || {{}};
    \\      switch (event && event.type) {{
    \\        case "session.created":
    \\          emit("idle");
    \\          break;
    \\        case "tool.execute.before":
    \\          emit("working");
    \\          break;
    \\        case "message.part.updated":
    \\          if (props.part && props.part.type === "text") {{
    \\            emit("working");
    \\            const p = props.part;
    \\            if (p.messageID && typeof p.text === "string") {{
    \\              let inner = texts.get(p.messageID);
    \\              if (!inner) {{ inner = new Map(); texts.set(p.messageID, inner); }}
    \\              inner.set(p.id, p.text);
    \\            }}
    \\          }}
    \\          break;
    \\        case "message.updated": {{
    \\          const m = props.info;
    \\          if (m && m.role === "assistant" && m.time && m.time.completed) emitUsage(m);
    \\          break;
    \\        }}
    \\        case "permission.asked":
    \\          emit("input");
    \\          break;
    \\        case "permission.replied":
    \\          emit("working");
    \\          break;
    \\        case "session.idle":
    \\          emit("idle");
    \\          break;
    \\        case "session.status":
    \\          if (props.status && props.status.type === "idle") emit("idle");
    \\          break;
    \\        case "session.deleted":
    \\          emit("none");
    \\          break;
    \\        default:
    \\          break;
    \\      }}
    \\    }},
    \\  }};
    \\}};
    \\export {{ AttyxStatus }};
    \\export default AttyxStatus;
    \\
;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const test_url = "file:///E/attyx-status.js";
const test_entry = "\"file:///E/attyx-status.js\"";

/// Assert `s` parses as valid JSON (the config cases here carry no comments).
fn expectValidJson(a: std.mem.Allocator, s: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, a, s, .{});
    parsed.deinit();
}

test "plugin template embeds the emitter path and maps key events" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plugin = try std.fmt.allocPrint(a, plugin_fmt, .{ "/E/attyx-status", "true" });
    try testing.expect(std.mem.indexOf(u8, plugin, "const EMIT = \"/E/attyx-status\"") != null);
    try testing.expect(std.mem.indexOf(u8, plugin, "const TELEMETRY = true") != null);
    try testing.expect(std.mem.indexOf(u8, plugin, "permission.asked") != null);
    try testing.expect(std.mem.indexOf(u8, plugin, "permission.replied") != null);
    try testing.expect(std.mem.indexOf(u8, plugin, "session.idle") != null);
    try testing.expect(std.mem.indexOf(u8, plugin, "emit(\"working\")") != null);
    try testing.expect(std.mem.indexOf(u8, plugin, "emit(\"idle\")") != null);
    try testing.expect(std.mem.indexOf(u8, plugin, "session.created") != null);
    // Usage enrichment: cumulative accumulator + message.updated mapping.
    try testing.expect(std.mem.indexOf(u8, plugin, "message.updated") != null);
    try testing.expect(std.mem.indexOf(u8, plugin, "function emitUsage") != null);
    try testing.expect(std.mem.indexOf(u8, plugin, "spawnSync(EMIT, [\"usage\"") != null);
    try testing.expect(std.mem.indexOf(u8, plugin, "m.time.completed") != null);
    // Transcript: buffers text parts, writes Claude-schema lines, rides tx= on usage.
    try testing.expect(std.mem.indexOf(u8, plugin, "function recordTurn") != null);
    try testing.expect(std.mem.indexOf(u8, plugin, "process.pid") != null);
    try testing.expect(std.mem.indexOf(u8, plugin, "kv.push(\"tx=\" + TX)") != null);
    try testing.expect(std.mem.indexOf(u8, plugin, "if (!TELEMETRY) return") == null);
    try testing.expect(std.mem.indexOf(u8, plugin, "m.tokens &&") == null);
}

test "insert into an empty object adds the plugin key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = insertPlugin(a, "{}", test_entry).?;
    try testing.expect(std.mem.indexOf(u8, out, test_url) != null);
    try expectValidJson(a, out);
}

test "insert preserves unrelated keys and JSONC comments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\{
        \\  // keep me
        \\  "model": "opus"
        \\}
    ;
    const out = insertPlugin(a, src, test_entry).?;
    try testing.expect(std.mem.indexOf(u8, out, "// keep me") != null); // comment kept
    try testing.expect(std.mem.indexOf(u8, out, "\"model\"") != null); // key kept
    try testing.expect(std.mem.indexOf(u8, out, test_url) != null); // ours added
}

test "insert prepends into an existing plugin array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = insertPlugin(a, "{ \"plugin\": [\"existing-pkg\"] }", test_entry).?;
    try testing.expect(std.mem.indexOf(u8, out, "existing-pkg") != null); // user entry kept
    try testing.expect(std.mem.indexOf(u8, out, test_url) != null); // ours added
    try expectValidJson(a, out);
}

test "insert into an empty plugin array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = insertPlugin(a, "{ \"plugin\": [] }", test_entry).?;
    try testing.expect(std.mem.indexOf(u8, out, test_url) != null);
    try expectValidJson(a, out);
}

test "patchConfig is idempotent when the plugin is already registered" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "{ \"plugin\": [\"file:///E/attyx-status.js\"] }";
    try testing.expect(patchConfig(a, src, test_entry, test_url) == null);
}

test "insert bails when plugin is present but not an array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(insertPlugin(a, "{ \"plugin\": \"nope\" }", test_entry) == null);
}

test "pluginKeyColon ignores a string value that happens to be \"plugin\"" {
    // The value "plugin" must not be mistaken for the key; with no real key we
    // fall through to adding one.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = insertPlugin(a, "{ \"type\": \"plugin\" }", test_entry).?;
    try testing.expect(std.mem.indexOf(u8, out, test_url) != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"type\"") != null);
    try expectValidJson(a, out);
}
