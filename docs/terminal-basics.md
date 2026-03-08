# Terminal Basics

A reference for how terminals actually work, written as we learn by building one.

## What Is a Terminal Emulator?

A **terminal** was originally a physical device (like the DEC VT100) — a screen
and keyboard connected to a mainframe via a serial cable. The mainframe sent
bytes down the wire, and the terminal hardware interpreted them.

A **terminal emulator** is software that pretends to be that physical device.
It receives bytes (from a shell process via a PTY), interprets them the same
way, and renders the result on screen.

## The Grid Model

A terminal's display is a fixed-size **grid** of cells, typically 80 columns
by 24 rows. Each cell holds one Unicode codepoint (plus up to 2 combining
marks), along with color and style attributes.

A **cursor** tracks where the next character will be written, like a typewriter
head. It has a row and column position.

A **scrollback buffer** preserves rows that scroll off the top of the visible
grid. Attyx uses a bounded ring buffer (default 5,000 lines, configurable)
so users can scroll back through history.

## Control Characters (C0)

Bytes below 0x20 are **control characters** — they don't print anything visible.
Instead they move the cursor or trigger special behavior. These date back to
mechanical teletypes in the 1960s:

| Byte | Abbreviation | Name | What it does |
|------|-------------|------|--------------|
| 0x08 | BS | Backspace | Move cursor left one column (doesn't erase) |
| 0x09 | TAB | Horizontal Tab | Jump to next tab stop (every 8 columns) |
| 0x0A | LF | Line Feed | Move cursor down one row |
| 0x0D | CR | Carriage Return | Move cursor to column 0 |
| 0x1B | ESC | Escape | Start an escape sequence |

### Why LF Doesn't Reset the Column

This surprises many people. In VT terminals, LF ("line feed") literally means
"feed the paper up one line" — it moves the cursor down but does NOT go to
column 0. CR ("carriage return") moves to column 0 but does NOT go down.

That's why network protocols and many file formats use `\r\n` — CR moves to
the start of the line, LF moves to the next line. Two separate operations.

## Escape Sequences

Bytes starting with ESC (0x1B) begin **escape sequences** — multi-byte
instructions that control the terminal beyond what single control characters
can do.

### CSI (Control Sequence Introducer)

The most important family of escape sequences. Format:

```
ESC [ <parameters> <final byte>
```

- **ESC** (0x1B): starts the sequence
- **[** (0x5B): identifies this as a CSI sequence
- **Parameters**: digits and semicolons (0x30–0x3F), e.g., `31;1`
- **Final byte**: a letter (0x40–0x7E) that identifies the command

Examples:

| Sequence | Final | Meaning |
|----------|-------|---------|
| `ESC[H` | H | Move cursor to home (1,1) |
| `ESC[2J` | J | Clear entire screen |
| `ESC[31m` | m | Set text color to red |
| `ESC[A` | A | Move cursor up 1 row |
| `ESC[10;20H` | H | Move cursor to row 10, column 20 |
| `ESC[L` | L | Insert blank lines |
| `ESC[P` | P | Delete characters |
| `ESC[?1049h` | h | Enter alternate screen |
| `ESC[?2004h` | h | Enable bracketed paste |

### Two-byte Escape Sequences

ESC followed by a single byte (not `[`) is a simpler escape sequence:

| Sequence | Meaning |
|----------|---------|
| `ESC D` | Index (move cursor down, scroll if at bottom) |
| `ESC M` | Reverse index (move cursor up, scroll if at top) |
| `ESC 7` | Save cursor position |
| `ESC 8` | Restore cursor position |
| `ESC =` | Keypad application mode (DECKPAM) |
| `ESC >` | Keypad normal mode (DECKPNM) |

### OSC (Operating System Command)

OSC sequences carry string payloads for higher-level features:

```
ESC ] <number> ; <payload> BEL
```

| Sequence | Meaning |
|----------|---------|
| `OSC 0;title BEL` | Set window title |
| `OSC 2;title BEL` | Set window title |
| `OSC 7;uri BEL` | Report working directory |
| `OSC 8;params;uri ST` | Start/end hyperlink |
| `OSC 10;? BEL` | Query foreground color |
| `OSC 11;? BEL` | Query background color |

### DCS (Device Control String)

DCS sequences are used for protocols like tmux passthrough:

```
ESC P <payload> ESC \
```

### APC (Application Program Command)

APC sequences carry application-specific data, notably the Kitty graphics
protocol:

```
ESC _ G <key=value pairs> ; <base64 payload> ESC \
```

## Line Wrapping

When a character is printed at the last column, the cursor wraps to column 0
of the next row. If the cursor is on the bottom row and needs to go further
down, the grid **scrolls**: the top row moves into the scrollback buffer,
all rows shift up, and a blank row appears at the bottom.

## Unicode

Attyx handles full UTF-8 input. Each cell stores a `u21` codepoint (covering
all of Unicode). **Combining characters** (diacritics, Thai marks, Devanagari
vowel signs, etc.) are stored in a per-cell `combining: [2]u21` array, allowing
up to 2 combining marks per base character.

## The Parser State Machine

Attyx implements an eleven-state parser:

```
                      ESC
  Ground ──────────────────▸ Escape
    ▲                          │
    │  non-[/]/_ /P            │  [         ]         _         P
    │◂─────────────────────────│──────▸ CSI  OSC  APC/Kitty  DCS
    │                                   │     │      │        │
    │        final byte / BEL / ST      │     │      │        │
    │◂──────────────────────────────────┘─────┘──────┘────────┘
```

- **Ground**: Normal text processing. Printable bytes print (UTF-8 decoded),
  control bytes execute, ESC transitions to Escape.
- **Escape**: Waiting for the byte after ESC. `[` → CSI, `]` → OSC,
  `_` → APC, `P` → DCS. Anything else is a two-byte escape sequence.
- **CSI**: Buffering parameter bytes until a final byte (0x40–0x7E) terminates
  the sequence. Handles `?` prefix for DEC private modes.
- **OSC**: Buffering string payload until BEL (0x07) or ST (ESC \).
- **APC**: Buffering payload until ST. Used for Kitty graphics protocol.
- **DCS**: Device control strings, including tmux passthrough.

The parser is **incremental** — it can handle bytes arriving in any chunk size,
even one byte at a time, because it stores its state between calls.
Zero allocations — all state lives in fixed-size struct fields.
