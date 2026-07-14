//! POSIX shell integration scripts (zsh/bash/fish/nushell), split out of
//! shell_integration.zig to keep that module under the file-size limit. Mirrors
//! the existing shell_scripts_windows.zig split. These are referenced (and some
//! re-exported) from shell_integration.zig.

pub const zsh_script =
    \\#!/bin/zsh
    \\# Attyx shell integration (zsh .zshenv)
    \\# ZDOTDIR stays pointed at our integration dir so zsh also picks up
    \\# our .zshrc wrapper (which re-installs hooks after user's .zshrc).
    \\# Resolve user's original ZDOTDIR for sourcing their config files.
    \\__ATTYX_ZDOTDIR="${__ATTYX_ORIGINAL_ZDOTDIR:-$HOME}"
    \\if [[ -n "$__ATTYX_BIN_DIR" ]] && [[ ":$PATH:" != *":$__ATTYX_BIN_DIR:"* ]]; then
    \\  export PATH="$__ATTYX_BIN_DIR:$PATH"
    \\fi
    \\unset __ATTYX_BIN_DIR
    \\# OSC 7: report cwd on directory changes and on every prompt
    \\# Write to stderr so OSC sequences reach the terminal even when stdout
    \\# is redirected (e.g. --wait capture pipe).
    \\__attyx_chpwd() { printf '\e]7;file://%s%s\a' "${HOST}" "${PWD}" >&2 }
    \\# OSC 7337: report PATH for popup commands
    \\__attyx_report_path() { printf '\e]7337;set-path;%s\a' "$PATH" >&2 }
    \\# Agent status dot: Codex defers its launch hook to the first turn and has no
    \\# exit hook, and an agent that's killed or Ctrl-C'd fires no stop/end hook. So
    \\# drive the per-tab dot from the shell — idle when a known agent launches,
    \\# cleared when it exits — as a backstop independent of each agent's own hooks.
    \\__attyx_agent_name() {
    \\  local -a words=(${(z)1}); local w base=""
    \\  for w in $words; do
    \\    case $w in (*=*) ;; (sudo|env|command|exec|nohup|nice|time|builtin) ;; (*) base=${w:t}; break ;; esac
    \\  done
    \\  case $base in (codex|claude|opencode|pi) print -r -- $base ;; esac
    \\}
    \\__attyx_preexec() {
    \\  __ATTYX_AGENT=$(__attyx_agent_name "$1")
    \\  [[ -n $__ATTYX_AGENT ]] && printf '\e]7337;agent-status;agent;idle\a' >&2
    \\}
    \\__attyx_agent_clear() {
    \\  [[ -n $__ATTYX_AGENT ]] || return
    \\  printf '\e]7337;agent-status;agent;none\a' >&2; __ATTYX_AGENT=""
    \\}
    \\# Execute startup command after full shell init, then remove the hook
    \\__attyx_startup() {
    \\  __attyx_chpwd; __attyx_report_path
    \\  if [[ -n "$__ATTYX_STARTUP_CMD" ]]; then
    \\    local cmd="$__ATTYX_STARTUP_CMD"
    \\    unset __ATTYX_STARTUP_CMD
    \\    eval "$cmd"
    \\  fi
    \\}
    \\__attyx_precmd() { __attyx_agent_clear; __attyx_chpwd; __attyx_report_path }
    \\# Run startup hook once on first prompt, then switch to normal precmd
    \\__attyx_first_precmd() {
    \\  __attyx_startup
    \\  precmd_functions=(${precmd_functions:#__attyx_first_precmd} __attyx_precmd)
    \\}
    \\# Source user's .zshenv
    \\[[ -f "$__ATTYX_ZDOTDIR/.zshenv" ]] && source "$__ATTYX_ZDOTDIR/.zshenv"
    \\# Sensible history defaults — only set if user hasn't configured them.
    \\# Without these, zsh defaults to SAVEHIST=0 (no history saved to disk).
    \\[[ -z "$HISTFILE" ]] && export HISTFILE="$HOME/.zsh_history"
    \\(( HISTSIZE <= 100 )) && HISTSIZE=10000
    \\(( SAVEHIST <= 0 )) && SAVEHIST=10000
    \\setopt APPEND_HISTORY SHARE_HISTORY HIST_IGNORE_DUPS 2>/dev/null
    \\# Emit initial CWD report
    \\__attyx_chpwd
    \\
;

/// .zshrc wrapper — sources user's .zshrc, then re-installs hooks.
/// This runs AFTER user's .zshrc, so hooks survive frameworks that
/// reset precmd_functions / chpwd_functions (oh-my-zsh, etc.).
pub const zsh_rc_script =
    \\#!/bin/zsh
    \\# Attyx shell integration (zsh .zshrc)
    \\# Restore ZDOTDIR so subsequent zsh invocations use user's config
    \\if [[ -n "$__ATTYX_ORIGINAL_ZDOTDIR" ]]; then
    \\  ZDOTDIR="$__ATTYX_ORIGINAL_ZDOTDIR"
    \\elif [[ -z "$__ATTYX_ORIGINAL_ZDOTDIR" ]]; then
    \\  ZDOTDIR="$HOME"
    \\fi
    \\unset __ATTYX_ORIGINAL_ZDOTDIR
    \\# Source user's .zshrc
    \\[[ -f "$ZDOTDIR/.zshrc" ]] && source "$ZDOTDIR/.zshrc"
    \\# Re-install hooks — user's .zshrc may have reset the arrays
    \\[[ -z "${chpwd_functions[(r)__attyx_chpwd]}" ]] && chpwd_functions+=(__attyx_chpwd)
    \\if [[ -z "${precmd_functions[(r)__attyx_precmd]}" ]] && [[ -z "${precmd_functions[(r)__attyx_first_precmd]}" ]]; then
    \\  precmd_functions+=(__attyx_first_precmd)
    \\fi
    \\[[ -z "${preexec_functions[(r)__attyx_preexec]}" ]] && preexec_functions+=(__attyx_preexec)
    \\
;

/// .zprofile wrapper — sources user's .zprofile.
pub const zsh_profile_script =
    \\#!/bin/zsh
    \\# Attyx shell integration (zsh .zprofile)
    \\__ATTYX_ZDOTDIR="${__ATTYX_ORIGINAL_ZDOTDIR:-$HOME}"
    \\[[ -f "$__ATTYX_ZDOTDIR/.zprofile" ]] && source "$__ATTYX_ZDOTDIR/.zprofile"
    \\
;

/// .zlogin wrapper — sources user's .zlogin.
pub const zsh_login_script =
    \\#!/bin/zsh
    \\# Attyx shell integration (zsh .zlogin)
    \\[[ -f "$ZDOTDIR/.zlogin" ]] && source "$ZDOTDIR/.zlogin"
    \\
;

pub const bash_script =
    \\# Attyx shell integration (bash)
    \\# Source the real rc files first
    \\if [ -f /etc/profile ]; then . /etc/profile; fi
    \\if [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi
    \\# Append attyx bin dir to PATH
    \\if [ -n "${__ATTYX_BIN_DIR:-}" ] && [ "${PATH#*"$__ATTYX_BIN_DIR"}" = "$PATH" ]; then
    \\  export PATH="$__ATTYX_BIN_DIR:$PATH"
    \\fi
    \\unset __ATTYX_BIN_DIR
    \\# OSC 7: report cwd (stderr so --wait capture pipe doesn't eat it)
    \\__attyx_chpwd() { printf '\e]7;file://%s%s\a' "$(hostname)" "$PWD" >&2; }
    \\# OSC 7337: report PATH for popup commands
    \\__attyx_report_path() { printf '\e]7337;set-path;%s\a' "$PATH" >&2; }
    \\# Agent status dot: Codex defers its launch hook to the first turn and has no
    \\# exit hook, and an agent that's killed or Ctrl-C'd fires no stop/end hook. So
    \\# drive the per-tab dot from the shell — idle when a known agent launches (a
    \\# DEBUG trap, the bash preexec), cleared on the next prompt — as a backstop
    \\# independent of each agent's own hooks.
    \\__attyx_agent_name() {
    \\  local -a arr; local tok first="" base; read -ra arr <<< "$1"
    \\  for tok in "${arr[@]}"; do
    \\    case $tok in *=*) ;; sudo|env|command|exec|nohup|nice|time|builtin) ;; *) first=$tok; break ;; esac
    \\  done
    \\  base=${first##*/}
    \\  case $base in codex|claude|opencode|pi) printf '%s' "$base" ;; esac
    \\}
    \\__attyx_preexec() {
    \\  [ -n "${COMP_LINE:-}" ] && return
    \\  # The DEBUG trap fires for every command; skip our own hooks and bail before
    \\  # the agent_name subshell unless an agent name actually appears.
    \\  case "$BASH_COMMAND" in __attyx_*) return ;; *codex*|*claude*|*opencode*|*pi*) ;; *) return ;; esac
    \\  local a; a=$(__attyx_agent_name "$BASH_COMMAND")
    \\  [ -n "$a" ] && { __ATTYX_AGENT=$a; printf '\e]7337;agent-status;agent;idle\a' >&2; }
    \\}
    \\__attyx_agent_clear() {
    \\  [ -n "${__ATTYX_AGENT:-}" ] || return
    \\  printf '\e]7337;agent-status;agent;none\a' >&2; __ATTYX_AGENT=
    \\}
    \\# Execute startup command on first prompt, then remove the hook
    \\__attyx_first_prompt() {
    \\  __attyx_agent_clear; __attyx_chpwd; __attyx_report_path
    \\  if [ -n "${__ATTYX_STARTUP_CMD:-}" ]; then
    \\    local cmd="$__ATTYX_STARTUP_CMD"
    \\    unset __ATTYX_STARTUP_CMD
    \\    eval "$cmd"
    \\  fi
    \\  PROMPT_COMMAND="__attyx_agent_clear;__attyx_chpwd;__attyx_report_path${__ATTYX_ORIG_PC:+;$__ATTYX_ORIG_PC}"
    \\  unset __ATTYX_ORIG_PC
    \\}
    \\__ATTYX_ORIG_PC="${PROMPT_COMMAND:-}"
    \\PROMPT_COMMAND="__attyx_first_prompt"
    \\# Install the preexec DEBUG trap only if the user hasn't set one (bash allows
    \\# a single DEBUG trap; clobbering theirs could break their setup).
    \\[ -z "$(trap -p DEBUG)" ] && trap '__attyx_preexec' DEBUG
    \\
;

pub const fish_script =
    \\# Attyx shell integration (fish)
    \\if set -q __ATTYX_BIN_DIR; and not contains $__ATTYX_BIN_DIR $PATH
    \\  set -gx PATH $__ATTYX_BIN_DIR $PATH
    \\end
    \\set -e __ATTYX_BIN_DIR
    \\# OSC 7: report cwd on directory changes and on every prompt
    \\function __attyx_chpwd --on-variable PWD
    \\  printf '\e]7;file://%s%s\a' (hostname) "$PWD" >&2
    \\end
    \\# Execute startup command on first prompt, then switch to normal hook
    \\function __attyx_first_prompt --on-event fish_prompt
    \\  __attyx_chpwd
    \\  printf '\e]7337;set-path;%s\a' "$PATH" >&2
    \\  if set -q __ATTYX_STARTUP_CMD
    \\    set -l cmd $__ATTYX_STARTUP_CMD
    \\    set -e __ATTYX_STARTUP_CMD
    \\    eval $cmd
    \\  end
    \\  functions -e __attyx_first_prompt
    \\end
    \\# OSC 7337: report PATH for popup commands; also report CWD on prompt
    \\function __attyx_report_path --on-event fish_prompt
    \\  __attyx_chpwd
    \\  printf '\e]7337;set-path;%s\a' "$PATH" >&2
    \\end
    \\# Agent status dot: Codex defers its launch hook to the first turn and has no
    \\# exit hook, and an agent that's killed or Ctrl-C'd fires no stop/end hook. So
    \\# drive the per-tab dot from the shell — idle when a known agent launches,
    \\# cleared when it exits — as a backstop independent of each agent's own hooks.
    \\function __attyx_agent_name --argument-names cmd
    \\  set -l first ""
    \\  for w in (string split -n -- ' ' $cmd)
    \\    string match -q '*=*' -- $w; and continue
    \\    contains -- $w sudo env command exec nohup nice time builtin; and continue
    \\    set first $w; break
    \\  end
    \\  test -n "$first"; or return
    \\  set -l base (string split -- / $first)[-1]
    \\  contains -- $base codex claude opencode pi; and echo $base
    \\end
    \\function __attyx_preexec --on-event fish_preexec
    \\  set -g __ATTYX_AGENT (__attyx_agent_name $argv[1])
    \\  test -n "$__ATTYX_AGENT"; and printf '\e]7337;agent-status;agent;idle\a' >&2
    \\end
    \\function __attyx_postexec --on-event fish_postexec
    \\  test -n "$__ATTYX_AGENT"; or return
    \\  printf '\e]7337;agent-status;agent;none\a' >&2
    \\  set -e __ATTYX_AGENT
    \\end
    \\__attyx_chpwd
    \\
;

pub const nushell_script =
    \\# Attyx shell integration (nushell)
    \\$env.config = ($env.config? | default {} | merge {
    \\  hooks: {
    \\    pre_prompt: [{ ||
    \\      # Agent status dot: clear it when a known agent that we flagged on launch
    \\      # has exited (Codex/an interrupted agent fires no exit hook of its own).
    \\      if ($env.__ATTYX_AGENT? | is-not-empty) {
    \\        print -ne $"\e]7337;agent-status;agent;none\a"
    \\        hide-env __ATTYX_AGENT
    \\      }
    \\      # OSC 7: report cwd (stderr so --wait capture pipe doesn't eat it)
    \\      print -ne $"\e]7;file://(sys host | get hostname)(pwd)\a"
    \\      # OSC 7337: report PATH for popup commands
    \\      print -ne $"\e]7337;set-path;($env.PATH | str join ':')\a"
    \\      # Execute startup command on first prompt
    \\      if ($env.__ATTYX_STARTUP_CMD? | is-not-empty) {
    \\        let cmd = $env.__ATTYX_STARTUP_CMD
    \\        hide-env __ATTYX_STARTUP_CMD
    \\        nu -c $cmd
    \\      }
    \\    }]
    \\    # Show the dot as idle the moment a known agent launches (Codex defers its
    \\    # own launch hook to the first turn, so the dot would otherwise be blank).
    \\    pre_execution: [{ ||
    \\      let words = ((commandline) | split row ' '
    \\        | where {|w| $w !~ '=' }
    \\        | where {|w| $w not-in ['sudo' 'env' 'command' 'exec' 'nohup' 'nice' 'time' 'builtin'] })
    \\      let agent = (if ($words | is-empty) { '' } else {
    \\        let base = ($words | first | path basename)
    \\        if $base in ['codex' 'claude' 'opencode' 'pi'] { $base } else { '' }
    \\      })
    \\      if ($agent | is-not-empty) {
    \\        $env.__ATTYX_AGENT = $agent
    \\        print -ne $"\e]7337;agent-status;agent;idle\a"
    \\      }
    \\    }]
    \\  }
    \\})
    \\# Append attyx bin dir to PATH
    \\if ($env.__ATTYX_BIN_DIR? | is-not-empty) {
    \\  $env.PATH = ($env.PATH | prepend $env.__ATTYX_BIN_DIR)
    \\  hide-env __ATTYX_BIN_DIR
    \\}
    \\
;

/// Xyron is not POSIX and sources no script, but it loads ~/.config/xyron/
/// config.lua and exposes on_command_start/finish hooks. attyx drops this
/// managed module and requires it from config.lua, mirroring the zsh/bash/
/// fish/nu shell backstop: idle when a known agent launches, none when it exits.
pub const xyron_status_lua =
    \\-- Attyx agent-status backstop (managed by attyx; safe to delete).
    \\-- Codex defers its own launch hook to the first turn, so the per-tab status
    \\-- dot wouldn't appear until you prompt it. Drive the dot from the shell:
    \\-- idle when a known agent launches, cleared when it exits.
    \\if xyron.is_attyx() then
    \\  local agents = { codex = true, claude = true, opencode = true, pi = true }
    \\  local wrappers = { sudo = true, env = true, command = true, exec = true,
    \\    nohup = true, nice = true, time = true, builtin = true }
    \\  local function agent_of(raw)
    \\    for word in (raw or ""):gmatch("%S+") do
    \\      if word:find("=", 1, true) then
    \\        -- env assignment prefix, skip
    \\      elseif wrappers[word] then
    \\        -- command wrapper, skip
    \\      else
    \\        local base = word:match("[^/]+$") or word
    \\        return agents[base] and base or nil
    \\      end
    \\    end
    \\    return nil
    \\  end
    \\  local function emit(state)
    \\    io.stderr:write("\27]7337;agent-status;agent;" .. state .. "\7")
    \\  end
    \\  xyron.on("on_command_start", function(d)
    \\    if agent_of(d.raw) then emit("idle") end
    \\  end)
    \\  xyron.on("on_command_finish", function(d)
    \\    if agent_of(d.raw) then emit("none") end
    \\  end)
    \\end
    \\
;

/// The line attyx appends to config.lua so xyron loads xyron_status_lua.
pub const xyron_require_line = "require(\"attyx_status\") -- attyx-managed: agent status dot\n";

const std = @import("std");
const testing = std.testing;

// Every standalone-launching POSIX script must emit the agent-status dot OSC on
// launch (idle) and clear it (none), and detect the three agents. Guards against
// a future edit silently dropping the lifecycle hooks from one shell.
test "each posix script drives the agent-status dot for all agents" {
    const launchers = [_][]const u8{ zsh_script, bash_script, fish_script, nushell_script };
    for (launchers) |s| {
        try testing.expect(std.mem.indexOf(u8, s, "agent-status;agent;idle") != null);
        try testing.expect(std.mem.indexOf(u8, s, "agent-status;agent;none") != null);
        for ([_][]const u8{ "codex", "claude", "opencode", "pi" }) |agent|
            try testing.expect(std.mem.indexOf(u8, s, agent) != null);
    }
}

test "xyron lua module drives the agent-status dot for all agents" {
    try testing.expect(std.mem.indexOf(u8, xyron_status_lua, "agent-status;agent;\" .. state") != null);
    try testing.expect(std.mem.indexOf(u8, xyron_status_lua, "on_command_start") != null);
    try testing.expect(std.mem.indexOf(u8, xyron_status_lua, "on_command_finish") != null);
    try testing.expect(std.mem.indexOf(u8, xyron_status_lua, "is_attyx") != null);
    for ([_][]const u8{ "codex", "claude", "opencode", "pi" }) |agent|
        try testing.expect(std.mem.indexOf(u8, xyron_status_lua, agent) != null);
}

test "zsh registers the preexec hook and bash installs a DEBUG trap" {
    try testing.expect(std.mem.indexOf(u8, zsh_rc_script, "preexec_functions+=(__attyx_preexec)") != null);
    try testing.expect(std.mem.indexOf(u8, bash_script, "trap '__attyx_preexec' DEBUG") != null);
}

// The bash script is sourced by non-interactive shells via BASH_ENV, and the
// DEBUG trap fires while a caller may have `set -u` (nounset) active. Every
// variable the script may dereference before it is guaranteed set must use
// ${x:-} default expansion, or nounset aborts with "unbound variable" on every
// command. Regression guard for the bare forms. See issue #293.
test "bash integration is nounset-safe" {
    // Guarded forms present.
    for ([_][]const u8{
        "${COMP_LINE:-}",
        "${__ATTYX_AGENT:-}",
        "${__ATTYX_STARTUP_CMD:-}",
        "${__ATTYX_BIN_DIR:-}",
        "${PROMPT_COMMAND:-}",
    }) |guarded|
        try testing.expect(std.mem.indexOf(u8, bash_script, guarded) != null);
    // Bare forms that abort under nounset must be gone.
    for ([_][]const u8{
        "[ -n \"$COMP_LINE\" ]",
        "[ -n \"$__ATTYX_AGENT\" ]",
        "[ -n \"$__ATTYX_STARTUP_CMD\" ]",
        "[ -n \"$__ATTYX_BIN_DIR\" ]",
        "__ATTYX_ORIG_PC=\"$PROMPT_COMMAND\"",
    }) |bare|
        try testing.expect(std.mem.indexOf(u8, bash_script, bare) == null);
}
