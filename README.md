<p align="center">
  <img src="images/Attyx.png" alt="Attyx" width="200">
</p>

<h1 align="center">Attyx</h1>

<p align="center">
  <strong>GPU-accelerated terminal environment written in Zig</strong>
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

Attyx is a GPU-accelerated terminal environment built from scratch in Zig. Sessions, splits, tabs, popups, a status bar, command palette — the stuff you'd usually need tmux and a bunch of config for, just works out of the box. Metal on macOS, OpenGL on Linux, under 5MB.

I started Attyx because I wanted to understand how terminals actually work — and I wanted to learn Zig. Weekend experiment that got out of hand. I'm daily-driving it now and it's solid enough for real work, so here it is.

Why not Ghostty or Kitty? Both are great — I used both before this. But I needed to build my own to really understand what's going on. And no, I didn't steal from Ghostty. "GPU terminal in Zig" is a category, not a trademark. Not a single matching line of code.

For more details, see the [documentation](https://semos.sh/docs/attyx).

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

## License

MIT
