# Drive an Agent — `attyx agent send` / `attyx agent await`

A first-class way for one agent (or a script) to **send a prompt to another agent in
a pane and block until that agent's turn completes**, returning the outcome, the
output produced during the turn, and (optionally) the tokens it spent.

Today this is hand-rolled: send keystrokes, then `attyx watch agents -p N | while
read … '"state":"idle"' && break`, then `get-text` and hope you captured the right
window. The SKILL.md even documents that dance. This feature formalizes it into one
reliable command, removing the sleep-and-pray glue everyone reinvents when
orchestrating multiple agents.

Implementation spec. Builds on: `send_keys` (`src/ipc/client.zig`,
`src/config/cli_ipc.zig`), the `watch agents` stream (`src/ipc/watch.zig`,
`client_watch.zig`), agent status (`src/term/actions.zig` `AgentStatus`), and
ideally incremental capture (`docs/incremental-get-text.md`) for clean output.

---

## 1. Why client-side, not server `--wait`

`tab create --cmd … --wait` and `split --cmd … --wait` already block until a spawned
command exits (`handler_cmd.zig`: wrap command with `exit $?`, `capture_stdout`,
`waitForExit`). That mechanism is for a **new process you launch**, and it blocks on
**process exit**. It's the wrong model here:

- The target is a **long-lived interactive agent** already running in a pane, not a
  one-shot command. It never exits between turns.
- "Turn complete" is an **agent lifecycle event** (working → idle/input), not a
  process exit.
- A turn can run for minutes; blocking a server/PTY thread on it is unacceptable.

The right signal already exists and is already pushed: the agent status stream. So
`agent send --wait` is **client-side orchestration** over existing primitives —
`send_keys` to submit, the `watch agents -p N` stream to detect completion, and
`get_text --since` to capture the turn's output. No PTY-thread blocking, no new
long-lived server state. (MCP is the one exception — see §7 — where the same
orchestration runs in the MCP request handler because MCP calls may block until they
return a single response.)

---

## 2. The turn state machine

An agent reports `idle` / `working` / `input` / `none` via OSC (see
`docs/architecture.md`). A turn driven by us looks like:

```
(precondition: agent present, state ∈ {idle, input})
  │  send prompt + Enter  → UserPromptSubmit fires → state: working
  ▼
working ───────────────► idle    = turn finished, agent done            → outcome: done
        └──────────────► input   = agent paused for permission/question → outcome: needs_input
        └──(timeout)───► …       = still working after deadline          → outcome: timeout
```

Await algorithm (client):

1. **Precondition check.** Snapshot the pane's agent via `list agents -p N`. If
   `state == none`, error: *"pane N is not running an agent."* If `working`, either
   error (busy) or, with `--queue`, wait for it to return to idle first (default:
   error, keep it predictable).
2. **Seed an output cursor** (if `--capture`): `get_text -p N --since ""` to get the
   current bottom cursor before we submit (see incremental-get-text doc).
3. **Open the watch stream** filtered to the pane: `watch agents -p N` (reuse
   `client_watch`/`client_daemon.watchAgents`). Begin reading frames *before*
   sending, so we can't miss a fast transition.
4. **Submit** the prompt via `send_keys` (text + `{Enter}`, see §4).
5. **Detect turn start:** wait for a frame with `state == working` (the submit causes
   it). If none arrives within a short **start grace** (e.g. 2–3 s), treat as
   `no_turn` (the agent didn't accept the input as a prompt — wrong pane, modal open,
   etc.) and return without claiming success.
6. **Detect turn end:** after `working` is seen, wait for the first frame with
   `state ∈ {idle, input}`. That's the outcome (`done` / `needs_input`). Capture the
   agent's `message` from that frame.
7. **Capture output** (if `--capture`): `get_text -p N --since <seeded cursor>` →
   exactly the rows the turn produced.
8. **Token delta** (if `--tokens` and telemetry is implemented): diff `usage` from
   the start snapshot vs. the end frame; report per-turn token/cost.
9. **Timeout:** if the end state doesn't arrive within `--timeout` (default e.g.
   600 s), return `timeout` with whatever partial output was captured. Do **not**
   kill or interrupt the agent — just stop waiting.

Race notes:
- Read frames from the stream starting before the send to avoid missing `working`.
- Some agents emit `working` then quickly `idle`; the snapshot-on-connect the watch
  stream sends first (current state) plus live frames covers both orderings.
- If the agent goes straight to `input` without an observable `working` (rare),
  accept `input` after submit as a valid end state too.
- If the agent ends (`none`) mid-wait (crashed/quit), return outcome `ended`.

---

## 3. Commands

Two commands — a low-level await and a send-that-awaits built on it.

### `attyx agent await`

Block until a pane's agent reaches a target state. No input sent — just observe.

```
attyx agent await -p <id> [--state idle|input|any] [--timeout <s>] [-s <sess>] [--json]
```

- `--state` (default `idle`): the state to wait for. `any` = idle or input.
- Returns when reached (or on timeout/`none`). This is the formalized version of the
  SKILL's `watch … | while read … break` pattern, useful on its own (e.g. "block my
  script until the agent in pane 3 is done").

### `attyx agent send`

Submit a prompt and (optionally) await the turn.

```
attyx agent send -p <id> "<prompt>" [--wait] [--capture] [--tokens]
                 [--timeout <s>] [--submit-key <key>] [-s <sess>] [--json]
```

- Without `--wait`: types the prompt + Enter and returns immediately (just a
  convenience wrapper over `send_keys`).
- With `--wait`: runs the §2 algorithm and returns the outcome.
- `--capture`: include the turn's output (needs incremental get_text; without it,
  fall back to a `--wait-stable`-style final screen grab and note it's the whole
  screen, not a delta).
- `--tokens`: include per-turn token/cost delta (needs telemetry doc).
- `--submit-key`: the key that submits (default `{Enter}`); some TUIs use other
  submit chords — keep it overridable.

---

## 4. Submitting the prompt safely

Reuse the `send_keys` path (`client.zig` send loop). Details that matter:

- **Bracketed paste for the text body, then the submit key separately.** Sending the
  prompt as bracketed paste (the same mechanism `send_image` uses for the path)
  prevents a multi-line prompt from triggering early submission line-by-line, and
  stops embedded newlines/control chars from being interpreted as keybindings.
  Then send `--submit-key` (default `{Enter}`) as a discrete keypress.
- **Escape handling:** the prompt is arbitrary text; do not run it through the
  `{Name}` key parser. Use the text/paste path so `{`/`}`/`\` in the prompt are
  literal. (Contrast with `send_keys` where `{Enter}` is special — here only the
  explicit `--submit-key` goes through the key parser.)
- **Focus-free:** target by pane id, never change focus (the user may be elsewhere).

---

## 5. Result shape

`--json` (and the MCP result):

```json
{
  "pane": 3,
  "session": 1,
  "outcome": "done",            // done | needs_input | timeout | no_turn | ended
  "duration_ms": 48213,
  "message": "Ran 142 tests, all passing",   // agent's end-of-turn status preview
  "output": "…rows the turn produced…",       // present with --capture
  "truncated": false,                          // output scrolled past scrollback
  "tokens": {                                  // present with --tokens + telemetry
    "input": 12000, "output": 3400,
    "cache_read": 80000, "cost_usd": 0.071, "cost_is_estimate": false
  }
}
```

Plain CLI: print a one-line human summary to stderr (`pane 3: done in 48.2s`) and the
captured `output` to stdout (so it pipes), or just the summary if no `--capture`.
Exit code encodes outcome for scripting: `0` done, `2` needs_input, `3` timeout,
`4` no_turn/ended — so `attyx agent send -p 3 "run tests" --wait && deploy` works.

---

## 6. Implementation shape

New client module `src/ipc/client_agent.zig` (sibling of `client_watch.zig`):

- `pub fn awaitState(socket_path, parsed) u8` — open watch stream filtered to pane,
  read frames, return outcome. Reuse `client_watch`'s connect + frame-read loop;
  factor the NDJSON frame reader out of `client_watch.zig` so both share it rather
  than duplicating the header/payload parsing.
- `pub fn send(socket_path, parsed) u8` — precondition snapshot → seed cursor →
  start await reader → `send_keys` → run the state machine → capture → print result.
  Orchestrates one-shot requests (`list_agents -p`, `send_keys`, `get_text_since`)
  plus the streamed await, all over the existing client helpers.

Dispatch (`src/config/cli_ipc.zig`): add an `agent` subcommand with `send` / `await`
sub-subcommands, parsing the flags above into `IpcRequest` (new fields:
`agent_action: enum{send,await}`, `await_state`, `timeout_s`, `capture`,
`want_tokens`, `submit_key`, `prompt` in `text_arg`). Route `.agent_*` to
`client_agent`.

No new server IPC command is strictly required for v1 — it composes existing ones.
(Optional later optimization: a server-side `await_turn` that parks like
`watch_agents` and returns a single frame on completion, to save the client a
persistent connection. Not needed first.)

### Reuse, don't reinvent
- Frame reading: `client_watch.zig` already has the header+NDJSON read loop — extract
  and share.
- Pane/session targeting + socket resolution: identical to every other client path.
- `send_keys` text path: already supports escapes/named keys; add the paste-body +
  discrete submit-key behavior (§4).

---

## 7. MCP tool

Add `agent_send` (and optionally `agent_await`) to `src/ipc/mcp_tools.zig`. Unlike
`watch_agents` (omitted because streaming doesn't fit request/response), a blocking
await **does** fit: the tool call makes one request and returns one result when the
turn completes. Schema:

```json
{"name":"agent_send","description":"Send a prompt to the agent in a pane and wait for its turn to finish. Returns the outcome, the output produced during the turn, and token usage. Use to drive another agent.",
 "inputSchema":{"type":"object","properties":{
   "pane":{"type":"integer"},"text":{"type":"string"},
   "wait":{"type":"boolean","default":true},
   "capture":{"type":"boolean","default":true},
   "tokens":{"type":"boolean"},
   "timeout":{"type":"integer","description":"Seconds."},
   "session":{"type":"integer"}},
 "required":["pane","text"]}}
```

Because MCP handlers are request/response, run the §2 orchestration inside the MCP
server's handler thread (it can block until the single response is ready). Reuse the
`client_agent` logic so CLI and MCP share one implementation. Mind the MCP client's
own timeout — cap `--timeout` and return a `timeout` outcome cleanly rather than
hanging the transport.

---

## 8. Safety & norms

- **Never interrupt or kill** the target agent. On timeout we stop waiting; we don't
  send Ctrl-C or close the pane. (If a caller wants that, it's a separate explicit
  action.)
- **No focus stealing** — target by id.
- **Submitting a prompt is an inbound-to-an-agent action, which the repo treats as
  allowed** (messaging an AI agent is not "outbound to a person"). This is the
  intended use; no confirmation gate. Keep it that way — but the command must target
  exactly the pane id given and never broadcast.
- **Honest outcomes:** `no_turn` and `timeout` are first-class results, not errors to
  paper over. A caller must be able to tell "the agent finished" from "the agent
  never started" from "it's still going."

---

## 9. Testing (mandatory, headless)

The state machine is the thing to test; make it a pure function over a sequence of
status frames so it needs no real agent:

- `working → idle` ⇒ `done`; `working → input` ⇒ `needs_input`.
- No `working` within start grace ⇒ `no_turn`.
- `working` then nothing before deadline ⇒ `timeout`.
- `working → none` ⇒ `ended`.
- Snapshot-first ordering (stream sends current state on connect) doesn't false-fire:
  a pre-existing `idle` before the send isn't mistaken for completion.
- Direct `idle`-already → `working` (after send) → `idle` sequences resolve to one
  turn, not zero.
- Output capture: with a fake `get_text_since` returning a known delta, the result's
  `output` matches and `truncated` propagates.
- Exit-code mapping per outcome.
- Submit path: prompt with `{`, `}`, newlines is sent literally (paste path), submit
  key sent as a discrete key.

Extract the frame reader and the state machine so both are unit-testable without a
socket. Manual smoke (PR): drive a real Claude/Codex/opencode/pi pane from another,
assert outcomes and captured output line up.

---

## 10. File-touch checklist

New:
- `src/ipc/client_agent.zig` — `send` + `awaitState`, the state machine, result
  formatting. (Split if it nears 600 lines: `client_agent_await.zig` for the machine.)

Edited:
- `src/ipc/client_watch.zig` — extract the shared NDJSON frame reader.
- `src/config/cli_ipc.zig` — `agent send` / `agent await` parsing, `IpcRequest`
  fields, help text; dispatch to `client_agent`.
- `src/ipc/client.zig` — reuse send_keys/get_text encoders; expose the paste-body +
  discrete-submit submit path.
- `src/ipc/mcp_tools.zig` — `agent_send` (+ optional `agent_await`) tool + routing
  through the shared `client_agent` logic.
- `src/config/cli_ipc_help.zig` — help.
- `skills/claude/attyx/SKILL.md` — replace the hand-rolled await snippet with
  `agent send --wait` / `agent await`, document outcomes and exit codes.
- `releases/vX.Y.Z.md` — user-facing note.

Dependencies: `--capture` is best with `docs/incremental-get-text.md` (falls back to
a full-screen grab without it); `--tokens` requires `docs/agent-token-telemetry.md`.
Both are optional flags, so `agent send`/`await` can ship before either lands.

---

## 11. Out of scope

- **Server-side `await_turn`** parked connection (optimization; client-side is fine
  for v1).
- **Multi-pane fan-out** (`agent send` to many panes, await all) — a nice batch layer
  on top later; v1 is one pane per call.
- **Interrupting/steering** a running turn. Separate explicit action.
- **Conversation transcript extraction** beyond the visible delta — that's the
  telemetry/transcript surface, not this command.
