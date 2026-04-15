# Design: Server-Side VT Engine (tmux-style)

## Motivation

Attyx session switching is ~60–200ms because the daemon is a **byte-level**
multiplexer — it ships raw PTY output to the client and the client's VT
engine reprocesses those bytes to rebuild cell state. For a session with
several altscreen TUI apps (Claude Code, vim, htop), every switch requires
replaying tens of KB of VT sequences per pane.

Tmux is instant because its server runs the engine itself: it keeps a
rendered cell grid per pane in server memory, and switching just ships the
grid. There's nothing to replay.

This doc proposes moving the VT engine from client to daemon so attyx can
match tmux's switch latency.

## Current architecture (byte-level)

```
┌─ attyx client ────────────────────┐   ┌─ attyx daemon ────────┐
│                                   │   │                       │
│  render (Metal/GL)                │   │  PTY masters          │
│       ↑                           │   │       ↓               │
│  cells (AttyxCell buffer)         │   │  per-pane ring        │
│       ↑                           │   │  buffer of raw bytes  │
│  Engine per pane (src/term/)      │◀──┼──────── socket ───────┤
│       ↑                           │   │  (pane_output msgs)   │
│  pane_output bytes via socket     │   │                       │
│                                   │   │                       │
└───────────────────────────────────┘   └───────────────────────┘
```

- Daemon stores raw PTY bytes, sends them on focus.
- Client runs `src/term/` Engine to parse bytes → cells.
- On focus change, daemon replays the ring; client re-parses from scratch.

## Proposed architecture (cell-level)

```
┌─ attyx client ────────────────┐   ┌─ attyx daemon ────────────┐
│                               │   │                           │
│  render (Metal/GL)            │   │  PTY masters              │
│       ↑                       │   │       ↓                   │
│  cells (AttyxCell buffer)     │◀──┼── socket (grid sync) ─────┤
│       ↑                       │   │       ↑                   │
│  grid sync (apply deltas)     │   │  Engine per pane          │
│  input router                 │   │  (src/term/ moved here)   │
│                               │   │       ↑                   │
│                               │   │  PTY bytes → engine       │
│                               │   │                           │
└───────────────────────────────┘   └───────────────────────────┘
```

- Daemon owns the Engine per pane, feeds PTY bytes into it continuously.
- Daemon maintains an authoritative cell grid per pane at all times.
- Focus/session switch: daemon ships a cell snapshot (or delta since the
  client's last-seen generation). No replay. No shadow engine. No
  reprocessing.
- Client is now a "thin" renderer + input router.

## Protocol sketch

Two new message types; `pane_output` + `replay_end` go away.

### `grid_snapshot` (daemon → client)

Sent on first focus and whenever the client requests a full resync.

```
pane_id: u32
generation: u64       // monotonic per-pane counter; client tracks last-seen
rows: u16
cols: u16
alt_active: u8
cursor_row: u16
cursor_col: u16
cursor_visible: u8
cursor_shape: u8
// followed by rows*cols packed cells (same wire format as AttyxCell or similar)
```

### `grid_delta` (daemon → client)

Sent every time the daemon's engine emits dirty rows (throttled to
~60Hz per-client).

```
pane_id: u32
generation: u64                    // new generation after this delta
dirty_row_bitmap: [N]u64           // which rows changed
// for each dirty row: packed row cells
cursor_row/col/visible/shape: ...  // (include even if unchanged, it's tiny)
```

Client applies: if its last-seen generation matches `generation - 1`,
apply dirty rows; otherwise request a full `grid_snapshot`.

### Input still flows as-is

`pane_input` (client → daemon, raw bytes for PTY write) stays unchanged.
That path is already thin.

## One engine codebase, two run-time locations

**The engine module is not duplicated.**  `src/term/` stays exactly where
it is — a single pure, deterministic implementation.  Both the client
binary and the daemon binary `@import` it.

- **Plain mode (no daemon):** client's PTY thread runs the engine
  in-process, same as today.  No grid protocol kicks in.
- **Session mode (daemon attached):** the daemon runs the engine in its
  own process.  Client receives grid snapshots/deltas over the socket
  and becomes a thin renderer.

A given pane's engine runs in exactly one process — whichever owns the
PTY.  Never both.  The renderer can take its cells from either source
based on a small enum at the cell-publishing layer.

**Per-pane vs. per-viewer state.**  Some state currently living in
`TerminalState` is really per-client, not per-pane: `viewport_offset`
(scroll position), search matches, selection, Xyron UI state.  When the
engine moves server-side for session mode, these must stay client-side
(each attached client can scroll independently).  The refactor needs to
split `TerminalState` into:
- **Authoritative engine state** (daemon-side in session mode):
  cells, cursor, altscreen mode, saved cursor, scroll region, title,
  mouse/cursor-keys modes, theme colors.
- **Per-viewer UI state** (always client-side): viewport_offset, search
  state, selection rect, Xyron integration fields.

In plain mode both live in the same process so nothing changes.  In
session mode the boundary matters.

## Implementation plan

1. **Prepare `src/term/` for the split.**
   - Engine must not depend on client globals (`terminal.g_*`) or anything
     platform-specific.  Already true per CLAUDE.md; double-check.
   - Separate per-viewer fields (viewport_offset, etc.) out of
     `TerminalState` into a new `ViewerState` struct owned by the client.
   - Remove engine instances from client-side `Pane` only for
     daemon-backed panes (local panes keep theirs).

2. **Daemon owns engines.**
   - Each `DaemonPane` gets an `Engine` alongside its existing ring buffer
     (keep the ring buffer initially for debugging/reconstruction).
   - PTY read path: `engine.feed(bytes)` instead of (or in addition to)
     appending to the ring.

3. **Dirty-row tracking per client.**
   - Daemon tracks `last_sent_generation` per (client, pane) pair.
   - After each `engine.feed`, if generation advanced, flag pane for sync
     to each attached client that has it in `active_panes`.

4. **Grid sync loop.**
   - Every daemon poll iteration (~16ms), for each flagged (client, pane):
     - If client's last-seen == gen-N (adjacent), send `grid_delta`.
     - Otherwise send `grid_snapshot`.
   - Client replies with ack? Probably not needed — daemon just tracks
     what it sent.

5. **Client becomes renderer-only.**
   - On `grid_snapshot`: copy cells into `pane.cells_view` (new field
     replacing `pane.engine`). Mark pane dirty for render.
   - On `grid_delta`: apply dirty rows, update cursor globals.
   - `switchActiveTab` no longer composes from `pane.engine` — copies
     from `pane.cells_view` into `ctx.cells`.

6. **Retire dead code.**
   - Shadow engine (`pane.shadow_engine`) — no longer needed.
   - `pane_output` handler in event_loop — gone.
   - `replay_end` handler + `replay_end` protocol msg — gone.
   - `notifyRedraw` / SIGWINCH nudge in daemon — gone. The TUI's redraws
     flow into the daemon's engine naturally; no need to force them.
   - `needs_engine_reinit` flag on Pane — gone.
   - Client-side `src/term/` Engine usage — gone (replaced by cells_view).

7. **Keep ring buffer?**
   - The daemon's replay ring was useful for "new client attaches to
     existing session" scenarios and for debugging. For new clients,
     we can bootstrap them by sending a snapshot from the current
     engine state. Ring becomes redundant — remove it.

## Input routing

Currently `attyx_handle_key` on the client translates keys to VT bytes
and sends them via `pane_input`. That stays. The daemon's engine
processes both the child's output AND receives input bytes — but input
goes straight to the PTY master (write to child), not through the
engine. Same as today.

## What breaks during the refactor

- **Xyron integration:** Xyron-specific overlays and completion state
  live in the client's engine today (`engine.state.xyron_ipc_socket`
  etc.). Either (a) keep those fields in a client-side per-pane struct
  that's orthogonal to the engine, or (b) move those to daemon too.
  Option (a) is cleaner — Xyron's UI decisions belong on the client.

- **Per-pane viewport_offset (scrollback scroll):** Currently the engine
  tracks this. Server-side engine must either (a) maintain per-client
  viewport offsets (complicated) or (b) expose scrollback as a separate
  query (`get_scrollback_range` → bytes, client re-parses for its local
  scroll view). (b) is saner: active viewport tracking per pane, but
  scrollback rendering becomes an explicit "give me rows N..M" RPC.
  This is actually how tmux copy-mode works — it asks the server for
  historical cells.

- **Search (`src/app/ui/search.zig`):** Currently searches client's
  engine. Needs to search via the daemon — add `search_pane` RPC.

- **Selection/copy:** Client-side selection state is fine; the actual
  copy reads cells from `pane.cells_view` which is up-to-date.

## Performance expectations

- **Tab switch within session:** already fast after the warm-panes
  change. Server-side engine doesn't improve this much.
- **Session switch:** 60–200ms → 5–15ms. The win.
- **First attach / session restore:** need to ship one snapshot per
  pane, each ~rows*cols*sizeof(Cell) = 80*30*32 = ~77KB. Localhost
  socket = <5ms per pane.
- **Steady-state bandwidth:** deltas are tiny (usually 1-3 dirty rows
  per frame). Similar or less than current pane_output stream, because
  the daemon coalesces engine-internal state transitions.

## Migration strategy

Can ship incrementally:
1. Ship the engine in daemon alongside the existing byte-stream path.
   Run both, compare cell grids for sanity.
2. Add `grid_snapshot` / `grid_delta` protocol. Client opt-in via flag.
3. Flip default to grid-sync. Remove byte-stream path and client engine
   after a release of field testing.

## What we already did in preparation

Not really preparation, but the recent work made the client-side flow
cleaner:
- `scratch_cells` + atomic `@memcpy` for cell publishing — the renderer
  already treats the cell buffer as authoritative. Swapping in a daemon-
  delivered grid instead of a client-engine-rendered one is a drop-in.
- Shadow engine — can be deleted once daemon owns the engine.
- Warm-panes (`sendActiveFocusPanes` keeps all daemon panes active) —
  already matches the server-side engine model; the daemon already
  streams all output. The only reason we still replay is that the
  client reboots its engine on first-time focus. Server-side engine
  removes that.

## Rough effort

- Extract engine to daemon: 1 day (engine is already pure).
- Protocol + serialization: 1 day.
- Client renderer wiring: 1 day.
- Search / scrollback / Xyron integration patches: 2 days.
- Testing / debugging: 2 days.

**~1 week of focused work** for a proper migration.
