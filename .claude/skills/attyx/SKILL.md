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

## Identifying Panes — The Index System

Every pane has an **index** in the format `<tab>.<pane>` (e.g. `1.0`, `2.3`).
- **Tab** is 1-indexed (1, 2, 3, ...).
- **Pane** is 0-indexed within the tab (0, 1, 2, ...). Pane indices are pool-based, NOT sequential — they may be non-contiguous (e.g. 0, 2, 4 instead of 0, 1, 2).

### How to find your own pane
Run `attyx list splits` — the pane marked with `*` is the **active/focused** pane (the one you're running in):
```
0	bash	*	80x24    ← this is YOU (pane 0)
2	python		40x24    ← another pane (pane 2)
```

Or `attyx list` for the full tree with tab context:
```
1	bash	*
  1.0	bash	*	80x24    ← YOU (tab 1, pane 0)
  1.2	python		40x24    ← another pane (tab 1, pane 2)
2	vim
  2.0	vim		80x24
```

### Tracking newly created panes
When you create a tab or split, the command **returns the new pane's index**:
```bash
idx=$(attyx tab create)              # returns e.g. "2.0"
idx=$(attyx tab create --cmd htop)   # returns e.g. "2.0"
idx=$(attyx split v)                 # returns e.g. "1.2"
idx=$(attyx split v --cmd python3)   # returns e.g. "1.2"
```
**Always capture this output** so you can target the pane later without guessing:
```bash
attyx send-keys -p "$idx" "print('hello')\r"
attyx get-text -p "$idx"
```

### Don't confuse titles with identity
Multiple panes can have the same title (e.g. two `bash` panes). **Never rely on title matching** to find a specific pane. Always use indices from `attyx list` or captured from creation.

## Critical Rules

### Don't Close Yourself
Before closing a pane, use targeted close with `--pane` / `-p`:
```bash
attyx split close -p 2              # close pane 2 in active tab
attyx split close -p 1.2            # close pane 2 in tab 1
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
Almost all commands support `--pane` (`-p`) to target any pane without changing focus:
```bash
# IO
attyx send-keys -p 1.0 "ls -la\r"    # send to tab 1, pane 0
attyx get-text -p 1.0                 # read from tab 1, pane 0

# Split management
attyx split close -p 2                # close pane 2 in active tab
attyx split close -p 1.2              # close pane 2 in tab 1
attyx split zoom -p 1.2               # toggle zoom on pane 2 in tab 1
attyx split rotate -p 2.0             # rotate panes in tab 2

# Tab management (positional tab number)
attyx tab close 3                     # close tab 3
attyx tab rename 2 "build logs"       # rename tab 2
```
Format: `<tab>.<pane>` (tab is 1-indexed, pane is 0-indexed) or just `<pane>` for active tab.
Use `attyx list` to see pane indices. This avoids focus juggling and is the recommended approach.

### Focus Management (Legacy)
Without `--pane`, `send-keys` and `get-text` operate on the focused pane:
1. `attyx focus <direction>` to switch to it
2. Do your `send-keys` / `get-text`
3. Focus back if needed

## Argument Handling

If the user provides arguments, interpret them as a natural language instruction:
- `/attyx open a split with htop` → `attyx split v --cmd htop`
- `/attyx send "hello" to the other pane` → `attyx send-keys -p <idx> "hello"`
- `/attyx close the other pane` → `attyx split close -p <idx>`
- `/attyx what's on screen in the right pane` → `attyx get-text -p <idx>`

If no arguments, ask the user what they'd like to do with the terminal.
