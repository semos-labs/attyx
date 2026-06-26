---
name: attyx
description: Control the Attyx terminal via IPC — manage splits, send input, read output, track and watch agent status, orchestrate panes. Use when the user asks to interact with terminal panes, run commands in splits, monitor AI agents running in panes, or coordinate multi-pane workflows.
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

### Always Pin Your Session
The user can switch sessions at any time. If you send commands without `-s`, they'll hit whatever session is currently focused — which may not be yours.

**At the start of every interaction**, discover your session and pane IDs and use them for all subsequent commands:
```bash
# Step 1: Find your session and pane from the full tree
attyx list
# Output:
# Session 1 "myapp" *          ← your session (marked *)
#   1	bash	*	80x24        ← your pane (marked *)
#   3	python		40x24
# Session 2 "server"
#   4	bash	*	80x24

# Step 2: Use -s <session_id> on EVERY command from now on
attyx -s 1 split v --cmd htop
attyx -s 1 send-keys -p 3 "print('hi'){Enter}"
attyx -s 1 get-text -p 3
attyx -s 1 tab create
```

**Never omit `-s`** after the initial discovery. Even if you think you're still in the same session, always be explicit — the user may have switched focus between your commands.

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

### Reading Scrollback History — `--lines` / `-n`
By default `get-text` returns only the visible screen. To capture more (like `tail -N` over the pane's scrollback + screen), pass `--lines N` / `-n N`:

```bash
attyx get-text -n 100              # last 100 rows from focused pane
attyx get-text -p 3 -n 500         # last 500 rows from pane 3
attyx -s 1 get-text -p 5 -n 1000   # last 1000 rows from pane 5 in session 1
```

The count is clamped to the pane's available scrollback depth. Use this when a long-running command's output has scrolled off-screen, or when you need to inspect history beyond the current viewport.

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
attyx get-text -p 3                   # read visible screen from pane 3
attyx get-text -p 3 -n 200            # last 200 rows (scrollback + screen)

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

## Tracking Agents — Status & Watching

Attyx tracks the run state of AI agents (Claude Code, Codex, etc.) running inside panes. An agent reports one of four states:

| State | Meaning |
|-------|---------|
| `idle` | Parked, waiting for the next prompt |
| `working` | Actively processing a request |
| `input` | Blocked on you (a permission prompt or question) |
| `none` | No agent running, or the agent's session ended |

### Listing active agents — `list agents`
`attyx list agents` lists every pane currently running an agent (any state except `none`). Use `--json` for a machine-readable array:

```bash
attyx list agents
# pane_id  tab_id  session  pid    state    message
# 3        3       1        48213  working  Editing parser.zig
# 8        7       1        48455  input    Approve running tests?

attyx list agents --json
# [{"pane_id":3,"tab_id":3,"session":1,"pid":48213,"state":"working","message":"Editing parser.zig",
#   "usage":{"input_tokens":7199162,"output_tokens":320836,"context_used":82000,"context_max":200000,
#            "cost_usd":0.4213,"cost_is_estimate":false,"model":"claude-opus-4-8"}},
#  {"pane_id":8,"tab_id":7,"session":1,"pid":48455,"state":"input","message":"Approve running tests?","usage":{}}]
```

Fields: `pane_id` (stable ID of the agent's pane — use for targeting), `tab_id` (stable ID of the agent's tab; in attyx a tab is identified by its focused pane's id — the same `pane:N` shown by `attyx list` — so for a single-pane tab `tab_id == pane_id`), `session`, `pid` (the agent's foreground process id; `0` when unknown, e.g. daemon-backed panes), `state`, `message` (the agent's latest status preview, may be empty), and `usage` (token/cost/context telemetry — see below). Default scope is the attached/local session.

**`usage` object.** Present on every record (possibly `{}` before the agent reports anything). Only known fields appear — an absent field means *unknown*, never zero, so don't treat a missing `cost_usd` as free. Fields: `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `reasoning_tokens` (cumulative for the session), `context_used` / `context_max` (current context window), `cost_usd`, `cost_is_estimate` (`true` when attyx computed cost from a built-in price table because the agent didn't report one — Codex), and `model`. Coverage varies by agent (Claude/opencode/Pi report cost directly; Codex is estimated; Codex pre-Sep-2025 builds and some gaps report no usage at all). The TSV form (`list agents` without `--json`) appends these as fixed trailing columns after `message` — `in out cr cw rsn ctx ctxmax cost model` — empty for unknowns; the leading columns are unchanged.

A live table of the same data is available in-app via the **agent dashboard** overlay (`Cmd+Shift+A` on macOS, or the `agent_dashboard` command in the palette). Add `-s <id>` to list any session's agents directly from the daemon — it works even when no window is attached to that session:

```bash
attyx -s 2 list agents             # agents in session 2
attyx -s 2 list agents --json
```

For per-session counts across **all** daemon sessions, use `attyx list sessions`.

### Watching for changes — `watch agents`
`attyx watch agents` opens a long-lived stream and prints one JSON object per line (NDJSON) every time an agent's status changes. On connect it first emits a snapshot of the current active agents, then live changes. It blocks until interrupted — pipe it or run it in the background:

```bash
attyx watch agents
# {"pane_id":3,"tab_id":3,"session":1,"pid":48213,"state":"working","message":"..."}
# {"pane_id":3,"tab_id":3,"session":1,"pid":48213,"state":"input","message":"Needs your input"}
# {"pane_id":8,"tab_id":7,"session":1,"pid":48455,"state":"idle","message":""}

# React to agents that need attention
attyx watch agents | while read -r line; do
  echo "$line" | grep -q '"state":"input"' && notify-send "Agent needs input"
done
```

Unlike `list agents`, the watch stream **includes** transitions to `state:"none"` so you can tell when an agent's session ends. Use `watch agents` instead of polling `list agents` in a loop — it's push-based and won't miss fast transitions.

Like `list agents`, the stream defaults to the attached/local session. Add `-s <id>` to watch a specific session straight from the daemon, regardless of which session a window is showing (or whether any window is attached):

```bash
attyx -s 2 watch agents            # stream session 2's agents
```

### Watching a single agent — `--pane` / `-p`
To follow just one agent instead of all of them, pass its stable pane ID with `-p`. The snapshot and the live stream are both filtered to that pane:
```bash
attyx watch agents -p 3             # only pane 3's agent
# {"pane_id":3,"tab_id":3,"session":1,"pid":48213,"state":"working","message":"..."}
# {"pane_id":3,"tab_id":3,"session":1,"pid":48213,"state":"idle","message":""}

# Block until a specific agent finishes its current turn
attyx watch agents -p 3 | while read -r line; do
  echo "$line" | grep -q '"state":"idle"' && break
done
```
The pane ID is the `pane_id` from `attyx list agents` (or the ID returned when you created the pane). `0`/omitted means all agents.

### Checking a single agent
To check one pane's agent without streaming, pass its stable pane ID:
```bash
attyx list agents -p 3              # just pane 3's agent (one line, or empty if none)
attyx list agents -p 3 --json      # same, as a JSON array
```
`-p`/`--pane` works on both `list agents` and `watch agents`; omit it for all agents.

## Argument Handling

If the user provides arguments, interpret them as a natural language instruction. Remember to always use `-s <session_id>` (discovered via `attyx list` at start):
- `/attyx open a split with htop` → `attyx -s <sid> split v --cmd htop`
- `/attyx send "hello" to the other pane` → `attyx -s <sid> send-keys -p <id> "hello{Enter}"`
- `/attyx close the other pane` → `attyx -s <sid> split close -p <id>`
- `/attyx what's on screen in the right pane` → `attyx -s <sid> get-text -p <id>`
- `/attyx create a background session for ~/Projects/api` → `attyx session create ~/Projects/api -b`
- `/attyx list sessions` → `attyx session list`
- `/attyx create a tab in session 5` → `attyx -s 5 tab create`
- `/attyx which agents are running` → `attyx list agents`
- `/attyx tell me when an agent needs input` → `attyx watch agents` (filter for `"state":"input"`)
- `/attyx watch the agent in pane 3` → `attyx watch agents -p 3`

If no arguments, ask the user what they'd like to do with the terminal.
