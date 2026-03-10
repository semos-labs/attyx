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
    \\Usage: attyx [--target <pid>] [--json] <command> [args...]
    \\
    \\Commands:
    \\  tab          Manage tabs (create, close, switch, move, rename)
    \\  split        Manage pane splits (create, close, rotate, zoom)
    \\  focus        Move focus between panes (up, down, left, right)
    \\  session      Manage daemon sessions (list, create, kill, switch, rename)
    \\  send-keys    Send keystrokes to the active pane (supports escape sequences)
    \\  send-text    Send raw text to the active pane (no escape processing)
    \\  get-text     Read visible text from the active pane
    \\  reload       Reload configuration from disk
    \\  theme        Switch to a named theme
    \\  scroll-to    Scroll the viewport (top, bottom, page-up, page-down)
    \\  list         Query tabs, panes, and sessions (supports --json)
    \\  popup        Open a popup terminal overlay
    \\  run          Open a new tab with a command (shorthand for tab create --cmd)
    \\
    \\Global options:
    \\  --target <pid>   Target a specific Attyx instance by PID
    \\  --json           Output in JSON format (for scripts and agents)
    \\  --help, -h       Show this help (works on every subcommand)
    \\
    \\Examples:
    \\  attyx tab create                  Open a new shell tab
    \\  attyx tab create --cmd htop       Open a tab running htop
    \\  attyx split vertical --cmd claude Open a vertical split running claude
    \\  attyx focus right                 Move focus to the right pane
    \\  attyx send-keys "ls -la\n"        Type "ls -la" and press Enter
    \\  attyx send-text "hello"           Write "hello" to PTY (no newline)
    \\  attyx get-text                    Read what's on screen
    \\  attyx list --json                 Get structured tab/pane info
    \\  attyx reload                      Hot-reload config from disk
    \\
    \\Typical agent workflow:
    \\  1. attyx split vertical --cmd "your-tool"   # open a pane
    \\  2. attyx get-text                            # read its output
    \\  3. attyx send-keys "some input\n"            # interact with it
    \\  4. attyx get-text                            # read the result
    \\  5. attyx split close                         # clean up when done
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
    \\  create [--cmd <command>]   Create a new tab
    \\  close                      Close the active tab
    \\  next                       Switch to the next tab
    \\  prev                       Switch to the previous tab
    \\  select <1-9>               Switch to tab by number (1-indexed)
    \\  move <left|right>          Reorder the active tab in the tab bar
    \\  rename <name>              Set a custom tab title
    \\
    \\Examples:
    \\  attyx tab create                         New shell tab
    \\  attyx tab create --cmd htop              New tab running htop
    \\  attyx tab create --cmd "tail -f app.log" New tab tailing a log
    \\  attyx tab select 3                       Jump to tab 3
    \\  attyx tab move left                      Move current tab left
    \\  attyx tab rename "build logs"            Set tab title
    \\  attyx tab close                          Close current tab
    \\
;

pub const tab_create =
    \\Create a new tab.
    \\
    \\Usage: attyx tab create [--cmd <command>]
    \\
    \\Options:
    \\  --cmd <command>   Run a command in the new tab instead of a bare shell.
    \\                    The command runs inside a full interactive shell, so
    \\                    your PATH and shell config are fully available.
    \\                    When the command exits, the shell remains open.
    \\
    \\Examples:
    \\  attyx tab create
    \\  attyx tab create --cmd htop
    \\  attyx tab create --cmd "tail -f /var/log/syslog"
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
    \\Rename the active tab.
    \\
    \\Usage: attyx tab rename <name>
    \\
    \\The name is displayed in the tab bar. Use quotes for names with spaces.
    \\
    \\Examples:
    \\  attyx tab rename server
    \\  attyx tab rename "build logs"
    \\
;

// ── Split ────────────────────────────────────────────────────────────────

pub const split =
    \\Manage pane splits in a running Attyx instance.
    \\
    \\Usage: attyx split <command> [args...]
    \\
    \\Commands:
    \\  vertical [--cmd <cmd>]     Split vertically (new pane to the right)
    \\  horizontal [--cmd <cmd>]   Split horizontally (new pane below)
    \\  close                      Close the active pane (focus moves to neighbor)
    \\  rotate                     Rotate the split layout
    \\  zoom                       Toggle zoom on the active pane
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
    \\  attyx split zoom                      Toggle pane zoom
    \\  attyx split close                     Close focused pane
    \\
;

pub const split_create =
    \\Split the active pane.
    \\
    \\Usage: attyx split <vertical|horizontal> [--cmd <command>]
    \\
    \\Options:
    \\  --cmd <command>   Run a command in the new pane instead of a bare shell.
    \\                    The command runs inside a full interactive shell, so
    \\                    your PATH and shell config are fully available.
    \\                    When the command exits, the shell remains open.
    \\
    \\Directions:
    \\  vertical (v)     New pane appears to the right of the current pane
    \\  horizontal (h)   New pane appears below the current pane
    \\
    \\Examples:
    \\  attyx split vertical
    \\  attyx split horizontal --cmd htop
    \\  attyx split v --cmd "tail -f /var/log/syslog"
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
    \\Focus determines which pane receives keystrokes from send-keys/send-text.
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
    \\  create                     Create a new empty session
    \\  kill <id>                  Kill a session and all its panes
    \\  switch <id>                Switch the window to a different session
    \\  rename [id] <name>         Rename a session (default: current)
    \\
    \\Examples:
    \\  attyx session list
    \\  attyx session create
    \\  attyx session switch 2
    \\  attyx session rename "dev server"
    \\  attyx session rename 1 "dev server"
    \\  attyx session kill 3
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
    \\Send keystrokes to the active pane.
    \\
    \\Usage: attyx send-keys <keys>
    \\
    \\The key string supports C-style escape sequences. This is the primary
    \\way for agents to type into a terminal pane.
    \\
    \\Escape sequences:
    \\  \n           Enter / newline
    \\  \t           Tab
    \\  \x03         Ctrl-C (interrupt)
    \\  \x04         Ctrl-D (EOF)
    \\  \x1a         Ctrl-Z (suspend)
    \\  \x1b         Escape
    \\  \x1b[A       Arrow up
    \\  \x1b[B       Arrow down
    \\  \x1b[C       Arrow right
    \\  \x1b[D       Arrow left
    \\  \x7f         Backspace
    \\
    \\Examples:
    \\  attyx send-keys "ls -la\n"        Type ls -la and press Enter
    \\  attyx send-keys "\x03"            Send Ctrl-C to interrupt
    \\  attyx send-keys "\x1b"            Send Escape
    \\  attyx send-keys "y\n"             Confirm a prompt
    \\  attyx send-keys "\x1b[A\n"        Arrow up then Enter (rerun last cmd)
    \\  attyx send-keys "q"               Press q (e.g. to quit less/man)
    \\
;

pub const send_text =
    \\Send text to the active pane.
    \\
    \\Usage: attyx send-text <text>
    \\
    \\The text is written to the pane's PTY. Supports the same C-style
    \\escape sequences as send-keys (\n, \t, \x03, etc.).
    \\
    \\Examples:
    \\  attyx send-text "hello"           Write "hello" (no newline)
    \\  attyx send-text "echo hello\n"    Write "echo hello" + Enter
    \\  attyx send-text "yes\n"           Confirm a prompt
    \\
;

pub const get_text =
    \\Read visible text from the active pane.
    \\
    \\Usage: attyx get-text [--json]
    \\
    \\Returns the current screen content of the focused pane. This is what
    \\an agent uses to "see" what's on screen.
    \\
    \\Output format (plain text):
    \\  One line per screen row. Trailing whitespace is trimmed per row.
    \\  Empty trailing rows are omitted.
    \\
    \\Output format (--json):
    \\  { "lines": ["row1", "row2", ...] }
    \\
    \\Examples:
    \\  attyx get-text                    Print screen content
    \\  attyx get-text --json             Get as JSON (for parsing)
    \\
    \\Tip: After running a command with send-keys, wait briefly before
    \\calling get-text to give the command time to produce output.
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
    \\
    \\Aliases:
    \\  panes      Same as splits
    \\
    \\Plain text output is tab-separated, one entry per line.
    \\Active items are marked with * in the third column.
    \\Use --json for structured output that's easier to parse.
    \\
    \\Examples:
    \\  attyx list                   Full tab/pane tree
    \\  attyx list tabs              Just tab names and IDs
    \\  attyx list splits            Panes in the active tab
    \\  attyx list sessions          All daemon sessions
    \\  attyx list --json            Full tree as JSON
    \\  attyx list tabs --json       Tabs as JSON
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
    \\Usage: attyx run <command>
    \\
    \\Shorthand for 'attyx tab create --cmd <command>'.
    \\The command runs inside a full interactive shell, so your PATH and
    \\shell config are fully available. When the command exits, the shell
    \\remains open.
    \\
    \\Examples:
    \\  attyx run htop
    \\  attyx run "tail -f /var/log/syslog"
    \\  attyx run claude
    \\
;
