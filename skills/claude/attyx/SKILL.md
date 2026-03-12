---
name: attyx
description: Control the Attyx terminal via IPC — manage splits, send input, read output, orchestrate panes. Use when the user asks to interact with terminal panes, run commands in splits, or coordinate multi-pane workflows.
allowed-tools: Bash
argument-hint: [action] [args...]
---

# Attyx Terminal IPC Skill

You are running inside Attyx, a terminal emulator with a full IPC interface. You can control it programmatically.

## Identifying Panes — Stable IPC IDs

Every pane has a **stable numeric ID** that never changes once assigned, even when other panes are closed. IDs are monotonically increasing integers (1, 2, 3, ...).

### How to find your own pane
Run `attyx list splits` — the pane marked with `*` is the **active/focused** pane (the one you're running in):
```
1	bash	*	80x24    ← this is YOU (pane 1)
3	python		40x24    ← another pane (pane 3)
```

Or `attyx list` for the full tree with tab context:
```
1	bash	*
  1	bash	*	80x24    ← YOU (pane 1)
  3	python		40x24    ← another pane (pane 3)
2	vim
  2	vim		80x24
```

### Tracking newly created panes
When you create a tab or split, the command **returns the new pane's ID**:
```bash
id=$(attyx tab create)              # returns e.g. "4"
id=$(attyx tab create --cmd htop)   # returns e.g. "5"
id=$(attyx split v)                 # returns e.g. "6"
id=$(attyx split v --cmd python3)   # returns e.g. "7"
```
**Always capture this output** so you can target the pane later without guessing:
```bash
attyx send-keys -p "$id" "print('hello'){Enter}"
attyx get-text -p "$id"
```

### Waiting for Commands (`--wait`)
`tab create` and `split` support `--wait` to block until the spawned command exits (requires `--cmd`):
```bash
attyx tab create --cmd "make test" --wait    # blocks, returns exit code + stdout
attyx split v --cmd "cargo build" --wait     # same for splits
```
The response is the process exit code (first byte) followed by captured stdout. Useful for scripting:
```bash
attyx run "make test" --wait && echo "Tests passed"
```

### Don't confuse titles with identity
Multiple panes can have the same title (e.g. two `bash` panes). **Never rely on title matching** to find a specific pane. Always use IDs from `attyx list` or captured from creation.

## Session Management

Sessions are independent workspaces, each with their own tabs and panes. They persist across window reconnects.

### Creating Sessions
```bash
# Create and switch to a new session
attyx session create

# Create with a working directory (name derived from path: "myapp")
attyx session create ~/Projects/myapp

# Create with explicit name
attyx session create ~/Projects/myapp "dev server"

# Create in background (don't switch)
attyx session create ~/Projects/myapp -b "build"

# Capture the session ID
sid=$(attyx session create ~/Projects/myapp -b)
```

### Session-Targeted Commands
Use `-s`/`--session <id>` to route **any** command to a specific session:
```bash
attyx -s 123 tab create                # create tab in session 123
attyx -s 123 send-keys "hello" -p 2    # send to pane 2 in session 123
attyx -s 123 get-text -p 5             # read from pane 5 in session 123
attyx -s 123 list                      # list tabs/panes in session 123
```
When `-s` is omitted, commands target the currently attached session.

### Other Session Commands
```bash
attyx session list                     # list all sessions
attyx session switch 2                 # switch to session 2
attyx session rename "dev server"      # rename current session
attyx session rename 1 "dev server"    # rename session 1
attyx session kill 3                   # kill session 3
```

## Critical Rules

### Don't Close Yourself
Before closing a pane, use targeted close with `--pane` / `-p`:
```bash
attyx split close -p 3              # close pane 3
attyx tab close 2                   # close entire tab 2
```
This closes the specified pane/tab **without changing focus**. Plain `attyx split close` (no target) closes the focused pane — which is YOU.

### Named Keys — Use `{Enter}`, Not `\n`
`send-keys` supports `{KeyName}` syntax (case-insensitive) for all special keys:

```bash
# Press Enter to submit a command
attyx send-keys "ls -la{Enter}"

# Arrow keys for navigation
attyx send-keys "{Down}{Down}{Enter}"    # navigate a menu
attyx send-keys "{Up}{Enter}"            # rerun last command

# Ctrl combos
attyx send-keys "{Ctrl-c}"              # interrupt
attyx send-keys "{Ctrl-d}"              # EOF
attyx send-keys "{Ctrl-z}"              # suspend

# Tab completion, Escape, function keys
attyx send-keys "{Tab}{Tab}"            # show completions
attyx send-keys "{Escape}:wq{Enter}"    # vim: save and quit
attyx send-keys "{F1}"                  # help in many TUIs
```

**Full key reference:**
| Key | Name(s) |
|-----|---------|
| Enter | `{Enter}`, `{Return}`, `{CR}` |
| Tab | `{Tab}` |
| Space | `{Space}` |
| Escape | `{Escape}`, `{Esc}` |
| Backspace | `{Backspace}`, `{BS}` |
| Delete | `{Delete}`, `{Del}` |
| Insert | `{Insert}`, `{Ins}` |
| Arrows | `{Up}`, `{Down}`, `{Left}`, `{Right}` |
| Page | `{PgUp}`, `{PgDn}`, `{PageUp}`, `{PageDown}` |
| Home/End | `{Home}`, `{End}` |
| Function | `{F1}` through `{F12}` |
| Ctrl+key | `{Ctrl-a}` through `{Ctrl-z}` |

**Modifier combos** — prefixes are combinable (Ctrl-, Shift-, Alt-, Super-):
| Combo | Example | Use case |
|-------|---------|----------|
| Ctrl+Arrow | `{Ctrl-Right}` | Word jump in shells |
| Alt+letter | `{Alt-a}` | Alt shortcuts in TUIs |
| Shift+Tab | `{Shift-Tab}` | Reverse tab / backtab |
| Ctrl+Shift | `{Ctrl-Shift-p}` | Command palettes (CSI u) |
| Shift+F-key | `{Shift-F5}` | Modified function keys |
| Ctrl+Delete | `{Ctrl-Delete}` | Delete word forward |

C-style escapes (`\r`, `\t`, `\xHH`, `\e`) also work but named keys are preferred for clarity.

### Navigating TUI Applications
When interacting with interactive programs (menus, prompts, fzf, editors, etc.):

1. **Read the screen first** — use `attyx get-text -p <id>` to see what's displayed
2. **Navigate with arrow keys** — `{Up}`, `{Down}` to move through lists/menus
3. **Select with Enter** — `{Enter}` to confirm a selection
4. **Type to filter** — many TUIs support typing to search/filter
5. **Use Tab for completion** — `{Tab}` cycles through options in shells and some TUIs
6. **Cancel/back with Escape** — `{Escape}` to dismiss dialogs or go back
7. **Read again after each action** — always `get-text` to verify the result

**Example: navigating a numbered list and selecting item 3:**
```bash
attyx send-keys -p "$id" "3{Enter}"
```

**Example: scrolling down in a TUI and selecting:**
```bash
attyx send-keys -p "$id" "{Down}{Down}{Down}{Enter}"
output=$(attyx get-text -p "$id")
```

**Example: searching in fzf-style interface:**
```bash
attyx send-keys -p "$id" "search query"
sleep 0.5  # let filter update
attyx send-keys -p "$id" "{Enter}"
```

**Example: vim/editor interaction:**
```bash
attyx send-keys -p "$id" "ihello world{Escape}:wq{Enter}"
```

### Reading Output — Use `--wait-stable`
Instead of blind `sleep N && attyx get-text`, use `--wait-stable` to send keys and automatically wait for output to settle:

```bash
# Send a command and wait for output to stabilize (default: 300ms stable window)
attyx send-keys --wait-stable "ls -la{Enter}"

# Custom stability window (500ms) for slower commands
attyx send-keys --wait-stable 500 "make build{Enter}"

# With pane targeting
attyx send-keys -p 3 --wait-stable "cargo test{Enter}"
```

`--wait-stable [ms]` sends the keys, then polls `get-text` every 50ms until screen content is unchanged for `ms` milliseconds (default 300). The final screen content is printed to stdout. Hard timeout at 30s.

For quick commands where you don't need the output, plain `send-keys` without `--wait-stable` is fine. Use `--wait-stable` when you need to read the result.

### Pane Targeting (Preferred)
Almost all commands support `--pane` (`-p`) to target any pane by its stable ID:
```bash
# IO
attyx send-keys -p 3 "ls -la{Enter}"  # send to pane 3
attyx get-text -p 3                   # read from pane 3

# Split management
attyx split close -p 5               # close pane 5
attyx split zoom -p 5                # toggle zoom on pane 5
attyx split rotate -p 3              # rotate splits in pane 3's tab

# Tab management (positional tab number)
attyx tab close 3                     # close tab 3
attyx tab rename 2 "build logs"       # rename tab 2
```
Pane IDs are flat integers shown in `attyx list` output. This avoids focus juggling and is the recommended approach.

### Focus Management (Legacy)
Without `--pane`, `send-keys` and `get-text` operate on the focused pane:
1. `attyx focus <direction>` to switch to it
2. Do your `send-keys` / `get-text`
3. Focus back if needed

## Argument Handling

If the user provides arguments, interpret them as a natural language instruction:
- `/attyx open a split with htop` → `attyx split v --cmd htop`
- `/attyx send "hello" to the other pane` → `attyx send-keys -p <id> "hello{Enter}"`
- `/attyx close the other pane` → `attyx split close -p <id>`
- `/attyx what's on screen in the right pane` → `attyx get-text -p <id>`
- `/attyx create a background session for ~/Projects/api` → `attyx session create ~/Projects/api -b`
- `/attyx list sessions` → `attyx session list`
- `/attyx create a tab in session 5` → `attyx -s 5 tab create`

If no arguments, ask the user what they'd like to do with the terminal.
