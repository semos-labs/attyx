<p align="center">
  <img src="images/Attyx.png" alt="Attyx" width="200">
</p>

<h1 align="center">Attyx</h1>

<p align="center">
  <strong>GPU-accelerated terminal emulator written in Zig</strong>
</p>

<p align="center">
  <a href="https://github.com/semos-labs/attyx/releases/latest"><img src="https://img.shields.io/github/v/release/semos-labs/attyx?label=Release&amp;color=green" alt="Latest Release"></a>
  <a href="https://github.com/semos-labs/attyx/releases/latest"><img src="https://img.shields.io/github/downloads/semos-labs/attyx/total?label=Downloads&amp;color=blue" alt="Downloads"></a>
  <a href="https://github.com/semos-labs/attyx/actions/workflows/test.yml"><img src="https://github.com/semos-labs/attyx/actions/workflows/test.yml/badge.svg" alt="Tests"></a>
  <img src="https://img.shields.io/badge/Zig-0.15-f7a41d?logo=zig&logoColor=white" alt="Zig 0.15">
  <img src="https://img.shields.io/badge/License-MIT-blue" alt="MIT License">
</p>

---

## Features

- **GPU-rendered** — Metal on macOS, OpenGL 3.3 on Linux
- **VT-compatible** — deterministic state machine core, 197 headless tests
- **Fast** — non-blocking PTY I/O, 60 fps rendering, zero per-character allocations
- **Configurable** — TOML config with hot-reload (Ctrl+Shift+R or SIGUSR1)
- **Transparent backgrounds** — window opacity + blur (macOS compositor, Linux compositor-dependent)
- **Theming** — built-in themes + custom TOML color schemes
- **Font fallback** — primary font + ordered fallback chain for symbols and emoji
- **Keybindings** — fully rebindable hotkeys + custom escape sequences
- **Popups** — floating terminal overlays for tools like lazygit
- **Search** — incremental in-terminal search (Cmd+F / Ctrl+F)
- **Scrollback** — configurable buffer with mouse wheel and keyboard navigation
- **IME** — CJK composition input on macOS
- **Cross-platform** — macOS and Linux from a single codebase

---

## Install

### Homebrew

**macOS:**

```bash
brew install semos-labs/tap/attyx --cask
```

**Linux (x86_64):**

```bash
brew install semos-labs/tap/attyx
```

Runtime dependencies (glfw, freetype, fontconfig, mesa, libpng, zlib) are installed automatically. Make sure your shell is configured with `eval "$(brew shellenv)"` so that Homebrew's library paths are visible at runtime.

### Build from source

Requires **Zig 0.15.2+**.

```bash
zig build run           # build and launch
```

**Linux build prerequisites:**

```bash
sudo apt install libglfw3-dev libfreetype-dev libfontconfig-dev libgl-dev
```

---

## Configuration

Config file: `~/.config/attyx/attyx.toml`

See [`config/attyx.toml.example`](config/attyx.toml.example) for all options with defaults.

```toml
[font]
family = "JetBrains Mono"
size = 14
cell_width = "110%"
cell_height = 20
fallback = ["Symbols Nerd Font Mono", "Noto Color Emoji"]

[cursor]
shape = "block"        # "block" | "beam" | "underline"
blink = true

[scrollback]
lines = 20000

[background]
opacity = 0.9          # 0.0–1.0
blur = 30              # macOS compositor blur radius

[window]
decorations = true     # hide title bar when false
padding = 8            # padding around the grid (px)

[theme]
name = "catppuccin-mocha"

[program]
shell = "/bin/zsh"
args = ["-l"]
```

### Keybindings

All hotkeys can be rebound via the `[keybindings]` table. Bind an action to `"none"` to disable it. Changes apply on hot-reload.

```toml
[keybindings]
search_toggle = "ctrl+f"
search_next = "ctrl+g"
search_prev = "ctrl+shift+g"
scroll_page_up = "shift+page_up"
scroll_page_down = "shift+page_down"
scroll_to_top = "shift+home"
scroll_to_bottom = "shift+end"
config_reload = "ctrl+shift+r"
new_window = "ctrl+shift+n"
close_window = "ctrl+shift+w"
debug_toggle = "none"          # unbind
```

**Key combo syntax:** `modifier+key` — modifiers: `ctrl`, `shift`, `alt` (`option`), `super` (`cmd`). Keys: `a`–`z`, `0`–`9`, `f1`–`f12`, `enter`, `tab`, `escape`, `backspace`, `delete`, `insert`, `space`, `page_up`, `page_down`, `home`, `end`, `up`, `down`, `left`, `right`.

| Action | macOS default | Linux default |
|---|---|---|
| `search_toggle` | `super+f` | `ctrl+f` |
| `search_next` | `super+g` | `ctrl+g` |
| `search_prev` | `super+shift+g` | `ctrl+shift+g` |
| `copy` | *(system menu)* | `ctrl+shift+c` |
| `paste` | *(system menu)* | `ctrl+shift+v` |
| `scroll_page_up` | `shift+page_up` | `shift+page_up` |
| `scroll_page_down` | `shift+page_down` | `shift+page_down` |
| `scroll_to_top` | `shift+home` | `shift+home` |
| `scroll_to_bottom` | `shift+end` | `shift+end` |
| `config_reload` | `ctrl+shift+r` | `ctrl+shift+r` |
| `new_window` | `ctrl+shift+n` | `ctrl+shift+n` |
| `close_window` | `ctrl+shift+w` | `ctrl+shift+w` |

### Custom sequences

Bind any key combo to send a raw escape sequence to the terminal:

```toml
[sequences]
"ctrl+shift+k" = "\u001b[K"
"alt+enter" = "\u001b\r"
```

Values use standard TOML string escapes (`\u001b` for ESC, `\n`, `\r`, `\t`, etc.).

### Hot-reload

Press **Ctrl+Shift+R** (or your rebound key) or send `SIGUSR1` to reload config without restarting. Font, cursor, scrollback, theme, and keybinding changes apply immediately. Background opacity/blur require a restart.

### CLI flags

All config options can be overridden from the command line. Run `attyx --help` for the full list.

```bash
attyx --font-size 16 --theme catppuccin-mocha --background-opacity 0.85
```

---

## Popups

Popups are floating terminal windows that run a command inside the main Attyx window. Up to 32 popups can be configured, each bound to a hotkey. Press the hotkey again to close.

```toml
[[popup]]
hotkey = "ctrl+shift+g"
command = "lazygit"
width = "80%"
height = "80%"
border = "rounded"        # "single" (default) | "double" | "rounded" | "heavy" | "none"
border_color = "#78829a"  # hex color for the border (default: "#78829a")

[[popup]]
hotkey = "ctrl+shift+t"
command = "htop"
width = "60%"
height = "60%"
border = "heavy"
border_color = "#ff6600"
```

| Option | Default | Description |
|---|---|---|
| `hotkey` | *(required)* | Key combo to toggle the popup (e.g. `ctrl+shift+g`, `alt+g`) |
| `command` | *(required)* | Shell command to run |
| `width` | `"80%"` | Popup width as percentage of terminal |
| `height` | `"80%"` | Popup height as percentage of terminal |
| `border` | `"single"` | Border style: `single`, `double`, `rounded`, `heavy`, or `none` |
| `border_color` | `"#78829a"` | Border foreground color (`#RRGGBB`) |

---

## Themes

Attyx ships with built-in themes and supports custom TOML theme files.

**Built-in:** `default`, `catppuccin-mocha`

Set the theme in your config:

```toml
[theme]
name = "catppuccin-mocha"
```

Custom themes follow the same TOML format — define `[colors]` (foreground, background, cursor) and `[palette]` (ANSI 0–15). See `themes/default.toml` for the full structure.

---

## License

MIT
