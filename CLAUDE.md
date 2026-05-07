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

- **No file may exceed roughly 600 lines, small overflow is allowed.** This is a hard limit required for AI-assisted development.
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

## Configuration

- When adding or renaming a config option, always update `src/config/default_config.toml` to include it with a comment explaining what it does.

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

## Pull Requests

- Never add "Generated with Claude Code" or similar attribution lines.
- Never add a "Files" section listing changed files — the diff shows that.
- Keep the description focused on what changed and why, not inventory.

## Release Notes

- All release notes go in the `releases/` folder as Markdown files.
- One file per version, named `v<version>.md` (e.g. `releases/v0.1.45.md`).
- Focus on the user-facing side of features: what users can do, how to use it, and why it matters.
- No technical deep dives, internal architecture details, or implementation specifics.
- Keep descriptions concise and practical — a user reading these should immediately understand what changed and how it affects them.
- Always include PR links for each fix or feature (e.g. `(#178)`). Link to the specific PR that introduced the change.

# Behavioral guidelines

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.
