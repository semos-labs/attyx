// Attyx — Styled help output
//
// Uses ANSI escape codes for colors/formatting.
// Comptime string concatenation keeps the source readable.

const std = @import("std");

// ── ANSI style tokens ───────────────────────────────────────────────────
const b = "\x1b[1m"; // bold
const d = "\x1b[2m"; // dim
const c = "\x1b[36m"; // cyan
const g = "\x1b[32m"; // green
const y = "\x1b[33m"; // yellow
const m = "\x1b[35m"; // magenta
const r = "\x1b[0m"; // reset
const bc = b ++ c; // bold cyan
const bd = b ++ d; // bold dim

// ── Helpers ─────────────────────────────────────────────────────────────

/// Format an IPC command entry: cyan name + default description
fn cmd(comptime name: []const u8, comptime desc: []const u8) []const u8 {
    return "  " ++ c ++ name ++ r ++ desc ++ "\n";
}

/// Format an option entry: yellow flag + default description
fn opt(comptime flag: []const u8, comptime desc: []const u8) []const u8 {
    return "  " ++ y ++ flag ++ r ++ desc ++ "\n";
}

/// Format a dim example line
fn ex(comptime line: []const u8) []const u8 {
    return "  " ++ d ++ line ++ r ++ "\n";
}

/// Indented continuation line (for multi-line descriptions)
fn cont(comptime line: []const u8) []const u8 {
    return "  " ++ line ++ "\n";
}

// ── Help sections ───────────────────────────────────────────────────────

const title =
    "\n" ++
    bc ++ "  Attyx" ++ r ++ "  GPU-accelerated VT-compatible terminal emulator\n" ++
    "\n";

const usage =
    b ++ "USAGE" ++ r ++ "\n" ++
    "  " ++ c ++ "attyx" ++ r ++ " [options]            Launch terminal\n" ++
    "  " ++ c ++ "attyx" ++ r ++ " <command>            Run a subcommand\n" ++
    "\n";

const commands =
    b ++ "COMMANDS" ++ r ++ "\n" ++
    cmd("login                      ", "Authenticate with Attyx AI services") ++
    cmd("device                     ", "Show device and account info") ++
    cmd("uninstall                  ", "Remove config, auth tokens, and desktop entry") ++
    cmd("skill <install|uninstall>  ", "Install/remove the Claude Code skill") ++
    cmd("daemon                     ", "Run the session daemon") ++
    cmd("kill-daemon                ", "Kill the session daemon and remove socket") ++
    "\n";

const ipc_header =
    b ++ "IPC COMMANDS" ++ r ++ d ++ "  control a running instance, usable by agents/scripts" ++ r ++ "\n" ++
    "\n" ++
    d ++ "  All commands operate on the currently focused Attyx window." ++ r ++ "\n" ++
    d ++ "  Use --json for machine-readable output. Run 'attyx <cmd> --help' for details." ++ r ++ "\n" ++
    "\n";

const ipc_tabs =
    "  " ++ d ++ "Tabs" ++ r ++ "\n" ++
    cmd("tab create [--cmd <cmd>] [--wait]   ", "Create a new tab (returns pane ID)") ++
    cmd("tab close [<N>]                      ", "Close tab N (default: active)") ++
    cmd("tab next" ++ r ++ " / " ++ c ++ "tab prev                  ", "Switch tabs") ++
    cmd("tab select <1-9>                     ", "Switch to tab by number") ++
    cmd("tab move <left|right>                ", "Reorder the active tab") ++
    cmd("tab rename [<N>] <name>              ", "Set tab title (default: active)") ++
    "\n";

const ipc_splits =
    "  " ++ d ++ "Panes" ++ r ++ "\n" ++
    cmd("split vertical [--cmd <cmd>] [--wait]   ", "New pane to the right " ++ d ++ "(alias: v)" ++ r) ++
    cmd("split horizontal [--cmd <cmd>] [--wait]  ", "New pane below " ++ d ++ "(alias: h)" ++ r) ++
    cmd("split close [-p <id>]                    ", "Close a pane (default: focused)") ++
    cmd("split rotate [-p <id>]                   ", "Rotate splits (default: active tab)") ++
    cmd("split zoom [-p <id>]                     ", "Toggle zoom (default: focused)") ++
    "\n";

const ipc_focus =
    "  " ++ d ++ "Focus" ++ r ++ "\n" ++
    cmd("focus <up|down|left|right>           ", "Move focus to a neighboring pane") ++
    "\n";

const ipc_io =
    "  " ++ d ++ "Input / Output" ++ r ++ "\n" ++
    cmd("send-keys [-p <id>] [--wait-stable] <keys>   ", "Send keystrokes to a pane") ++
    cont("                                " ++ d ++ "Named: {Enter} {Up} {Down} {Tab} {Ctrl-c} ... or \\n \\xHH" ++ r) ++
    cmd("get-text [-p <id>] [--json]     ", "Read visible screen text from a pane") ++
    "\n";

const ipc_misc =
    "  " ++ d ++ "Utilities" ++ r ++ "\n" ++
    cmd("list [tabs|splits|sessions] [--json]   ", "Query tabs, panes, or sessions") ++
    cmd("scroll-to <top|bottom|page-up|page-down>   ", "Scroll the viewport") ++
    cmd("reload                 ", "Hot-reload config from disk") ++
    cmd("theme <name>           ", "Switch to a named theme") ++
    cmd("popup <cmd> [-w N] [--height N] [-b <style>]   ", "Floating overlay terminal") ++
    cmd("run <cmd> [--wait]     ", "Open a new tab with a command") ++
    "\n";

const ipc_sessions =
    "  " ++ d ++ "Sessions" ++ r ++ "\n" ++
    cmd("session list           ", "List all daemon sessions") ++
    cmd("session create [cwd] [-b] [name]   ", "Create a session (returns ID)") ++
    cmd("session switch <id>    ", "Switch to a session by ID") ++
    cmd("session rename [id] <name>   ", "Rename a session") ++
    cmd("session kill <id>      ", "Kill a session and all its panes") ++
    "\n";

const agent_workflow =
    b ++ "AGENT WORKFLOW" ++ r ++ "\n" ++
    ex("id=$(attyx split v --cmd \"tool\")    " ++ r ++ d ++ "# open pane, capture ID") ++
    ex("attyx get-text -p \"$id\"             " ++ r ++ d ++ "# read its output") ++
    ex("attyx send-keys -p \"$id\" \"input{Enter}\" " ++ r ++ d ++ "# type into it") ++
    ex("attyx get-text -p \"$id\"             " ++ r ++ d ++ "# read the result") ++
    ex("attyx split close -p \"$id\"          " ++ r ++ d ++ "# clean up by ID") ++
    "\n";

const options =
    b ++ "OPTIONS" ++ r ++ "\n" ++
    opt("--rows N                   ", "Terminal rows (default: 24)") ++
    opt("--cols N                   ", "Terminal cols (default: 80)") ++
    opt("-e, -c, --cmd <command...> ", "Override shell command") ++
    opt("--config <path>            ", "Load config from a specific file") ++
    opt("--no-config                ", "Skip reading config from disk") ++
    opt("--font-family <string>     ", "Font family (default: \"JetBrains Mono\")") ++
    opt("--font-size <int>          ", "Font size in points (default: 14)") ++
    opt("--cell-width <value>       ", "Cell width: points or percent (e.g. \"110%\")") ++
    opt("--cell-height <value>      ", "Cell height: points or percent (e.g. \"115%\")") ++
    opt("--theme <string>           ", "Theme name (default: \"default\")") ++
    opt("--scrollback-lines <int>   ", "Scrollback buffer lines (default: 20000)") ++
    opt("--reflow / --no-reflow     ", "Enable/disable reflow on resize") ++
    opt("--cursor-shape <shape>     ", "Cursor shape: block, beam, underline") ++
    opt("--cursor-blink             ", "Enable cursor blinking " ++ d ++ "(--no-cursor-blink to disable)" ++ r) ++
    opt("--cursor-trail             ", "Enable cursor trail " ++ d ++ "(--no-cursor-trail to disable)" ++ r) ++
    opt("--font-ligatures           ", "Enable ligatures " ++ d ++ "(--no-font-ligatures to disable, default: on)" ++ r) ++
    opt("--shell <path>             ", "Shell program (default: $SHELL or /bin/sh)") ++
    opt("-d, --working-directory    ", "Initial working directory (default: ~)") ++
    opt("--background-opacity <f>   ", "Background opacity 0.0\u{2013}1.0 (default: 1.0)") ++
    opt("--background-blur <int>    ", "Blur radius when opacity < 1 (default: 30)") ++
    opt("--decorations              ", "Show/hide title bar " ++ d ++ "(--no-decorations)" ++ r) ++
    opt("--padding <int>            ", "Window padding on all sides") ++
    opt("--padding-x / --padding-y  ", "Horizontal / vertical padding") ++
    opt("--log-level <level>        ", "Log level: err, warn, info, debug, trace") ++
    opt("--log-file <path>          ", "Append logs to file (default: stderr)") ++
    opt("--print-config             ", "Print merged config and exit") ++
    opt("--help, -h                 ", "Show this help") ++
    "\n";

// ── Public API ──────────────────────────────────────────────────────────

pub const help_text = title ++ usage ++ commands ++
    ipc_header ++ ipc_tabs ++ ipc_splits ++ ipc_focus ++ ipc_io ++ ipc_misc ++ ipc_sessions ++
    agent_workflow ++ options;

/// Plain-text version for non-TTY output and AI consumption.
/// Strips all ANSI escape codes at comptime.
pub const help_text_plain = stripAnsi(help_text);

pub fn printUsage() void {
    // Use styled output when stderr is a terminal, plain otherwise.
    const is_tty = std.fs.File.stderr().isTty();
    const text = if (is_tty) help_text else help_text_plain;
    std.debug.print("{s}", .{text});
}

fn stripAnsi(comptime input: []const u8) []const u8 {
    @setEvalBranchQuota(input.len * 4);
    comptime {
        var out: []const u8 = "";
        var i: usize = 0;
        while (i < input.len) {
            if (input[i] == '\x1b' and i + 1 < input.len and input[i + 1] == '[') {
                // Skip until we find the terminating letter (@ through ~)
                i += 2;
                while (i < input.len and input[i] < 0x40) : (i += 1) {}
                if (i < input.len) i += 1; // skip the terminator
            } else {
                out = out ++ input[i .. i + 1];
                i += 1;
            }
        }
        return out;
    }
}
