<p align="center">
  <img src="images/Attyx.png" alt="Attyx" width="200">
</p>

<h1 align="center">Attyx</h1>

<p align="center">
  <strong>Terminal for agentic workflows</strong>
</p>

<p align="center">
  <a href="https://github.com/semos-labs/attyx/releases/latest"><img src="https://img.shields.io/github/v/release/semos-labs/attyx?label=Release&amp;color=green" alt="Latest Release"></a>
  <a href="https://github.com/semos-labs/attyx/releases/latest"><img src="https://img.shields.io/github/downloads/semos-labs/attyx/total?label=Downloads&amp;color=blue" alt="Downloads"></a>
  <a href="https://github.com/semos-labs/attyx/actions/workflows/test.yml"><img src="https://github.com/semos-labs/attyx/actions/workflows/test.yml/badge.svg" alt="Tests"></a>
  <img src="https://img.shields.io/badge/Zig-0.15-f7a41d?logo=zig&logoColor=white" alt="Zig 0.15">
  <img src="https://img.shields.io/badge/License-MIT-blue" alt="MIT License">
</p>

<p align="center">
  <a href="https://semos.sh/docs/attyx">Documentation</a>
  &middot;
  <a href="https://semos.sh/attyx">Download</a>
  &middot;
  <a href="https://github.com/semos-labs/attyx/issues">Issues</a>
</p>

## About

Attyx is a GPU-accelerated terminal built for the agentic era — the operator console for AI agents. It's agent-aware end to end: it tracks agent lifecycle natively and exposes the full terminal surface over an IPC layer, the `attyx` CLI, and MCP, so one agent can spawn, watch, and drive others across panes.

The terminal fundamentals — sessions, splits, tabs, popups, a status bar, command palette — are all built in, no tmux + config pile. Written in Zig, GPU-rendered on Metal (macOS) and OpenGL (Linux), a single binary under 5 MB.

### Agent status, at a glance

Attyx reads each agent's lifecycle — Claude and Codex via JSON lifecycle hooks, opencode via an event-bus plugin — and paints a colored dot on its pane: **working**, **waiting on you**, or **idle**. Run a swarm and tell at a glance which one needs you, right from the tab and status bars.

### Drive it from anywhere

Every pane has a stable ID. Over a Unix socket, one agent spawns panes, sends keystrokes, and reads output from any other — no focus change, no guesswork.

```bash
# spawn an agent in a new pane, capture its id
id=$(attyx split v --cmd "claude -p 'run tests'")

# read what it's doing — anytime, no focus change
attyx get-text -p $id

# nudge it when it pauses for input
attyx send-keys -p $id "yes{Enter}"

# clean up when it's done
attyx split close -p $id
```

It speaks **MCP**, too: `attyx mcp` is a stdio bridge for every platform, and an embedded loopback HTTP MCP server (`http://127.0.0.1:7333/mcp`, POSIX) hands the same tools — panes, tabs, keystrokes, output, sessions, agent status, image injection — to Claude Desktop and any MCP client. The Claude Code skill drops in with `attyx skill install`.

### Built-in terminal craft

Vertical and horizontal splits, tabs, and floating popups — no plugins. Sessions are backed by a daemon: close the window, reopen it tomorrow, every pane exactly where you left it. A fuzzy command palette (`Cmd+Shift+P` / `Ctrl+Shift+P`) runs every action, 22 themes ship in the box, and a deterministic VT-compatible engine keeps behavior predictable. Regex scrollback search, vim-style visual mode, inline images via the Kitty protocol, a scriptable status bar, TOML config with hot reload.

For more details, see the [documentation](https://semos.sh/docs/attyx).

## Origin

I started Attyx because I wanted to understand how terminals actually work — and I wanted to learn Zig. Weekend experiment that got out of hand. I'm daily-driving it now and it's solid enough for real work, so here it is.

Why not Ghostty or Kitty? Both are great — I used both before this. But I needed to build my own to really understand what's going on. And no, I didn't steal from Ghostty. "GPU terminal in Zig" is a category, not a trademark. Not a single matching line of code.

## Install

### Homebrew (macOS)

```bash
brew install semos-labs/tap/attyx --cask
```

### Homebrew (Linux x86_64)

```bash
brew install semos-labs/tap/attyx
```

On Linux, Attyx installs as a desktop application. It should appear in your app launcher automatically. If it doesn't, log out and back in to refresh the desktop entry cache.

### Build from source

Requires **Zig 0.15.2+**. On Linux, install build dependencies first:

```bash
sudo apt install libglfw3-dev libfreetype-dev libfontconfig-dev libgl-dev
```

```bash
zig build run
```


## Configuration

Attyx is configured via `~/.config/attyx/attyx.toml`. See the [configuration docs](https://semos.sh/docs/attyx/configuration) for all available options, or check the included [`config/attyx.toml.example`](config/attyx.toml.example) for a quick-start template.

## Part of Semos Labs

Attyx is part of [Semos Labs](https://semos.sh) — a constellation of terminal-native tools.

## License

MIT
