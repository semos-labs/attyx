/// Windows shell integration setup — injects env vars / scripts so child
/// processes (cmd.exe, PowerShell) report CWD and PATH via OSC sequences,
/// and so the `attyx` CLI binary is on PATH.
const std = @import("std");
const shell_integration = @import("shell_integration.zig");

const DWORD = std.os.windows.DWORD;
const HANDLE = std.os.windows.HANDLE;
const LPCWSTR = [*:0]const u16;

extern "kernel32" fn GetModuleFileNameW(
    hModule: ?HANDLE,
    lpFilename: [*]u16,
    nSize: DWORD,
) callconv(.winapi) DWORD;

extern "kernel32" fn GetEnvironmentVariableW(
    lpName: LPCWSTR,
    lpBuffer: ?[*]u16,
    nSize: DWORD,
) callconv(.winapi) DWORD;

extern "kernel32" fn SetEnvironmentVariableW(
    lpName: LPCWSTR,
    lpValue: ?LPCWSTR,
) callconv(.winapi) std.os.windows.BOOL;

// ── Public API ──

/// Prepend the directory containing attyx.exe to the PATH env var.
pub fn injectExeDirIntoPath() void {
    var exe_path: [std.fs.max_path_bytes]u16 = undefined;
    const exe_len = GetModuleFileNameW(null, &exe_path, @intCast(exe_path.len));
    if (exe_len == 0) return;

    // Find last backslash to extract directory.
    var dir_len: usize = 0;
    for (0..exe_len) |i| {
        if (exe_path[i] == '\\') dir_len = i;
    }
    if (dir_len == 0) return;

    // Get current PATH. Static buffers — called once at startup, not reentrant.
    const path_name = comptime toUtf16Literal("PATH");
    const S = struct {
        var old_path: [32768]u16 = undefined;
        var new_path: [32768]u16 = undefined;
    };
    const old_len = GetEnvironmentVariableW(&path_name, &S.old_path, @intCast(S.old_path.len));

    // Build new PATH: exe_dir + ";" + old_path.
    var pos: usize = 0;
    @memcpy(S.new_path[0..dir_len], exe_path[0..dir_len]);
    pos = dir_len;
    if (old_len > 0) {
        S.new_path[pos] = ';';
        pos += 1;
        const copy_len = @min(old_len, S.new_path.len - pos - 1);
        @memcpy(S.new_path[pos .. pos + copy_len], S.old_path[0..copy_len]);
        pos += copy_len;
    }
    S.new_path[pos] = 0;
    _ = SetEnvironmentVariableW(&path_name, S.new_path[0..pos :0]);
}

/// Detect shell type from the command line and set up integration:
/// - cmd.exe: set PROMPT env var for OSC 7/7337 reporting
/// - PowerShell: write script, append -ExecutionPolicy Bypass -NoExit -File
/// - bash (Git Bash): append --login for normal login shell behavior
pub fn setupShellIntegration(cmd_line: [*:0]u16) void {
    // Convert command line to UTF-8 for shell detection.
    var utf8_buf: [1024]u8 = undefined;
    var utf8_len: usize = 0;
    var i: usize = 0;
    while (cmd_line[i] != 0 and utf8_len < utf8_buf.len - 4) : (i += 1) {
        const cp: u21 = cmd_line[i];
        const n = std.unicode.utf8Encode(cp, utf8_buf[utf8_len..]) catch break;
        utf8_len += n;
    }
    const cmd_utf8 = utf8_buf[0..utf8_len];

    // WSL is a launcher, not a shell — detect it before shell dispatch.
    if (isWslCommand(cmd_utf8)) {
        setupWslIntegration(cmd_line);
        return;
    }

    const shell = shell_integration.detectShell(cmd_utf8);
    switch (shell) {
        .cmd => {
            setEnvW("PROMPT", shell_integration.cmd_prompt_string);
        },
        .powershell => {
            // Write integration script and point env var to it.
            // Don't use -Command to inject — it suppresses the banner until
            // the script finishes, causing visible startup delay.
            // Instead, set env var so users can opt in via $PROFILE.
            const script = shell_integration.getPowerShellScript();
            const script_path = writeIntegrationScript("powershell\\attyx.ps1", script) orelse return;
            const env_name = comptime toUtf16Literal("__ATTYX_INTEGRATION");
            _ = SetEnvironmentVariableW(&env_name, script_path);
        },
        .bash => {
            // HOME redirect: write a shadow .bash_profile that restores real HOME,
            // sources user profiles, then injects OSC 7/7337 hooks for CWD and PATH
            // reporting. This is the bash equivalent of the ZDOTDIR trick for zsh.
            setupBashHomeRedirect();
            appendLoginFlag(cmd_line);
        },
        .zsh => {
            // ZDOTDIR redirect: write a shadow .zshenv that restores real ZDOTDIR,
            // sources user configs, then injects OSC 7/7337 hooks.
            setupZshZdotdirRedirect();
            appendLoginFlag(cmd_line);
        },
        else => {},
    }
}

// ── Internals ──

fn setEnvW(comptime name: []const u8, comptime value: []const u8) void {
    const name_w = comptime toUtf16Literal(name);
    const value_w = comptime toUtf16Literal(value);
    _ = SetEnvironmentVariableW(&name_w, &value_w);
}

fn toUtf16Literal(comptime s: []const u8) [s.len:0]u16 {
    comptime {
        var result: [s.len:0]u16 = undefined;
        for (s, 0..) |ch, idx| result[idx] = ch;
        return result;
    }
}

/// Write a shell integration script to %LOCALAPPDATA%\attyx\shell-integration\<rel_path>.
/// Returns the full path as a wide string, or null on failure.
fn writeIntegrationScript(comptime rel_path: []const u8, content: []const u8) ?[*:0]const u16 {
    const S = struct {
        var path_buf: [1024:0]u16 = undefined;
    };

    const appdata_name = comptime toUtf16Literal("LOCALAPPDATA");
    var appdata_buf: [512]u16 = undefined;
    const appdata_len = GetEnvironmentVariableW(&appdata_name, &appdata_buf, @intCast(appdata_buf.len));
    if (appdata_len == 0 or appdata_len >= appdata_buf.len) return null;

    const suffix = comptime toUtf16Literal("\\attyx\\shell-integration\\" ++ rel_path);
    if (appdata_len + suffix.len >= S.path_buf.len) return null;
    @memcpy(S.path_buf[0..appdata_len], appdata_buf[0..appdata_len]);
    @memcpy(S.path_buf[appdata_len .. appdata_len + suffix.len], &suffix);
    S.path_buf[appdata_len + suffix.len] = 0;

    // Convert to UTF-8 for std.fs operations.
    var utf8_path: [1024]u8 = undefined;
    var utf8_len: usize = 0;
    var j: usize = 0;
    while (j < appdata_len + suffix.len) : (j += 1) {
        const cp: u21 = S.path_buf[j];
        const n = std.unicode.utf8Encode(cp, utf8_path[utf8_len..]) catch return null;
        utf8_len += n;
    }

    // Ensure parent directories exist.
    if (std.mem.lastIndexOfScalar(u8, utf8_path[0..utf8_len], '\\')) |last_sep| {
        std.fs.makeDirAbsolute(utf8_path[0..last_sep]) catch |err| {
            if (err != error.PathAlreadyExists) {
                makeDirsWindows(utf8_path[0..last_sep]);
            }
        };
    }

    // Skip write if the file already exists with identical content.
    if (std.fs.openFileAbsolute(utf8_path[0..utf8_len], .{})) |existing| {
        defer existing.close();
        const stat = existing.stat() catch null;
        if (stat) |s| {
            if (s.size == content.len) return &S.path_buf;
        }
    } else |_| {}

    const file = std.fs.createFileAbsolute(utf8_path[0..utf8_len], .{}) catch return null;
    defer file.close();
    file.writeAll(content) catch return null;

    return &S.path_buf;
}

fn makeDirsWindows(path: []const u8) void {
    var i: usize = 0;
    while (i < path.len) {
        if (path[i] == '\\' and i > 2) {
            std.fs.makeDirAbsolute(path[0..i]) catch {};
        }
        i += 1;
    }
    std.fs.makeDirAbsolute(path) catch {};
}

/// Set up HOME redirect for bash shell integration.
/// 1. Saves real HOME to __ATTYX_REAL_HOME
/// 2. Writes shadow .bash_profile to %LOCALAPPDATA%\attyx\bash-home\
/// 3. Points HOME at the shadow dir so bash --login sources our profile
fn setupBashHomeRedirect() void {
    const userprofile_name = comptime toUtf16Literal("USERPROFILE");
    const home_name = comptime toUtf16Literal("HOME");

    // If __ATTYX_REAL_HOME is already set, the redirect is active from a
    // previous pane spawn. Skip to avoid corrupting the saved real HOME
    // (HOME now points at the shadow dir).
    {
        const check_env = comptime toUtf16Literal("__ATTYX_REAL_HOME");
        var probe: [4]u16 = undefined;
        if (GetEnvironmentVariableW(&check_env, &probe, @intCast(probe.len)) > 0) return;
    }

    // Get real home — prefer USERPROFILE (always set on Windows), fall back to HOME.
    var real_home: [512]u16 = undefined;
    var real_home_len = GetEnvironmentVariableW(&userprofile_name, &real_home, @intCast(real_home.len));
    if (real_home_len == 0 or real_home_len >= real_home.len) {
        real_home_len = GetEnvironmentVariableW(&home_name, &real_home, @intCast(real_home.len));
    }
    if (real_home_len == 0 or real_home_len >= real_home.len) return;

    // Write shadow .bash_profile to %LOCALAPPDATA%\attyx\bash-home\.bash_profile
    const profile_path = writeIntegrationScript(
        "bash-home\\.bash_profile",
        shell_integration.bash_login_profile,
    ) orelse return;

    // Extract shadow home dir (strip trailing \.bash_profile).
    var shadow_len: usize = 0;
    {
        var j: usize = 0;
        while (profile_path[j] != 0) : (j += 1) {
            if (profile_path[j] == '\\') shadow_len = j;
        }
    }
    if (shadow_len == 0) return;

    // Convert real home to MSYS2-style path for __ATTYX_REAL_HOME.
    // Git Bash's bash expects forward-slash paths: /c/Users/Foo
    var msys_home: [512]u16 = undefined;
    const msys_len = toMsysPath(real_home[0..real_home_len], &msys_home);
    if (msys_len == 0) return;
    msys_home[msys_len] = 0;

    // Set __ATTYX_REAL_HOME to the real home (MSYS path).
    const real_home_env = comptime toUtf16Literal("__ATTYX_REAL_HOME");
    _ = SetEnvironmentVariableW(&real_home_env, msys_home[0..msys_len :0]);

    // Convert shadow dir to MSYS path for HOME.
    var msys_shadow: [512]u16 = undefined;
    const msys_shadow_len = toMsysPath(profile_path[0..shadow_len], &msys_shadow);
    if (msys_shadow_len == 0) return;
    msys_shadow[msys_shadow_len] = 0;

    // Point HOME at the shadow dir.
    _ = SetEnvironmentVariableW(&home_name, msys_shadow[0..msys_shadow_len :0]);
}

/// Set up ZDOTDIR redirect for zsh shell integration on Windows.
/// 1. Saves real ZDOTDIR (or HOME) to __ATTYX_ORIGINAL_ZDOTDIR
/// 2. Writes shadow .zshenv to %LOCALAPPDATA%\attyx\shell-integration\zsh\
/// 3. Points ZDOTDIR at the shadow dir so zsh sources our .zshenv
fn setupZshZdotdirRedirect() void {
    const zdotdir_name = comptime toUtf16Literal("ZDOTDIR");
    const home_name = comptime toUtf16Literal("HOME");
    const userprofile_name = comptime toUtf16Literal("USERPROFILE");

    // If __ATTYX_ORIGINAL_ZDOTDIR is already set, the redirect is active
    // from a previous pane spawn. Don't re-read ZDOTDIR (which now points
    // at the shadow dir) or we'd save the shadow path as the "original",
    // causing infinite .zshenv recursion on the second pane.
    {
        const check_env = comptime toUtf16Literal("__ATTYX_ORIGINAL_ZDOTDIR");
        var probe: [4]u16 = undefined;
        if (GetEnvironmentVariableW(&check_env, &probe, @intCast(probe.len)) > 0) return;
    }

    // Determine the original ZDOTDIR — fallback to HOME, then USERPROFILE.
    var orig_zd: [512]u16 = undefined;
    var orig_zd_len = GetEnvironmentVariableW(&zdotdir_name, &orig_zd, @intCast(orig_zd.len));
    if (orig_zd_len == 0 or orig_zd_len >= orig_zd.len) {
        orig_zd_len = GetEnvironmentVariableW(&home_name, &orig_zd, @intCast(orig_zd.len));
    }
    if (orig_zd_len == 0 or orig_zd_len >= orig_zd.len) {
        orig_zd_len = GetEnvironmentVariableW(&userprofile_name, &orig_zd, @intCast(orig_zd.len));
    }
    if (orig_zd_len == 0 or orig_zd_len >= orig_zd.len) return;

    // Convert original ZDOTDIR to MSYS path and save as __ATTYX_ORIGINAL_ZDOTDIR.
    var msys_orig: [512]u16 = undefined;
    const msys_orig_len = toMsysPath(orig_zd[0..orig_zd_len], &msys_orig);
    if (msys_orig_len == 0) return;
    msys_orig[msys_orig_len] = 0;
    const orig_env = comptime toUtf16Literal("__ATTYX_ORIGINAL_ZDOTDIR");
    _ = SetEnvironmentVariableW(&orig_env, msys_orig[0..msys_orig_len :0]);

    // Write shadow .zshenv — this is the zsh integration script content.
    const script = shell_integration.zsh_script;
    const zshenv_path = writeIntegrationScript("zsh\\.zshenv", script) orelse return;

    // Extract shadow dir (strip trailing \.zshenv).
    var shadow_len: usize = 0;
    {
        var j: usize = 0;
        while (zshenv_path[j] != 0) : (j += 1) {
            if (zshenv_path[j] == '\\') shadow_len = j;
        }
    }
    if (shadow_len == 0) return;

    // Convert shadow dir to MSYS path for ZDOTDIR.
    var msys_shadow: [512]u16 = undefined;
    const msys_shadow_len = toMsysPath(zshenv_path[0..shadow_len], &msys_shadow);
    if (msys_shadow_len == 0) return;
    msys_shadow[msys_shadow_len] = 0;

    // Point ZDOTDIR at the shadow dir.
    _ = SetEnvironmentVariableW(&zdotdir_name, msys_shadow[0..msys_shadow_len :0]);
}

/// Convert a Windows path (C:\Users\Foo) to MSYS2-style (/c/Users/Foo).
/// Returns the length of the converted path in `out`, or 0 on failure.
fn toMsysPath(win_path: []const u16, out: []u16) usize {
    if (win_path.len < 2) return 0;
    // Check for drive letter pattern: X:
    const drive = win_path[0];
    if (win_path[1] != ':') return 0;
    if (out.len < win_path.len + 1) return 0; // need 1 extra for /x vs X:

    // /x
    out[0] = '/';
    // Lowercase the drive letter.
    out[1] = if (drive >= 'A' and drive <= 'Z') drive + ('a' - 'A') else drive;

    var pos: usize = 2;
    var i: usize = 2;
    while (i < win_path.len) : (i += 1) {
        out[pos] = if (win_path[i] == '\\') '/' else win_path[i];
        pos += 1;
    }
    return pos;
}

/// Append " --login" to the bash command line so it starts as a login shell
/// (matching Git Bash's default behavior with proper MSYS2 profile sourcing).
fn appendLoginFlag(cmd_line: [*:0]u16) void {
    var pos: usize = 0;
    while (cmd_line[pos] != 0) : (pos += 1) {}

    const flag = comptime toUtf16Literal(" --login");
    if (pos + flag.len >= 4095) return;

    @memcpy(cmd_line[pos .. pos + flag.len], &flag);
    pos += flag.len;
    cmd_line[pos] = 0;
}

/// Append " -ExecutionPolicy Bypass -NoExit -Command ". '<script_path>'"" to the
/// PowerShell command line. Uses -Command with dot-sourcing (not -File) so that
/// $PROFILE loads automatically — users get their aliases, oh-my-posh, Starship, etc.
/// -ExecutionPolicy Bypass is scoped to this process only.
fn appendPowerShellArgs(cmd_line: [*:0]u16, script_path: [*:0]const u16) void {
    var pos: usize = 0;
    while (cmd_line[pos] != 0) : (pos += 1) {}

    const prefix = comptime toUtf16Literal(" -ExecutionPolicy Bypass -NoExit -Command \". '");
    const suffix = comptime toUtf16Literal("'\"");

    var sp_len: usize = 0;
    while (script_path[sp_len] != 0) : (sp_len += 1) {}

    if (pos + prefix.len + sp_len + suffix.len >= 4095) return;

    @memcpy(cmd_line[pos .. pos + prefix.len], &prefix);
    pos += prefix.len;
    @memcpy(cmd_line[pos .. pos + sp_len], script_path[0..sp_len]);
    pos += sp_len;
    @memcpy(cmd_line[pos .. pos + suffix.len], &suffix);
    pos += suffix.len;
    cmd_line[pos] = 0;
}

// ── WSL integration ──

const win_scripts = @import("shell_scripts_windows.zig");

/// Check if the command string starts with "wsl" (case-insensitive).
fn isWslCommand(cmd: []const u8) bool {
    // Extract first token.
    const exe = blk: {
        for (cmd, 0..) |ch, i| {
            if (ch == ' ') break :blk cmd[0..i];
        }
        break :blk cmd;
    };
    return std.ascii.eqlIgnoreCase(exe, "wsl") or
        std.ascii.eqlIgnoreCase(exe, "wsl.exe");
}

/// Set up shell integration for WSL panes.
/// Writes POSIX integration scripts to %LOCALAPPDATA%\attyx\shell-integration\wsl\
/// and appends `-- sh <wsl_path_to_bootstrap>` to the command line so the inner
/// shell starts with CWD/PATH reporting hooks.
fn setupWslIntegration(cmd_line: [*:0]u16) void {
    // Write bootstrap script.
    const init_path = writeIntegrationScript(
        "wsl\\init.sh",
        win_scripts.wsl_bootstrap_script,
    ) orelse return;

    // Write bash integration.
    _ = writeIntegrationScript("wsl\\bashrc", shell_integration.bash_script);

    // Write zsh integration (full startup chain).
    _ = writeIntegrationScript("wsl\\zsh\\.zshenv", shell_integration.zsh_script);
    _ = writeIntegrationScript("wsl\\zsh\\.zshrc", shell_integration.zsh_rc_script);
    _ = writeIntegrationScript("wsl\\zsh\\.zprofile", shell_integration.zsh_profile_script);
    _ = writeIntegrationScript("wsl\\zsh\\.zlogin", shell_integration.zsh_login_script);

    // Write fish integration (vendor_conf.d structure).
    _ = writeIntegrationScript("wsl\\fish\\fish\\vendor_conf.d\\attyx.fish", shell_integration.fish_script);

    // Convert Windows path of init.sh to WSL path and append exec args.
    appendWslBootstrapArgs(cmd_line, init_path);
}

/// Append " -- sh <wsl_path>" to the WSL command line.
/// The `--` separates WSL flags (like -d Ubuntu) from the Linux command.
fn appendWslBootstrapArgs(cmd_line: [*:0]u16, init_path_w: [*:0]const u16) void {
    // Find end of current command line.
    var pos: usize = 0;
    while (cmd_line[pos] != 0) : (pos += 1) {}

    // Get length of init path.
    var path_len: usize = 0;
    while (init_path_w[path_len] != 0) : (path_len += 1) {}

    // " -- sh " = 7 chars, plus WSL path (slightly longer due to /mnt/ prefix).
    const prefix = comptime toUtf16Literal(" -- sh ");
    const wsl_extra: usize = 4; // "/mnt" replaces drive "X:" — net +2, but /mnt/x/ vs X:\ is +3 chars
    if (pos + prefix.len + path_len + wsl_extra >= 4095) return;

    // Append " -- sh ".
    @memcpy(cmd_line[pos .. pos + prefix.len], &prefix);
    pos += prefix.len;

    // Convert Windows path to WSL path inline: C:\foo\bar → /mnt/c/foo/bar
    const dest: [*]u16 = cmd_line + pos;
    pos += toWslPathUtf16(init_path_w[0..path_len], dest[0 .. 4095 - pos]);
    cmd_line[pos] = 0;
}

/// Convert a Windows UTF-16 path (C:\Users\Foo) to WSL-style (/mnt/c/Users/Foo).
/// Writes into `out` and returns the number of u16 code units written.
fn toWslPathUtf16(win_path: []const u16, out: []u16) usize {
    if (win_path.len < 2) return 0;
    const drive = win_path[0];
    if (win_path[1] != ':') return 0;

    // /mnt/x  = 5 chars, replacing X: = 2 chars → need 3 extra
    const needed = win_path.len + 3;
    if (out.len < needed) return 0;

    // /mnt/
    const mnt = comptime toUtf16Literal("/mnt/");
    @memcpy(out[0..mnt.len], &mnt);
    var pos: usize = mnt.len;

    // Lowercase drive letter.
    out[pos] = if (drive >= 'A' and drive <= 'Z') drive + ('a' - 'A') else drive;
    pos += 1;

    // Copy rest of path, converting backslash to forward slash.
    var i: usize = 2;
    while (i < win_path.len) : (i += 1) {
        out[pos] = if (win_path[i] == '\\') '/' else win_path[i];
        pos += 1;
    }
    return pos;
}

// ── Tests ──

test "toUtf16Literal basic" {
    const w = toUtf16Literal("hello");
    try std.testing.expectEqual(@as(u16, 'h'), w[0]);
    try std.testing.expectEqual(@as(u16, 'o'), w[4]);
    try std.testing.expectEqual(@as(u16, 0), w[5]);
}

test "toMsysPath converts drive paths" {
    // C:\Users\Foo → /c/Users/Foo
    const input = comptime toUtf16Literal("C:\\Users\\Foo");
    var out: [64]u16 = undefined;
    const len = toMsysPath(&input, &out);
    try std.testing.expectEqual(@as(usize, 12), len);
    // /c/Users/Foo
    try std.testing.expectEqual(@as(u16, '/'), out[0]);
    try std.testing.expectEqual(@as(u16, 'c'), out[1]);
    try std.testing.expectEqual(@as(u16, '/'), out[2]);
    try std.testing.expectEqual(@as(u16, 'U'), out[3]);
}

test "toMsysPath lowercase drive letter" {
    const input = comptime toUtf16Literal("D:\\work");
    var out: [64]u16 = undefined;
    const len = toMsysPath(&input, &out);
    try std.testing.expectEqual(@as(usize, 6), len);
    try std.testing.expectEqual(@as(u16, '/'), out[0]);
    try std.testing.expectEqual(@as(u16, 'd'), out[1]);
    try std.testing.expectEqual(@as(u16, '/'), out[2]);
}

test "isWslCommand detects wsl variants" {
    try std.testing.expect(isWslCommand("wsl"));
    try std.testing.expect(isWslCommand("wsl.exe"));
    try std.testing.expect(isWslCommand("WSL"));
    try std.testing.expect(isWslCommand("wsl -d Ubuntu"));
    try std.testing.expect(isWslCommand("WSL.EXE -d Debian"));
    try std.testing.expect(!isWslCommand("bash"));
    try std.testing.expect(!isWslCommand("pwsh.exe"));
    try std.testing.expect(!isWslCommand("wslconfig"));
}

test "toWslPathUtf16 converts drive paths" {
    // C:\Users\Foo → /mnt/c/Users/Foo
    const input = comptime toUtf16Literal("C:\\Users\\Foo");
    var out: [64]u16 = undefined;
    const len = toWslPathUtf16(&input, &out);
    try std.testing.expectEqual(@as(usize, 15), len);
    // /mnt/c/Users/Foo
    try std.testing.expectEqual(@as(u16, '/'), out[0]);
    try std.testing.expectEqual(@as(u16, 'm'), out[1]);
    try std.testing.expectEqual(@as(u16, 'n'), out[2]);
    try std.testing.expectEqual(@as(u16, 't'), out[3]);
    try std.testing.expectEqual(@as(u16, '/'), out[4]);
    try std.testing.expectEqual(@as(u16, 'c'), out[5]);
    try std.testing.expectEqual(@as(u16, '/'), out[6]);
    try std.testing.expectEqual(@as(u16, 'U'), out[7]);
}

test "toWslPathUtf16 lowercase drive letter" {
    const input = comptime toUtf16Literal("D:\\work");
    var out: [64]u16 = undefined;
    const len = toWslPathUtf16(&input, &out);
    try std.testing.expectEqual(@as(usize, 9), len);
    try std.testing.expectEqual(@as(u16, '/'), out[0]);
    try std.testing.expectEqual(@as(u16, 'm'), out[1]);
    try std.testing.expectEqual(@as(u16, 'n'), out[2]);
    try std.testing.expectEqual(@as(u16, 't'), out[3]);
    try std.testing.expectEqual(@as(u16, '/'), out[4]);
    try std.testing.expectEqual(@as(u16, 'd'), out[5]);
}
