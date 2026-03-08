# Testing

## How to Run Tests

```bash
zig build test                # run all tests
zig build test --summary all  # run with detailed summary
```

## Test Strategy

All tests run in **headless mode** — no PTY, no window, no OS interaction.
The terminal core is fully deterministic, so given the same input bytes,
it always produces the same grid state.

### Test Layers

1. **Unit tests** (colocated in each module)
   - `grid.zig`: Cell creation, get/set, clearRow, scrollUp, combining marks.
   - `parser.zig`: State transitions, action emission, buffering, UTF-8.
   - `state.zig`: Individual `apply()` calls for each action type.
   - `snapshot.zig`: Serialization correctness.
   - `sgr.zig`: SGR attribute parsing (bold, colors, 256-color, truecolor).
   - `scrollback.zig`: Ring buffer operations, capacity limits.
   - `search.zig`: Text search across grid + scrollback.
   - `key_encode.zig`: Kitty keyboard protocol encoding.
   - `graphics_store.zig`: Kitty image storage and placement.
   - `split_layout.zig`: Binary tree split operations.
   - `keybinds.zig`: Keybind matching and action dispatch.
   - `commands.zig`: Command registry validation.
   - `git_widget.zig`: Git status parsing.
   - `daemon/`: Session lifecycle, state persistence, ring buffer, migrations.

2. **Golden snapshot tests** (`headless/tests/`)
   - Create a terminal of known size.
   - Feed specific bytes.
   - Compare the grid snapshot against an exact expected string.
   - If even one space is wrong, the test fails with a diff.
   - Test files organized by category:
     - `text.zig` — basic text rendering
     - `parser.zig`, `parser_basic.zig`, `parser_utf8_dcs.zig` — parser states
     - `csi.zig`, `csi_cursor.zig`, `csi_device.zig` — CSI sequences
     - `erase.zig` — erase operations
     - `scroll.zig`, `scrollback.zig` — scrolling and scrollback
     - `screen.zig`, `screen_altscreen.zig` — screen management
     - `screen_reflow.zig`, `screen_resize.zig`, `state_resize_extra.zig` — reflow/resize
     - `modes.zig` — DEC private modes
     - `osc.zig` — OSC sequences
     - `color.zig` — color handling
     - `search.zig` — text search
     - `graphics_parse.zig`, `graphics_store.zig` — Kitty graphics

3. **Incremental chunk tests**
   - Feed the same input split across multiple `feed()` calls.
   - Verifies the parser handles partial sequences correctly.

4. **Daemon tests** (`app/daemon/`)
   - `session_test.zig` — session create/attach/detach
   - `session_lifecycle_test.zig` — full lifecycle flows
   - `session_restore_test.zig` — state persistence and restore
   - `session_stress_test.zig` — concurrent operations
   - `session_chaos_test.zig` — fault injection
   - `session_migration_test.zig` — upgrade format migration
   - `cwd_test.zig` — working directory tracking

### Snapshot Format

The snapshot is a plain text string: exactly `rows` lines, each exactly `cols`
characters wide. Trailing spaces are preserved (not trimmed). Each row ends
with `\n`.

Example: a 3×5 grid with "Hi" at position (0,0):

```
Hi


```

Total bytes: `3 × (5 + 1) = 18` (5 chars + newline per row).

### Attribute tests

SGR tests cannot rely on snapshots (snapshots are text-only, no style info).
Instead, these tests create an `Engine`, feed input, and inspect `Cell.style`
directly:

```zig
var engine = try Engine.init(alloc, 2, 10);
engine.feed("\x1b[31mA\x1b[0mB");
try expectEqual(Color.red, engine.state.grid.getCell(0, 0).style.fg);
try expectEqual(Color.default, engine.state.grid.getCell(0, 1).style.fg);
```

## Current Test Count

**964 test declarations** across the full codebase, covering:

| Area | Modules |
|------|---------|
| Terminal core | grid, parser, state, snapshot, sgr, scrollback, search, unicode, dirty, graphics |
| Input encoding | input, key_encode |
| Headless integration | 22 categorized test files in `headless/tests/` |
| Config | keybinds, commands |
| App | split_layout, git_widget |
| Daemon | session lifecycle, persistence, stress, chaos, migration, ring buffer |
