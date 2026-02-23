# Attyx Milestones

## Status

| # | Milestone | Status |
|---|-----------|--------|
| 1 | Headless terminal core (text-only) | ✅ Done |
| 2 | Action stream + parser skeleton | ✅ Done |
| 3 | Minimal CSI support (cursor, erase, SGR) | ✅ Done |
| 4 | Scroll regions (DECSTBM) + IND/RI | ✅ Done |
| 5 | Alternate screen + save/restore cursor + mode handling | ✅ Done |
| 6 | SGR extended colors (256-color + truecolor) | ✅ Done |
| 7 | OSC support — hyperlinks + title | ✅ Done |
| 8 | Mouse reporting + bracketed paste + input encoder | ✅ Done |
| UI-1 | PTY bridge (headless app loop) | ✅ Done |
| S-0 | Minimal session event log | ✅ Done |
| UI-2 | Window + GPU renderer (live grid, Metal/macOS) | ✅ Done |
| UI-3 | Keyboard input + interactive shell | ✅ Done |

---

## Milestone 1: Headless Terminal Core

**Goal:** Build a fixed-size grid with a cursor that processes plain text
and basic control characters. No escape sequences, no PTY, no rendering.

**What was built:**

- `Cell` type (stores one ASCII byte, default space).
- `Grid` type (flat row-major `[]Cell` array, single allocation).
- `TerminalState` with cursor and `feed(bytes)` (later refactored in M2).
- Snapshot serialization to plain text for golden testing.
- Headless runner for test convenience.

**Byte handling:**

| Byte | Name | Behavior |
|------|------|----------|
| 0x20–0x7E | Printable ASCII | Write to grid at cursor, advance cursor |
| 0x0A | LF (line feed) | Move cursor down one row (does NOT reset column) |
| 0x0D | CR (carriage return) | Move cursor to column 0 |
| 0x08 | BS (backspace) | Move cursor left by 1, clamp at 0, no erase |
| 0x09 | TAB | Advance to next 8-column tab stop, clamp at last column |
| Everything else | — | Ignored |

**Line wrapping:** When a printable character is written at the last column,
the cursor wraps to column 0 of the next row. If that row is past the bottom,
the grid scrolls up.

**Scrolling:** Drop top row, shift all rows up by one, clear new bottom row.
No scrollback buffer — scrolled-off content is lost.

**Tests added:** 28 (grid unit tests, state unit tests, snapshot tests,
golden behavior tests).

---

## Milestone 2: Action Stream + Parser Skeleton

**Goal:** Decouple parsing from state mutation. Introduce an Action type
so the parser emits actions and the state only applies them.

**Architecture change:**

```
Before:  bytes → TerminalState.feed() → grid (parsing + mutation coupled)
After:   bytes → Parser.next() → Action → TerminalState.apply() → grid
```

**What was built:**

- `Action` tagged union: `print(u8)`, `control(ControlCode)`, `nop`.
- `Parser` — incremental 3-state machine (ground / escape / CSI).
- `TerminalState.apply(action)` — replaces old `feed(bytes)`.
- `Engine` — owns Parser + TerminalState, provides `feed(bytes)` API.
- `runChunked()` for testing sequences split across chunk boundaries.

**Parser states:**

| State | Entered by | Exits on |
|-------|------------|----------|
| Ground | Default / after sequence | ESC → Escape; printable/control → emit action |
| Escape | ESC byte | `[` → CSI; any other → Nop, back to Ground |
| CSI | ESC + `[` | Final byte (0x40–0x7E) → Nop, back to Ground |

**Key design decisions:**

- `next(byte) → ?Action`: one byte in, zero or one action out.
  Null means "byte consumed, no complete action yet" (e.g., ESC entering escape state).
- CSI sequences are fully consumed but emit Nop (semantics deferred to M3).
- CSI parameter bytes are buffered in a fixed [64]u8 for future use and tracing.
- Parser is zero-allocation and fully incremental across chunk boundaries.

**Behavioral change from M1:**
ESC is no longer simply skipped. It enters escape state and consumes the
following byte as part of the escape sequence. This matches real VT100 behavior
where ESC is always at least a two-byte sequence.

**Tests added:** 20 new (48 total). Covers parser unit tests, ESC/CSI golden
tests, and incremental chunk-splitting tests.

---

## Milestone 3: Minimal CSI Semantics

**Goal:** CSI sequences actually do things. Extend the parser to produce
structured actions with parsed parameters, and implement them in the state.

**What was built:**

- `Color` enum (8 standard ANSI colors + default).
- `Style` struct (fg, bg, bold, underline) attached to every `Cell`.
- The "pen" — current text attributes in `TerminalState`, stamped onto every printed cell.
- CSI parameter parsing: `"31;1"` → `[31, 1]`. Handles semicolons, missing params, overflow.
- Structured CSI dispatch in the parser for 5 CSI command types.
- State implementation for all 5 CSI commands.

**Supported CSI sequences:**

| Sequence | Name | Behavior |
|----------|------|----------|
| `ESC[{r};{c}H` | CUP (Cursor Position) | Move cursor to absolute position (1-based, default 1;1) |
| `ESC[{r};{c}f` | HVP | Same as CUP |
| `ESC[{n}A` | CUU (Cursor Up) | Move cursor up by n (default 1), clamp at row 0 |
| `ESC[{n}B` | CUD (Cursor Down) | Move cursor down by n, clamp at last row |
| `ESC[{n}C` | CUF (Cursor Forward) | Move cursor right by n, clamp at last col |
| `ESC[{n}D` | CUB (Cursor Back) | Move cursor left by n, clamp at col 0 |
| `ESC[{n}J` | ED (Erase in Display) | 0: cursor→end, 1: start→cursor, 2: all |
| `ESC[{n}K` | EL (Erase in Line) | 0: cursor→EOL, 1: BOL→cursor, 2: full line |
| `ESC[{...}m` | SGR (Select Graphic Rendition) | See below |

**SGR codes supported:**

| Code | Effect |
|------|--------|
| 0 | Reset all attributes |
| 1 | Bold |
| 4 | Underline |
| 30–37 | Set foreground (black, red, green, yellow, blue, magenta, cyan, white) |
| 39 | Reset foreground to default |
| 40–47 | Set background (same 8 colors) |
| 49 | Reset background to default |

**New Action variants:**

```zig
cursor_abs: CursorAbs,    // CSI H / f
cursor_rel: CursorRel,    // CSI A/B/C/D
erase_display: EraseMode,  // CSI J
erase_line: EraseMode,     // CSI K
sgr: Sgr,                  // CSI m
```

**Data model change:** `Cell` now stores `Style` alongside `char`. Snapshot
format remains text-only (characters only) — style is verified through
programmatic attribute tests.

**Tests added:** 33 new (81 total). Includes golden snapshot tests for all
CSI commands, SGR attribute tests (direct cell inspection), and incremental
parsing tests for CSI with parameters split across chunks.

---

## Milestone 4: Scroll Regions + IND/RI

**Goal:** Implement DECSTBM scroll margins so that scrolling can be limited
to a subset of rows. This is the mechanism TUI apps use to keep status bars
fixed while content scrolls.

**What was built:**

- `scrollUpRegion(top, bottom)` and `scrollDownRegion(top, bottom)` on Grid.
- `scroll_top` / `scroll_bottom` fields on TerminalState (0-based inclusive).
- DECSTBM (`ESC[top;bottomr`) parsing and application.
- Region-bounded scrolling: LF at region bottom scrolls only within the region.
- Wrapping at region bottom also triggers region-bounded scroll.
- `ESC D` (Index) — same as LF, scroll within region if at bottom margin.
- `ESC M` (Reverse Index) — move up, scroll region down if at top margin.

**Supported sequences added:**

| Sequence | Name | Behavior |
|----------|------|----------|
| `ESC[{t};{b}r` | DECSTBM | Set scroll region (1-based, default = full screen) |
| `ESC[r` | DECSTBM reset | Reset scroll region to full screen |
| `ESC D` | IND (Index) | Move down; scroll within region if at bottom |
| `ESC M` | RI (Reverse Index) | Move up; scroll region down if at top |

**Key rules:**

- Scroll regions only affect *scrolling* (LF at margin, wrap at margin, IND, RI).
- Cursor movement (CUP, CUU/CUD) clamps to screen bounds, NOT to scroll region.
- Invalid regions (top >= bottom after clamping) are silently ignored.
- `scrollUp()` now delegates to `scrollUpRegion(0, rows-1)` for DRY.

**Tests added:** 19 new (100 total). Covers region set/reset, invalid region
rejection, LF within region, multiple scrolls, wrap-triggered region scroll,
IND at region bottom, RI at region top, RI outside region, cursor movement
outside region, and LF outside region.

---

## Milestone 5 — Alternate screen + save/restore cursor + mode handling

**Goal:** Implement dual-buffer alternate screen, cursor save/restore, and DEC
private mode parsing. This is the mechanism that makes `vim`, `htop`, `less`
restore your original terminal contents on exit.

### Sequences added

| Sequence | Name | Action |
|----------|------|--------|
| `ESC[?1049h` | Enter alt screen | Switch to alt buffer, clear, cursor home |
| `ESC[?1049l` | Leave alt screen | Switch back to main buffer, restore cursor |
| `ESC[?47h/l` | Alt screen (legacy) | Treated equivalently to `?1049` |
| `ESC[?1047h/l` | Alt screen (variant) | Treated equivalently to `?1049` |
| `ESC 7` | DECSC | Save cursor + pen + scroll region |
| `ESC 8` | DECRC | Restore cursor + pen + scroll region |
| `CSI s` | Save cursor (ANSI) | Same as DECSC |
| `CSI u` | Restore cursor (ANSI) | Same as DECRC |

### Parser changes

- DEC private mode sequences (`ESC[?...h` / `ESC[?...l`) are now recognized.
  The `?` prefix byte is detected in the CSI buffer and routed to
  `dispatchDecPrivate()`.
- `ESC 7` and `ESC 8` are handled in `onEscape()`.
- `CSI s` and `CSI u` are handled in `dispatchCsi()`.

### Architecture: the swap-based dual buffer

Instead of wrapping per-buffer state in a `BufferContext` struct (which would
require rewriting every field access), we keep the flat layout:

```
TerminalState
  grid, cursor, pen, scroll_top, scroll_bottom, saved_cursor   ← active
  inactive_grid, inactive_cursor, inactive_pen, ...             ← stashed
  alt_active: bool
```

`swapBuffers()` exchanges all 6 field pairs using `std.mem.swap`. This is
zero-copy for grids (just swaps the slice headers, ~16 bytes each) and keeps
all existing code (`printChar`, `cursorDown`, etc.) untouched — they naturally
operate on whichever buffer is active.

**Enter alt screen:**
1. `swapBuffers()` — main state goes to inactive, alt state becomes active
2. Clear the (now-active) alt grid, reset cursor to home, reset pen/scroll
3. Set `alt_active = true`

**Leave alt screen:**
1. `swapBuffers()` — alt state goes to inactive, main state becomes active
2. Set `alt_active = false`

This preserves main buffer contents perfectly and costs zero allocations.

### SavedCursor

`SavedCursor` captures: cursor position, pen (SGR attributes), and scroll
region bounds. It is stored per-buffer (swapped along with the rest), so
save/restore in the alt screen does not affect the main screen's saved state.

### Data model changes

- `TerminalState` gained 7 new fields: `inactive_grid`, `inactive_cursor`,
  `inactive_pen`, `inactive_scroll_top`, `inactive_scroll_bottom`,
  `inactive_saved_cursor`, `alt_active`.
- `SavedCursor` struct: `cursor`, `pen`, `scroll_top`, `scroll_bottom`.
- `init()` now allocates two grids (with `errdefer` for safety).
- `deinit()` frees both grids.

### Action variants added

`enter_alt_screen`, `leave_alt_screen`, `save_cursor`, `restore_cursor`.

**Tests added:** 22 new (122 total). Covers alt screen preserving main,
alt cleared on re-entry, `?47h`/`?1047h` variants, double-enter idempotency,
cursor restore on leave, DECSC/DECRC golden test, CSI s/u golden test,
save/restore pen attributes, per-buffer cursor isolation, save/restore
scroll region capture, DEC private mode parsing, unsupported mode nop.

---

## Milestone 6 — SGR extended colors (256-color + truecolor + bright)

**Goal:** Extend SGR support from 8 basic ANSI colors to the full spectrum:
256-color palette and 24-bit truecolor for both foreground and background.

### Color type redesign

The `Color` type changed from a flat `enum(u8)` (~1 byte) to a tagged union
(~4 bytes) with four variants:

```zig
pub const Color = union(enum) {
    default,          // terminal theme color
    ansi: u8,         // 0–15 standard + bright
    palette: u8,      // 0–255 xterm palette
    rgb: Rgb,         // 24-bit truecolor
};
```

Named constants (`Color.red`, `Color.green`, etc.) preserve backward
compatibility with existing tests and code.

### SGR forms now supported

| SGR code | Meaning |
|----------|---------|
| `0` | Reset all attributes |
| `1` | Bold |
| `4` | Underline |
| `30–37` | Standard ANSI fg (black..white) |
| `38;5;n` | 256-color fg (n=0..255) |
| `38;2;r;g;b` | Truecolor fg |
| `39` | Reset fg to default |
| `40–47` | Standard ANSI bg |
| `48;5;n` | 256-color bg |
| `48;2;r;g;b` | Truecolor bg |
| `49` | Reset bg to default |
| `90–97` | Bright ANSI fg (colors 8–15) |
| `100–107` | Bright ANSI bg (colors 8–15) |

### Parser behavior

No parser changes needed. The CSI parameter buffer already stores the full
`;`-separated integer list. The `Sgr` action carries a `[16]u8` param array
which is enough for even combined sequences like `38;5;196;48;2;10;20;30;1`.

### State changes

`applySgr` switched from a `for` loop (one param per iteration) to a `while`
loop with an explicit index. When it encounters `38` or `48`, it calls
`parseExtendedColor()` which consumes 2 additional params (`5;n`) or 4
additional params (`2;r;g;b`). Truncated groups are silently ignored.

### Data model impact

`Cell` grew from ~5 bytes to ~11 bytes due to the larger `Color` union. For a
24×80 grid (two buffers), total memory went from ~19 KB to ~42 KB — negligible.

**Tests added:** 12 new (134 total). Covers 256-color fg/bg, truecolor fg/bg,
SGR 39 resetting truecolor, SGR 0 resetting 256-color + flags, combined
256+truecolor in one sequence, bright fg (90–97), bright bg (100–107),
truncated 38;5, truncated 38;2;r;g, and truecolor surviving chunked input.

---

## Milestone 7 — OSC support (hyperlinks + title)

**Goal:** Implement OSC (Operating System Command) parsing and support OSC 8
hyperlinks and OSC 0/2 terminal title. This enables clickable links in the
terminal UI (when a renderer is added later).

### OSC commands supported

| Sequence | Name | Behavior |
|----------|------|----------|
| `ESC ] 8 ; params ; URI ST` | Hyperlink start | Attach URI to subsequent cells |
| `ESC ] 8 ; ; ST` | Hyperlink end | Stop linking subsequent cells |
| `ESC ] 0 ; title ST` | Set icon name + title | Store title in state |
| `ESC ] 2 ; title ST` | Set title | Store title in state |

ST (String Terminator) can be `ESC \` or BEL (0x07) or C1 ST (0x9C).

### Parser changes

Two new states added to the state machine:

```
Ground ──ESC──▸ Escape ──[──▸ CSI
                   │
                   ]──▸ OSC ──BEL/C1──▸ dispatch
                         │
                         ESC──▸ OscEscape ──\──▸ dispatch (ST)
                                   │
                                   other──▸ abort, re-enter Escape
```

A 4 KB fixed buffer (`osc_buf`) stores the OSC payload. If the payload exceeds
the buffer, an overflow flag is set and the entire sequence is silently ignored.

`dispatchOsc()` parses the leading number, splits on `;`, and routes to
`makeOscHyperlink()` (for OSC 8) or emits `set_title` (for OSC 0/2).

### Action variants added

- `hyperlink_start: []const u8` — URI borrowed from parser's `osc_buf`
- `hyperlink_end` — clears the current hyperlink
- `set_title: []const u8` — title text borrowed from parser's `osc_buf`

**Borrowed slices:** The URI and title payloads in actions point into the
parser's internal buffer. They are only valid until the next `parser.next()`
call. `Engine.feed()` consumes them immediately via `state.apply()`, which
copies the data into its own allocations.

### Data model changes

- `Cell` gained `link_id: u32 = 0`.
- `TerminalState` gained:
  - `pen_link_id` / `inactive_pen_link_id` (per-buffer, swapped on alt screen)
  - `link_uris: ArrayListUnmanaged([]const u8)` — allocated URI strings
  - `next_link_id: u32` — monotonically increasing counter
  - `title: ?[]const u8` — latest terminal title
- `getLinkUri(link_id) ?[]const u8` — public lookup method.
- `deinit()` frees all URI strings and title.
- Allocations happen per hyperlink start (rare), not per character (hot path).

### Hyperlink flow

1. Parser emits `hyperlink_start("https://...")` with borrowed slice.
2. `state.apply()` calls `startHyperlink()`: duplicates URI into state's
   allocator, appends to `link_uris`, sets `pen_link_id = next_link_id++`.
3. `printChar()` stamps each new cell with `pen_link_id`.
4. Parser emits `hyperlink_end`.
5. `state.apply()` calls `endHyperlink()`: sets `pen_link_id = 0`.
6. Subsequent cells have `link_id = 0`.

**Tests added:** 20 new (154 total). Covers OSC 8 hyperlink start/end (BEL and
ST terminators), multiple links with distinct IDs, URI lookup, chunked OSC
input, buffer overflow handling, snapshot unaffected by links, OSC 0/2 title
set and replace, parser unit tests for OSC state machine and dispatch.

---

## Milestone 8 — Mouse reporting modes + bracketed paste + input encoder

**Status:** ✅ Complete

### What was added

**Terminal mode flags** in `TerminalState` (global, not per-buffer):

| Flag | Type | DEC Private Mode |
|------|------|-----------------|
| `bracketed_paste` | `bool` | `?2004h/l` |
| `mouse_tracking` | `MouseTrackingMode` | `?1000h/l` (x10), `?1002h/l` (button_event), `?1003h/l` (any_event) |
| `mouse_sgr` | `bool` | `?1006h/l` |

**Compound DEC private mode action:** The parser now emits a single
`dec_private_mode` action carrying up to 8 mode params for sequences like
`ESC[?1000;1006h`. The state iterates through all params and applies each.
This replaces the old single-param approach and subsumes alt screen
handling (`?47`, `?1047`, `?1049`).

**Mouse tracking precedence:** Enabling 1000/1002/1003 sets the tracking
mode directly (last writer wins). Disabling only takes effect if the mode
being disabled is currently active — otherwise it's a no-op.

**Input encoder module (`src/term/input.zig`):** Pure, allocation-free
functions that produce byte sequences for the PTY based on current modes:

- `wrapPaste(enabled, text, out_buf) → []const u8` — wraps text with
  `ESC[200~`/`ESC[201~` when bracketed paste is enabled.
- `encodeMouse(tracking, sgr_enabled, event, out_buf) → []const u8` —
  produces SGR mouse encoding (`CSI < Cb;Cx;Cy M/m`). Only SGR encoding
  is implemented (legacy X10 `ESC[M` not needed for modern TUIs). Move
  events are only reported in `any_event` mode.

`MouseEvent` struct carries kind (press/release/move/scroll_up/scroll_down),
button (left/middle/right/none), 1-based coordinates, and modifier booleans
(shift/alt/ctrl).

### Data flow

```
Application sends:  ESC[?1000;1006h
Parser emits:       Action.dec_private_mode { params=[1000,1006], set=true }
State applies:      mouse_tracking = .x10, mouse_sgr = true

User clicks at (10,5):
Input encoder:      encodeMouse(.x10, true, {press, left, 10, 5}) → "\x1b[<0;10;5M"
→ bytes sent to PTY
```

### Files changed

| File | Changes |
|------|---------|
| `src/term/actions.zig` | Added `MouseTrackingMode`, `DecPrivateModes`, `dec_private_mode` action variant |
| `src/term/parser.zig` | `dispatchDecPrivate` now emits compound `dec_private_mode`; updated parser tests |
| `src/term/state.zig` | Mode flags, `applyDecPrivateModes()` handler |
| `src/term/input.zig` | **New module** — `wrapPaste()`, `encodeMouse()`, `MouseEvent` |
| `src/root.zig` | Re-exports input module and new types |
| `src/headless/tests.zig` | 22 new integration tests |

**Tests added:** 37 new (191 total). Covers bracketed paste toggle, all
mouse tracking modes (enable/disable/precedence/override), SGR mouse toggle,
compound mode sequences, mode persistence across alt screen, paste wrapper
output, SGR mouse encoding (press/release/scroll/ctrl+click), and
incremental parsing for DEC private modes split across chunks.

---

## Milestone UI-1 — PTY bridge (headless app loop)

**Status:** ✅ Complete

**Goal:** Spawn a real shell attached to a PTY, feed its output through the
terminal engine, and print snapshots to stdout on state changes. No windowing
or GPU rendering — purely headless.

### What was built

**State hash (`src/term/hash.zig`):**

- Pure FNV-1a 64-bit hash over `alt_active`, cursor position, and all cell
  characters + style attributes.
- Used to detect whether the visible screen changed between poll iterations.
- 3 unit tests (identical state, different content, cursor move).

**PTY module (`src/app/pty.zig`):**

- `Pty.spawn(opts)` — opens pseudoterminal via `openpty()`, forks, sets up
  slave as controlling terminal (`setsid` + `TIOCSCTTY`), sets
  `TERM=xterm-256color`, execs command via `execvp`.
- Default command: `/bin/bash --noprofile --norc`.
- `--cmd` override via CLI args.
- Master fd set to `O_NONBLOCK` for non-blocking reads.
- `read(buf)` — returns 0 on `WouldBlock`.
- `writeToPty(bytes)` — write to master.
- `resize(rows, cols)` — `TIOCSWINSZ` ioctl.
- `childExited()` — non-blocking `waitpid` check.
- `deinit()` — close fd, reap child.
- Platform support: macOS + Linux (compile-time ioctl constants).

**UI-1 runner (`src/app/ui1.zig`):**

- Creates `Engine` at configured size (default 24×80).
- Spawns PTY with configured command.
- Puts stdin in raw mode (disables echo, canonical, signals, iexten).
- Event loop using `poll()` with 16ms timeout:
  - PTY output → `engine.feed(bytes)`.
  - stdin input → forward to PTY master.
  - State hash comparison → print snapshot if changed (throttled to ~30 fps).
- Final snapshot flush on exit to catch last-frame changes.
- Restores original termios on exit.
- Graceful handling of stdin EOF (piped input) and PTY write errors.

**CLI interface (`src/main.zig`):**

- Subcommand dispatch: `attyx ui1 [options]`.
- Options: `--rows N`, `--cols N`, `--cmd <command...>`, `--no-snapshot`,
  `--separator`, `--help`.

### Run commands

```bash
zig build run -- ui1                         # default bash, 24×80
zig build run -- ui1 --rows 40 --cols 120    # custom size
zig build run -- ui1 --cmd /bin/zsh          # custom shell
zig build run -- ui1 --separator             # --- between frames
```

### Files added/changed

| File | Change |
|------|--------|
| `src/term/hash.zig` | **New** — state hashing |
| `src/app/pty.zig` | **New** — POSIX PTY module |
| `src/app/ui1.zig` | **New** — UI-1 event loop |
| `src/main.zig` | **Rewritten** — subcommand dispatch + arg parsing |
| `src/root.zig` | Re-exports hash module |
| `build.zig` | Main exe links libc (+ libutil on Linux) |

### Constraints preserved

- `term/` remains pure and deterministic — zero dependencies on app/.
- Hash module is in `term/` (pure function over state, no side effects).
- PTY module is in `app/` (platform-specific, uses libc).
- All 191 existing tests still pass.

**Tests added:** 3 new (194 total).

---

## Milestone S-0 — Minimal Session Event Log

**Status:** ✅ Complete

**Goal:** Add a lightweight session event log that records PTY input/output and
frame boundaries. Preparation for AI integration — no AI in this milestone.

### What was built

**Session log (`src/app/session_log.zig`, ~180 lines):**

A bounded ring buffer of session events with three event types:

| Event | Payload |
|-------|---------|
| `output_chunk` | timestamp + byte slice (PTY → engine) |
| `input_chunk` | timestamp + byte slice (user → PTY) |
| `frame` | timestamp + frame_id + grid_hash + alt_active |

**Storage model:**

- Events stored in a flat array (contiguous, no wrap — shift on drop).
- Byte slices are individually allocated copies, freed when events are dropped.
- Bounded by `max_events` (default 4096) and `max_bytes` (default 4 MB).
- When either limit is reached, oldest events are dropped (batch shift).
- Frame events are only appended when the grid hash has changed since the
  last frame.

**API:**

```zig
pub fn appendOutput(bytes: []const u8) void
pub fn appendInput(bytes: []const u8) void
pub fn appendFrame(grid_hash: u64, alt_active: bool) void
pub fn lastEvents(n: usize) []const Event
pub fn stats() Stats  // { event_count, total_bytes }
```

**Integration in UI-1 event loop:**

```
PTY read  → session.appendOutput(chunk) → engine.feed(chunk) → session.appendFrame(hash)
stdin read → session.appendInput(chunk) → pty.writeToPty(chunk)
```

### Files added/changed

| File | Change |
|------|--------|
| `src/app/session_log.zig` | **New** — event log with ring buffer + 7 tests |
| `src/app/ui1.zig` | Wired session log into event loop |

### Constraints preserved

- `term/` unchanged — zero modifications.
- No UI dependency, no stdout logging, no AI.
- No persistence — log exists only in memory for the session lifetime.

**Tests added:** 7 new (event limit, byte limit, ordering, frame_id increment,
hash dedup, lastEvents clamping, stats tracking).

---

## Milestone UI-2 — Window + GPU Renderer (live grid rendering)

**Status:** ✅ Complete

**Goal:** Render the live `TerminalState` grid in a Metal-backed window on macOS.
Connect it to the existing PTY bridge so the terminal engine drives real-time display.

### Architecture

Two threads cooperate through a shared `AttyxCell` buffer:

- **Main thread (Cocoa):** Runs `[NSApp run]`, drives the `MTKView` delegate at
  60 fps. Reads the shared cell buffer and cursor position each frame.
- **PTY thread (Zig):** Polls the PTY fd with 16ms timeout. Reads bytes, feeds
  the engine, converts state to `AttyxCell` values, updates cursor globals.

No locking — `AttyxCell` is 8 bytes (effectively atomic on 64-bit), and
single-frame tearing is acceptable at 60 fps.

### What was built

**Updated C bridge (`src/app/bridge.h`):**

- `attyx_run(cells, cols, rows)` now takes a mutable `AttyxCell*` (dropped `const`).
- `attyx_set_cursor(row, col)` — update cursor position from PTY thread.
- `attyx_request_quit()` — signal the window to close (dispatches to main thread).
- `attyx_should_quit()` — polled by PTY thread to detect window close.

**Updated Metal renderer (`src/app/platform_macos.m`):**

- Accepts mutable `g_cells` — the PTY thread writes cells, the renderer reads them.
- Cursor rendering: solid light-gray block drawn as a third pass after background
  and text quads. Reads `g_cursor_row` / `g_cursor_col` volatile globals.
- Quit signaling: `applicationWillTerminate:` sets `g_should_quit = 1`.
  `attyx_request_quit()` dispatches `[NSApp terminate:]` on the main thread.
- Window title updated to "Attyx".

**UI-2 runner (`src/app/ui2.zig`):**

1. Creates `Engine` at configured size (default 24x80).
2. Allocates `AttyxCell` buffer (`rows * cols`).
3. Spawns PTY (shell).
4. Performs initial state-to-cell conversion.
5. Spawns PTY reader thread.
6. Calls `attyx_run()` — blocks on Cocoa run loop.
7. On return (window closed): thread joins, cleanup runs.

PTY reader thread:
- `poll()` loop with 16ms timeout.
- Read → `engine.feed()` → `fillCells()` → `attyx_set_cursor()`.
- Session log integration (`appendOutput`, `appendFrame`).
- On child exit: `attyx_request_quit()`.
- On `attyx_should_quit()`: break.

`fillCells()` iterates the engine grid, resolves each cell's fg/bg color
via `render/color.zig`, and writes to the shared `AttyxCell` buffer.

**CLI (`src/main.zig`):**

- Added `ui2` subcommand with `--rows`, `--cols`, `--cmd` options.
- On non-macOS: prints an error message and returns.

**Build system (`build.zig`):**

- Main `attyx` executable conditionally links Cocoa/Metal frameworks and
  compiles `platform_macos.m` on macOS.
- Old `attyx-ui` (UI-0 spike) build target remains as-is.

### Run commands

```bash
zig build run -- ui2                         # default bash, 24x80
zig build run -- ui2 --rows 30 --cols 100    # custom size
zig build run -- ui2 --cmd /bin/zsh          # custom shell
```

### Files added/changed

| File | Change |
|------|--------|
| `src/app/bridge.h` | Mutable cells, cursor, quit signaling |
| `src/app/platform_macos.m` | Cursor rendering, quit flag, mutable cells |
| `src/app/ui2.zig` | **New** — UI-2 orchestrator (PTY thread + cell conversion) |
| `src/main.zig` | Added `ui2` subcommand |
| `build.zig` | Main exe links Metal frameworks on macOS |

### Constraints preserved

- `term/` completely unchanged.
- Renderer only reads from state (via shared cell buffer).
- `src/render/color.zig` reused as-is for color resolution.
- Metal shaders, font atlas, vertex format — all reused from UI-0.
- Session log integration follows same pattern as UI-1.
- All 194 existing tests still pass.

---

## Milestone UI-3 — Keyboard Input + Interactive Shell

**Status:** ✅ Complete

**Goal:** Make Attyx usable as an interactive terminal: capture keyboard input in
the Metal window and send correct byte sequences to the PTY so bash, vim, and
tmux work.

### What was built

**DECCKM mode (`src/term/state.zig`):**

- Added `cursor_keys_app: bool` flag to `TerminalState`.
- Handle DEC private mode 1 (`?1h` / `?1l`) in `applyDecPrivateModes()`.
- Global mode (not per-buffer), persists across alt screen switches.
- 3 new headless tests.

**Updated C bridge (`src/app/bridge.h`):**

- `attyx_send_input(bytes, len)` — called from Cocoa main thread to write
  keyboard bytes to the PTY. Implemented as a Zig `export fn` in `ui2.zig`.
- `attyx_set_mode_flags(bracketed_paste, cursor_keys_app)` — called from PTY
  thread after each `engine.feed()` to keep the key handler in sync.

**Keyboard handling (`src/app/platform_macos.m`):**

Subclassed MTKView as `AttyxView` with:

- **Text input:** Regular characters via `event.characters` → UTF-8 → PTY.
- **Special keys** (via `kVK_*` key codes):

| Key | Sequence |
|-----|----------|
| Enter | `\r` |
| Backspace | `\x7f` (DEL) |
| Tab | `\t` |
| Escape | `\x1b` |
| Arrows (normal) | `\x1b[A/B/C/D` |
| Arrows (DECCKM) | `\x1bOA/B/C/D` |
| Home / End | `\x1b[H` / `\x1b[F` |
| Page Up / Down | `\x1b[5~` / `\x1b[6~` |
| Insert / Delete | `\x1b[2~` / `\x1b[3~` |
| F1–F4 | `\x1bOP` / `OQ` / `OR` / `OS` |
| F5–F12 | `\x1b[15~` ... `\x1b[24~` |

- **Ctrl+key:** `Ctrl+A..Z` → 0x01..0x1A. Also handles `Ctrl+[`, `Ctrl+]`, etc.
- **Alt/Option+key:** ESC prefix (`\x1b` + character).
- **Paste (Cmd+V):** Wraps with `\x1b[200~`/`\x1b[201~` when bracketed paste is enabled.
- **Cmd+Q:** Passes through to system quit handler.
- Edit menu added for Cmd+V paste support.

**PTY input path (`src/app/ui2.zig`):**

- Global `g_pty_master` fd set before `attyx_run()`, used by `attyx_send_input`.
- Mode flags updated after each `engine.feed()` via `attyx_set_mode_flags()`.
- `write()` is thread-safe for the PTY fd — main thread writes, PTY thread reads.

### Files added/changed

| File | Change |
|------|--------|
| `src/term/state.zig` | Added `cursor_keys_app` flag + DECCKM handling |
| `src/headless/tests/modes.zig` | 3 new DECCKM tests |
| `src/app/bridge.h` | `attyx_send_input`, `attyx_set_mode_flags` |
| `src/app/platform_macos.m` | `AttyxView` subclass with keyboard + paste |
| `src/app/ui2.zig` | Export `attyx_send_input`, mode flag updates |
| `src/app/main.zig` | Stub for UI-0 demo, test reference for ui2 |

### Constraints preserved

- `term/` changes limited to adding one mode flag — pure and deterministic.
- Keyboard encoding lives entirely in the platform layer (ObjC).
- PTY thread only reads from PTY; main thread writes via `attyx_send_input`.
- All 197 tests pass (194 existing + 3 new DECCKM tests).

### Verified keys

- Typing in bash, arrow keys for history, backspace, tab completion
- Ctrl+C (interrupt), Ctrl+D (EOF), Ctrl+Z (suspend)
- Cmd+V paste (with and without bracketed paste)
- Escape key, function keys
- Alt+key prefix encoding
