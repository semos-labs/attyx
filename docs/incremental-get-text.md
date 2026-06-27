# Incremental Capture — `get_text --since <cursor>`

Let an agent read only the rows a pane has produced **since its last read**, instead
of re-capturing the whole screen every poll. A cursor token returned by each read is
passed back on the next read; the response carries only new rows plus a fresh cursor.

This is the highest token-savings-per-effort change on the agent surface: anything
that babysits a long-running pane (a build, a test loop, another agent) currently
re-reads the full screen each tick and re-sends it to the model. With `--since`, a
quiet pane returns ~nothing.

Implementation spec, written to hand to an agent. Depends on the existing `get_text`
path (`src/ipc/handler_query.zig`, `src/term/grid.zig` ring buffer,
`src/ipc/client.zig`, `src/ipc/mcp_tools.zig`).

---

## 1. The core problem: absolute indices aren't stable

Today `writeScreenText` (`handler_query.zig`) reads the ring by **absolute index**:

```zig
const ring = &pane.engine.state.ring;
total_rows = if (lines == 0) ring.screen_rows else @min(lines, ring.count);
start_abs  = if (lines == 0) ring.scrollbackCount() else ring.count - total_rows;
... ring.getRow(start_abs + i) ...
```

`ring.count` is scrollback+screen rows currently retained; `scrollbackCount()` is the
rows above the visible screen. As the pane emits output, old rows **evict** off the
top of the ring, so a given absolute index points at different content over time. An
absolute index is therefore useless as a durable cursor.

We need a **monotonic logical line number** that never repeats for the life of the
pane, so a cursor means "the next line after logical line N" regardless of how much
has since scrolled away.

---

## 2. The cursor

A cursor is an opaque token the client treats as a blob and hands back verbatim.
Internally it is two integers:

```
Cursor {
  gen:  u32   // layout generation — bumps on resize/reflow/clear/alt-screen switch
  line: u64   // logical line number: the count of lines that have entered the ring
}
```

- **`line`** — a per-pane monotonic counter, incremented every time a row is
  committed into the ring (i.e., every time the cursor scrolls a line into history,
  and for the live screen rows, see §3). It never decreases and never repeats. A
  cursor's `line` is "I have consumed everything up to and including this logical
  line."
- **`gen`** — invalidates cursors when the line-to-content mapping is no longer
  comparable: terminal resize, reflow, full clear (`ED 3` / clear scrollback), and
  switching into/out of the alt screen. On a `gen` mismatch the server can't compute
  a meaningful delta, so it returns a full snapshot and a fresh cursor with
  `reset: true` (§5).

Wire form: serialize as a short ASCII token so it survives shell pipelines and JSON,
e.g. `g<gen>.l<line>` → `g3.l10427`, or base64 of the 12 packed bytes. Pick one;
ASCII is easier to debug. The client must never parse it — treat as opaque.

---

## 3. Engine changes — the logical line counter

Add to the ring/state (`src/term/grid.zig` and/or `src/term/state.zig`, wherever the
ring lives):

- `lines_total: u64` — incremented every time a line scrolls off the top of the
  screen into scrollback (the existing scroll-up path). This is the count of lines
  that have *ever* existed in this pane's stream.
- `layout_gen: u32` — bumped in the resize/reflow/clear/alt-screen paths.

Derived quantities at read time:

- The oldest logical line still in the ring:
  `oldest = lines_total - ring.scrollbackCount()` for history, but the cleanest
  model is to treat the **whole ring** (scrollback + screen) as logical lines
  `[lines_total - ring.count, lines_total + screen_rows)` — see the mapping in §4.
  Implementer: define one consistent mapping and unit-test it; the rest follows.

Important semantic choice — **append vs. live-screen rewrites.** Two regimes:

1. **Scrolling output** (shells, build logs, agent transcripts): new content pushes
   lines into history. `lines_total` advances; `--since` returns those new lines.
   This is the common, important case and the one to get right.
2. **In-place screen rewrites** (TUIs, progress bars, an editor): content changes
   without scrolling. There is no new *logical* line, but the visible screen differs.

For v1, `--since` uses **append semantics**: it returns logical lines with index ≥
the cursor, where the live screen rows are assigned provisional logical indices
above the last scrolled line. Concretely: after returning, the next cursor points at
the bottom of the current screen, so a subsequent call returns (a) any newly
scrolled-in history, plus (b) the current screen rows that are at-or-below the prior
screen bottom. For a TUI that only rewrites in place, successive `--since` reads
return the current screen (it can't tell a redraw from new content without a full
diff) — acceptable and documented. Agents that need exact screen-diff semantics use
plain `get_text` (full screen) instead. Don't build a cell-diff engine here; that's
the dashboard renderer's job (`docs/agent-dashboard.md`).

> Keep it append-only and simple. The 90% use case is "tail the new output of a
> scrolling pane," and that's crisp and cheap.

---

## 4. Read semantics (server)

Given an incoming cursor `(gen, line)` on a pane:

1. **Gen mismatch** (`gen != layout_gen`): can't delta. Return the visible screen (or
   `lines` rows if requested), `reset: true`, and a fresh cursor at the current
   bottom. The client should treat the returned text as a fresh baseline.
2. **Gen match:**
   - Compute the available logical range in the ring:
     `[base, head)` where `base = lines_total - ring.scrollbackCount()` (oldest
     retained) and `head` = logical index just past the last screen row.
   - **Truncation:** if `line < base`, the client's cursor is older than what the
     ring still holds — some lines were evicted unseen. Clamp the start to `base`,
     set `truncated: true` so the caller knows there's a gap.
   - Emit rows for logical indices in `[max(line, base), head)`, reusing the existing
     row-rendering loop in `writeScreenText` (trailing-space trim, UTF-8 encode,
     `\n` per row). Skip nothing else — same formatting as today.
   - New cursor = `(layout_gen, head)`.
3. **Nothing new** (`line == head`): return empty text and the same cursor. This is
   the hot path for a quiet pane — make it allocate ~nothing and return fast.

Edge cases:
- A cursor from the **future** (`line > head`, e.g., pane was cleared and counter
  reset) → treat as gen-mismatch/reset.
- `lines` and `--since` together: `--since` wins (the cursor defines the start);
  `lines` may still cap the maximum rows returned to bound a catch-up read after a
  long gap. Document that combination.

---

## 5. Response shape

The caller needs both the text and the next cursor. Two surfaces:

**Structured (MCP + `--json`):** return a JSON object:

```json
{
  "cursor": "g3.l10581",
  "text": "make[1]: Entering directory ...\n  CC parser.o\n",
  "truncated": false,
  "reset": false,
  "rows": 2
}
```

**Plain CLI (`attyx get-text --since <tok>`):** print the new **text to stdout**
(clean for pipelines) and the next **cursor to stderr** as `cursor: g3.l10581`. Add
`--cursor-only` to print just the next cursor to stdout (no text) for scripts that
advance without consuming, and surface `truncated`/`reset` as a stderr note. Rationale:
keeping text on stdout means existing `get-text | grep ...` pipelines still behave;
the cursor rides the side channel.

---

## 6. Protocol & wiring

### 6.1 IPC protocol

Today get_text uses two message types — `.get_text` (focused pane, payload
`[lines:u32]`) and `.get_text_pane` (payload `[pane_id:u32][lines:u32]`). Add a
**third** to keep decoding unambiguous and back-compat intact:

- `.get_text_since` — payload `[pane_id:u32 (0 = focused)][gen:u32][line:u64][lines:u32]`.

Decode in a new handler `buildGetTextSince` next to `buildGetText`/`buildGetTextPane`
in `handler_query.zig`, factoring the row-emit loop in `writeScreenText` into a
helper that takes a `(start_logical, end_logical)` range and a `reset/truncated`
result so all three entry points share it. The response is framed as today
(`sendOk`), but when the request set `json_output`, emit the JSON object of §5;
otherwise emit raw text and append the cursor as a trailing framed field — simplest:
always return JSON for `.get_text_since` and let the CLI/MCP layer unwrap (the cursor
must travel with the text regardless, so structured is the honest wire shape here).

### 6.2 `IpcRequest` & CLI parsing (`src/config/cli_ipc.zig`)

- Add fields to `IpcRequest`: `since_gen: u32 = 0`, `since_line: u64 = 0`,
  `has_since: bool = false`, `cursor_only: bool = false`.
- In the `get-text` arg parser (currently handles `--lines`/`-n` ~line 206), add:
  - `--since <token>` → parse the token into `since_gen`/`since_line`, set
    `has_since = true`. A malformed token is a fatal arg error.
  - `--cursor-only` → `cursor_only = true`.
- Help text (`help.get_text`): document `--since`, the cursor, `truncated`/`reset`,
  and `--cursor-only`, with a tailing-a-build example.

### 6.3 Client (`src/ipc/client.zig`)

- In the get_text encoding (the `.get_text` blk ~line 427), when `has_since`, encode
  `.get_text_since` with the full payload (pane id may be 0 for focused).
- Parse the JSON response: print `text` to stdout; print `cursor` to stderr (or
  stdout under `--cursor-only`); note `truncated`/`reset` to stderr.

### 6.4 MCP (`src/ipc/mcp_tools.zig`)

Extend the `get_text` tool schema with optional `since` (string) and a `cursor_only`
(bool); when `since` is present, `fill()` routes to `.get_text_since`. The tool
result becomes the JSON object of §5 (or keep returning text but add the cursor —
structured is cleaner for the model to consume). Update the tool `description`:
"Pass the `cursor` from a previous call as `since` to get only new output."

### 6.5 Daemon

For daemon-backed panes, the logical counter lives on the engine (daemon side, in
grid-sync mode). Ensure the `get_text_since` query is answered where the engine
actually runs (same place `get_text` is answered today) — no separate propagation
needed beyond routing the new message type through the daemon handler like the
existing get_text variants.

---

## 7. SKILL.md update

Add a subsection under "Reading Output" in `skills/claude/attyx/SKILL.md`:

```bash
# First read seeds a cursor (to stderr); capture it.
out=$(attyx get-text -p 3 --since "" 2>cur); cur=$(cut -d' ' -f2 <cur)
# Later: only the new rows since last time.
new=$(attyx get-text -p 3 --since "$cur" 2>cur2); cur=$(cut -d' ' -f2 <cur2)
```

Document the `--json` shape (the cleaner path for agents) and that an empty/omitted
`since` means "from now" (return current screen + a starting cursor), while
`--since <tok>` returns the delta. Note `truncated:true` means output scrolled past
the retained scrollback between reads (increase `--scrollback-lines` or read more
often), and `reset:true` means the layout changed and the text is a fresh baseline.

> Decide and document the empty-cursor semantics: `--since ""` (or no token) = "start
> here, return current screen and a cursor" is the most useful seed for a tailer.

---

## 8. Testing (mandatory, headless)

Pure ring/cursor logic — test without rendering:

- **Append delta:** write N lines, read with no cursor → get baseline + cursor;
  write M more → read with cursor → get exactly the M new lines + advanced cursor.
- **No-change:** reading twice with no output between returns empty text, same cursor.
- **Truncation:** force eviction (write more than scrollback depth) between reads →
  `truncated: true`, start clamped to oldest retained.
- **Gen reset:** resize/reflow/clear between reads → `reset: true`, fresh baseline,
  new gen.
- **Future cursor:** a cursor beyond head (post-clear) → reset path, no panic.
- **`lines` + `since`:** catch-up read is capped by `lines`.
- **Token round-trip:** serialize/parse cursor token; malformed token rejected.
- **Formatting parity:** `--since` rows match `get_text`'s trimming/UTF-8 for the
  same content (share the helper, assert identical bytes).

---

## 9. File-touch checklist

- `src/term/grid.zig` / `src/term/state.zig` — `lines_total` counter, `layout_gen`,
  bump points (scroll-up, resize/reflow/clear/alt-screen), logical↔physical mapping
  helper + tests.
- `src/ipc/handler_query.zig` — `buildGetTextSince`, shared row-emit helper, JSON
  response, truncated/reset flags.
- `src/app/daemon/*` — route `.get_text_since` like the existing get_text variants.
- `src/ipc/protocol.zig` (or wherever `MessageType` lives) — add `.get_text_since`.
- `src/config/cli_ipc.zig` — `--since`/`--cursor-only` parsing, `IpcRequest` fields,
  help text.
- `src/ipc/client.zig` — encode `.get_text_since`, parse + split text/cursor output.
- `src/ipc/mcp_tools.zig` — `since`/`cursor_only` on the `get_text` tool + routing.
- `skills/claude/attyx/SKILL.md` — usage + semantics.
- `releases/vX.Y.Z.md` — user-facing note.

---

## 10. Out of scope

- **Cell-level screen diffing** for TUIs (cursor-addressed redraws). Append semantics
  only; exact screen diff belongs to the dashboard renderer, not this query.
- **Styled output** (colors/attrs in the delta). `get_text` is plaintext today; keep
  `--since` plaintext. A styled capture is a separate feature.
- **Cross-pane cursors.** A cursor is scoped to one pane; don't make it portable.
