---
name: attyx
description: Control the Attyx terminal via IPC — manage splits, send input, read output, orchestrate panes. Use when the user asks to interact with terminal panes, run commands in splits, or coordinate multi-pane workflows.
allowed-tools: Bash
argument-hint: [action] [args...]
---

# Attyx Terminal IPC Skill

You are running inside Attyx, a terminal emulator with a full IPC interface. You can control it programmatically.

## Available IPC Commands

!`attyx --help 2>&1 | sed -n '/^IPC commands/,/^$/p'`

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
attyx send-keys -p "$id" "print('hello')\r"
attyx get-text -p "$id"
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
attyx -s 123 send-text "hello" -p 2    # send to pane 2 in session 123
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

### Use \r for Enter, Not \n
When sending input via `send-keys`, always use `\r` (carriage return) to submit:
```bash
attyx send-keys "ls -la\r"
```

### Reading Output — Don't Guess Sleep Times
Instead of blind `sleep N && attyx get-text`, poll until output stabilizes:

```bash
# Wait for command output to stabilize (poll every 2s, 3 stable reads = done)
stable=0; prev=""; for i in $(seq 1 15); do
  sleep 2
  curr=$(attyx get-text 2>/dev/null)
  if [ "$curr" = "$prev" ] && [ -n "$curr" ]; then
    stable=$((stable + 1))
    [ $stable -ge 2 ] && break
  else
    stable=0
  fi
  prev="$curr"
done
echo "$curr"
```

For quick commands (ls, cat, etc.) a simple `sleep 1` is fine. Use polling for anything interactive or slow (builds, AI responses, installs).

### Pane Targeting (Preferred)
Almost all commands support `--pane` (`-p`) to target any pane by its stable ID:
```bash
# IO
attyx send-keys -p 3 "ls -la\r"      # send to pane 3
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
- `/attyx send "hello" to the other pane` → `attyx send-keys -p <id> "hello"`
- `/attyx close the other pane` → `attyx split close -p <id>`
- `/attyx what's on screen in the right pane` → `attyx get-text -p <id>`
- `/attyx create a background session for ~/Projects/api` → `attyx session create ~/Projects/api -b`
- `/attyx list sessions` → `attyx session list`
- `/attyx create a tab in session 5` → `attyx -s 5 tab create`

If no arguments, ask the user what they'd like to do with the terminal.
