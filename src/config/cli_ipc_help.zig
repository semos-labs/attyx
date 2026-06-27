// Attyx — IPC subcommand help text
//
// Extracted from cli_ipc.zig to keep file sizes under the 600-line limit.
// These descriptions are read by both humans and AI agents, so be precise
// about formats, escape sequences, and output structure.

pub const top_level =
    \\Control a running Attyx instance.
    \\
    \\These commands talk to the currently focused Attyx window over IPC.
    \\They are designed to be used by both humans and automated tools
    \\(AI agents, scripts, etc.). Use --json for machine-readable output.
    \\
    \\Usage: attyx [--target <pid>] [--session <id>] [--json] <command> [args...]
    \\
    \\Commands:
    \\  tab          Manage tabs (create, close, switch, move, rename)
    \\  split        Manage pane splits (create, close, rotate, zoom)
    \\  focus        Move focus between panes (up, down, left, right)
    \\  session      Manage daemon sessions (list, create, kill, switch, rename)
    \\  send-keys    Send keystrokes to a pane (supports escape sequences)
    \\               Alias: send-text
    \\  get-text     Read visible text from a pane
    \\  send-image   Attach an image file to a pane (e.g. a screenshot)
    \\  reload       Reload configuration from disk
    \\  theme        Switch to a named theme
    \\  scroll-to    Scroll the viewport (top, bottom, page-up, page-down)
    \\  list         Query tabs, panes, sessions, and agents (supports --json)
    \\  watch        Stream agent status/usage changes live (table; --json for NDJSON)
    \\  agent        Drive another agent: send a prompt and await its turn
    \\  popup        Open a popup terminal overlay
    \\  run          Open a new tab with a command (shorthand for tab create --cmd)
    \\
    \\Global options:
    \\  --target <pid>       Target a specific Attyx instance by PID
    \\  -s, --session <id>   Target a specific session directly via the daemon
    \\                       (works without that session being attached)
    \\  --json               Output in JSON format (for scripts and agents)
    \\  --help, -h           Show this help (works on every subcommand)
    \\
    \\Examples:
    \\  attyx tab create                  Open a new shell tab
    \\  attyx tab create --cmd htop       Open a tab running htop
    \\  attyx split vertical --cmd claude Open a vertical split running claude
    \\  attyx focus right                 Move focus to the right pane
    \\  attyx send-keys "ls -la{Enter}"    Type "ls -la" and press Enter
    \\  attyx send-keys -p 3 "ls{Enter}"  Send to pane 3 (no focus change)
    \\  attyx send-keys --wait-stable "ls{Enter}"  Send and wait for output
    \\  attyx get-text                    Read what's on screen
    \\  attyx get-text --pane 5           Read from pane 5
    \\  attyx list --json                 Get structured tab/pane info
    \\  attyx list agents --json          List panes running an agent
    \\  attyx watch agents                Stream agent status changes
    \\  attyx reload                      Hot-reload config from disk
    \\
    \\Pane targeting:
    \\  Most commands accept --pane (-p) to target a specific pane/tab without
    \\  changing focus. Format: a flat pane ID (e.g. 5). Pane IDs are stable — they don't change when
    \\  other panes are closed. Creation commands return the new pane's ID.
    \\  Tab commands (close, rename) accept a positional tab number instead.
    \\  Use 'attyx list' to see pane IDs.
    \\
    \\Typical agent workflow:
    \\  1. id=$(attyx split v --cmd "your-tool")     # open pane, capture stable ID
    \\  2. attyx get-text -p "$id"                   # read its output
    \\  3. attyx send-keys -p "$id" "input{Enter}"     # send input without focus
    \\  4. attyx get-text -p "$id"                   # read the result
    \\  5. attyx split close -p "$id"                # clean up by ID
    \\
    \\Run 'attyx <command> --help' for details on a specific command.
    \\
;

// ── Tab ──────────────────────────────────────────────────────────────────

pub const tab =
    \\Manage tabs in a running Attyx instance.
    \\
    \\Usage: attyx tab <command> [args...]
    \\
    \\Commands:
    \\  create [--cmd <command>]   Create a new tab (returns pane ID)
    \\  close [<N>]                Close tab N (default: active tab)
    \\  next                       Switch to the next tab
    \\  prev                       Switch to the previous tab
    \\  select <1-9>               Switch to tab by number (1-indexed)
    \\  move <left|right>          Reorder the active tab in the tab bar
    \\  rename [<N>] <name>        Set tab title (default: active tab)
    \\
    \\Examples:
    \\  attyx tab create                         New shell tab
    \\  attyx tab create --cmd htop              New tab running htop
    \\  attyx tab create --cmd "tail -f app.log" New tab tailing a log
    \\  attyx tab select 3                       Jump to tab 3
    \\  attyx tab move left                      Move current tab left
    \\  attyx tab rename "build logs"            Set active tab title
    \\  attyx tab rename 2 "build logs"          Set tab 2 title
    \\  attyx tab close                          Close active tab
    \\  attyx tab close 3                        Close tab 3
    \\
;

pub const tab_create =
    \\Create a new tab.
    \\
    \\Usage: attyx tab create [--cmd <command>] [--wait]
    \\
    \\Options:
    \\  --cmd <command>   Run a command in the new tab instead of a bare shell.
    \\                    The command runs inside a full interactive shell, so
    \\                    your PATH and shell config are fully available.
    \\                    When the command exits, the shell remains open.
    \\  --wait, -w        Wait for the command to exit and return its exit code.
    \\                    Requires --cmd. Useful for scripting and automation.
    \\
    \\Examples:
    \\  attyx tab create
    \\  attyx tab create --cmd htop
    \\  attyx tab create --cmd "make test" --wait
    \\  attyx tab create --cmd claude
    \\
;

pub const tab_select =
    \\Switch to a tab by number.
    \\
    \\Usage: attyx tab select <N>
    \\
    \\Arguments:
    \\  N   Tab number (1-indexed). Use 'attyx list tabs' to see tab numbers.
    \\
    \\Examples:
    \\  attyx tab select 1
    \\  attyx tab select 3
    \\
;

pub const tab_move =
    \\Move the active tab left or right in the tab bar.
    \\
    \\Usage: attyx tab move <left|right>
    \\
    \\Examples:
    \\  attyx tab move left
    \\  attyx tab move right
    \\
;

pub const tab_rename =
    \\Rename a tab.
    \\
    \\Usage: attyx tab rename [<N>] <name>
    \\
    \\Arguments:
    \\  N      Tab number (1-indexed, optional — defaults to active tab)
    \\  name   New non-empty tab title. Use quotes for names with spaces.
    \\
    \\Examples:
    \\  attyx tab rename server
    \\  attyx tab rename "build logs"
    \\  attyx tab rename 2 "build logs"
    \\
;

// ── Split ────────────────────────────────────────────────────────────────

pub const split =
    \\Manage pane splits in a running Attyx instance.
    \\
    \\Usage: attyx split <command> [args...]
    \\
    \\Commands:
    \\  vertical [--cmd <cmd>]     Split vertically (returns pane ID)
    \\  horizontal [--cmd <cmd>]   Split horizontally (returns pane ID)
    \\  close [-p <target>]        Close a pane (default: focused pane)
    \\  rotate [-p <target>]       Rotate splits in a tab (default: active tab)
    \\  zoom [-p <target>]         Toggle zoom on a pane (default: focused pane)
    \\
    \\Aliases:
    \\  v   Same as vertical
    \\  h   Same as horizontal
    \\
    \\The --cmd option runs a command inside a full interactive shell, so
    \\your PATH and shell config are fully available. When the command
    \\exits, the shell remains open.
    \\
    \\Examples:
    \\  attyx split vertical                  New shell pane on the right
    \\  attyx split h --cmd htop              Monitoring pane below
    \\  attyx split v --cmd claude            Claude in a side pane
    \\  attyx split zoom                      Toggle zoom on focused pane
    \\  attyx split zoom -p 5                Toggle zoom on pane 5
    \\  attyx split close                     Close focused pane
    \\  attyx split close -p 3               Close pane 3
    \\  attyx split rotate -p 2              Rotate splits in pane 2's tab
    \\
;

pub const split_create =
    \\Split the active pane.
    \\
    \\Usage: attyx split <vertical|horizontal> [--cmd <command>] [--wait]
    \\
    \\Options:
    \\  --cmd <command>   Run a command in the new pane instead of a bare shell.
    \\                    The command runs inside a full interactive shell, so
    \\                    your PATH and shell config are fully available.
    \\                    When the command exits, the shell remains open.
    \\  --wait, -w        Wait for the command to exit and return its exit code.
    \\                    Requires --cmd. Useful for scripting and automation.
    \\
    \\Directions:
    \\  vertical (v)     New pane appears to the right of the current pane
    \\  horizontal (h)   New pane appears below the current pane
    \\
    \\Examples:
    \\  attyx split vertical
    \\  attyx split horizontal --cmd htop
    \\  attyx split v --cmd "make test" --wait
    \\  attyx split v --cmd claude
    \\
;

// ── Focus ────────────────────────────────────────────────────────────────

pub const focus =
    \\Move focus between panes.
    \\
    \\Usage: attyx focus <direction>
    \\
    \\Directions:
    \\  up       Focus the pane above
    \\  down     Focus the pane below
    \\  left     Focus the pane to the left
    \\  right    Focus the pane to the right
    \\
    \\Focus determines which pane receives keystrokes by default.
    \\Use --pane on send-keys to target any pane without changing focus.
    \\
    \\Examples:
    \\  attyx focus right
    \\  attyx focus up
    \\
;

// ── Session ──────────────────────────────────────────────────────────────

pub const session =
    \\Manage daemon sessions.
    \\
    \\Sessions are independent workspaces, each with their own tabs and panes.
    \\They persist across window reconnects.
    \\
    \\Usage: attyx session <command> [args...]
    \\
    \\Commands:
    \\  list                       List all sessions (supports --json)
    \\  create [cwd] [-b] [name]    Create a new session (switches to it by default)
    \\  kill <id>                  Kill a session and all its panes
    \\  switch <id>                Switch the window to a different session
    \\  rename [id] <name>         Rename a session (default: current)
    \\
    \\Examples:
    \\  attyx session list
    \\  attyx session create
    \\  attyx session create ~/Projects/myapp -b "build"
    \\  attyx session switch 2
    \\  attyx session rename "dev server"
    \\  attyx session rename 1 "dev server"
    \\  attyx session kill 3
    \\
;

pub const session_create =
    \\Create a new session.
    \\
    \\Usage: attyx session create [cwd] [-b|--background] [name]
    \\
    \\By default, the window switches to the new session immediately.
    \\Use -b/--background to create the session without switching to it.
    \\
    \\Options:
    \\  -b, --background   Create in the background (don't switch)
    \\
    \\Arguments:
    \\  cwd    Starting directory (optional)
    \\  name   Session name (optional, default: "new")
    \\
    \\Examples:
    \\  attyx session create
    \\  attyx session create ~/Projects/myapp
    \\  attyx session create ~/Projects/myapp "dev server"
    \\  attyx session create ~/Projects/myapp -b "build"
    \\
;

pub const session_kill =
    \\Kill a session by ID.
    \\
    \\Usage: attyx session kill <id>
    \\
    \\This kills all panes in the session and removes it. Use
    \\'attyx session list' to find session IDs.
    \\
    \\Arguments:
    \\  id   Session ID (numeric)
    \\
;

pub const session_switch =
    \\Switch to a session by ID.
    \\
    \\Usage: attyx session switch <id>
    \\
    \\Arguments:
    \\  id   Session ID (use 'attyx session list' to find it)
    \\
;

pub const session_rename =
    \\Rename a session.
    \\
    \\Usage: attyx session rename [id] <name>
    \\
    \\Arguments:
    \\  id     Session ID (optional — defaults to the current session)
    \\  name   New name for the session
    \\
    \\Examples:
    \\  attyx session rename "dev server"
    \\  attyx session rename 1 "dev server"
    \\
;

// ── Standalone commands ──────────────────────────────────────────────────

pub const send_keys =
    \\Send keystrokes to a pane.
    \\
    \\Usage: attyx send-keys [--pane <target>] [--wait-stable [ms]] <keys>
    \\
    \\The key string supports C-style escape sequences. This is the primary
    \\way for agents to type into a terminal pane.
    \\
    \\Aliases: send-text (identical behavior)
    \\
    \\Options:
    \\  --pane, -p <id>       Target a specific pane by its stable ID instead of
    \\                        the focused one. Pane IDs are shown in 'attyx list'
    \\                        output and returned by creation commands.
    \\  --wait-stable [ms]    After sending, poll screen content and wait until it
    \\                        stabilizes, then print the final screen text to stdout.
    \\                        Default: 300ms. Max timeout: 30s.
    \\                        Replaces manual sleep + get-text polling loops.
    \\
    \\Named keys (case-insensitive, inside braces):
    \\  {Enter}      Carriage return         {Tab}        Tab
    \\  {Space}      Space                   {Escape}     Escape
    \\  {Backspace}  Backspace (0x7f)        {Delete}     Delete
    \\  {Up}         Arrow up                {Down}       Arrow down
    \\  {Left}       Arrow left              {Right}      Arrow right
    \\  {Home}       Home                    {End}        End
    \\  {PgUp}       Page Up                 {PgDn}       Page Down
    \\  {Insert}     Insert
    \\  {F1}-{F12}   Function keys
    \\  {Ctrl-a}     Ctrl+A (works for a-z, e.g. {Ctrl-c} = interrupt)
    \\
    \\Modifier combos (prefix with Ctrl-, Shift-, Alt-, combinable):
    \\  {Ctrl-Up}          Ctrl+Arrow (word jump in shells)
    \\  {Ctrl-Shift-Up}    Ctrl+Shift+Arrow
    \\  {Alt-a}            Alt+A (ESC prefix)
    \\  {Shift-Tab}        Backtab (reverse tab)
    \\  {Shift-F5}         Shift+F5
    \\  {Ctrl-Shift-p}     Ctrl+Shift+P (CSI u encoding)
    \\
    \\C-style escape sequences (also supported):
    \\  \n  \t  \r  \e  \xHH  \\  \'  \"  \0  \a  \b
    \\
    \\Examples:
    \\  attyx send-keys "ls -la{Enter}"         Type ls -la and press Enter
    \\  attyx send-keys -p 3 "ls{Enter}"        Send to pane 3 (no focus change)
    \\  attyx send-keys -p 5 "{Ctrl-c}"         Send Ctrl-C to pane 5
    \\  attyx send-keys "{Up}{Enter}"            Arrow up then Enter (rerun last)
    \\  attyx send-keys "q"                      Press q (e.g. to quit less/man)
    \\  attyx send-keys "{Down}{Down}{Enter}"    Navigate a menu: down twice, select
    \\  attyx send-keys "{Tab}{Tab}{Enter}"      Tab through options, then confirm
    \\  attyx send-keys --wait-stable "ls{Enter}"   Send, wait for output, print it
    \\  attyx send-keys --wait-stable 500 "make{Enter}"  500ms stable window
    \\  attyx send-keys "{Escape}:wq{Enter}"     Vim: exit with save
    \\
;

// send_text removed — send-text is now an alias for send-keys (same help)

pub const get_text =
    \\Read visible text (or scrollback history) from a pane.
    \\
    \\Usage: attyx get-text [--pane <target>] [--lines <N>] [--since <cursor>]
    \\                      [--cursor-only] [--json]
    \\
    \\By default, returns the current screen content of the specified pane
    \\(or the focused pane if --pane is not given). With --lines N, returns
    \\the last N rows from scrollback + screen — like `tail -N`.
    \\
    \\Options:
    \\  --pane, -p <id>       Target a specific pane by its stable ID instead of
    \\                        the focused one. Pane IDs are shown in 'attyx list'
    \\                        output and returned by creation commands.
    \\  --lines, -n <N>       Return the last N rows from scrollback + visible
    \\                        screen, instead of just the visible screen. Capped
    \\                        at the pane's scrollback depth.
    \\  --since <cursor>      Incremental capture: return only rows produced since
    \\                        the cursor from a previous read. Use "" to seed
    \\                        (returns the current screen + a starting cursor). The
    \\                        next cursor prints to stderr as `cursor: g<gen>.l<n>`;
    \\                        pass it back next time. Treat it as opaque. With
    \\                        --lines, caps a long catch-up read to the last N rows.
    \\  --cursor-only         With --since, print just the next cursor to stdout
    \\                        (no text) — advance without consuming output.
    \\
    \\Output format (plain text):
    \\  One line per row. Trailing whitespace is trimmed per row. With --since, new
    \\  rows go to stdout and the next cursor to stderr; `truncated` (output
    \\  scrolled past retained scrollback) and `reset` (layout changed — text is a
    \\  fresh baseline) show as stderr notes.
    \\
    \\Output format (--json):
    \\  { "lines": ["row1", "row2", ...] }   — or, with --since:
    \\  { "cursor":"g3.l10581", "text":"...", "truncated":false, "reset":false,
    \\    "rows":2 }
    \\
    \\Examples:
    \\  attyx get-text                         Print screen content
    \\  attyx get-text --pane 3                Read from pane 3
    \\  attyx get-text -n 100                  Last 100 rows (scrollback + screen)
    \\  attyx get-text -p 5 -n 500             Last 500 rows from pane 5
    \\  # Tail a build: seed once, then read only the new output each tick.
    \\  attyx get-text -p 3 --since "" 2>cur   Seed; cursor saved to file `cur`
    \\  attyx get-text -p 3 --since "$(cut -d' ' -f2 cur)" 2>cur   New rows only
    \\
    \\Tip: After running a command with send-keys, wait briefly before
    \\calling get-text to give the command time to produce output.
    \\
;

pub const send_image =
    \\Attach an image file to a pane — as if the file were dragged or pasted in
    \\(e.g. to hand Claude Code a screenshot).
    \\
    \\Usage: attyx send-image <path> [--pane <target>]
    \\
    \\The image's file path is injected into the pane as a bracketed paste; Enter
    \\is NOT pressed, so the agent receives the reference without submitting. The
    \\path must already exist on disk.
    \\
    \\Options:
    \\  --pane, -p <id>   Target a specific pane by its stable ID instead of the
    \\                    focused one (IDs shown in 'attyx list').
    \\
    \\Examples:
    \\  attyx send-image ~/shot.png            Attach to the focused pane
    \\  attyx send-image /tmp/diagram.png -p 3 Attach to pane 3
    \\
;

pub const reload =
    \\Reload configuration from disk.
    \\
    \\Usage: attyx reload
    \\
    \\Re-reads attyx.toml and applies changes that support hot-reload
    \\(cursor shape, font, scrollback, theme, keybindings, etc.).
    \\
;

pub const theme =
    \\Switch to a named theme.
    \\
    \\Usage: attyx theme <name>
    \\
    \\The theme must exist in the theme registry (built-in or in
    \\~/.config/attyx/themes/).
    \\
    \\Examples:
    \\  attyx theme dracula
    \\  attyx theme "catppuccin-mocha"
    \\
;

pub const scroll_to =
    \\Scroll the viewport.
    \\
    \\Usage: attyx scroll-to <position>
    \\
    \\Positions:
    \\  top         Scroll to the top of the scrollback buffer
    \\  bottom      Scroll to the bottom (live output)
    \\  page-up     Scroll one page up
    \\  page-down   Scroll one page down
    \\
    \\Examples:
    \\  attyx scroll-to top
    \\  attyx scroll-to bottom
    \\  attyx scroll-to page-up
    \\
;

pub const list =
    \\Query tabs, panes, and sessions in a running Attyx instance.
    \\
    \\Usage: attyx list [target] [--json]
    \\
    \\Targets:
    \\  (none)     Show full tab/pane tree (default)
    \\  tabs       List tabs only
    \\  splits     List panes in the active tab
    \\  sessions   List daemon sessions
    \\  agents     List panes currently running an agent
    \\
    \\Aliases:
    \\  panes      Same as splits
    \\
    \\Plain text output is tab-separated, one entry per line (tabs/splits/
    \\sessions); active items are marked with * in the third column. The 'agents'
    \\target instead prints an aligned, human-readable table. Use --json for
    \\structured output that's easier to parse.
    \\
    \\The 'agents' target lists panes running an agent (state idle/working/
    \\input). Plain output is an aligned table: PANE, SESSION, STATE, MODEL, IN,
    \\OUT, CTX (used/max), COST, MESSAGE — tokens humanized (1.2M), unknowns shown
    \\as '-'. --json returns the same data with raw numbers: each record has
    \\pane_id, tab_id, session, pid, state, message, and a usage object
    \\(input/output/cache tokens, context_used, context_max, cost_usd +
    \\cost_is_estimate, model); absent fields mean unknown, not zero. tab_id is the
    \\agent's tab's stable handle (its focused pane's id); for a single-pane tab it
    \\equals pane_id. pid is the agent's foreground process id (0 = unknown, e.g.
    \\daemon-backed panes). Pass --pane/-p <id> to list one agent's pane. Default
    \\scope is the attached/local session; add -s/--session <id> to list any
    \\session's agents directly from the daemon (no window needs to be attached).
    \\Use 'list sessions' for per-session counts, or 'watch agents' to stream live.
    \\
    \\Examples:
    \\  attyx list                   Full tab/pane tree
    \\  attyx list tabs              Just tab names and IDs
    \\  attyx list splits            Panes in the active tab
    \\  attyx list sessions          All daemon sessions
    \\  attyx list agents            Panes running an agent
    \\  attyx list agents -p 3       Just pane 3's agent
    \\  attyx list agents -s 2       Agents in session 2
    \\  attyx list agents --json     Agents as a JSON array
    \\  attyx list --json            Full tree as JSON
    \\  attyx list tabs --json       Tabs as JSON
    \\
;

pub const watch =
    \\Stream agent status/usage changes from a running Attyx instance — the live
    \\counterpart of 'list agents', emitting the same data as it changes.
    \\
    \\Usage: attyx watch agents [--json] [--pane <id>] [--session <id>]
    \\
    \\Opens a long-lived connection and emits the current agents as a snapshot,
    \\then one update per change. Blocks until interrupted (Ctrl-C) or the
    \\instance exits.
    \\
    \\Default output is the same aligned table as 'list agents' (a header, then a
    \\row per update). Use --json for one JSON object per line (NDJSON) — the same
    \\record shape as 'list agents --json', including the usage object — ideal for
    \\scripts. A 'none' state means the agent ended.
    \\
    \\Options:
    \\  --json            One NDJSON record per change (machine-readable).
    \\  --pane, -p <id>   Watch only the agent in this pane (by stable pane ID
    \\                    from 'attyx list agents'). Default: all agents.
    \\  --session, -s <id>  Stream a specific session's agents directly from the
    \\                    daemon, regardless of which session a window is showing
    \\                    (or whether any window is attached). Default: the
    \\                    attached/local session.
    \\
    \\Frames for a slow/stuck reader are dropped rather than stalling the
    \\terminal.
    \\
    \\Examples:
    \\  attyx watch agents                 Live table of every agent
    \\  attyx watch agents -p 3            Watch only pane 3's agent
    \\  attyx watch agents -s 2            Watch session 2's agents
    \\  attyx watch agents --json | while read l; do notify-send "$l"; done
    \\
;

pub const popup =
    \\Open a popup terminal overlay.
    \\
    \\Usage: attyx popup <command> [options]
    \\
    \\The popup floats above the terminal content. It closes automatically
    \\when the command exits. Useful for quick interactive tools.
    \\
    \\Options:
    \\  --width, -w <1-100>        Width as % of terminal (default: 80)
    \\  --height <1-100>           Height as % of terminal (default: 80)
    \\  --border, -b <style>       Border style (default: rounded)
    \\                             Styles: single, double, rounded, heavy, none
    \\
    \\Examples:
    \\  attyx popup lazygit
    \\  attyx popup htop --width 90 --height 90
    \\  attyx popup "k9s" --border heavy
    \\  attyx popup fzf --width 60 --height 40 --border none
    \\
;

pub const run =
    \\Open a new tab with a command.
    \\
    \\Usage: attyx run <command> [--wait]
    \\
    \\Shorthand for 'attyx tab create --cmd <command>'.
    \\The command runs inside a full interactive shell, so your PATH and
    \\shell config are fully available. When the command exits, the shell
    \\remains open.
    \\
    \\Options:
    \\  --wait, -w   Wait for the command to exit and return its exit code.
    \\               Useful for scripting: `attyx run "make test" --wait && echo OK`
    \\
    \\Examples:
    \\  attyx run htop
    \\  attyx run "make test" --wait
    \\  attyx run claude
    \\
;

pub const agent =
    \\Drive another agent: send it a prompt and wait for its turn to finish.
    \\
    \\Usage:
    \\  attyx agent send -p <id> "<prompt>" [--wait] [--capture] [--tokens]
    \\                   [--timeout <s>] [--submit-key <key>] [--json]
    \\  attyx agent await -p <id> [--state idle|input|any] [--timeout <s>] [--json]
    \\
    \\`agent send` types the prompt into the pane's agent (as a bracketed paste,
    \\so multi-line prompts and `{`/`}`/`\` are literal) and presses the submit
    \\key. Without --wait it returns immediately. With --wait it blocks until the
    \\agent's turn completes and reports the outcome.
    \\
    \\`agent await` sends nothing — it just blocks until the pane's agent reaches
    \\a state (the formalized `watch agents | while …` pattern).
    \\
    \\Options (send):
    \\  --pane, -p <id>     Target pane (required). From 'attyx list agents'.
    \\  --wait              Block until the turn completes (implied by --capture
    \\                      and --tokens).
    \\  --capture           Include only the output the turn produced (uses
    \\                      get-text --since under the hood).
    \\  --tokens            Include the per-turn token/cost delta.
    \\  --timeout <s>       Stop waiting after N seconds (default 600). The agent
    \\                      is never interrupted — we just stop watching.
    \\  --submit-key <key>  Key that submits the prompt (default {Enter}).
    \\Options (await):
    \\  --pane, -p <id>     Target pane (required).
    \\  --state <s>         Wait for idle (default), input, or any.
    \\  --timeout <s>       Stop waiting after N seconds (default 600).
    \\
    \\Outcomes (and exit codes): done (0) · needs_input (2) · timeout (3) ·
    \\no_turn / ended (4). So `attyx agent send -p 3 "run tests" --wait && deploy`
    \\runs deploy only if the turn finished cleanly.
    \\
    \\Plain output: a one-line summary to stderr; with --capture the turn's output
    \\goes to stdout (so it pipes). --json returns the full result object.
    \\
    \\Examples:
    \\  attyx agent send -p 3 "run the tests and fix failures" --wait
    \\  attyx agent send -p 3 "summarize src/api" --wait --capture --json
    \\  attyx agent await -p 3 --state any        # block until done or needs input
    \\
;
