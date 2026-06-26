# Agent Token & Context Telemetry

Implementation spec for collecting per-agent token usage, cost, and context-window
data across every agent Attyx already tracks (Claude Code, Codex, opencode, Pi),
and surfacing it through the existing IPC / CLI / MCP surfaces plus a new dashboard
overlay.

This document is written to be handed to an implementing agent. It assumes the
reader knows the existing agent-status pipeline (`docs/architecture.md`,
`src/app/agent_integration.zig`, `src/term/state_osc.zig`, `src/ipc/watch.zig`).
Read those first if the data path below isn't already familiar.

---

## 1. Goal and non-goals

### Goal

Attyx already paints a status dot per pane (idle / working / input) driven by each
agent's own lifecycle reporter. Extend that same pipeline to also carry **usage
telemetry** so the operator console can answer:

- How many tokens has each running agent burned this session (in / out / cache)?
- What's the running cost?
- How full is each agent's context window?
- Aggregated across all panes/sessions: how many agents, total spend, total tokens.

The end state is a `attyx list agents --json` that includes a `usage` object, a
`watch agents` stream that emits usage updates, MCP parity, and a built-in
dashboard overlay (`Cmd/Ctrl+Shift+A`) showing a live table.

### Non-goals

- **Historical/billing-grade accounting.** This is a live operator view, not a
  replacement for `ccusage`. We report what the agent reports, normalized.
- **Cross-session persistence of usage.** Usage is in-memory, scoped to the life
  of the pane's agent session. When the agent ends (`status → none`), its usage
  record is cleared like its status is today.
- **Parsing full transcripts for content.** We only extract token/cost/context
  counters, never message bodies.

---

## 2. Why this is feasible (research summary)

All four agents persist token usage locally, and `ccusage` already reads all four
from these exact files — so cross-agent support is proven, not speculative. The
catch is that the *acquisition path differs per agent*, and Claude's on-disk JSONL
token counts are unreliable. Details:

| Agent | Source of truth | Format | Accurate? | Acquisition path for Attyx |
|---|---|---|---|---|
| **Claude Code** | statusline JSON payload (NOT the JSONL) | JSON on stdin to a `statusLine` command | statusline = accurate; JSONL `input_tokens`/`output_tokens` are streaming **placeholders** (under-count 100–174× / 10–17×); cache fields accurate | Inject a `statusLine` command into `settings.json`, same mechanism as hooks |
| **Codex** | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | JSONL; `event_msg` with `payload.type=="token_count"` = cumulative totals | accurate; **only ≥ 2025-09-06 builds**; needs `turn_context` for model | Tail the active rollout file (only agent that needs file I/O) |
| **opencode** | live event bus + session storage | message events carry tokens **and** opencode's own computed cost | accurate | Enrich the JS **plugin** we already inject |
| **Pi** | `~/.pi/agent/sessions/*.jsonl` and `ctx.getContextUsage()` | JSONL assistant messages w/ usage; in-process context API | accurate | Enrich the TS **extension** we already inject |

**Key architectural consequence:** three of four agents can emit accurate usage
*in-process or via injection* (Claude via statusline, opencode + Pi via their
plugins) — i.e. through infrastructure we already own. Only **Codex** requires
reading session files. So the bulk of this work is enriching the existing
reporters to emit a second OSC message, not building four JSONL parsers in Zig.

**Do not** build the dashboard on Claude's JSONL `input_tokens`/`output_tokens`.
They are streaming placeholders (≈75% of entries are 0 or 1, never finalized).
The statusline payload Claude pipes to `statusLine` scripts carries the accurate
cumulative `total_input_tokens`, `total_output_tokens` (incl. thinking), context
window, and cost. See §10 sources.

---

## 3. Normalized schema

Define one normalized usage record that every agent fills as completely as it can.
Unknown fields are `null`/absent, never `0` — the UI renders `—` for unknowns so
we never imply "zero spend" when we simply lack data.

```
AgentUsage {
  input_tokens:        u64?   // non-cached input this session (cumulative)
  output_tokens:       u64?   // output incl. reasoning/thinking where the agent counts it
  cache_read_tokens:   u64?
  cache_write_tokens:  u64?   // a.k.a. cache_creation
  reasoning_tokens:    u64?   // optional, when reported separately (informational)
  context_used:        u64?   // tokens currently in the context window
  context_max:         u64?   // model context window size
  cost_usd:            f64?   // agent-reported cost if available; else computed (§7)
  model:               []u8?  // model id/alias, for display + pricing
  cost_is_estimate:    bool   // true when we computed cost ourselves
  updated_ms:          i64    // monotonic ms of last update
}
```

Coverage by agent (what each can realistically fill):

| Field | Claude (statusline) | Codex (JSONL) | opencode (plugin) | Pi (extension) |
|---|---|---|---|---|
| input / output | ✅ | ✅ | ✅ | ✅ |
| cache read/write | ✅ | ✅ | ✅ | ✅ |
| reasoning | ➖ (folded into output) | ✅ | ✅ | ➖ |
| context_used / max | ✅ | ➖ (derivable) | ✅ | ✅ (`getContextUsage`) |
| cost_usd | ✅ (payload has cost) | ❌ → compute | ✅ (opencode computes) | ➖ → compute |
| model | ✅ | ✅ (`turn_context`) | ✅ | ✅ |

Where `cost_usd` is unavailable we compute it (§7) and set `cost_is_estimate=true`.

---

## 4. End-to-end data path

The usage signal rides the **same pipeline as agent status**, as a parallel
channel. Reuse every layer; add a sibling message type at each.

```
agent reporter (per agent)
   │  emits OSC 7337;agent-usage;<agent>;<kv...>
   ▼
term parser (src/term/parser.zig dispatchOsc7337)
   │  → new Action: set_agent_usage
   ▼
term state (src/term/state.zig + src/term/state_osc.zig)
   │  stores AgentUsage; sets agent_usage_changed flag
   ▼
event loop (src/app/ui/event_loop.zig)
   │  on flag: broadcast to watchers + (daemon) propagate
   ▼
daemon propagation (src/app/daemon/*) — new msg pane_agent_usage = 0x98
   │  cross-session aggregation
   ▼
IPC surfaces:
   • list_agents JSON/TSV (src/ipc/agents.zig)         → add "usage"
   • watch agents stream  (src/ipc/watch.zig)          → include usage
   • MCP list_agents      (src/ipc/mcp_tools.zig)       → unchanged schema, richer payload
   ▼
dashboard overlay (src/overlay/agent_dashboard.zig — NEW)
```

Design rule: **usage is a separate OSC subcommand and a separate state field from
status.** Status changes are low-frequency lifecycle transitions; usage updates
can arrive every turn or every statusline refresh. Keeping them separate means a
usage refresh never spuriously flips the status dot and never churns
`agent_status_changed` (which gates native notifications in `maybeNotifyAgent`).

---

## 5. Wire format — OSC `7337;agent-usage`

Current status OSC (do not change): `7337;agent-status;<agent>;<state>[;<message>]`.

Add a sibling: 

```
ESC ] 7337 ; agent-usage ; <agent> ; <k=v>[; <k=v>...] BEL
```

Key/value pairs, `;`-separated, keys from the normalized schema. Keys are optional;
emit only what's known. Integer values are base-10; `cost` is a decimal string;
`model` is percent-or-nothing escaped (no `;`). Example:

```
ESC]7337;agent-usage;agent;in=1234;out=5678;cr=900000;cw=12000;ctx=82000;ctxmax=200000;cost=0.4213;model=claude-opus-4-6BEL
```

Canonical key set:

| key | field | type |
|---|---|---|
| `in` | input_tokens | u64 |
| `out` | output_tokens | u64 |
| `cr` | cache_read_tokens | u64 |
| `cw` | cache_write_tokens | u64 |
| `rsn` | reasoning_tokens | u64 |
| `ctx` | context_used | u64 |
| `ctxmax` | context_max | u64 |
| `cost` | cost_usd | decimal |
| `model` | model | string (no `;`) |

Rationale for KV-over-JSON: the emitter side is often a POSIX `sh` script (Claude,
the shared emitter) where assembling JSON safely is painful; a flat KV list is
trivial to build with `printf` and trivial to parse with a single split loop in
Zig. The message field on the status OSC already proved the "remainder may contain
delimiters" pattern; here we forbid `;` in values to keep parsing a clean split.

Parser changes (`src/term/parser.zig`, `dispatchOsc7337`): after the existing
`agent-status;` branch, add an `agent-usage;` branch that strips the optional
`<agent>;` prefix (mirror the status branch) and returns a new action
`.{ .set_agent_usage = .{ .usage = parsed } }`. Parse the KV list into the
`AgentUsage` struct in the parser or defer raw bytes to the state layer — prefer
parsing in a small helper in `actions.zig`/`state_osc.zig` so the parser stays
allocation-free and operates on the OSC buffer slice. Values absent from the
message leave the corresponding `?` field unchanged from its prior value
(cumulative semantics: a later partial update must not wipe earlier fields).

---

## 6. Per-layer implementation

### 6.1 `src/term/actions.zig`

- Add `pub const AgentUsage = struct { ... }` per §3 (use `?u64` / `?f64` /
  `?[]const u8` and a small fixed model buffer pattern consistent with how
  `agent_msg` is stored — see below; the action carries a parsed view, the state
  owns the storage).
- Add action variant: `set_agent_usage: struct { usage: AgentUsage }` next to
  `set_agent_status`.

### 6.2 `src/term/state.zig`

Alongside the existing agent block (lines ~72–77):

```zig
// -- Agent usage (OSC 7337;agent-usage) --
agent_usage: actions_mod.AgentUsage = .{},
agent_usage_changed: bool = false,
agent_model_buf: [64]u8 = undefined,
agent_model_len: u8 = 0,
```

`model` is variable-length; store it in a fixed buffer like `agent_msg_buf`
(`[256]u8` + len). Keep `context_max`/`model` sticky across updates.

### 6.3 `src/term/state_osc.zig`

- `pub fn setAgentUsage(self: *TerminalState, u: AgentUsage) void` — merge non-null
  fields into `self.agent_usage` (cumulative/sticky merge, NOT replace), copy
  `model` into `agent_model_buf`, set `agent_usage_changed = true`,
  `agent_usage.updated_ms = nowMs()`.
- `pub fn agentUsage(self: *const TerminalState) AgentUsage` — return current,
  with `model` sliced from the buffer.
- On `setAgentStatus(.none, ...)` (session end), also reset usage to `.{}` and
  clear the model buffer, so a dead agent shows no stale spend. Wire this into the
  existing `.none` handling.
- Add unit tests mirroring the existing `state_osc.zig` tests: a usage OSC updates
  fields; a partial update preserves prior fields; `.none` clears usage.

### 6.4 `src/app/ui/event_loop.zig`

Where `agent_status_changed` is drained (~line 1185) and where `pane_agent_status`
is applied (~line 1996), add the parallel `agent_usage_changed` path:

- On `agent_usage_changed`: clear the flag and call `ipc_watch.broadcastAgent(...)`
  (the existing broadcast already serializes the whole agent record — once
  `writeAgentJson` includes usage, watchers get it for free). Do **not** call
  `maybeNotifyAgent` from the usage path — usage changes never notify.
- Daemon client path: add handling for the new `pane_agent_usage` message
  (see 6.6) symmetric to `pane_agent_status`.

### 6.5 `src/ipc/agents.zig`

This is the shared serializer for both `list agents` and `watch agents`, so adding
usage here lights up both surfaces at once.

- Extend `writeAgentJson` to append a `"usage"` object after `"message"`. Emit only
  known fields; omit nulls. Example output:

```json
{"pane_id":3,"tab_id":3,"session":1,"pid":48213,"state":"working",
 "message":"Editing parser.zig",
 "usage":{"input_tokens":1234,"output_tokens":5678,"cache_read_tokens":900000,
          "cache_write_tokens":12000,"context_used":82000,"context_max":200000,
          "cost_usd":0.4213,"cost_is_estimate":false,"model":"claude-opus-4-6"}}
```

- Extend `writeAgentTsv`: append usage columns in a fixed order after `message`
  (use empty string for unknowns). Keep the existing leading columns unchanged so
  current scripts don't break; document the appended columns in the skill.
- Update the existing `writeAgentJson`/`writeAgentTsv` tests and add coverage for
  the unknown-field (null → omitted/empty) case.
- The function signature gains an `AgentUsage` parameter; update both call sites
  (`handler_query.zig` and `watch.zig` `buildFrame`) to pass
  `pane.engine.state.agentUsage()`.

### 6.6 Daemon propagation — `src/app/daemon/protocol.zig` + `client.zig`

For daemon-backed (detached) sessions, usage must cross the daemon boundary like
status does via `pane_agent_status = 0x97`.

- Add message type `pane_agent_usage = 0x98` (next free; confirm against the enum).
- Add `encodePaneAgentUsage` / `decodePaneAgentUsage` mirroring
  `encodePaneAgentStatus` (pane_id:u32, then a fixed struct of the numeric fields
  as LE u64s with a presence bitmask, then model_len:u16 + model bytes). Use a
  presence bitmask (u16) so `null` survives the wire — do **not** sentinel-encode
  with 0.
- `DaemonClient.sendPaneAgentUsage(pane_id, usage)` mirroring
  `sendPaneAgentStatus`. Emit it from the same daemon tick that detects
  `agent_usage_changed` (see `daemon/daemon.zig` ~line 264 where `agent_dirty`
  is computed — add a `usage_dirty` sibling).
- Round-trip test alongside `"pane_agent_status round-trip"`.

### 6.7 MCP — `src/ipc/mcp_tools.zig`

No schema change required: `list_agents` already returns the JSON from
`writeAgentJson`, so the richer payload flows through automatically. **Do** update
the tool's `description` string to mention the `usage` object, and update the
inline example in `skills/claude/attyx/SKILL.md`. (`watch_agents` remains
MCP-omitted; the `ponytail` note about MCP notifications still applies and is
out of scope here.)

### 6.8 CLI / skill docs

Update `skills/claude/attyx/SKILL.md` "Tracking Agents" section: document the new
`usage` JSON object and the appended TSV columns, with an example. Update
`src/config/cli_ipc_help.zig` `list agents` help text.

---

## 7. Per-agent reporters

This is the bulk of the work. Each reporter must emit the `agent-usage` OSC
(§5) to the pane TTY, self-gated on `ATTYX_PID` exactly like the existing
emitter. All injection is best-effort, non-destructive, idempotent, and gated on
the agent actually being installed — match the conventions already in
`src/app/agent_integration*.zig`.

### 7.1 Claude Code — `statusLine` injection (NOT JSONL)

Claude pipes a JSON payload to the configured `statusLine` command on every status
refresh. That payload carries the **accurate** cumulative totals (the JSONL does
not — §2). We register a statusline command that reads the payload and re-emits it
as an `agent-usage` OSC, then prints a status line to stdout (Claude renders
whatever the command prints).

**Payload shape** (fields we consume; confirm against the installed Claude version
at implementation time — the schema evolves):

```json
{
  "model": { "id": "claude-opus-4-6", "display_name": "Opus 4.6" },
  "cost": { "total_cost_usd": 0.4213,
            "total_lines_added": 120, "total_lines_removed": 8 },
  "context_window": {
    "total_input_tokens": 7199162,
    "total_output_tokens": 3208365,
    "cache_read_input_tokens": 114798863,
    "cache_creation_input_tokens": 2717775,
    "used_tokens": 82000, "max_tokens": 200000
  }
}
```

(Exact key names vary by version; the implementing agent must dump a live payload
once and map fields. `total_output_tokens` here includes thinking — that's the
point of using this source.)

**Injection** (`src/app/agent_integration.zig`, extend `install`): write a second
script next to the emitter, e.g.
`~/.config/attyx/shell-integration/agent-bin/attyx-statusline`, and set it as the
`statusLine` command in each discovered `settings.json`.

```jsonc
// settings.json
"statusLine": { "type": "command", "command": "<abs>/attyx-statusline" }
```

**CRITICAL — single-slot conflict.** Unlike `hooks` (an additive array), `statusLine`
is a **single command**. Overwriting it clobbers any custom statusline the user
already has — a real regression that the hook injection never risked. Required
behavior:

1. On install, read the existing `statusLine.command` (if any and not already
   ours). Persist it (e.g. `~/.config/attyx/shell-integration/.prev-statusline`
   or an env var baked into our script).
2. Our script: read stdin once into a variable, emit the `agent-usage` OSC from it,
   then **delegate** — if a previous command was captured, exec it with the same
   stdin (tee the buffer) and pass through its stdout so the user's statusline still
   renders. If none, print a minimal default (or nothing).
3. On uninstall, restore the captured previous command.
4. Idempotency: detect our own command by marker filename and don't re-wrap.

This wrapping logic is the single highest-risk piece of the project — implement and
test it first (see §9 Phase 0).

Script sketch (POSIX sh; mirror the existing emitter's gating/escaping):

```sh
#!/bin/sh
[ -n "$ATTYX_PID" ] || { exec_prev "$@"; exit 0; }   # outside attyx → just delegate
raw=$(cat)
# extract fields (jq if present, else sed/grep fallbacks) → in/out/cr/cw/ctx/ctxmax/cost/model
osc="in=$in;out=$out;cr=$cr;cw=$cw;ctx=$ctx;ctxmax=$ctxmax;cost=$cost;model=$model"
printf '\033]7337;agent-usage;agent;%s\a' "$osc" > "${ATTYX_TTY:-/dev/tty}" 2>/dev/null
# delegate to the user's previous statusline (if any), feeding it the same payload
if [ -n "$ATTYX_PREV_STATUSLINE" ]; then printf '%s' "$raw" | "$ATTYX_PREV_STATUSLINE"; fi
```

`jq` may not be installed; provide a `sed`-based fallback for the handful of numeric
fields (they're flat integers/decimals in the payload). Keep the script under the
same robustness bar as the emitter: never block, never error out the caller.

> Note: Claude's hook-based **status** (working/idle/input) is unchanged and still
> comes from `agent_integration.zig`'s hooks. The statusline only adds **usage**.

### 7.2 Codex — rollout-file tailer (the only file reader)

Codex hooks carry no tokens and Codex has no statusline. Its accurate token data is
in the session rollout JSONL: `event_msg` entries with
`payload.type == "token_count"` reporting **cumulative** totals. We tail the active
rollout file and emit deltas-as-cumulative over the OSC.

Two viable designs — pick (A):

- **(A) Tailer spawned by the existing PreToolUse/Stop hook** (preferred): the hook
  already fires on activity. Have a small companion script (installed beside the
  emitter) that, on `Stop`/`PreToolUse`, locates the newest
  `$CODEX_HOME/sessions/**/rollout-*.jsonl` for this session, reads the **last**
  `token_count` event, and emits an `agent-usage` OSC with the cumulative totals
  and the `turn_context` model. Stateless, no daemon, fires exactly when status
  already changes. Downside: only updates at turn boundaries (fine for a dashboard).
- **(B) A long-lived tailer thread in Attyx** keyed off the pane's `$CODEX_HOME`.
  More responsive, but adds a background reader and file-watching to the app — more
  surface area, more failure modes. Not worth it for turn-granularity data.

Implementation notes for (A):
- `CODEX_HOME` defaults to `~/.codex`; honor the env override (it can be a
  comma-list — take the one containing the active session).
- Identify the session file by mtime (newest) scoped to today's `YYYY/MM/DD`
  directory; the hook runs in the agent's process so `cwd`/env is available.
- `token_count` is cumulative → emit as-is (our schema is cumulative).
- **Hard gate: builds before 2025-09-06 don't emit `token_count`.** When absent,
  emit nothing (agent shows status but no usage — correct degradation). When
  `turn_context` is missing (a few Sep-2025 builds), omit `model` (cost becomes an
  estimate via fallback pricing, or is left null).
- Cost: not in the log → compute (§8) or leave null.

Add the companion script content to `src/app/agent_integration_codex.zig` and wire
its install next to the hook install. New events may be needed: ensure `Stop` (and
optionally `PreToolUse`) also invoke the tailer — you can chain it into the same
hook command or add a parallel hook entry (hooks are additive arrays, so this is
safe and idempotent via the existing `groupIsAttyx` dedupe).

### 7.3 opencode — enrich the plugin (in-process, cost included)

The plugin we already inject (`src/app/agent_integration_opencode.zig`,
`plugin_fmt`) runs on opencode's event bus and has the message objects in hand.
opencode tracks token usage **and computes cost itself**, exposed on assistant
message metadata. Extend the plugin to emit usage.

Add to the event switch (names per opencode's current event API — verify against
the installed version; opencode's event shapes have shifted between releases):

```js
case "message.updated":
case "message.part.updated": {
  const m = props.message || (props.part && props.part.message);
  const u = m && (m.tokens || m.usage);          // { input, output, cache:{read,write}, reasoning }
  const cost = m && m.cost;                        // opencode-computed USD
  const model = m && (m.modelID || m.model);
  if (u) emitUsage({
    in: u.input, out: u.output,
    cr: u.cache && u.cache.read, cw: u.cache && u.cache.write,
    rsn: u.reasoning, cost, model,
  });
  break;
}
// session.idle already emits status idle; also flush a final usage emit there.
```

Add an `emitUsage(obj)` helper beside `emit(state)` that builds the KV string and
`spawnSync`s the emitter with an `agent-usage` argument — OR extend the emitter to
accept a usage subcommand. Cleanest: teach the shared emitter a second mode:
`attyx-agent-status usage <kv>` emits the `agent-usage` OSC; the existing
`attyx-agent-status <state>` path is unchanged. Then both the plugin and the
statusline/codex scripts share one emitter binary.

If opencode exposes context-window info on the message/session object, map it to
`ctx`/`ctxmax`; otherwise omit.

### 7.4 Pi — enrich the extension (in-process)

The TS extension (`src/app/agent_integration_pi.zig`, `extension_fmt`) can call
`ctx.getContextUsage()` and read assistant-message usage. Extend the handlers:

```ts
pi.on("agent_end", async (ctx) => {
  emit("idle");
  try {
    const cu = ctx.getContextUsage?.();   // { input, output, cacheRead, cacheWrite, used, max, model? }
    if (cu) emitUsage({
      in: cu.input, out: cu.output, cr: cu.cacheRead, cw: cu.cacheWrite,
      ctx: cu.used, ctxmax: cu.max, model: cu.model,
    });
  } catch (e) {}
});
```

Pi has no permission event (no `input` state — documented limitation) and may not
report cost → compute cost (§8) or leave null. Confirm the exact `getContextUsage`
return shape against the installed Pi version (see `~/.pi/.../docs/extensions.md`).
Emit on `agent_end` (turn boundary) and optionally on `tool_call` for liveness.

### 7.5 Shared emitter change

Extend the emitter script in `agent_integration.zig` (`emitter_script`) to handle a
`usage` verb so all reporters share one binary:

```
attyx-agent-status <state>          # existing: emits agent-status OSC
attyx-agent-status usage <kv-list>  # new: emits agent-usage OSC
```

Keep the `ATTYX_PID` self-gate and the `ATTYX_TTY` target. The usage path skips the
stdin/notify classification entirely — it just formats and writes the OSC. Add a
test asserting the usage verb emits `]7337;agent-usage;`.

---

## 8. Cost computation (when the agent doesn't give us cost)

Claude (statusline) and opencode report cost directly. Codex and Pi may not. When
`cost_usd` is absent but we have `model` + token counts, compute it and set
`cost_is_estimate = true`.

Keep this dead simple and offline — **do not** fetch a pricing API at runtime:

- Vendor a small static price table: `src/app/agent_pricing.zig` mapping a model id
  (and known aliases) to per-million-token rates `{ input, output, cache_read,
  cache_write }`. Cover the models these four agents actually use (Claude Opus/Sonnet/Haiku,
  GPT-5 / Codex models, plus whatever opencode/Pi default to). This mirrors what
  `ccusage` does with LiteLLM's dataset, but a hand-maintained subset is enough for
  a live operator view and avoids a network dependency in `term/`-adjacent code.
- Formula (per million):
  `cost = (input*in_rate + output*out_rate + cache_read*cr_rate + cache_write*cw_rate) / 1e6`
- Unknown model → no estimate (`cost_usd = null`). Show `—`, don't guess.
- Make the table easy to update and add a comment pointing at where rates come from.
  Stale rates are acceptable for a live view; document that it's an estimate in the UI
  (e.g. a `~` prefix or a footnote).

This module is pure and trivially unit-testable: feed tokens + model, assert cost.

---

## 9. Dashboard overlay

A new overlay, `src/overlay/agent_dashboard.zig`, following the existing overlay
pattern (`session_picker.zig` / `theme_picker.zig` + their `_panel.zig`
render halves). **This avoids the inline-card rendering problem that killed the
xyron blocks UI** — it's a fixed-layout modal table redrawn on a tick, not
reflow-aware inline content.

### Data source

The overlay reads the same aggregated agent records the daemon already maintains
across all sessions (`src/app/daemon/agent_watch.zig` enumerates every pane's
`agent_status`; extend it to also surface `agentUsage()`). For the attached window,
read directly from `tab_mgr` panes. Reuse `agents.zig` serialization if convenient,
or read the structs directly — the overlay is in-process so it can read
`pane.engine.state.agentUsage()` without going through JSON.

### Layout

Modal, centered, themed (use the theme's colors — match `theme_picker`). One row per
active agent (status != none), plus a totals footer:

```
 Agents — 4 running · $1.83 this session
 ─────────────────────────────────────────────────────────────────────
  ● pane  session   model         in       out     ctx        cost
  ● 3     myapp     opus-4.6     1.2M     842K    82k/200k    $0.42
  ● 8     myapp     opus-4.6      —        —      12k/200k    needs input
  ● 5     server    gpt-5        430K     210K    55k/256k   ~$0.31
  ● 7     api       (codex<sep25) —        —        —          —
 ─────────────────────────────────────────────────────────────────────
  TOTAL                          1.6M    1.0M               $1.83 (~$0.31 est)
```

- Status dot uses existing color mapping (idle=green, working=orange, input=purple).
- Humanize counts (`1.2M`, `842K`). Show `—` for unknowns, `~` prefix for estimated
  cost, and a short note (e.g. `needs input`) from the agent message where useful.
- `ctx` as `used/max` with a tiny bar if cheap to render.
- Footer: agent count, summed cost (mark when any component is estimated).
- Refresh on a timer (e.g. 500ms–1s while open) and/or on the same broadcast tick
  that updates watchers. Selecting a row could focus that pane (reuse the
  pane-focus path) — nice-to-have, not required for v1.

### Trigger

- Keybind: `Cmd+Shift+A` (macOS) / `Ctrl+Shift+A` (Linux). Register in the command
  palette too (`src/config/commands.zig` — add an `agent_dashboard_toggle` command,
  matching the existing `*_toggle` naming).
- Respect the file-size limit: split render (`_panel.zig`) from state/logic, like
  the other overlays.

---

## 10. Configuration

Per the repo rule, every new option goes in `src/config/default_config.toml` with a
comment. Add an `[agents]` section:

```toml
# ── Agents ───────────────────────────────────────────────────────────
# Token/cost/context telemetry for AI coding agents running in panes.

[agents]
# Master switch for usage telemetry injection (statusline/plugin/extension/codex
# tailer). Status dots are unaffected by this. Default true.
# telemetry = true

# Show estimated cost when the agent doesn't report cost directly (uses a built-in
# static price table). When false, cost shows "—" instead of an estimate.
# cost_estimates = true

# Currency label for display only (no FX conversion).
# currency = "USD"

# Dashboard refresh interval while open, milliseconds.
# dashboard_refresh_ms = 750
```

Wire these through the config system (`src/config/*`). `telemetry = false` must make
the injectors no-op (and ideally uninstall previously injected statusline wrapping
on next launch, to honor the single-slot restore).

---

## 11. Testing (mandatory — see `docs/testing.md` and CLAUDE.md)

Every piece below needs headless coverage. No rendering required for core tests.

Parser / state (`src/term/`):
- `agent-usage` OSC with full KV set → correct `AgentUsage`.
- Partial update merges (sticky): a second OSC with only `cost=` preserves earlier
  `in`/`out`.
- `model=` round-trips through the fixed buffer; over-long model truncates safely.
- `status → none` clears usage.
- Malformed KV (missing `=`, non-numeric, trailing `;`) → ignored gracefully (strict
  mode may log; default ignores — matches existing OSC robustness).

Serialization (`src/ipc/agents.zig`):
- `writeAgentJson` emits `usage` with known fields and omits nulls.
- `writeAgentTsv` appends columns in fixed order; unknowns are empty.
- Existing status-only tests still pass (back-compat of leading columns).

Daemon (`src/app/daemon/protocol.zig`):
- `pane_agent_usage` encode/decode round-trip, including null-via-bitmask fields
  and model bytes.

Pricing (`src/app/agent_pricing.zig`):
- Known model → expected cost; unknown model → null; cache-rate math.

Reporters (string-level, like existing emitter tests):
- Shared emitter `usage` verb emits `]7337;agent-usage;` and self-gates on
  `ATTYX_PID`.
- Claude statusline wrapper: with `ATTYX_PREV_STATUSLINE` set, delegates and passes
  through prev stdout; without attyx env, pure delegation. (Test the generated
  script's structure the way `agent_integration` tests assert script contents.)
- opencode plugin template contains the `message.updated`/`emitUsage` mapping; Pi
  extension template contains `getContextUsage`.
- Codex: install writes the tailer companion and a hook that invokes it; tailer
  picks the newest rollout and the last `token_count` (can unit-test the
  selection/parse logic on a fixture JSONL).

Integration smoke (manual, document in PR): run each agent inside Attyx, confirm
`attyx list agents --json` shows a populated `usage`, and the dashboard renders.

---

## 12. Suggested implementation phases

Land in vertical slices so each phase is independently testable and shippable.

- **Phase 0 — Claude statusline wrapping (de-risk first).** Implement only the
  statusline injection + the single-slot capture/delegate/restore logic and prove it
  doesn't clobber a user's existing statusline. No schema work yet — just confirm the
  payload fields and the wrapping. This is the riskiest piece; if it can't be made
  safe, reconsider the Claude path before building everything else.
- **Phase 1 — Plumbing.** OSC `agent-usage` parse → `AgentUsage` state → `agents.zig`
  serialization → `list agents --json` shows usage for Claude. Shared emitter `usage`
  verb. Daemon `pane_agent_usage`. (Watchers light up for free.)
- **Phase 2 — opencode + Pi** plugin/extension enrichment (in-process, easy wins).
- **Phase 3 — Codex** tailer (the file reader; gated on ≥ Sep-2025 builds).
- **Phase 4 — Pricing** module + estimated-cost fields.
- **Phase 5 — Dashboard overlay** + keybind + command palette + config.
- **Phase 6 — Docs**: SKILL.md, cli help, `default_config.toml`, release note in
  `releases/`.

---

## 13. Risks and edge cases

- **Claude statusline is a single slot.** Highest risk; handled in §7.1/Phase 0.
  Must restore on uninstall and when `telemetry=false`.
- **Schema drift.** All four agents' payload/event/log shapes evolve between
  versions. Every reporter must degrade to "no usage" (status still works) rather
  than emit garbage. Dump a live payload per agent at implementation time; don't
  trust the field names in this doc verbatim.
- **Claude JSONL is a trap** — never use it for in/out tokens (§2). Statusline only.
- **Codex pre-Sep-2025** builds emit no `token_count`; **Pi** has no cost and no
  `input` state. These are honest gaps — show `—`, don't fabricate.
- **Cumulative vs delta.** Codex `token_count` and Claude statusline are cumulative;
  our schema is cumulative; never sum successive emits.
- **Cost estimates are estimates.** Static price table goes stale; mark estimated
  costs in the UI and keep the table easy to bump.
- **No per-character / hot-path cost.** Usage emits are turn- or refresh-frequency
  (low). Keep parsing allocation-free in `term/`; the dashboard refresh is the only
  timer, and only while open.
- **Privacy.** We read counters and model ids only — never message content — from
  payloads/logs. Keep it that way; don't widen the Codex tailer to parse message
  bodies.

---

## 14. File-touch checklist

New files:
- `src/app/agent_pricing.zig` — static price table + cost calc (pure, tested).
- `src/overlay/agent_dashboard.zig` (+ `agent_dashboard_panel.zig` for render).

Edited files:
- `src/term/actions.zig` — `AgentUsage`, `set_agent_usage` action.
- `src/term/parser.zig` — `agent-usage;` branch in `dispatchOsc7337`.
- `src/term/state.zig` — usage fields + model buffer.
- `src/term/state_osc.zig` — `setAgentUsage` / `agentUsage` + `.none` reset.
- `src/app/ui/event_loop.zig` — drain `agent_usage_changed`, apply daemon msg.
- `src/ipc/agents.zig` — usage in JSON/TSV serializers + tests.
- `src/ipc/watch.zig`, `src/ipc/handler_query.zig` — pass `agentUsage()` to serializer.
- `src/app/daemon/protocol.zig` — `pane_agent_usage = 0x98` + codec + test.
- `src/app/daemon/client.zig`, `daemon.zig`, `agent_watch.zig` — send/aggregate usage.
- `src/app/agent_integration.zig` — shared emitter `usage` verb; Claude statusline
  install + single-slot wrapping/restore.
- `src/app/agent_integration_codex.zig` — rollout tailer companion + hook wiring.
- `src/app/agent_integration_opencode.zig` — plugin `emitUsage` + message events.
- `src/app/agent_integration_pi.zig` — extension `getContextUsage` emit.
- `src/config/default_config.toml` + `src/config/*` — `[agents]` options.
- `src/config/commands.zig` — `agent_dashboard_toggle`; keybind registration.
- `src/config/cli_ipc_help.zig`, `skills/claude/attyx/SKILL.md` — docs.
- `releases/vX.Y.Z.md` — user-facing note.

---

## 15. Sources

Token-format research backing §2 (accessed 2026-06):

- Claude Code session/JSONL format — https://databunny.medium.com/inside-claude-code-the-session-file-format-and-how-to-inspect-it-b9998e66d56b
- Claude Code JSONL token undercount (statusline is the accurate source) — https://gille.ai/en/blog/claude-code-jsonl-logs-undercount-tokens/ ; filed as https://github.com/anthropics/claude-code/issues/28197
- ccusage Codex data source (`token_count` events, `turn_context`, Sep-2025 cutoff) — https://ccusage.com/guide/codex/
- Codex session/rollout files — https://github.com/openai/codex/discussions/3827
- opencode session management + token/cost tracking — https://deepwiki.com/sst/opencode/2.1-session-management ; plugin reference: https://github.com/Ainsley0917/opencode-token-monitor
- Pi extensions + `getContextUsage` — https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md ; usage package: https://pi.dev/packages/@alexanderfortin/pi-token-usage
- Cross-agent prior art (reads all four) — https://github.com/junhoyeo/tokscale ; https://github.com/ryoppippi/ccusage


