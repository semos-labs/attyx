# Attyx — Claude Instructions

## Project Philosophy

- Attyx is a deterministic VT-compatible state machine.
- Clarity > cleverness.
- Correctness > feature count.
- Minimalism > abstraction.
- The core must be testable without rendering or PTY.

## Architecture

### Layer Separation

```
src/
  term/     # Pure terminal engine (no side effects)
  headless/ # Deterministic runner + tests
  app/      # PTY + OS integration
  render/   # GPU + font rendering
```

### Rules

- `term/` must not depend on PTY, windowing, rendering, clipboard, or platform APIs.
- `term/` must be fully deterministic and pure.
- Parser emits `Action` values. State applies `Action`. Renderer consumes state.
- Parser must never modify state directly.
- Renderer must never influence parsing or state.

## File Size

- **No file may exceed 600 lines.** This is a hard limit required for AI-assisted development.
- If a file approaches this limit, split it into focused modules before adding more code.

## Code Style (Zig)

- Use explicit types in public APIs.
- Avoid metaprogramming unless it reduces complexity.
- No global mutable state.
- Keep modules small and focused; keep functions short and readable.
- Avoid clever abstractions. Favor data-oriented structs.
- No hidden allocations. Every allocation must have a clear ownership model.
- Pass `std.mem.Allocator` explicitly.

## Error Handling

- Use Zig errors, not sentinel values.
- Do not swallow errors silently.
- Parsing: ignore malformed sequences gracefully by default; log them in strict mode.

## Performance

- No per-character allocations.
- Parser operates on slices and indexes.
- Do not build temporary strings for CSI parsing.
- State updates should be O(1) per action where possible.
- No premature micro-optimizations.

## Testing (Mandatory)

Every feature must include at least one of:
- A golden snapshot test
- A state hash test
- A parser unit test

All tests must run in headless mode. No rendering required for core tests.

## Terminal Model Rules

- Maintain explicit mode flags.
- Alternate screen must be a separate buffer.
- Scrollback belongs only to the main screen.
- Do not mix rendering logic into state logic.

## Scope Control

Do NOT implement before MVP is complete:
- Tabs, splits, ligatures
- Kitty graphics protocol
- IME, UI overlays
- Experimental protocol extensions

Focus on minimal VT correctness first.

## Implementation Order (Do Not Skip)

1. Grid + cursor + printable bytes + `\n \r \b \t`
2. Headless snapshot system + golden tests
3. ESC detection + CSI parsing skeleton
4. Minimal CSI: cursor movement, erase line/screen, SGR reset + 16 colors
5. Scroll + scrollback
6. Alternate screen (`?1049h / ?1049l`)
7. Damage tracking (dirty rows first)

Do not implement advanced features before the above is stable and tested.
