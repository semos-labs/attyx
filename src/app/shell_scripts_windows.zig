/// Windows shell integration script constants.
/// Extracted from shell_integration.zig to keep file sizes manageable.

/// PowerShell integration script content. Dot-sourced AFTER $PROFILE loads
/// (via -Command ". 'script.ps1'"), so user config is already active.
pub const powershell_script =
    \\# Attyx shell integration (PowerShell 5.1+)
    \\$ESC = [char]27; $BEL = [char]7
    \\# Prepend attyx bin dir to PATH
    \\if ($env:__ATTYX_BIN_DIR -and ($env:PATH -notlike "*$env:__ATTYX_BIN_DIR*")) {
    \\    $env:PATH = "$env:__ATTYX_BIN_DIR;$env:PATH"
    \\}
    \\Remove-Item Env:__ATTYX_BIN_DIR -ErrorAction SilentlyContinue
    \\# Enable predictive IntelliSense (pwsh 7.2+) if not already configured
    \\if (Get-Module PSReadLine -ErrorAction SilentlyContinue) {
    \\    try { $src = (Get-PSReadLineOption).PredictionSource
    \\        if ($src -eq 'None') {
    \\            Set-PSReadLineOption -PredictionSource History 2>$null
    \\        }
    \\    } catch {}
    \\}
    \\# Save the current prompt (after $PROFILE loaded — captures oh-my-posh, Starship, etc.)
    \\$global:__attyx_orig_prompt = $function:prompt
    \\function global:prompt {
    \\    $prevExit = $global:LASTEXITCODE
    \\    $cwd = (Get-Location).Path
    \\    # OSC 7: report CWD
    \\    [Console]::Error.Write("${ESC}]7;file://$($env:COMPUTERNAME)/$($cwd -replace '\\','/')${BEL}")
    \\    # OSC 7337: report PATH for popup commands
    \\    [Console]::Error.Write("${ESC}]7337;set-path;$($env:PATH)${BEL}")
    \\    # OSC 2: set terminal title to current directory
    \\    [Console]::Error.Write("${ESC}]2;$cwd${BEL}")
    \\    # Execute startup command on first prompt
    \\    if ($env:__ATTYX_STARTUP_CMD) {
    \\        $cmd = $env:__ATTYX_STARTUP_CMD
    \\        Remove-Item Env:__ATTYX_STARTUP_CMD -ErrorAction SilentlyContinue
    \\        Invoke-Expression $cmd
    \\    }
    \\    # Restore $LASTEXITCODE so prompt themes see the real exit code
    \\    $global:LASTEXITCODE = $prevExit
    \\    # Call original prompt (oh-my-posh, Starship, or default)
    \\    if ($global:__attyx_orig_prompt) {
    \\        & $global:__attyx_orig_prompt
    \\    } else {
    \\        "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) "
    \\    }
    \\}
    \\
;

/// Generate the cmd.exe PROMPT string that emits OSC 7 for CWD reporting.
/// cmd.exe doesn't support OSC 7337 easily, so we only report CWD.
/// The PROMPT var uses $e for ESC and $p for current directory.
pub const cmd_prompt_string = "$e]7;file://$h/$p$e\\$e]7337;set-path;%PATH%$e\\$p$g";

/// Shadow .bash_profile for the HOME redirect trick on Windows.
/// bash --login reads this from the shadow HOME dir. It immediately restores
/// the real HOME, sources user profiles normally, then injects integration.
pub const bash_login_profile =
    \\# Attyx shell integration — shadow .bash_profile
    \\# Restore real HOME before anything else.
    \\HOME="$__ATTYX_REAL_HOME"
    \\export HOME
    \\unset __ATTYX_REAL_HOME
    \\cd "$HOME"
    \\# Source real user profiles (bash --login precedence order).
    \\if   [ -f "$HOME/.bash_profile" ]; then . "$HOME/.bash_profile"
    \\elif [ -f "$HOME/.bash_login" ];   then . "$HOME/.bash_login"
    \\elif [ -f "$HOME/.profile" ];      then . "$HOME/.profile"
    \\fi
    \\# Append attyx bin dir to PATH
    \\if [ -n "$__ATTYX_BIN_DIR" ] && [ "${PATH#*"$__ATTYX_BIN_DIR"}" = "$PATH" ]; then
    \\  export PATH="$__ATTYX_BIN_DIR:$PATH"
    \\fi
    \\unset __ATTYX_BIN_DIR
    \\# OSC 7: report cwd (stderr so --wait capture pipe doesn't eat it)
    \\__attyx_chpwd() { printf '\e]7;file://%s%s\a' "$(hostname)" "$PWD" >&2; }
    \\# OSC 7337: report PATH for popup commands
    \\__attyx_report_path() { printf '\e]7337;set-path;%s\a' "$PATH" >&2; }
    \\# Execute startup command on first prompt, then remove the hook
    \\__attyx_first_prompt() {
    \\  __attyx_chpwd; __attyx_report_path
    \\  if [ -n "$__ATTYX_STARTUP_CMD" ]; then
    \\    local cmd="$__ATTYX_STARTUP_CMD"
    \\    unset __ATTYX_STARTUP_CMD
    \\    eval "$cmd"
    \\  fi
    \\  PROMPT_COMMAND="__attyx_chpwd;__attyx_report_path${__ATTYX_ORIG_PC:+;$__ATTYX_ORIG_PC}"
    \\  unset __ATTYX_ORIG_PC
    \\}
    \\__ATTYX_ORIG_PC="$PROMPT_COMMAND"
    \\PROMPT_COMMAND="__attyx_first_prompt"
    \\
;

/// WSL bootstrap script — launched via `wsl.exe -- sh <path>`.
/// Detects the user's login shell inside WSL and exec's into it
/// with the appropriate integration hooks already configured.
pub const wsl_bootstrap_script =
    \\#!/bin/sh
    \\# Attyx WSL shell integration bootstrap
    \\INT_DIR="$(cd "$(dirname "$0")" && pwd)"
    \\_shell_name="$(basename "${SHELL:-/bin/bash}")"
    \\export TERM_PROGRAM=attyx
    \\export ATTYX=1
    \\case "$_shell_name" in
    \\  zsh)
    \\    export __ATTYX_ORIGINAL_ZDOTDIR="${ZDOTDIR:-$HOME}"
    \\    export ZDOTDIR="$INT_DIR/zsh"
    \\    exec zsh -l
    \\    ;;
    \\  bash)
    \\    exec bash --rcfile "$INT_DIR/bashrc"
    \\    ;;
    \\  fish)
    \\    if [ -n "$XDG_DATA_DIRS" ]; then
    \\      export XDG_DATA_DIRS="$INT_DIR/fish:$XDG_DATA_DIRS"
    \\    else
    \\      export XDG_DATA_DIRS="$INT_DIR/fish:/usr/local/share:/usr/share"
    \\    fi
    \\    exec fish -l
    \\    ;;
    \\  *)
    \\    exec "${SHELL:-/bin/bash}" -l
    \\    ;;
    \\esac
    \\
;
