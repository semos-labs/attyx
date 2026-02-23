# Attyx Architecture

## Overview

Attyx is a deterministic VT-compatible terminal state machine written in Zig.
The design follows strict layer separation: parsing, state, and rendering
are fully independent.

## Data Flow

```
Raw bytes ─▸ Parser ─▸ Action ─▸ TerminalState.apply() ─▸ Grid mutation
              │                        │
              │  (no side effects)     │  (no parsing)
              ▼                        ▼
         Incremental              Pure state
         state machine            transitions
```

The **Parser** converts raw bytes into **Actions**. The **TerminalState** applies
Actions to the **Grid**. The **Engine** glues them together with a simple
`feed(bytes)` API.

## Directory Structure

```
src/
  term/              Pure terminal engine (no side effects)
    actions.zig        Action union + ControlCode enum + mode types
    parser.zig         Incremental VT parser (ground/escape/CSI/OSC states)
    state.zig          TerminalState — grid + cursor + modes + apply(Action)
    grid.zig           Cell + Grid — 2D character storage
    snapshot.zig       Serialize grid to plain text for testing
    engine.zig         Glue layer: Parser + TerminalState
    input.zig          Input encoder: paste wrapping + mouse SGR encoding
    hash.zig           FNV-1a state hash for change detection
  headless/          Deterministic runner + tests
    runner.zig         Convenience functions for test harness
    tests.zig          Golden snapshot tests + attribute tests
  config/            Configuration loading + CLI parsing
    config.zig         AppConfig struct, TOML file parsing, CellSize type
    cli.zig            CLI argument parser + usage text
  app/               PTY + OS integration
    pty.zig            POSIX PTY bridge (spawn, read, write, resize)
    ui2.zig            Terminal orchestrator (PTY thread + GPU window, macOS/Linux)
    session_log.zig    Session event log (bounded ring buffer)
    bridge.h           C bridge types (AttyxCell, cursor, quit signaling)
    platform_macos.m   Metal renderer + Cocoa window (macOS)
    platform_linux.c   OpenGL renderer + GLFW window (Linux)
  render/            GPU + font rendering
    color.zig          ANSI/palette/truecolor → RGB resolution
  root.zig           Library root — re-exports public API
  main.zig           CLI entry point — subcommand dispatch
config/
  attyx.toml.example   Example config file with all defaults
```

## Layer Rules

- `term/` must not depend on PTY, windowing, rendering, clipboard, or platform APIs.
- `term/` must be fully deterministic and pure.
- Parser must never modify state directly.
- Renderer must never influence parsing or state.

## Configuration (`config/`)

Configuration is loaded in three layers with increasing precedence:

```
Defaults (AppConfig struct) → TOML file → CLI flags
```

**Config file:** `$XDG_CONFIG_HOME/attyx/attyx.toml` (default `~/.config/attyx/attyx.toml`).
Override with `--config <path>` or skip entirely with `--no-config`.

### AppConfig (`config/config.zig`)

Central struct holding all configuration values. Key fields:

| Section | Field | Type | Default | Description |
|---------|-------|------|---------|-------------|
| `[font]` | `family` | string | `"JetBrains Mono"` | Font family name |
| | `size` | u16 | `14` | Font size in points |
| | `cell_width` | CellSize | `100%` | Grid cell width |
| | `cell_height` | CellSize | `100%` | Grid cell height |
| | `fallback` | string[] | none | Fallback font families |
| `[theme]` | `name` | string | `"default"` | Theme name |
| `[scrollback]` | `lines` | u32 | `20000` | Scrollback buffer lines |
| `[reflow]` | `enabled` | bool | `true` | Reflow on resize |
| `[cursor]` | `shape` | enum | `block` | Cursor shape |
| | `blink` | bool | `true` | Cursor blinking |

### CellSize

Tagged union for cell dimensions — supports both absolute and relative sizing:

```zig
pub const CellSize = union(enum) {
    pixels: u16,   // absolute pixel value (e.g. 10)
    percent: u16,  // percentage of font-derived default (e.g. 110 = 110%)
};
```

In TOML: `cell_width = 10` (pixels) or `cell_width = "110%"` (percent).
In CLI: `--cell-width 10` or `--cell-width 110%`.

Default is `"100%"` — use the font-derived cell size as-is.

### Bridge encoding

Config values are published to the C bridge at startup via `publishFontConfig()`.
Cell size is encoded as a single `volatile int`:

- Positive value → pixels (e.g. `10`)
- Negative value → negated percentage (e.g. `-110` = 110%)

### CLI parser (`config/cli.zig`)

Parses `argv` into a `CliResult` containing the merged `AppConfig` and an action
(`run`, `print_config`, `show_help`). `--print-config` outputs the fully merged
config in TOML format.

## Key Types

### Action (`term/actions.zig`)

```zig
pub const Action = union(enum) {
    print: u8,                 // Write a printable ASCII byte at cursor
    control: ControlCode,      // Execute a C0 control code (LF/CR/BS/TAB)
    nop,                       // Ignored byte or unsupported sequence
    cursor_abs: CursorAbs,           // CSI H / f — absolute cursor position
    cursor_rel: CursorRel,           // CSI A/B/C/D — relative cursor movement
    erase_display: EraseMode,        // CSI J — erase in display
    erase_line: EraseMode,           // CSI K — erase in line
    sgr: Sgr,                        // CSI m — colors, bold, underline
    set_scroll_region: ScrollRegion, // CSI r — DECSTBM
    index,                           // ESC D — move down / scroll within region
    reverse_index,                   // ESC M — move up / scroll within region
    enter_alt_screen,                // ESC[?1049h — switch to alt buffer
    leave_alt_screen,                // ESC[?1049l — switch to main buffer
    save_cursor,                     // ESC 7 / CSI s — save cursor + pen
    restore_cursor,                  // ESC 8 / CSI u — restore cursor + pen
    hyperlink_start: []const u8,     // OSC 8 — start hyperlink (URI borrowed)
    hyperlink_end,                   // OSC 8 — end hyperlink
    set_title: []const u8,           // OSC 0/2 — set terminal title (borrowed)
    dec_private_mode: DecPrivateModes, // ESC[?...h/l — compound mode set/reset
};
```

### Parser (`term/parser.zig`)

Five-state machine: Ground → Escape → CSI / OSC.

```
Ground ──ESC──▸ Escape ──[──▸ CSI
  ▲                │            │
  │                ]──▸ OSC ──BEL──▸ dispatch
  │                      │
  │                      ESC──▸ OscEscape ──\──▸ dispatch
  └──── any ◂───────────────────────────────────┘
```

- `next(byte) → ?Action` — process one byte, return action or null.
- Zero allocations. All state in fixed-size struct fields.
- Handles partial sequences across `feed()` chunk boundaries.
- CSI dispatch: parses parameter bytes into integers, recognizes final byte,
  emits structured Action with parsed data (e.g., CursorAbs with row/col).

### TerminalState (`term/state.zig`)

- Owns **two** `Grid`s (main + alt) plus per-buffer cursor, pen, scroll region,
  and saved cursor. Only the "active" set of fields is used by `apply()`.
- `apply(action)` — the only way state changes.
- Scroll region (`scroll_top`, `scroll_bottom`) bounds scrolling to a subset of rows.
  Default = full screen. Only LF/IND/RI/wrap respect the region; cursor movement is screen-wide.
- **Hyperlinks:** `link_uris` table maps `link_id → URI`. `pen_link_id` is per-buffer.
  `getLinkUri(id)` for lookup. Allocations happen per hyperlink start only.
- **Title:** `title: ?[]const u8` — latest OSC 0/2 title, globally shared.
- **Terminal modes** (global, not per-buffer): `bracketed_paste: bool`,
  `mouse_tracking: MouseTrackingMode` (.off/.x10/.button_event/.any_event),
  `mouse_sgr: bool`, `cursor_keys_app: bool` (DECCKM, DEC private mode 1).
  These persist across alt screen switches.
- **Alternate screen:** `swapBuffers()` exchanges all 7 per-buffer field pairs
  using `std.mem.swap` (zero-copy for grids). Enter clears the alt grid;
  leave restores main as-is.
- **SavedCursor:** captures cursor, pen, and scroll region. Stored per-buffer
  (swapped with the rest), so main/alt saves are isolated.

### Cell + Style + Color (`term/grid.zig`)

- `Color` tagged union with four variants:
  - `default` — terminal theme color
  - `ansi: u8` — standard (0–7) or bright (8–15) ANSI color
  - `palette: u8` — 256-color xterm palette index
  - `rgb: Rgb` — 24-bit truecolor (`struct { r: u8, g: u8, b: u8 }`)
- Named constants: `Color.black`, `Color.red`, ..., `Color.white` for ANSI 0–7.
- `Style` struct: `fg: Color`, `bg: Color`, `bold: bool`, `underline: bool`.
- `Cell` struct: `char: u8`, `style: Style`.

### Grid (`term/grid.zig`)

- Fixed-size 2D array of `Cell` values (row-major, flat allocation).
- `getCell(row, col)`, `setCell(row, col, cell)`, `clearRow(row)`, `scrollUp()`.
- `scrollUpRegion(top, bottom)`, `scrollDownRegion(top, bottom)` for DECSTBM.

### Engine (`term/engine.zig`)

- Owns Parser + TerminalState.
- `feed(bytes)` — the high-level API: parse bytes → apply actions.

### Parser DEC Private Mode

DEC private mode sequences (`ESC[?...h` / `ESC[?...l`) are recognized by
detecting a `?` prefix in the CSI parameter buffer. The parser emits a
single `dec_private_mode` action carrying all params (up to 8), so
compound sequences like `ESC[?1000;1006h` are supported.

Supported modes:

| Mode | Set (h) | Reset (l) |
|------|---------|-----------|
| 1 | DECCKM: application cursor keys | Normal cursor keys |
| 47 / 1047 / 1049 | Enter alt screen | Leave alt screen |
| 1000 | X10 mouse tracking | Off (if active) |
| 1002 | Button-event tracking | Off (if active) |
| 1003 | Any-event tracking | Off (if active) |
| 1006 | SGR mouse encoding | Disable SGR encoding |
| 2004 | Bracketed paste | Disable bracketed paste |

Unrecognized modes are silently ignored by the state.

### Input Encoder (`term/input.zig`)

Pure, allocation-free functions for producing bytes to send to the PTY:

- `wrapPaste(enabled, text, out_buf)` — wraps text with `ESC[200~`/`ESC[201~`
  when bracketed paste is active.
- `encodeMouse(tracking, sgr_enabled, event, out_buf)` — SGR mouse encoding
  (`CSI < Cb;Cx;Cy M/m`). Returns empty when tracking is off or SGR disabled.
  Move events only reported in `any_event` mode.

All write into caller-provided buffers. No allocations.

### State Hash (`term/hash.zig`)

Pure FNV-1a hash over the visible terminal state: `alt_active` flag, cursor
position, and every cell's character + style attributes. Returns a `u64`.
Used by the UI-1 event loop to detect when the screen has actually changed,
avoiding redundant snapshot output.

No allocations, no side effects — just reads `TerminalState` fields.

### PTY Bridge (`app/pty.zig`)

POSIX PTY module for macOS and Linux:

- `Pty.spawn(opts)` — opens a pseudoterminal via `openpty()`, forks, sets
  up the slave as the child's stdin/stdout/stderr with `setsid` + `TIOCSCTTY`,
  sets `TERM=xterm-256color`, and execs the shell (default: `/bin/bash --noprofile --norc`).
  Master fd is set to non-blocking.
- `read(buf)` — non-blocking read from master. Returns 0 on `WouldBlock`.
- `writeToPty(bytes)` — write to master.
- `resize(rows, cols)` — `TIOCSWINSZ` ioctl.
- `childExited()` — non-blocking waitpid check.
- `deinit()` — close master fd, reap child.

The PTY module has zero dependencies on `term/`.

### Session Event Log (`app/session_log.zig`)

Bounded in-memory log of session events for future AI integration:

- **Events:** `output_chunk` (PTY data), `input_chunk` (user keystrokes),
  `frame` (grid hash + metadata on visible change).
- **Limits:** max 4096 events / 4 MB of byte data. Oldest events dropped
  when either limit is reached.
- **Byte ownership:** each chunk is `dupe`'d on append, `free`'d on drop.
- **Frame dedup:** `appendFrame` is a no-op if the grid hash hasn't changed.
- **API:** `lastEvents(n)` returns a contiguous slice; `stats()` returns
  event count + total bytes.
- No persistence, no search, no stdout output. Pure sidecar data structure.

### UI-2 Windowed Renderer (`app/ui2.zig` + platform layers)

Live terminal rendering using GPU-backed windows. Two-thread architecture:

```
Main thread (platform):  event loop ──▸ draw callback (60fps, vsync)
                                              │
                                              ▼
                                         read shared AttyxCell buffer
                                         draw bg quads → text quads → cursor block

PTY thread (Zig):        poll PTY fd (16ms) ──▸ read bytes ──▸ engine.feed()
                             ──▸ fillCells() → shared buffer
                             ──▸ attyx_set_cursor()
                             ──▸ session.appendFrame()
```

**Shared state (no locks):**

- `AttyxCell*` buffer — 8 bytes per cell, effectively atomic on 64-bit.
- `g_cursor_row` / `g_cursor_col` — volatile int globals.
- `g_should_quit` — set by platform on window close, polled by PTY thread.
- `g_dirty[4]` — 256-bit dirty row bitset for damage-aware rendering.
- `g_cell_gen` — seqlock counter to detect torn frames.
- `g_ime_*` — IME composition state for preedit overlay.
- `g_sel_*` — mouse selection state.

**C bridge (`bridge.h`):** Defines `AttyxCell` struct (character + fg/bg RGB + flags)
and functions: `attyx_run`, `attyx_set_cursor`, `attyx_request_quit`,
`attyx_should_quit`, `attyx_send_input`, `attyx_set_mode_flags`,
`attyx_set_mouse_mode`, `attyx_begin/end_cell_update`, `attyx_set_dirty`,
`attyx_check_resize`, `attyx_scroll_viewport`, `attyx_mark_all_dirty`.

#### macOS: `platform_macos.m`

- Cocoa window with MTKView + Metal renderer.
- Core Text font rasterization with dynamic glyph atlas.
- NSTextInputClient protocol for IME composition (CJK).
- NSPasteboard clipboard (Cmd+C/V).

#### Linux: `platform_linux.c`

- GLFW window with OpenGL 3.3 core renderer.
- FreeType font rasterization with dynamic glyph atlas.
- Fontconfig for font discovery (with fallback for missing glyphs).
- GLFW clipboard API (Ctrl+Shift+C/V).
- Same vertex format, same shader logic (GLSL port of Metal shaders).
- Same damage-aware rendering, seqlock frame skipping, dirty bitset.

**Color resolution:** `render/color.zig` maps `Color` enum variants (default, ansi,
palette, rgb) to concrete RGB values using a hardcoded xterm-like palette.

### Keyboard Input

Both platform layers encode keyboard events identically and send them to the
PTY via `attyx_send_input()`:

```
keyboard event → encode key → attyx_send_input(bytes) → write(pty_master_fd)
```

Key encoding covers:
- Regular text (UTF-8 via system input method).
- Special keys: arrows (DECCKM-aware), function keys, Home/End, PgUp/PgDn, etc.
- Ctrl+key: maps to control codes 0x01–0x1A.
- Alt/Option+key: ESC prefix before the character.
- Paste: Cmd+V (macOS) / Ctrl+Shift+V (Linux), with bracketed paste wrapping.
- Copy: Cmd+C (macOS) / Ctrl+Shift+C (Linux).
- IME composition: NSTextInputClient (macOS) / GLFW char callback (Linux).

Mode flags (`g_bracketed_paste`, `g_cursor_keys_app`) are volatile globals
updated by the PTY thread via `attyx_set_mode_flags()` and read by the key
handler. Eventual consistency is acceptable — a one-frame lag on mode changes
is imperceptible.

### Mouse Input

Both platforms implement:
- SGR mouse reporting (when tracking modes are enabled).
- Text selection: single-click drag, double-click word selection, triple-click row selection.
- Scroll wheel: viewport scrollback (when not in alt screen / mouse tracking mode).
- Selection extends word-by-word or row-by-row based on initial click count.
