// Attyx — IPC subcommand help text
//
// Extracted from cli_ipc.zig to keep file sizes under the 600-line limit.

pub const top_level =
    \\Control a running Attyx instance.
    \\
    \\Usage: attyx [--target <pid>] <command> [args...]
    \\
    \\Commands:
    \\  tab          Manage tabs (create, close, switch, move, rename)
    \\  split        Manage pane splits (create, close, rotate, zoom)
    \\  focus        Move focus between panes (up, down, left, right)
    \\  session      Manage daemon sessions (list, create, kill, switch, rename)
    \\  send-keys    Send a key sequence to the active pane
    \\  send-text    Send literal text to the active pane
    \\  get-text     Read text from the active pane
    \\  reload       Reload configuration from disk
    \\  theme        Switch to a named theme
    \\  scroll-to    Scroll the viewport (top, bottom)
    \\  list         Show tabs, panes, and sessions (list tabs, list splits, ...)
    \\  popup        Open a popup terminal overlay
    \\  run          Open a new tab with a command (shorthand for tab create --cmd)
    \\
    \\Global options:
    \\  --target <pid>   Target a specific Attyx instance by PID
    \\  --json           Output in JSON format (default: plain text)
    \\  --help, -h       Show this help (also works on every subcommand)
    \\
    \\Examples:
    \\  attyx tab create --cmd htop
    \\  attyx focus right
    \\  attyx send-text "echo hello"
    \\  attyx reload
    \\  attyx theme dracula
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
    \\  create [--cmd <command>]   Create a new tab (optionally with a command)
    \\  close                      Close the active tab
    \\  next                       Switch to the next tab
    \\  prev                       Switch to the previous tab
    \\  select <1-9>               Switch to tab by number
    \\  move <left|right>          Move the active tab left or right
    \\  rename <name>              Rename the active tab
    \\
    \\Examples:
    \\  attyx tab create
    \\  attyx tab create --cmd htop
    \\  attyx tab select 3
    \\  attyx tab move left
    \\  attyx tab rename "build logs"
    \\
;

pub const tab_create =
    \\Create a new tab.
    \\
    \\Usage: attyx tab create [--cmd <command>]
    \\
    \\Options:
    \\  --cmd <command>   Run a specific command in the new tab
    \\                    (default: your shell)
    \\
    \\Examples:
    \\  attyx tab create
    \\  attyx tab create --cmd htop
    \\  attyx tab create --cmd "tail -f /var/log/syslog"
    \\
;

pub const tab_select =
    \\Switch to a tab by number.
    \\
    \\Usage: attyx tab select <N>
    \\
    \\Arguments:
    \\  N   Tab number, 1 through 9
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
    \\  vertical [--cmd <cmd>]     Split the active pane vertically (side by side)
    \\  horizontal [--cmd <cmd>]   Split the active pane horizontally (top/bottom)
    \\  close                      Close the active pane
    \\  rotate                     Rotate the split layout
    \\  zoom                       Toggle zoom on the active pane
    \\
    \\Aliases:
    \\  v   Same as vertical
    \\  h   Same as horizontal
    \\
    \\Examples:
    \\  attyx split vertical
    \\  attyx split h --cmd htop
    \\  attyx split zoom
    \\
;

pub const split_create =
    \\Split the active pane.
    \\
    \\Usage: attyx split <vertical|horizontal> [--cmd <command>]
    \\
    \\Options:
    \\  --cmd <command>   Run a specific command in the new pane
    \\                    (default: your shell)
    \\
    \\Examples:
    \\  attyx split vertical
    \\  attyx split horizontal --cmd htop
    \\  attyx split v --cmd "tail -f /var/log/syslog"
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
    \\Examples:
    \\  attyx focus right
    \\  attyx focus up
    \\
;

// ── Session ──────────────────────────────────────────────────────────────

pub const session =
    \\Manage daemon sessions.
    \\
    \\Usage: attyx session <command> [args...]
    \\
    \\Commands:
    \\  list                       List all sessions
    \\  create                     Create a new session
    \\  kill <id>                  Kill a session by ID
    \\  switch <id>                Switch to a session by ID
    \\  rename [id] <name>         Rename a session (default: current)
    \\
    \\Examples:
    \\  attyx session list
    \\  attyx session create
    \\  attyx session switch 2
    \\  attyx session rename 1 "dev server"
    \\
;

pub const session_kill =
    \\Kill a session by ID.
    \\
    \\Usage: attyx session kill <id>
    \\
    \\Arguments:
    \\  id   Session ID (use 'attyx session list' to find it)
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
    \\Send a key sequence to the active pane.
    \\
    \\Usage: attyx send-keys <keys>
    \\
    \\The key string is written directly to the pane's PTY.
    \\
    \\Examples:
    \\  attyx send-keys "ls -la\n"
    \\  attyx send-keys "\x03"        # Ctrl-C
    \\
;

pub const send_text =
    \\Send literal text to the active pane.
    \\
    \\Usage: attyx send-text <text>
    \\
    \\The text is written directly to the pane's PTY as-is.
    \\
    \\Examples:
    \\  attyx send-text "echo hello"
    \\  attyx send-text "make build\n"
    \\
;

pub const get_text =
    \\Read text from the active pane.
    \\
    \\Usage: attyx get-text
    \\
    \\Returns the visible text content of the active pane as plain text
    \\(one line per screen row, trailing whitespace trimmed).
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
    \\  top       Scroll to the top of the scrollback buffer
    \\  bottom    Scroll to the bottom (live output)
    \\
;

pub const list =
    \\Show tabs, panes, and sessions in a running Attyx instance.
    \\
    \\Usage: attyx list [target]
    \\
    \\Targets:
    \\  (none)     Show full tab/pane tree (default)
    \\  tabs       List tabs only
    \\  splits     List panes in the active tab
    \\  sessions   List daemon sessions
    \\
    \\Output is tab-separated, one entry per line. Pipe to fzf, awk, etc.
    \\Active items are marked with * in the third column.
    \\
    \\Aliases:
    \\  panes      Same as splits
    \\
    \\Examples:
    \\  attyx list
    \\  attyx list tabs
    \\  attyx list splits
    \\  attyx list tabs | fzf
    \\
;

pub const popup =
    \\Open a popup terminal overlay.
    \\
    \\Usage: attyx popup <command> [options]
    \\
    \\Options:
    \\  --width, -w <1-100>        Width as percentage of terminal (default: 80)
    \\  --height <1-100>           Height as percentage of terminal (default: 80)
    \\  --border, -b <style>       Border style: single, double, rounded, heavy, none
    \\                             (default: rounded)
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
    \\This is a shorthand for 'attyx tab create --cmd <command>'.
    \\
    \\Examples:
    \\  attyx run htop
    \\  attyx run "tail -f /var/log/syslog"
    \\
;
