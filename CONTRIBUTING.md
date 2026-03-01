# Contributing to Attyx

Thank you for your interest in contributing to Attyx! This guide will help you get started.

## Getting Started

### Prerequisites

- **Zig 0.15.2** — exact version required ([download](https://ziglang.org/download/))
- **macOS:** Xcode command-line tools (Metal, Cocoa, Core Text)
- **Linux:** `libglfw3-dev`, `libfreetype-dev`, `libfontconfig-dev`, `libgl-dev`

### Building

```sh
# Build the binary
zig build

# Run tests (headless, no window required)
zig build test

# Build with optimizations
zig build -Doptimize=ReleaseFast
```

### Running

```sh
./zig-out/bin/attyx
```

## Project Structure

```
src/
  term/      # Pure terminal engine — no side effects, fully deterministic
  headless/  # Deterministic runner + tests
  app/       # PTY + OS integration (macOS Metal, Linux OpenGL)
  config/    # TOML parsing, CLI flags, hot-reload
  render/    # Color resolution
  logging/   # Structured logger
```

The core principle: **`src/term/` is pure.** It must never depend on PTY, windowing, rendering, clipboard, or platform APIs.

## How to Contribute

### Reporting Bugs

Open an issue on [GitHub](https://github.com/semos-labs/attyx/issues) with:

- Steps to reproduce
- Expected vs actual behavior
- OS, Zig version, and Attyx version (`attyx --version`)
- Terminal output or screenshots if relevant

### Suggesting Features

Open an issue describing the feature and its use case. Keep in mind the project's scope control — Attyx focuses on minimal VT correctness before advanced features. See `CLAUDE.md` for what's currently out of scope.

### Submitting Code

1. **Fork** the repository and create a branch from `main`.
2. **Make your changes** following the guidelines below.
3. **Write tests** — every feature or fix needs at least one test (see [Testing](#testing)).
4. **Run `zig build test`** and make sure all tests pass.
5. **Open a pull request** against `main` with a clear description of what changed and why.

## Guidelines

### Architecture Rules

- `src/term/` must be fully deterministic and pure — no I/O, no platform APIs.
- Parser emits `Action` values. State applies `Action`. Renderer consumes state.
- Parser must never modify state directly.
- Renderer must never influence parsing or state.

### Code Style

- Use explicit types in public APIs.
- Avoid metaprogramming unless it reduces complexity.
- No global mutable state.
- Keep modules small and focused; keep functions short and readable.
- Favor data-oriented structs over clever abstractions.
- No hidden allocations — pass `std.mem.Allocator` explicitly.
- Every allocation must have a clear ownership model.

### File Size Limit

**No file may exceed 600 lines.** This is a hard limit. If a file approaches this limit, split it into focused modules before adding more code.

### Error Handling

- Use Zig errors, not sentinel values.
- Do not swallow errors silently.
- Parsing: ignore malformed sequences gracefully by default.

### Performance

- No per-character allocations.
- Parser operates on slices and indexes — no temporary strings for CSI parsing.
- State updates should be O(1) per action where possible.
- No premature micro-optimizations.

### Testing

Every contribution must include tests. Accepted test types:

- **Golden snapshot tests** — expected terminal output vs actual
- **State hash tests** — verify terminal state after a sequence of operations
- **Parser unit tests** — verify parsing of escape sequences and control codes

All tests must run in headless mode (`zig build test`). No rendering or PTY required.

### Commit Messages

Use clear, descriptive commit messages:

```
fix: correct cursor position after tab in last column
feat: add SGR 256-color support
chore: bump version to v0.1.39
refactor: split grid.zig into grid and row modules
```

Prefix with `fix:`, `feat:`, `chore:`, `refactor:`, `docs:`, or `test:` as appropriate.

## Code Review

All submissions require review before merging. Reviewers will check:

- Adherence to architecture rules (layer separation, purity of `src/term/`)
- Test coverage
- File size limits
- Code clarity and correctness

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
