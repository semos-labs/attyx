# Agent Dashboard (`attyx dashboard`)

A full-screen terminal UI that shows every AI agent running across all Attyx
sessions — their state, token/cost/context usage, and how long they've been
working — and lets you jump to, or act on, any of them. Launched with
`attyx dashboard`.

This is the operator console as a first-class app: think `htop`, but for the agent
swarm.

This document is the implementation spec. It depends on the agent-status pipeline
(`docs/architecture.md`, `src/ipc/watch.zig`) and the usage telemetry added in
`docs/agent-token-telemetry.md` (the dashboard renders the `usage` object that doc
introduces). It is written to be handed to an implementing agent.

---

## 1. What it is (and what it is not)

`attyx dashboard` is a **standalone, long-lived CLI mode** — the same family as
`attyx mcp` and `attyx watch agents`. It:

1. connects to the running Attyx instance over the existing Unix socket,
2. opens a persistent `watch_agents` stream for live data **in**,
3. fires one-shot IPC commands for actions **out** (focus a pane, zoom, close),
4. renders a full-screen TUI to its own stdout using VT escape sequences.

It is **not** the GPU/overlay path. Crucially, the dashboard process does **not**
use Attyx's rendering engine — it's an ordinary terminal client that draws itself
with ANSI escapes, exactly like any other TUI, and happens to run inside an Attyx
pane (or any VT-compatible terminal). This keeps it completely decoupled from the
renderer, makes it work over the daemon while detached, and lets it be its own pane
that you split/tab/popup like anything else.

### Relationship to the overlay in the telemetry doc

`docs/agent-token-telemetry.md` §9 sketched an in-process GPU **overlay**
(`Cmd+Shift+A`). This TUI app supersedes that as the canonical dashboard:

- **Recommended:** build this TUI app and make the keybind launch it (in a popup or
  split), and **drop the GPU overlay** from the telemetry doc scope. One
  implementation, works detached, far less coupling to the renderer.
- The overlay's only edge over the TUI is zero-process-spawn latency for a glance.
  If that ever matters, the overlay can come later as a thin reader of the same
  in-memory data; it is explicitly out of scope here.

Treat §9 of the telemetry doc as deprecated in favor of this document.

---

## 2. Goals / non-goals

### Goals

- One screen that answers: how many agents are running, which need me, who's
  burning tokens/cost, how full is each context window — live, across **all**
  sessions, including detached ones.
- Navigate: select an agent and **focus its pane** (switch session + focus split)
  with one keypress, so the dashboard is also a launcher/jump list.
- Light operator actions: zoom a pane, close a pane (with confirmation).
- Cheap to run: idle CPU ≈ 0 (event-driven, blocks on I/O), no busy polling.
- Degrade gracefully: no daemon, stream drop, tiny window, non-TTY stdout.

### Non-goals

- Not a metrics database or historical view — it shows *current* live agents only
  (an agent that ended is removed). Persistence/history is out of scope.
- Not a chat/IO surface — you don't type *to* an agent here; you jump to its pane
  and interact there. (Sending keystrokes from the dashboard is a possible future,
  §16, but not v1.)
- Not Windows-first. The `watch_agents` stream is POSIX-only (see `watch.zig`);
  Windows uses a polling fallback (§13) or is unsupported in v1.

---

## 3. Architecture & process model

```
                          ┌─────────────────────────────┐
   attyx dashboard  ──────┤  Attyx instance / daemon     │
   (this process)         │                              │
     │                    │  watch_agents (NDJSON stream)│  ← data IN (persistent)
     │  one-shot cmds ───►│  focus / split_zoom / close  │  ← actions OUT (per keypress)
     ▼                    └─────────────────────────────┘
   TUI runtime (raw mode + alt screen, draws to its own tty)
```

Two connections, by design:

- **Stream connection (in):** one persistent socket running `watch_agents`. Reuse
  `client.connectToSocket` + the request framing in
  `src/ipc/client_watch.zig` / `client_daemon.zig` (`watchAgents`). The stream emits
  a snapshot on connect, then one NDJSON frame per status/usage change (including
  `state:"none"` when an agent leaves — see `watch.zig`). With `-s`, target a
  specific session straight from the daemon; **default scope for the dashboard is
  ALL sessions** (see §5 on how to get cross-session — may require a small
  protocol addition).
- **Action connections (out):** when the user presses a key that acts on a pane
  (focus, zoom, close), open a short-lived one-shot connection and send the
  corresponding `IpcRequest`, exactly as the normal CLI does. Don't try to multiplex
  actions over the watch socket — the watch fd is parked server-side as a
  write-only broadcast target.

The main loop multiplexes three fds with `poll(2)`:

1. the stream socket (new agent frames),
2. `stdin` (keypresses),
3. a self-pipe or `signalfd`/`kqueue` for `SIGWINCH` (resize).

Block in `poll` indefinitely; wake only on data, input, or resize. No timers except
an optional 1 Hz "elapsed time" tick (only armed when at least one agent is
`working`, so a fully idle dashboard still sleeps).

---

## 4. CLI entry

Add a `dashboard` subcommand alongside `mcp` in `src/config/cli.zig`:

- Extend the `Action` enum (currently has `mcp` at line ~29) with `dashboard`.
- In the dispatch chain (the `else if (eql(first, "mcp"))` block ~line 80), add
  `else if (eql(first, "dashboard"))` → `result.action = .dashboard;`.
- Route `.dashboard` to `src/ipc/dashboard/run.zig` `run(...)` (new module, §6).
- Honor the global `-s/--session <id>` already parsed for IPC commands and the
  socket path resolution used by the other clients.

Flags:

| Flag | Meaning |
|---|---|
| `-s, --session <id>` | Scope to one session (default: all sessions) |
| `--once` | Render one frame to stdout and exit (snapshot; implies no raw mode) — for scripts/screenshots |
| `--no-color` | Disable color (also honor `NO_COLOR` env) |
| `--sort <col>` | Initial sort: `cost`\|`tokens`\|`ctx`\|`state`\|`session` (default `state` then `cost`) |
| `--interval <ms>` | Elapsed-time tick cadence (default 1000) |

`attyx dashboard --help` prints usage (wire into the existing help system,
`src/config/cli_help.zig` / `cli_ipc_help.zig`).

---

## 5. Getting all sessions

`watch agents` defaults to the attached/local session and `-s` targets one session.
The dashboard wants **every** session at once. Options, in order of preference:

- **(A) Add an all-sessions watch mode (preferred).** A `watch_agents` with a
  sentinel session (e.g. `session = 0xFFFFFFFF` or a new flag bit in the request
  payload) that the daemon interprets as "broadcast every session's transitions,
  tagged with their `session` id." The NDJSON already carries `session` per record
  (see `agents.zig writeAgentJson`), so the client can group by it with no
  ambiguity. This is a small, well-contained daemon change in
  `src/app/daemon/` (the watcher registry already tracks `session_id`; relax the
  per-session filter when the sentinel is set) and `src/ipc/watch.zig`.
- **(B) Multiplex N watch connections**, one per session, refreshed from
  `session_list`. Works with zero protocol change but is clumsy: you must poll
  `session_list` to discover new/dead sessions and open/close streams. Acceptable
  fallback only if (A) is rejected.

Recommend (A). Spec the sentinel in the request payload next to the existing
`pane_filter:u32`.

---

## 6. The TUI runtime (new, self-contained)

The repo has no client-side TUI primitives today (the CLI is line-based). Build a
small, dependency-free runtime under `src/ipc/dashboard/`. Keep each file under the
600-line limit; split as noted.

Modules:

- `dashboard/run.zig` — entry: setup/teardown, the `poll` loop, signal wiring.
- `dashboard/term.zig` — terminal control: raw mode, alt screen, cursor, queries.
- `dashboard/render.zig` — frame buffer + diff renderer + drawing helpers.
- `dashboard/input.zig` — keypress decoder (bytes → key events).
- `dashboard/model.zig` — the agent table model (merge stream frames, sort/filter).
- `dashboard/format.zig` — humanize tokens/cost/duration; column formatting.
- `dashboard/theme.zig` — color palette (read from config; fallback defaults).

### 6.1 Terminal setup (`term.zig`)

On start (only if `stdout` is a TTY; else see §13 non-TTY):

1. Save current `termios` (`tcgetattr`), then enter **raw mode** (`cfmakeraw`-style:
   clear `ICANON`/`ECHO`/`ISIG`/`IEXTEN`, `VMIN=1`/`VTIME=0`). Use POSIX termios via
   `std.posix` — mirror how the engine's PTY side configures terminals, but this is
   the *client* tty.
2. Enter **alt screen** (`\x1b[?1049h`), hide cursor (`\x1b[?25l`), clear.
3. Optionally enable bracketed paste off, and mouse off (we don't use them in v1).
4. Query size via `TIOCGWINSZ` (`ioctl`); re-query on `SIGWINCH`.

On exit (every path — normal quit, signal, panic, error): restore termios, show
cursor (`\x1b[?25h`), leave alt screen (`\x1b[?1049l`). **Install this as a
deferred/`atexit`-style teardown and also from the signal handler** so a `SIGTERM`
or crash never leaves the user's terminal wedged. This is the single most important
robustness requirement of the whole app.

### 6.2 Rendering (`render.zig`)

- Maintain a back buffer of styled cells (or styled lines) sized to the window.
- Each frame: clear the back buffer, draw the current model into it, then **diff
  against the front buffer and emit only changed runs** (move cursor + write). Full
  redraw on resize or first frame. This keeps output tiny and flicker-free over the
  socket/pty without needing a damage system.
- Use truecolor (`\x1b[38;2;r;g;bm`) when the terminal supports it (assume yes
  inside Attyx; gate on `COLORTAG`/`TERM` heuristics + `--no-color`/`NO_COLOR`).
- Provide helpers: `drawText(x,y,style,str)`, `hline`, `box`, `truncateToWidth`
  (must be **grapheme/again width-aware** — reuse the width logic from the term
  engine if exposed, else a minimal wcwidth for the CJK/emoji cases; agent messages
  and model names can contain wide chars). Never overrun a column.

### 6.3 Input (`input.zig`)

Decode stdin bytes into key events: printable keys, `Ctrl-*`, arrows/Home/End/
PgUp/PgDn (CSI sequences), `Enter`, `Esc`, `Tab`. A small state machine over the
escape grammar — Attyx already has a thorough key model in `src/ipc/keys.zig`;
reuse or mirror its decoding rather than reinventing edge cases. Map to a
`KeyEvent` enum the loop switches on.

### 6.4 Main loop (`run.zig`)

```
setup terminal + signals
open all-sessions watch stream
draw initial empty/snapshot frame
loop {
  poll([stream_fd, stdin_fd, sigwinch_fd], timeout = tick_if_any_working)
  if stream_fd readable: read frames → model.apply(frame); dirty = true
  if stdin readable:     decode keys → handle (may open action conn); dirty = true
  if sigwinch:           re-query size; full_redraw = true; dirty = true
  if tick:               model.refreshElapsed(); dirty = true
  if dirty:              render.frame(model); dirty = false
}
teardown (always)
```

Reads from the stream must be **non-blocking / frame-aware**: the `poll` says
readable, then read available bytes and split complete NDJSON lines; buffer a
partial trailing line for the next wake. Reuse the framing in `client_watch.zig`
(header + payload), or — since the watch payload is newline-delimited JSON — read
raw and split on `\n`. Match whatever framing the stream actually uses (it sends
`.success` frames whose payload is one JSON object; see `watch.zig buildFrame` and
`client_watch.zig`).

---

## 7. Data model (`model.zig`)

Keep an in-memory table keyed by `(session_id, pane_id)`.

```
AgentRow {
  session_id: u32, pane_id: u32, tab_id: u32, pid: u32,
  state: enum { idle, working, input },      // "none" removes the row
  message: []u8,                              // latest preview
  usage: AgentUsage,                          // from telemetry doc (may be empty)
  session_name: []u8,                         // resolved lazily (see below)
  first_seen_ms: i64, last_change_ms: i64,    // for elapsed/"working for 90s"
}
```

Apply rules per incoming frame:

- `state == none` → remove the row (agent ended). If it was selected, move
  selection to the neighbor.
- otherwise → upsert; merge `usage` fields **sticky** (a frame carrying only status
  must not wipe a previously-known usage; the telemetry layer already does sticky
  merge server-side, but be defensive).
- Track `last_change_ms` on any state transition; `working`'s elapsed = now −
  (time it entered `working`).

Session names: the NDJSON carries `session` (id) but not the name. Resolve names
once via a `session_list` one-shot at startup and refresh on demand (e.g. when a new
session id appears). Cache id→name. Don't block the render on it — show the id until
the name resolves.

Derived/aggregate state (recomputed on change):

- counts by state (e.g. "4 running · 1 needs input"),
- total cost (sum of `cost_usd`; mark if any component is an estimate),
- totals of in/out tokens.

Sorting & filtering live here (pure functions over the row list): sort by the active
column; filter by state (e.g. "only needs-input") or a text query over
session/model/message. Selection is an index into the sorted+filtered view.

This module is **pure and fully unit-testable** without a TTY — feed it frames,
assert the resulting table, totals, sort order, and selection behavior.

---

## 8. Layout & views

### 8.1 Main view (default)

```
┌ Attyx — Agents ───────────────────────────────── 4 running · 1 needs input ┐
│  ●  SESSION    PANE  MODEL       STATE     ELAPSED     IN     OUT    CTX        COST │
│  ●  myapp      3     opus-4.6    working    1m12s     1.2M   842K   82k/200k   $0.42 │
│ ▶●  myapp      8     opus-4.6    input        —         —      —     12k/200k  needs input │
│  ●  server     5     gpt-5       working      18s      430K   210K   55k/256k  ~$0.31 │
│  ●  api        7     codex       idle         —         —      —      —          —    │
├─────────────────────────────────────────────────────────────────────────────┤
│  TOTAL                                              1.6M   1.0M              $0.73 (~est) │
├─────────────────────────────────────────────────────────────────────────────┤
│ ↑↓ select  ⏎ focus  z zoom  x close  s sort  f filter  / search  r reconnect  ? help  q quit │
└─────────────────────────────────────────────────────────────────────────────┘
```

- **Status dot** colored by state: idle=green, working=orange, input=purple — same
  mapping as the tab dots (`fromHookStatus`). Make the `input` rows visually
  loudest (they're the ones that need the human).
- **Selected row** marked (`▶`) and reverse-video; `↑/↓`/`j/k` move it.
- **Columns** (drop/condense as width shrinks, see §9 responsive):
  dot, session, pane id, model, state, elapsed, input tokens, output tokens,
  context (`used/max`, optionally a 1-cell bar), cost.
- **Unknowns render `—`**, never `0`. **Estimated cost** gets a `~` prefix and the
  footer notes "(~est)".
- **Footer/totals**: agent count by state in the header bar; token + cost sums in
  the totals row.
- **Help bar**: one line of keybindings.

### 8.2 Detail view (Enter on a row, or a side panel toggle)

A focused view of one agent: full message/preview, full usage breakdown
(in/out/cache-read/cache-write/reasoning, context used vs max with a bar), model,
cost (and whether estimated), pid, session/tab/pane ids, time in current state.
`Esc`/`Enter` returns to the table. (v1 may implement this as a bottom panel rather
than a separate screen — simpler.)

### 8.3 Empty state

No agents: centered hint — "No agents running. Launch one with `claude`, `codex`,
`opencode`, or `pi` in any pane." Keep the header/help bar.

---

## 9. Interactions & keybindings

| Key | Action | Notes |
|---|---|---|
| `↑`/`k`, `↓`/`j` | move selection | wraps or clamps (clamp) |
| `g`/`G` | top / bottom | |
| `Enter` | **focus selected agent's pane** | `session_switch` (if cross-session) + `focus`/select pane; brings the human to the agent. Then optionally exit dashboard or stay (config, §11) |
| `z` | toggle zoom on selected pane | one-shot `split_zoom -p <id> -s <sess>` |
| `x` / `Del` | **close selected pane** | **destructive → confirm first** (modal y/N). Never close without confirmation |
| `s` | cycle sort column | persists in config/session |
| `f` | cycle state filter | all → needs-input → working → idle |
| `/` | search | live-filter over session/model/message; `Esc` clears |
| `r` | reconnect stream | manual recover after a drop |
| `Tab` | toggle detail panel | |
| `?` | help overlay | |
| `q` / `Ctrl-C` | quit | always restores the terminal |

**Action safety (matches repo norms):** focusing/zooming are non-destructive and
fire immediately. **Closing a pane is destructive and must be confirmed** with an
in-app y/N modal — never on a single keystroke. The dashboard never sends
keystrokes *to* an agent in v1 (no outbound-to-agent action), sidestepping any
"don't act on the user's behalf" concern.

Actions are issued as one-shot IPC requests (open conn → send `IpcRequest` → close),
reusing the command set in `src/config/cli_ipc.zig` / `src/ipc/client.zig`. Build
the request with the targeted `pane_id` and `session`. Surface failures as a toast
line (e.g. "pane 8 already closed") rather than crashing.

---

## 10. Visual style / theming (`theme.zig`)

For visual consistency with the terminal it runs in, read the user's Attyx config
(`~/.config/attyx/attyx.toml`, same path the app uses) and pull the active theme's
palette — or at minimum background/foreground/accent and the status colors. Reuse
the config parser (`src/config/*`) and theme tables (`src/theme/`, `themes/`) so the
dashboard matches the user's chosen theme.

Fallbacks: if config/theme can't be read, use a built-in 256-color default. Respect
`NO_COLOR` / `--no-color` (monochrome: use weight, brackets, and the `▶`/`●` glyphs
to carry meaning instead of color). Don't assume truecolor blindly — degrade to 256
if `TERM` suggests it.

---

## 11. Configuration

Add a `[dashboard]` section to `src/config/default_config.toml` (with comments, per
repo rule) and parse it in `src/config/*`:

```toml
# ── Dashboard ────────────────────────────────────────────────────────
# `attyx dashboard` — the full-screen agent TUI.

[dashboard]
# Default sort column: "state" | "cost" | "tokens" | "ctx" | "session".
# sort = "state"

# After pressing Enter to focus an agent's pane, also exit the dashboard.
# focus_exits = false

# Elapsed-time refresh cadence (ms) while any agent is working.
# tick_ms = 1000

# Show estimated costs (from the telemetry price table) with a ~ marker.
# show_estimates = true
```

**Default launch keybind / popup.** Make it trivially launchable: ship a commented
example `[[popup]]` (the popup system already supports `command =` and a hotkey) and
a default keybind that runs `attyx dashboard` in a popup or split. E.g. in the popup
section of `default_config.toml`:

```toml
# [[popup]]
# hotkey = "ctrl+shift+a"
# command = "attyx dashboard"
# width = "90%"
# height = "80%"
# border = "rounded"
```

This is the recommended replacement for the GPU overlay keybind from the telemetry
doc.

---

## 12. Performance

- Idle CPU ≈ 0: block in `poll`; no redraw without a change. The only timer is the
  elapsed-time tick, and it's only armed while something is `working`.
- Diff rendering means a status change repaints a few cells, not the screen.
- Coalesce bursts: if multiple stream frames are readable in one wake, apply them
  all, then render once.
- Stream volume is low (status/usage transitions), so no backpressure concerns on
  the client side; still, read all available bytes per wake and never block the
  loop on a partial line.

---

## 13. Edge cases & degradation

- **No running instance / no daemon:** connect fails → print a clear message to
  stderr ("no running Attyx instance found", matching `client_watch.zig`) and exit
  non-zero. Do not enter alt screen first.
- **Stream drops mid-run** (instance restarted): detect EOF on the stream fd, show a
  "disconnected — press r to reconnect" banner, keep the last table visible (dimmed),
  and auto-retry with backoff. On reconnect, the snapshot re-seeds the model.
- **Non-TTY stdout** (piped/redirected): skip raw mode and alt screen; if `--once`,
  print a plain text table and exit; otherwise refuse interactive mode with a hint
  to use `--once` or `attyx watch agents`.
- **Window too small** (e.g. < ~40 cols or < ~6 rows): render a compact "N agents,
  M need input" line instead of the table; restore the full layout when it grows.
- **Resize:** `SIGWINCH` → re-query `TIOCGWINSZ`, full redraw, re-clamp selection and
  column set.
- **Terminal restore on any exit:** normal quit, `q`, `Ctrl-C`, `SIGTERM`, error, or
  panic must all run teardown (§6.1). Test by killing the process and confirming the
  shell is usable.
- **Windows:** `watch_agents` is POSIX-only. v1 options: (a) on Windows, poll
  `list_agents` on an interval and render the same model (no live stream); or (b)
  mark the dashboard POSIX-only and print a notice on Windows. Pick (a) only if
  Windows is in scope; otherwise (b).

---

## 14. Testing (mandatory)

All core logic is TTY-free and must be covered headlessly (see `docs/testing.md`):

- **Model (`model.zig`):** apply a scripted sequence of NDJSON frames → assert table
  contents, removal on `none`, sticky usage merge, totals, sort orders, filters,
  selection movement (incl. selected-row removal). This is the bulk of the tests.
- **Input (`input.zig`):** byte sequences → expected `KeyEvent`s (arrows, Ctrl-C,
  Enter, Esc, printable, partial escape across reads).
- **Format (`format.zig`):** token humanization (`1234`→`1.2K`, `1_600_000`→`1.6M`),
  duration (`72s`→`1m12s`), cost formatting (`$0.42`, `~$0.31`, `—` for null),
  context `used/max` rendering, width truncation with wide chars.
- **Render diff (`render.zig`):** draw model A then model B into buffers → assert the
  emitted escape sequence touches only changed cells; full redraw on size change.
- **All-sessions request encoding (§5A):** the sentinel request round-trips.
- **`--once` snapshot:** given a model, the plain-text output matches a golden
  string.

Manual smoke (document in PR): run several agents across two sessions, open the
dashboard, confirm live updates, `Enter`-to-focus crosses sessions, `x` confirms
before closing, terminal restores cleanly on quit and on `kill`.

---

## 15. File-touch checklist

New (under `src/ipc/dashboard/`, each < 600 lines):
- `run.zig` — entry, poll loop, signals, teardown.
- `term.zig` — raw mode / alt screen / size query.
- `render.zig` — frame buffer + diff renderer + draw helpers.
- `input.zig` — key decoder.
- `model.zig` — agent table, merge, sort/filter, totals (heaviest tests).
- `format.zig` — humanize/format helpers.
- `theme.zig` — palette from config + fallback.

Edited:
- `src/config/cli.zig` — `dashboard` action + dispatch.
- `src/config/cli_help.zig` / `cli_ipc_help.zig` — help text.
- `src/ipc/client.zig` — reuse `connectToSocket`; possibly export the all-sessions
  watch request builder.
- `src/ipc/watch.zig` + `src/app/daemon/*` — all-sessions watch sentinel (§5A).
- `src/config/default_config.toml` + `src/config/*` — `[dashboard]` options +
  example popup/keybind.
- `releases/vX.Y.Z.md` — user-facing note.

---

## 16. Out of scope / future

- **Send-to-agent:** typing a prompt to the selected agent from the dashboard
  (would reuse `send_keys`); deferred — keep v1 read+navigate only.
- **GPU overlay** variant (telemetry doc §9): a thin in-process reader of the same
  model, for zero-spawn glances. Only if spawn latency proves annoying.
- **History/sparklines:** token/cost over time per agent. Needs persistence; out of
  scope for a live view.
- **Mouse support:** click-to-select/focus. Easy to add later; not v1.
