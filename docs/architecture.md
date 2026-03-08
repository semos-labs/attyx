# Attyx Architecture

## Overview

Attyx is a GPU-accelerated VT-compatible terminal emulator written in Zig 0.15.2.
The design follows strict layer separation: parsing, state, rendering, and
platform integration are fully independent.

- **macOS:** Metal + Cocoa + Core Text
- **Linux:** OpenGL 3.3 + GLFW + FreeType + Fontconfig

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
  term/                Pure terminal engine (no side effects)
    actions.zig          Action union + ControlCode enum + mode types
    parser.zig           Incremental VT parser (11-state: ground/escape/CSI/OSC/APC/DCS)
    state.zig            TerminalState — grid + cursor + modes + apply(Action)
    state_altscreen.zig  Alt screen buffer swap
    state_erase.zig      ED/EL erase operations
    state_graphics.zig   Kitty graphics protocol handler
    state_osc.zig        OSC handlers (hyperlinks, title, CWD, shell PATH)
    state_report.zig     Device status, cursor position, color query responses
    state_resize.zig     Grid reflow on resize
    grid.zig             Cell + Style + Grid — 2D character storage with combining marks
    csi.zig              CSI parameter parsing and action constructors
    sgr.zig              SGR attribute parsing (bold, italic, colors, underline, etc.)
    scrollback.zig       Bounded ring buffer for scroll history
    search.zig           Text search across grid + scrollback
    dirty.zig            Row-level damage tracking (256-bit bitset)
    graphics_cmd.zig     Kitty graphics protocol types
    graphics_decode.zig  Base64/zlib/PNG image decoding
    graphics_store.zig   Image storage + placement (up to 320 MB)
    snapshot.zig         Serialize grid to plain text for testing
    engine.zig           Glue layer: Parser + TerminalState
    input.zig            Paste wrapping + mouse SGR encoding
    key_encode.zig       Key encoding (xterm + Kitty keyboard protocol)
    unicode.zig          Combining mark detection (Thai, Lao, Devanagari, etc.)
    hash.zig             FNV-1a state hash for change detection
  headless/            Deterministic runner + tests
    runner.zig           Convenience functions for test harness
    tests.zig            Test entry point
    tests/               22 categorized test files (parser, CSI, scroll, graphics, etc.)
  config/              Configuration + CLI + keybinds
    config.zig           AppConfig struct, CellSize, TabAppearance, PopupConfigEntry
    config_parse.zig     TOML file parsing and validation
    cli.zig              CLI argument parser + subcommand routing
    reload.zig           Config reload helper (loadReloadedConfig)
    keybinds.zig         Keybind matching engine (key constants, modifiers, actions)
    commands.zig         Command registry (name, action, description, scope, hotkeys)
    statusbar_config.zig Statusbar position/widget configuration
  logging/             Structured logging + diagnostics
    log.zig              Logger (5 levels, file output, C bridge hook, stdLogFn)
    diag.zig             PTY throughput window + slow drain detector
  app/                 PTY + OS integration
    terminal.zig         Main Terminal struct — coordinates PTY, UI, config, overlays
    pane.zig             Pane (Engine + PTY pair), spawn/deinit lifecycle
    pty.zig              POSIX PTY bridge (spawn, read, write, resize)
    popup.zig            Popup PTY+Engine with border styles, padding, title
    split_layout.zig     Binary tree split manager (max 8 panes, 15 nodes)
    split_render.zig     Split border rendering
    tab_manager.zig      Tab array (max 16), active tab tracking
    tab_bar.zig          Tab bar renderer (StyledCells, title highlighting)
    statusbar.zig        Statusbar with configurable widgets, color spans, caching
    git_widget.zig       Git status parser (branch, ahead/behind, staged, modified)
    session_connect.zig  Daemon socket connection, auto-start, XDG state paths
    session_client.zig   V2 daemon protocol client (attach, detach, pane output)
    session_log.zig      Session event log (bounded ring buffer)
    shell_integration.zig Multi-shell PATH reporting (zsh, bash, fish, nushell, sh)
    layout_codec.zig     Binary serialization of tab+split layouts for daemon
    bridge.h             C bridge types (AttyxCell, cursor, quit signaling)
    macos_*.m            Metal renderer, glyph atlas, input, ligatures, box drawing, etc.
    linux_*.c            OpenGL renderer, glyph atlas, input, ligatures, etc.
    platform_macos.m     Cocoa window + Metal setup
    platform_linux.c     GLFW window + OpenGL setup
    ui/                  UI logic modules
      dispatch.zig         Unified keybind action dispatcher
      copy_mode.zig        Visual mode (char/line/block selection, vim motions)
      selection.zig        Scrollback-aware copy
      publish.zig          Publishes terminal state to C bridge for rendering
      ai.zig               AI overlay integration + SSE streaming
      search.zig           Search UI coordination
      input.zig            Input routing
      event_loop.zig       Main event loop
      resize.zig           Resize handling
      overlay_input.zig    Overlay-specific input
      session_actions.zig  Session management actions
      split_actions.zig    Split pane actions
      hup.zig              HUP signal handling
    daemon/              Multi-session daemon
      daemon.zig           Main loop, signal handling, client acceptance
      session.zig          DaemonSession (id, name, panes, layout, CWD, shell)
      pane.zig             DaemonPane (PTY + replay buffer, proc name, CWD, PATH)
      protocol.zig         Message types (create, list, attach, detach, kill, layout_sync)
      handler.zig          Message dispatch
      client.zig           DaemonClient struct, socket read, message parsing
      state_persist.zig    JSON serialization of session state
      upgrade.zig          Binary daemon state migration on hot-upgrade
      ring_buffer.zig      Lock-free ring buffer for replay data
  overlay/             Pure overlay rendering system
    overlay.zig          OverlayManager (max 16 layers), OverlayId enum
    search.zig           SearchBarState (query, cursor, match tracking)
    command_palette.zig  Command palette state + filtering
    session_picker.zig   Session picker (browsing, renaming, confirm_kill)
    theme_picker.zig     Theme picker
    ai_stream.zig        DeltaRing (16KB lock-free ring) for SSE streaming
    ai_content.zig       AI content rendering
    ai_edit.zig          AI edit workflows
    ai_auth.zig          AI token management
    diff.zig             Unified diff renderer
    anchor.zig           Popup placement constraints
    components.zig       Reusable UI components
    content.zig          Content rendering
    layout.zig           Layout calculation
    ui.zig / ui_cell.zig / ui_render.zig  Cell-level rendering
    update_check.zig     Update notification overlay
  finder/              Fuzzy file finder
    finder.zig           FinderState (directory walker + fuzzy matcher)
    fuzzy_match.zig      Path-aware scoring (fzf-inspired), 64-position tracking
    dir_walker.zig       Incremental directory traversal with depth limit
  theme/               Theme engine
    theme.zig            Theme struct (fg, bg, cursor, palette[16]), hex parsing
    registry.zig         ThemeRegistry (load, register, lookup)
    builtin.zig          22 built-in themes (catppuccin, dracula, gruvbox, nord, etc.)
  platform/            Platform abstraction
    platform.zig         POSIX constants, ConfigPaths, XDG helpers
    macos.zig            macOS-specific helpers
    linux.zig            Linux-specific helpers
  render/              Color utilities
    color.zig            ANSI/palette/truecolor → RGB resolution
  vendor/              Third-party C libraries
    stb_image.h          Image decoding (for Kitty graphics)
    jebp.h               JPEG/BMP decoding
  cli/                 CLI subcommands
    main.zig             doLogin, doDevice, doUninstall
  root.zig             Library root — re-exports public API
  main.zig             Entry point — subcommand dispatch
config/
  attyx.toml.example   Example config file with all defaults
```

## Layer Rules

- `term/` must not depend on PTY, windowing, rendering, clipboard, or platform APIs.
- `term/` must be fully deterministic and pure.
- Parser must never modify state directly.
- Renderer must never influence parsing or state.

## Two-Thread Architecture

```
Main thread (platform):  event loop ──▸ draw callback (60fps, vsync)
                                              │
                                              ▼
                                         read shared AttyxCell buffer
                                         draw bg quads → text quads → cursor → overlays

PTY thread (Zig):        poll PTY fd (16ms) ──▸ read bytes ──▸ engine.feed()
                             ──▸ publish cells → shared buffer
                             ──▸ update cursor, dirty rows
                             ──▸ check config reload flag
```

**Shared state (no locks):**

- `AttyxCell*` buffer — effectively atomic on 64-bit.
- `g_cursor_row` / `g_cursor_col` — volatile int globals.
- `g_should_quit` — set by platform on window close, polled by PTY thread.
- `g_dirty[4]` — 256-bit dirty row bitset for damage-aware rendering.
- `g_cell_gen` — seqlock counter to detect torn frames.
- `g_background_opacity` / `g_background_blur` — renderer opacity control.
- `g_needs_reload_config` — atomic flag; set by SIGUSR1 or Ctrl+Shift+R.
- `g_needs_font_rebuild` — set after font config change; read by render thread.

## Configuration (`config/`)

Configuration is loaded in three layers with increasing precedence:

```
Defaults (AppConfig struct) → TOML file → CLI flags
```

**Config file:** `$XDG_CONFIG_HOME/attyx/attyx.toml` (default `~/.config/attyx/attyx.toml`).
Override with `--config <path>` or skip entirely with `--no-config`.

### AppConfig (`config/config.zig`)

Central struct holding all configuration values:

| Section | Field | Type | Default | Description |
|---------|-------|------|---------|-------------|
| `[font]` | `family` | string | `"JetBrains Mono"` | Font family name |
| | `size` | u16 | `14` | Font size in points |
| | `cell_width` | CellSize | `auto` | Grid cell width |
| | `cell_height` | CellSize | `auto` | Grid cell height |
| | `fallback` | string[] | none | Fallback font families |
| | `ligatures` | bool | `true` | Programming ligatures (calt) |
| `[theme]` | `name` | string | `"default"` | Theme name (22 built-in options) |
| | `background` | hex | none | Override background color |
| `[scrollback]` | `lines` | u32 | `5000` | Scrollback buffer lines |
| `[reflow]` | `enabled` | bool | `true` | Reflow on resize |
| `[cursor]` | `shape` | enum | `block` | Cursor shape (block/beam/underline) |
| | `blink` | bool | `true` | Cursor blinking |
| | `trail` | bool | `false` | Trailing cursor effect |
| `[background]` | `opacity` | f32 | `1.0` | Window opacity (0.0–1.0) |
| | `blur` | u16 | `30` | Blur radius (macOS compositor) |
| `[window]` | `decorations` | bool | `true` | Show window decorations |
| | `padding_*` | u16 | `0` | Window padding (top/bottom/left/right) |
| `[program]` | `program` | string | none | Shell program override |
| | `args` | string[] | none | Program arguments |
| | `working_directory` | string | none | Initial working directory |
| `[logging]` | `level` | string | `"info"` | Log level (err/warn/info/debug/trace) |
| | `file` | string | none | Append log output to file |
| `[tabs]` | `appearance` | enum | `builtin` | Tab style (builtin/native) |
| | `always_show` | bool | `false` | Show tab bar with single tab |
| `[splits]` | `resize_step` | u16 | `4` | Split resize increment |
| `[sessions]` | `enabled` | bool | `false` | Enable daemon-backed sessions |
| | `finder_root` | string | `"~"` | Session finder root path |
| | `finder_depth` | u8 | `4` | Finder directory depth |
| `[updates]` | `check_updates` | bool | `true` | Auto-check for updates |
| `[statusbar]` | position | enum | bottom | Statusbar position (top/bottom) |
| | widgets | array | — | Configurable widget list |
| `[keybindings]` | overrides | array | — | Custom keybind overrides |
| `[[popup]]` | hotkey, command, etc. | — | — | Custom popup definitions |
| `[sequences]` | entries | array | — | Custom key sequences |

### CellSize

Tagged union for cell dimensions — supports auto, absolute, and relative:

```zig
pub const CellSize = union(enum) {
    auto,            // use font-derived cell size
    pixels: u16,     // absolute pixel value (e.g. 10)
    percent: u16,    // percentage of font-derived default (e.g. 110 = 110%)
};
```

In TOML: `cell_width = 10` (pixels) or `cell_width = "110%"` (percent).
Default is `auto`.

### Config reload (`config/reload.zig`)

`loadReloadedConfig()` re-reads the TOML file and re-applies CLI overrides. Called
by the PTY thread when `g_needs_reload_config` is set (via SIGUSR1 or Ctrl+Shift+R).
Hot-reloadable settings: cursor shape/blink, scrollback lines, font family/size/cell
dimensions, ligatures, theme. Background opacity/blur and logging settings take
effect only at startup.

## Key Types

### Action (`term/actions.zig`)

```zig
pub const Action = union(enum) {
    print: u21,                        // Unicode codepoint at cursor
    control: ControlCode,              // C0 control (LF/CR/BS/TAB)
    nop,                               // Ignored / unsupported
    cursor_abs: CursorAbs,             // CSI H/f — absolute positioning
    cursor_rel: CursorRel,             // CSI A/B/C/D — relative movement
    cursor_next_line: u16,             // CSI E — down + col 0
    cursor_prev_line: u16,             // CSI F — up + col 0
    cursor_col_abs: u16,               // CSI G — absolute column
    cursor_row_abs: u16,               // CSI d — absolute row
    erase_display: EraseMode,          // CSI J
    erase_line: EraseMode,             // CSI K
    erase_chars: u16,                  // CSI X
    sgr: Sgr,                          // CSI m — colors, bold, underline
    set_scroll_region: ScrollRegion,   // CSI r — DECSTBM
    scroll_up: u16,                    // CSI S
    scroll_down: u16,                  // CSI T
    insert_lines: u16,                 // CSI L
    delete_lines: u16,                 // CSI M
    insert_chars: u16,                 // CSI @
    delete_chars: u16,                 // CSI P
    index,                             // ESC D — down / scroll within region
    reverse_index,                     // ESC M — up / scroll within region
    enter_alt_screen,                  // ESC[?1049h
    leave_alt_screen,                  // ESC[?1049l
    save_cursor,                       // ESC 7 / CSI s
    restore_cursor,                    // ESC 8 / CSI u
    hyperlink_start: []const u8,       // OSC 8 — URI
    hyperlink_end,                     // OSC 8 — end
    set_title: []const u8,             // OSC 0/2
    set_cwd: []const u8,              // OSC 7 — working directory
    set_shell_path: []const u8,        // OSC 7337;set-path
    dec_private_mode: DecPrivateModes,  // ESC[?...h/l
    device_status,                     // CSI 5 n
    cursor_position_report,            // CSI 6 n
    device_attributes,                 // CSI c — DA1
    secondary_device_attributes,       // CSI > c — DA2
    set_cursor_shape: CursorShape,     // DECSCUSR
    query_dec_private_mode: u16,       // DECRQM
    graphics_command: []const u8,      // APC G — Kitty graphics
    kitty_push_flags: u5,              // Kitty keyboard push
    kitty_pop_flags: u8,               // Kitty keyboard pop
    kitty_query_flags,                 // Kitty keyboard query
    inject_into_main: []const u8,      // OSC 7337;write-main
    dcs_passthrough: []const u8,       // DCS tmux passthrough
    set_keypad_app_mode,               // ESC = (DECKPAM)
    reset_keypad_app_mode,             // ESC > (DECKPNM)
    query_color: ColorQueryType,       // OSC 10/11/12
    query_palette_color: u8,           // OSC 4;N;?
    notify: Notification,              // OSC 9 / OSC 777 — desktop notification
};
```

### Parser (`term/parser.zig`)

Eleven-state machine: Ground, Escape, EscapeCharset, CSI, OSC, OscEscape,
APC, ApcEscape, DCS, DcsEscape, StrIgnore.

- `next(byte) → ?Action` — process one byte, return action or null.
- Zero allocations. All state in fixed-size struct fields.
- OSC buffer: 4 KB. APC buffer: 64 KB (for Kitty graphics payloads).
- Handles partial sequences across `feed()` chunk boundaries.

### TerminalState (`term/state.zig`)

- Owns **two** `Grid`s (main + alt) plus per-buffer cursor, pen, scroll region,
  and saved cursor.
- `apply(action)` — the only way state changes. Logic split across:
  - `state_altscreen.zig` — alt screen swap
  - `state_erase.zig` — erase operations
  - `state_graphics.zig` — Kitty graphics
  - `state_osc.zig` — OSC handlers
  - `state_report.zig` — device queries
  - `state_resize.zig` — grid reflow
- **Scrollback:** `Scrollback` ring buffer per grid. Rows scroll off into history.
- **Hyperlinks:** `link_uris` table maps `link_id → URI`.
- **Terminal modes** (global): `bracketed_paste`, `mouse_tracking`, `mouse_sgr`,
  `cursor_keys_app`, `keypad_app_mode`.
- **Kitty keyboard protocol:** flag stack (push/pop/query).

### Cell + Style + Color (`term/grid.zig`)

- `Color` tagged union: `default`, `ansi: u8`, `palette: u8`, `rgb: Rgb`.
- `Style`: `fg`, `bg`, `bold`, `dim`, `italic`, `underline`, `blink`, `inverse`,
  `invisible`, `strikethrough`.
- `Cell`: `char: u21`, `combining: [2]u21`, `style: Style`, `link_id: u16`.
  Size: 32 bytes.

### Grid (`term/grid.zig`)

- Fixed-size 2D array of `Cell` values (row-major, flat allocation).
- Supports scroll regions (`scrollUpRegion`, `scrollDownRegion`).
- Insert/delete lines and characters.

### Engine (`term/engine.zig`)

- Owns Parser + TerminalState.
- `feed(bytes)` — the high-level API: parse bytes → apply actions.
- `response_buf` for device query responses sent back to PTY.

### Kitty Graphics (`term/graphics_*`)

Full Kitty graphics protocol support:

- **graphics_cmd.zig** — Action types (transmit, display, delete, query),
  image formats (RGB, RGBA, PNG), compression (none, zlib).
- **graphics_decode.zig** — Base64 decoding, zlib decompression, PNG decoding
  via stb_image.
- **graphics_store.zig** — Image storage (max 320 MB total), placement tracking,
  streaming chunk reassembly.
- **state_graphics.zig** — Processes `graphics_command` actions, responds to
  queries with status codes.

## Session Daemon (`app/daemon/`)

Multi-session daemon enabling instant tab/window switching with session persistence:

```
attyx (client) ──unix socket──▸ daemon
                                  ├── DaemonSession (tabs, splits, layout)
                                  │     ├── DaemonPane (PTY + replay buffer)
                                  │     ├── DaemonPane
                                  │     └── ...
                                  ├── DaemonSession
                                  └── ...
```

- **Protocol (V2):** create, list, attach, detach, kill, rename, create_pane,
  close_pane, layout_sync, pane_output, pane_died, proc_name.
- **Replay:** Each pane maintains a ring buffer so new clients get instant
  screen restore on attach.
- **State persistence:** `state_persist.zig` serializes dead session metadata
  to JSON for restore across daemon restarts.
- **Hot upgrade:** `upgrade.zig` migrates daemon state across binary versions
  using a versioned binary format (magic "ATUP", format v2).
- **Socket:** `~/.local/state/attyx/sessions.sock` (XDG_STATE_HOME).
- **Auto-start:** Client auto-launches daemon with exponential backoff.

## Overlay System (`overlay/`)

Pure, composable overlay layers rendered on top of the terminal grid:

- **OverlayManager** — manages up to 16 layers, each with a unique `OverlayId`.
- **Overlay types:** search bar, command palette, session picker, theme picker,
  AI prompt, update notification, tab bar, statusbar, context preview.
- **Rendering:** Cell-based rendering pipeline (`ui_cell.zig` → `ui_render.zig`).
- **Components:** Reusable text input, scrollable lists, diff viewer.

## Theme System (`theme/`)

- **22 built-in themes:** default, catppuccin-latte, catppuccin-mocha, dracula,
  everforest-dark, github-dark, gruvbox-dark, gruvbox-light, iceberg, kanagawa,
  material, monokai, nord, one-dark, palenight, rose-pine, rose-pine-moon,
  snazzy, solarized-dark, solarized-light, tokyo-night, tokyo-night-storm.
- Theme struct: foreground, background, cursor color, 16-color palette.
- Theme picker overlay for live switching.
- Themes are hot-reloadable.

## Split Panes & Tabs

- **Split layout:** Binary tree (max 8 panes, 15 total nodes). Supports
  horizontal/vertical splits, navigation, rotation, zoom, and mouse-drag resize.
- **Tabs:** Up to 16 tabs, each containing a split layout. Draggable tab
  reordering. Both built-in overlay bar and macOS native window tabs.
- **Statusbar:** Configurable widget bar (git status, clock, custom widgets).
  Always shows tabs when active.

## Keybind System (`config/keybinds.zig`, `config/commands.zig`)

- Centralized command registry with action names, descriptions, and scopes.
- Scopes: global, search, ai_prompt, overlay.
- Platform-specific default hotkeys (Cmd on macOS, Ctrl on Linux).
- User-configurable overrides via `[keybindings]` in config.
- Custom key sequences via `[sequences]` for sending arbitrary byte data.
- Command palette (`Ctrl+Shift+P`) for discovering and executing all commands.

## Shell Integration (`app/shell_integration.zig`)

Multi-shell support for feature-rich shell interaction:

- **Supported shells:** zsh, bash, fish, nushell, sh.
- **PATH reporting:** Each shell's integration script emits `\e]7337;set-path;$PATH\a`
  on every prompt. Popup commands inherit the shell's PATH.
- **CWD tracking:** OSC 7 reports the current working directory.
- **Injection methods:** zsh=ZDOTDIR, bash=--rcfile+BASH_ENV, fish=XDG_DATA_DIRS,
  nu=--env-config, sh=ENV.

## Fuzzy Finder (`finder/`)

Path-aware fuzzy file finder for the session picker:

- **dir_walker.zig** — Incremental directory traversal with configurable depth
  limit and hidden file filtering.
- **fuzzy_match.zig** — fzf-inspired scoring with bonuses for path separators,
  basename matches, and exact matches. Tracks up to 64 match positions.
- **finder.zig** — Combines walker + matcher, processes 200 entries per tick.

## Logging (`logging/`)

Structured logger with five levels: `err`, `warn`, `info`, `debug`, `trace`.

- Mutex-guarded writer: `HH:MM:SS.mmm [LVL] [scope] message`.
- Outputs to stderr + optional log file.
- C bridge: `attyx_log()` + `ATTYX_LOG_*` macros for platform code.
- `ThroughputWindow` for PTY byte-rate monitoring at debug level.

## Platform Renderers

### macOS (`platform_macos.m` + `macos_*.m`)

- Cocoa window with MTKView + Metal renderer.
- Core Text font rasterization with dynamic glyph atlas.
- Ligature support via CTLine shaping + CTFontDrawGlyphs.
- Box drawing character rendering.
- NSTextInputClient for IME (CJK).
- NSPasteboard clipboard.
- Native macOS tab bar support.
- In-app updater.

### Linux (`platform_linux.c` + `linux_*.c`)

- GLFW window with OpenGL 3.3 core renderer.
- FreeType rasterization + Fontconfig font discovery.
- Same vertex format, same shader logic (GLSL port of Metal shaders).
- Same damage-aware rendering, seqlock frame skipping, dirty bitset.
- GLFW clipboard API.

## XDG Directory Layout

- **Config:** `~/.config/attyx/` — attyx.toml, themes/
- **State:** `~/.local/state/attyx/` — sessions.sock, last-session, daemon.version,
  upgrade.bin, recent.json, auth.json
- Both respect `XDG_CONFIG_HOME` and `XDG_STATE_HOME` environment variables.
