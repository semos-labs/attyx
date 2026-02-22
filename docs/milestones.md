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
