/// Shell integration — detect user's shell and inject PATH reporting hooks.
///
/// Each shell gets an init script that:
/// 1. Appends the attyx binary dir to PATH
/// 2. Emits OSC 7337;set-path on every prompt so popups get the full PATH
/// 3. Reports CWD via OSC 7
///
/// On POSIX: called from the fork child in pty_posix.zig before execvp.
/// On Windows: shell integration is handled differently (Phase 1+).
const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

// POSIX-only extern declarations — guarded so they don't resolve on Windows.
const posix_ffi = if (!is_windows) struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    extern "c" fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;
    extern "c" fn readlink(path: [*:0]const u8, buf: [*]u8, bufsiz: usize) isize;
} else struct {};

pub const Shell = enum {
    zsh,
    bash,
    fish,
    nushell,
    posix_sh,
    powershell,
    cmd,
};

/// Extra argv entries to insert after argv[0] for shells that need them.
pub const ArgvOverride = struct {
    extra: [4]?[*:0]const u8 = .{ null, null, null, null },
    count: u8 = 0,
};

/// Detect the user's shell from $SHELL or a given path.
pub fn detectShell(shell_path: []const u8) Shell {
    if (std.mem.endsWith(u8, shell_path, "/zsh") or std.mem.eql(u8, shell_path, "zsh")) return .zsh;
    if (std.mem.endsWith(u8, shell_path, "/bash") or std.mem.eql(u8, shell_path, "bash")) return .bash;
    if (std.mem.endsWith(u8, shell_path, "/fish") or std.mem.eql(u8, shell_path, "fish")) return .fish;
    if (std.mem.endsWith(u8, shell_path, "/nu") or std.mem.eql(u8, shell_path, "nu")) return .nushell;
    // Windows shells
    if (std.mem.endsWith(u8, shell_path, "\\pwsh.exe") or
        std.mem.endsWith(u8, shell_path, "\\powershell.exe") or
        std.mem.eql(u8, shell_path, "pwsh.exe") or
        std.mem.eql(u8, shell_path, "powershell.exe") or
        std.mem.eql(u8, shell_path, "pwsh")) return .powershell;
    if (std.mem.endsWith(u8, shell_path, "\\cmd.exe") or
        std.mem.eql(u8, shell_path, "cmd.exe") or
        std.mem.eql(u8, shell_path, "cmd")) return .cmd;
    return .posix_sh;
}

/// Set up shell integration for the current fork child.
/// Returns an ArgvOverride with extra args to insert after argv[0] (e.g. --rcfile for bash).
/// All string pointers are backed by static buffers valid until execvp.
/// On Windows, this is a no-op — shell integration will be handled via ConPTY env vars.
pub fn setup() ArgvOverride {
    if (comptime is_windows) return .{};

    var exe_buf: [1024]u8 = undefined;
    const exe_dir = getExeDir(&exe_buf) orelse return .{};

    // Set __ATTYX_BIN_DIR for integration scripts
    var dir_buf: [1024]u8 = undefined;
    const dir_z = std.fmt.bufPrintZ(&dir_buf, "{s}", .{exe_dir}) catch return .{};
    _ = posix_ffi.setenv("__ATTYX_BIN_DIR", dir_z, 1);

    const shell = std.mem.sliceTo(posix_ffi.getenv("SHELL") orelse "/bin/sh", 0);
    const shell_type = detectShell(shell);

    const home = std.mem.sliceTo(posix_ffi.getenv("HOME") orelse return .{}, 0);

    return switch (shell_type) {
        .zsh => setupZsh(home),
        .bash => setupBash(home),
        .fish => setupFish(home),
        .nushell => setupNushell(home),
        .posix_sh => setupPosixSh(home, exe_dir),
        .powershell, .cmd => .{},
    };
}

// ---------------------------------------------------------------------------
// Per-shell setup (POSIX only — guarded at call site)
// ---------------------------------------------------------------------------

fn setupZsh(home: []const u8) ArgvOverride {
    var integ_dir_buf: [512]u8 = undefined;
    const integ_dir = std.fmt.bufPrintZ(
        &integ_dir_buf,
        "{s}/.config/attyx/shell-integration/zsh",
        .{home},
    ) catch return .{};

    mkdirp(integ_dir);

    var zshenv_buf: [600]u8 = undefined;
    const zshenv_path = std.fmt.bufPrintZ(
        &zshenv_buf,
        "{s}/.zshenv",
        .{integ_dir},
    ) catch return .{};
    writeScript(zshenv_path, zsh_script);

    // Save and override ZDOTDIR
    const orig_zdotdir = posix_ffi.getenv("ZDOTDIR");
    if (orig_zdotdir) |zd| {
        _ = posix_ffi.setenv("__ATTYX_ORIGINAL_ZDOTDIR", zd, 1);
    } else {
        _ = posix_ffi.setenv("__ATTYX_ORIGINAL_ZDOTDIR", "", 1);
    }
    _ = posix_ffi.setenv("ZDOTDIR", integ_dir, 1);

    return .{};
}

fn setupBash(home: []const u8) ArgvOverride {
    var integ_dir_buf: [512]u8 = undefined;
    const integ_dir = std.fmt.bufPrintZ(
        &integ_dir_buf,
        "{s}/.config/attyx/shell-integration/bash",
        .{home},
    ) catch return .{};

    mkdirp(integ_dir);

    // Static buffer for rcfile path — must survive until execvp
    const rcfile_path = std.fmt.bufPrintZ(
        &bash_rcfile_buf,
        "{s}/bashrc",
        .{integ_dir},
    ) catch return .{};
    writeScript(rcfile_path, bash_script);

    // Also set BASH_ENV for non-interactive subshells
    _ = posix_ffi.setenv("BASH_ENV", rcfile_path, 1);

    return .{
        .extra = .{ @ptrCast(bash_rcfile_flag.ptr), @ptrCast(rcfile_path.ptr), null, null },
        .count = 2,
    };
}

fn setupFish(home: []const u8) ArgvOverride {
    var integ_dir_buf: [512]u8 = undefined;
    const integ_dir = std.fmt.bufPrintZ(
        &integ_dir_buf,
        "{s}/.config/attyx/shell-integration/fish",
        .{home},
    ) catch return .{};

    // fish vendor_conf.d structure
    var vendor_dir_buf: [600]u8 = undefined;
    const vendor_dir = std.fmt.bufPrintZ(
        &vendor_dir_buf,
        "{s}/fish/vendor_conf.d",
        .{integ_dir},
    ) catch return .{};
    mkdirp(vendor_dir);

    var script_buf: [700]u8 = undefined;
    const script_path = std.fmt.bufPrintZ(
        &script_buf,
        "{s}/attyx.fish",
        .{vendor_dir},
    ) catch return .{};
    writeScript(script_path, fish_script);

    // Prepend our dir to XDG_DATA_DIRS so fish finds vendor_conf.d
    const existing_xdg = std.mem.sliceTo(posix_ffi.getenv("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share", 0);
    var xdg_buf: [4096]u8 = undefined;
    const new_xdg = std.fmt.bufPrintZ(&xdg_buf, "{s}:{s}", .{ integ_dir, existing_xdg }) catch return .{};
    _ = posix_ffi.setenv("XDG_DATA_DIRS", new_xdg, 1);

    return .{};
}

fn setupNushell(home: []const u8) ArgvOverride {
    var integ_dir_buf: [512]u8 = undefined;
    const integ_dir = std.fmt.bufPrintZ(
        &integ_dir_buf,
        "{s}/.config/attyx/shell-integration/nu",
        .{home},
    ) catch return .{};

    mkdirp(integ_dir);

    const env_path = std.fmt.bufPrintZ(
        &nu_env_buf,
        "{s}/env.nu",
        .{integ_dir},
    ) catch return .{};
    writeScript(env_path, nushell_script);

    return .{
        .extra = .{ @ptrCast(nu_env_config_flag.ptr), @ptrCast(env_path.ptr), null, null },
        .count = 2,
    };
}

fn setupPosixSh(_: []const u8, exe_dir: []const u8) ArgvOverride {
    // POSIX sh: best-effort direct PATH append + ENV for one-shot reporting
    appendExeDirToPath(exe_dir);
    return .{};
}

// ---------------------------------------------------------------------------
// Shell scripts
// ---------------------------------------------------------------------------

const zsh_script =
    \\#!/bin/zsh
    \\# Attyx shell integration (zsh)
    \\if [[ -n "$__ATTYX_ORIGINAL_ZDOTDIR" ]]; then
    \\  ZDOTDIR="$__ATTYX_ORIGINAL_ZDOTDIR"
    \\elif [[ -z "$__ATTYX_ORIGINAL_ZDOTDIR" ]]; then
    \\  ZDOTDIR="$HOME"
    \\fi
    \\unset __ATTYX_ORIGINAL_ZDOTDIR
    \\if [[ -n "$__ATTYX_BIN_DIR" ]] && [[ ":$PATH:" != *":$__ATTYX_BIN_DIR:"* ]]; then
    \\  export PATH="$__ATTYX_BIN_DIR:$PATH"
    \\fi
    \\unset __ATTYX_BIN_DIR
    \\# OSC 7: report cwd on directory changes and on every prompt
    \\# Write to stderr so OSC sequences reach the terminal even when stdout
    \\# is redirected (e.g. --wait capture pipe).
    \\__attyx_chpwd() { printf '\e]7;file://%s%s\a' "${HOST}" "${PWD}" >&2 }
    \\[[ -z "${chpwd_functions[(r)__attyx_chpwd]}" ]] && chpwd_functions+=(__attyx_chpwd)
    \\# OSC 7337: report PATH for popup commands
    \\__attyx_report_path() { printf '\e]7337;set-path;%s\a' "$PATH" >&2 }
    \\# Execute startup command after full shell init, then remove the hook
    \\__attyx_startup() {
    \\  __attyx_chpwd; __attyx_report_path
    \\  if [[ -n "$__ATTYX_STARTUP_CMD" ]]; then
    \\    local cmd="$__ATTYX_STARTUP_CMD"
    \\    unset __ATTYX_STARTUP_CMD
    \\    eval "$cmd"
    \\  fi
    \\}
    \\__attyx_precmd() { __attyx_chpwd; __attyx_report_path }
    \\# Run startup hook once on first prompt, then switch to normal precmd
    \\__attyx_first_precmd() {
    \\  __attyx_startup
    \\  precmd_functions=(${precmd_functions:#__attyx_first_precmd} __attyx_precmd)
    \\}
    \\[[ -z "${precmd_functions[(r)__attyx_first_precmd]}" ]] && precmd_functions+=(__attyx_first_precmd)
    \\[[ -f "$ZDOTDIR/.zshenv" ]] && source "$ZDOTDIR/.zshenv"
    \\__attyx_chpwd
    \\
;

const bash_script =
    \\# Attyx shell integration (bash)
    \\# Source the real rc files first
    \\if [ -f /etc/profile ]; then . /etc/profile; fi
    \\if [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi
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

const fish_script =
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
    \\__attyx_chpwd
    \\
;

const nushell_script =
    \\# Attyx shell integration (nushell)
    \\$env.config = ($env.config? | default {} | merge {
    \\  hooks: {
    \\    pre_prompt: [{ ||
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
    \\  }
    \\})
    \\# Append attyx bin dir to PATH
    \\if ($env.__ATTYX_BIN_DIR? | is-not-empty) {
    \\  $env.PATH = ($env.PATH | prepend $env.__ATTYX_BIN_DIR)
    \\  hide-env __ATTYX_BIN_DIR
    \\}
    \\
;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Static buffers for argv strings that must survive until execvp.
var bash_rcfile_buf: [600]u8 = undefined;
const bash_rcfile_flag: [:0]const u8 = "--rcfile";
var nu_env_buf: [600]u8 = undefined;
const nu_env_config_flag: [:0]const u8 = "--env-config";

fn appendExeDirToPath(exe_dir: []const u8) void {
    const existing = std.mem.sliceTo(posix_ffi.getenv("PATH") orelse "/usr/bin:/bin", 0);
    if (std.mem.indexOf(u8, existing, exe_dir) != null) return;
    var path_buf: [4096]u8 = undefined;
    const new_path = std.fmt.bufPrintZ(&path_buf, "{s}:{s}", .{
        exe_dir, existing,
    }) catch return;
    _ = posix_ffi.setenv("PATH", new_path, 1);
}

fn writeScript(path: [*:0]const u8, content: []const u8) void {
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    }, 0o644) catch return;
    defer std.posix.close(fd);
    _ = std.posix.write(fd, content) catch {};
}

/// Recursively create directories (like mkdir -p). Best-effort.
fn mkdirp(path_z: [*:0]const u8) void {
    const path = std.mem.sliceTo(path_z, 0);
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') {
            var component_buf: [512]u8 = undefined;
            if (i >= component_buf.len) return;
            @memcpy(component_buf[0..i], path[0..i]);
            component_buf[i] = 0;
            _ = std.posix.mkdiratZ(
                std.posix.AT.FDCWD,
                @ptrCast(&component_buf),
                0o755,
            ) catch {};
        }
    }
    _ = std.posix.mkdiratZ(std.posix.AT.FDCWD, path_z, 0o755) catch {};
}

fn getExeDir(buf: *[1024]u8) ?[]const u8 {
    const exe_path = getExePath(buf) orelse return null;
    var last_slash: usize = 0;
    for (exe_path, 0..) |ch, i| {
        if (ch == '/') last_slash = i;
    }
    if (last_slash == 0) return null;
    return exe_path[0..last_slash];
}

fn getExePath(buf: *[1024]u8) ?[]const u8 {
    if (comptime builtin.os.tag == .macos) {
        var size: u32 = buf.len;
        if (posix_ffi._NSGetExecutablePath(buf, &size) == 0) {
            return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(buf)), 0);
        }
    } else if (comptime is_windows) {
        // Windows exe path resolution (Phase 1+)
        return null;
    } else {
        const n = posix_ffi.readlink("/proc/self/exe", buf, buf.len);
        if (n > 0) {
            return buf[0..@intCast(n)];
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "detectShell" {
    const testing = std.testing;
    try testing.expectEqual(Shell.zsh, detectShell("/bin/zsh"));
    try testing.expectEqual(Shell.zsh, detectShell("/usr/local/bin/zsh"));
    try testing.expectEqual(Shell.zsh, detectShell("zsh"));
    try testing.expectEqual(Shell.bash, detectShell("/bin/bash"));
    try testing.expectEqual(Shell.bash, detectShell("/usr/bin/bash"));
    try testing.expectEqual(Shell.bash, detectShell("bash"));
    try testing.expectEqual(Shell.fish, detectShell("/usr/bin/fish"));
    try testing.expectEqual(Shell.fish, detectShell("fish"));
    try testing.expectEqual(Shell.nushell, detectShell("/usr/bin/nu"));
    try testing.expectEqual(Shell.nushell, detectShell("nu"));
    try testing.expectEqual(Shell.posix_sh, detectShell("/bin/sh"));
    try testing.expectEqual(Shell.posix_sh, detectShell("/bin/dash"));
    try testing.expectEqual(Shell.posix_sh, detectShell("/usr/bin/unknown"));
    // Windows shells
    try testing.expectEqual(Shell.powershell, detectShell("pwsh.exe"));
    try testing.expectEqual(Shell.powershell, detectShell("powershell.exe"));
    try testing.expectEqual(Shell.powershell, detectShell("pwsh"));
    try testing.expectEqual(Shell.powershell, detectShell("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"));
    try testing.expectEqual(Shell.cmd, detectShell("cmd.exe"));
    try testing.expectEqual(Shell.cmd, detectShell("cmd"));
    try testing.expectEqual(Shell.cmd, detectShell("C:\\Windows\\System32\\cmd.exe"));
}
