<h1 align="center">Attyx</h1>

<p align="center">
  <strong>Deterministic VT-compatible terminal emulator in Zig</strong>
</p>

<p align="center">
  <a href="https://github.com/semos-labs/attyx/actions/workflows/test.yml"><img src="https://github.com/semos-labs/attyx/actions/workflows/test.yml/badge.svg" alt="Tests"></a>
  <img src="https://img.shields.io/badge/Zig-0.15-f7a41d?logo=zig&logoColor=white" alt="Zig 0.15">
  <img src="https://img.shields.io/badge/License-MIT-blue" alt="MIT License">
</p>

<p align="center">
  <a href="#architecture">Architecture</a> &bull;
  <a href="#building">Building</a> &bull;
  <a href="#testing">Testing</a> &bull;
  <a href="#roadmap">Roadmap</a> &bull;
  <a href="docs/">Docs</a>
</p>

---

Attyx is a terminal emulator built from scratch in Zig. The core is a pure, deterministic state machine — no PTY, no windowing, no platform APIs required. Given the same input bytes, it always produces the same grid state.

The project prioritizes **correctness over features** and **clarity over cleverness**. Every feature is testable in headless mode.

---

## Architecture

The core follows a strict pipeline — parsing never touches state, state never influences parsing:

```
Raw bytes ─▸ Parser ─▸ Action ─▸ State.apply() ─▸ Grid
```

| Layer | Directory | Purpose |
|-------|-----------|---------|
| **Terminal engine** | `src/term/` | Pure, deterministic core — parser, state, grid, hash |
| **Headless runner** | `src/headless/` | Test harness and golden snapshot tests |
| **App** | `src/app/` | PTY bridge + OS integration |
| **Renderer** | `src/render/` | GPU + font rendering (Metal on macOS, OpenGL on Linux) |

### Key types

- **`Action`** — tagged union (20 variants including `print`, `control`, `sgr`, `enter_alt_screen`, `hyperlink_start`, `dec_private_mode`, ...) — the vocabulary between parser and state.
- **`Parser`** — incremental 5-state machine (ground → escape → CSI / OSC). Zero allocations in hot path, handles partial sequences across chunk boundaries. Recognizes DEC private modes and OSC sequences.
- **`TerminalState`** — dual-buffer (main + alt) with per-buffer cursor, pen, scroll region, saved cursor, and hyperlink state. Global hyperlink table, title, and terminal mode flags (mouse tracking, bracketed paste). Mutates only via `apply(action)`.
- **`Engine`** — glue that connects parser and state with a simple `feed(bytes)` API.
- **`input`** — allocation-free input encoder: bracketed paste wrapping and SGR mouse event encoding.
- **`hash`** — pure FNV-1a hash of visible terminal state (cursor + grid + attrs). Used to detect screen changes.
- **`Pty`** — POSIX PTY bridge: spawn a child shell, non-blocking reads, write bytes, resize via ioctl.
- **`SessionLog`** — bounded ring buffer of session events (PTY input/output chunks + frame snapshots). Preparation for AI integration.
- **`AttyxView`** — MTKView subclass handling keyboard input: special keys, Ctrl+key, Alt+ESC prefix, paste, DECCKM-aware arrow keys, IME composition (CJK), mouse selection (single/double/triple click).
- **`platform_linux.c`** — Linux platform layer: GLFW window, OpenGL 3.3 renderer, FreeType glyph rasterization, Fontconfig font discovery, same bridge.h shared-state interface.

See [docs/architecture.md](docs/architecture.md) for the full breakdown.

---

## Building

Requires **Zig 0.15.2+**.

```bash
zig build              # build all executables
zig build run          # build and run (shows usage)
zig build run -- ui1   # run PTY bridge (interactive shell)
```

### PTY bridge (UI-1)

Run a real shell inside the terminal engine. Output is snapshot-based (plain text grid printed to stdout).

```bash
zig build run -- ui1                         # default: bash 24x80
zig build run -- ui1 --rows 40 --cols 120    # custom size
zig build run -- ui1 --cmd /bin/zsh          # custom shell
zig build run -- ui1 --separator             # print --- between frames
```

### Windowed terminal (UI-2, macOS + Linux)

Live terminal rendered in a GPU-backed window. PTY output drives the engine; the renderer draws the grid at 60 fps.

- **macOS:** Metal + Cocoa + Core Text
- **Linux:** OpenGL 3.3 + GLFW + FreeType + Fontconfig

```bash
zig build run -- ui2                         # default: bash 24x80
zig build run -- ui2 --rows 30 --cols 100    # custom size
zig build run -- ui2 --cmd /bin/zsh          # custom shell
```

#### Linux prerequisites

```bash
sudo apt install libglfw3-dev libfreetype-dev libfontconfig-dev libgl-dev
```

Set `ATTYX_FONT` to override the default monospace font (e.g., `ATTYX_FONT="JetBrains Mono"`).

---

## Testing

All tests run in headless mode — no PTY, no window, no OS interaction.

```bash
zig build test                # run all tests
zig build test --summary all  # run with detailed summary
```

The test suite uses **golden snapshot testing**: feed known bytes into a terminal of known size, serialize the grid to a plain-text string, and compare against an exact expected value.

| What's tested | Count |
|---------------|-------|
| Grid operations (get/set, scroll, clear, region scroll, style) | 7 |
| Parser state machine (ESC, CSI, DEC private mode, OSC dispatch) | 39 |
| State mutations (apply actions, scroll regions, alt screen, hyperlinks, title) | 16 |
| Snapshot serialization | 2 |
| Input encoder (paste wrapper, SGR mouse encoding) | 15 |
| Engine + runner integration | 3 |
| State hashing (identity, content, cursor) | 3 |
| Golden + attribute tests (text, cursor, erase, SGR, 256/truecolor, alt, OSC, modes, DECCKM) | 112 |
| **Total** | **197** |

See [docs/testing.md](docs/testing.md) for the full testing strategy.

---

## Roadmap

Attyx is built milestone by milestone. Each milestone is stable and tested before the next begins.

| # | Milestone | Status |
|---|-----------|--------|
| 1 | Grid + cursor + printable text + control chars | ✅ Done |
| 2 | Action stream + parser skeleton (ESC/CSI framing) | ✅ Done |
| 3 | Minimal CSI support (cursor movement, erase, SGR 16 colors) | ✅ Done |
| 4 | Scroll regions (DECSTBM) + Index/Reverse Index | ✅ Done |
| 5 | Alternate screen + save/restore cursor + mode handling | ✅ Done |
| 6 | SGR extended colors (256-color + truecolor) | ✅ Done |
| 7 | OSC support (hyperlinks + title) | ✅ Done |
| 8 | Mouse reporting + bracketed paste + input encoder | ✅ Done |
| UI-0 | Rendering spike (Metal window, demo grid) | ✅ Done |
| UI-1 | PTY bridge (headless app loop — spawn shell, read/write PTY, snapshot) | ✅ Done |
| S-0 | Minimal session event log (ring buffer, no AI yet) | ✅ Done |
| UI-2 | Window + GPU renderer (live grid rendering, Metal on macOS) | ✅ Done |
| UI-3 | Keyboard input + interactive shell (PTY write + key encoding) | ✅ Done |
| UI-4 | Mouse selection + copy/paste (single/double/triple click) | ✅ Done |
| UI-5 | Scrollback viewport (Shift+PgUp/PgDn, mouse wheel) | ✅ Done |
| UI-6 | Window resize + grid snap | ✅ Done |
| UI-7 | IME composition input (CJK, macOS) | ✅ Done |
| UI-8 | Linux platform parity (GLFW + OpenGL + FreeType) | ✅ Done |

See [docs/milestones.md](docs/milestones.md) for detailed write-ups.

---

## Project Structure

```
src/
  term/
    actions.zig      Action union + control/CSI/mode types
    parser.zig       Incremental VT parser (ground/escape/CSI/OSC)
    state.zig        TerminalState — grid + cursor + pen + modes + apply()
    grid.zig         Cell + Grid + Color + Style
    snapshot.zig     Grid → plain text serialization
    engine.zig       Glue: Parser + TerminalState
    input.zig        Input encoder: paste wrapping + mouse SGR
    hash.zig         State hashing for change detection
  headless/
    runner.zig       Test convenience functions
    tests.zig        Golden snapshot + attribute tests
  app/
    pty.zig          POSIX PTY bridge (spawn, read, write, resize)
    ui1.zig          UI-1 runner (event loop, stdin forwarding, snapshots)
    ui2.zig          UI-2 runner (PTY thread + GPU window, macOS/Linux)
    session_log.zig  Session event log (ring buffer, byte tracking)
    bridge.h         C bridge types (AttyxCell, cursor, quit signaling)
    platform_macos.m Metal renderer + Cocoa window (macOS)
    platform_linux.c OpenGL renderer + GLFW window (Linux)
    main.zig         UI-0 demo (standalone executable)
  render/
    color.zig        Color resolution (ANSI → RGB lookup)
  root.zig           Library root
  main.zig           CLI entry point (subcommand dispatch)
docs/
  architecture.md    System design and data flow
  milestones.md      Milestone details and history
  terminal-basics.md How terminals work (learning reference)
  testing.md         Test strategy and snapshot format
```

---

## License

MIT

---

<p align="center">
  <sub>Built byte by byte &bull; escape sequence by escape sequence</sub>
</p>
