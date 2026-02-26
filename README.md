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

<p align="center">
  <a href="https://semos.sh/docs/attyx">Documentation</a>
  &middot;
  <a href="https://github.com/semos-labs/attyx/releases/latest">Download</a>
  &middot;
  <a href="https://github.com/semos-labs/attyx/issues">Issues</a>
</p>

## About

Attyx is a GPU-accelerated, VT-compatible terminal emulator built from scratch in Zig. It uses Metal on macOS and OpenGL 3.3 on Linux, with a deterministic state machine core that is fully testable without rendering or a PTY.

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

### Build from source

Requires **Zig 0.15.2+**.

```bash
zig build run
```

On Linux, install build dependencies first:

```bash
sudo apt install libglfw3-dev libfreetype-dev libfontconfig-dev libgl-dev
```

## Configuration

Attyx is configured via `~/.config/attyx/attyx.toml`. See the [configuration docs](https://semos.sh/docs/attyx/configuration) for all available options, or check the included [`config/attyx.toml.example`](config/attyx.toml.example) for a quick-start template.

## License

MIT
