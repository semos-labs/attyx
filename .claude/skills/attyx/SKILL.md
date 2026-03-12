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

## Critical Rules

### Don't Close Yourself
Before closing a pane, ALWAYS check which pane you're in:
```bash
attyx list splits
```
The pane marked with `*` is the ACTIVE pane — `attyx split close` will close THAT one. To close another pane:
1. `attyx focus <direction>` to move to the target pane
2. `attyx split close` to close it
3. Focus returns to a remaining pane automatically

Your pane is typically the one you started in. Track pane IDs from `attyx list splits` output.

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
Use `--pane` (`-p`) to target any pane without changing focus:
```bash
attyx send-keys --pane 1.0 "ls -la\r"    # tab 1, pane 0
attyx send-keys -p 1 "echo hi\r"          # pane 1 in active tab
attyx get-text --pane 1.0                  # read from tab 1, pane 0
attyx get-text -p 1                        # read from pane 1 in active tab
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
- `/attyx close the other pane` → focus + close (carefully!)
- `/attyx what's on screen in the right pane` → `attyx get-text -p <idx>`

If no arguments, ask the user what they'd like to do with the terminal.
