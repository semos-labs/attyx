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
    xyron,
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
    if (std.mem.endsWith(u8, shell_path, "/zsh") or
        std.mem.endsWith(u8, shell_path, "\\zsh.exe") or
        std.mem.eql(u8, shell_path, "zsh.exe") or
        std.mem.eql(u8, shell_path, "zsh")) return .zsh;
    if (std.mem.endsWith(u8, shell_path, "/bash") or
        std.mem.endsWith(u8, shell_path, "\\bash.exe") or
        std.mem.eql(u8, shell_path, "bash.exe") or
        std.mem.eql(u8, shell_path, "bash")) return .bash;
    if (std.mem.endsWith(u8, shell_path, "/fish") or std.mem.eql(u8, shell_path, "fish")) return .fish;
    if (std.mem.endsWith(u8, shell_path, "/nu") or std.mem.eql(u8, shell_path, "nu")) return .nushell;
    if (std.mem.endsWith(u8, shell_path, "/xyron") or std.mem.eql(u8, shell_path, "xyron")) return .xyron;
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
        .xyron => setupXyron(home, exe_dir),
        .posix_sh => setupPosixSh(home, exe_dir),
        .powershell, .cmd => .{},
    };
}

// ---------------------------------------------------------------------------
// Windows shell integration — script content generation
// ---------------------------------------------------------------------------

const win_scripts = @import("shell_scripts_windows.zig");
const posix_scripts = @import("shell_scripts_posix.zig");

pub const powershell_script = win_scripts.powershell_script;
pub const cmd_prompt_string = win_scripts.cmd_prompt_string;
pub const bash_login_profile = win_scripts.bash_login_profile;

pub fn getPowerShellScript() []const u8 {
    return powershell_script;
}

pub fn getBashScript() []const u8 {
    return bash_script;
}

pub fn getCmdPromptString() []const u8 {
    return cmd_prompt_string;
}

/// Generate the integration script path for a given shell on Windows.
/// Writes into the provided buffer. Returns the slice or null on failure.
pub fn windowsScriptPath(buf: []u8, shell: Shell) ?[]const u8 {
    // Use %LOCALAPPDATA%\attyx\shell-integration\ as base
    const base = "shell-integration";
    const suffix: []const u8 = switch (shell) {
        .powershell => "powershell\\attyx.ps1",
        .bash => "bash\\bashrc",
        .cmd => "cmd\\attyx_prompt.cmd",
        .zsh => "zsh\\.zshenv",
        else => return null,
    };
    return std.fmt.bufPrint(buf, "{s}\\{s}", .{ base, suffix }) catch null;
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

    // Write .zshrc wrapper — sources user's .zshrc then re-installs hooks
    // so they survive frameworks (oh-my-zsh, etc.) that reset the arrays.
    var zshrc_buf: [600]u8 = undefined;
    const zshrc_path = std.fmt.bufPrintZ(
        &zshrc_buf,
        "{s}/.zshrc",
        .{integ_dir},
    ) catch return .{};
    writeScript(zshrc_path, zsh_rc_script);

    // Write .zprofile wrapper — sources user's .zprofile.
    var zprofile_buf: [600]u8 = undefined;
    const zprofile_path = std.fmt.bufPrintZ(
        &zprofile_buf,
        "{s}/.zprofile",
        .{integ_dir},
    ) catch return .{};
    writeScript(zprofile_path, zsh_profile_script);

    // Write .zlogin wrapper — sources user's .zlogin.
    var zlogin_buf: [600]u8 = undefined;
    const zlogin_path = std.fmt.bufPrintZ(
        &zlogin_buf,
        "{s}/.zlogin",
        .{integ_dir},
    ) catch return .{};
    writeScript(zlogin_path, zsh_login_script);

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

/// Xyron is not POSIX and uses Lua for scripting, so it can't source one of
/// our shell init scripts. Instead, xyron itself reads __ATTYX_STARTUP_CMD,
/// emits OSC events natively (when ATTYX=1), and inherits PATH directly.
/// We make `attyx` reachable on PATH and drop a managed Lua module (wired into
/// config.lua) that drives the agent-status dot via xyron's command hooks —
/// xyron emits cwd/path natively but not agent-status.
fn setupXyron(home: []const u8, exe_dir: []const u8) ArgvOverride {
    appendExeDirToPath(exe_dir);
    installXyronStatus(home);
    return .{};
}

/// Write ~/.config/xyron/attyx_status.lua and ensure config.lua requires it.
/// Resolves the config dir like xyron does (XDG_CONFIG_HOME, else ~/.config).
fn installXyronStatus(home: []const u8) void {
    var dir_buf: [600]u8 = undefined;
    const dir = blk: {
        if (posix_ffi.getenv("XDG_CONFIG_HOME")) |xdg| {
            break :blk std.fmt.bufPrintZ(&dir_buf, "{s}/xyron", .{std.mem.sliceTo(xdg, 0)}) catch return;
        }
        break :blk std.fmt.bufPrintZ(&dir_buf, "{s}/.config/xyron", .{home}) catch return;
    };
    mkdirp(dir);

    var mod_buf: [700]u8 = undefined;
    const mod_path = std.fmt.bufPrintZ(&mod_buf, "{s}/attyx_status.lua", .{dir}) catch return;
    writeScript(mod_path, posix_scripts.xyron_status_lua);

    var cfg_buf: [700]u8 = undefined;
    const cfg_path = std.fmt.bufPrintZ(&cfg_buf, "{s}/config.lua", .{dir}) catch return;
    ensureXyronRequire(cfg_path);
}

/// Append the require line to config.lua unless it's already present (idempotent).
/// Creates config.lua if it doesn't exist.
fn ensureXyronRequire(path: [*:0]const u8) void {
    var read_buf: [64 * 1024]u8 = undefined;
    if (std.fs.openFileAbsoluteZ(path, .{})) |f| {
        defer f.close();
        const n = f.readAll(&read_buf) catch 0;
        if (std.mem.indexOf(u8, read_buf[0..n], "attyx_status") != null) return;
    } else |_| {}

    const f = std.fs.createFileAbsoluteZ(path, .{ .truncate = false }) catch return;
    defer f.close();
    f.seekFromEnd(0) catch {};
    f.writeAll(posix_scripts.xyron_require_line) catch {};
}

// ---------------------------------------------------------------------------
// Shell scripts
// ---------------------------------------------------------------------------

pub const zsh_script = posix_scripts.zsh_script;
pub const zsh_rc_script = posix_scripts.zsh_rc_script;
pub const zsh_profile_script = posix_scripts.zsh_profile_script;
pub const zsh_login_script = posix_scripts.zsh_login_script;
pub const bash_script = posix_scripts.bash_script;
pub const fish_script = posix_scripts.fish_script;
const nushell_script = posix_scripts.nushell_script;

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

test "detectShell — zsh on Windows" {
    const testing = std.testing;
    try testing.expectEqual(Shell.zsh, detectShell("zsh.exe"));
    try testing.expectEqual(Shell.zsh, detectShell("C:\\attyx\\share\\msys2\\usr\\bin\\zsh.exe"));
}

test "detectShell — Git Bash uses bash integration" {
    const testing = std.testing;
    // Git Bash on Windows uses /usr/bin/bash or /bin/bash inside MSYS2
    try testing.expectEqual(Shell.bash, detectShell("/usr/bin/bash"));
    try testing.expectEqual(Shell.bash, detectShell("/bin/bash"));
    try testing.expectEqual(Shell.bash, detectShell("bash"));
    // Git Bash accessed via Windows path
    try testing.expectEqual(Shell.bash, detectShell("C:\\Program Files\\Git\\bin\\bash.exe"));
    try testing.expectEqual(Shell.bash, detectShell("bash.exe"));
}

test "PowerShell script contains OSC sequences" {
    const testing = std.testing;
    const script = getPowerShellScript();
    // Must contain OSC 7337 for PATH reporting
    try testing.expect(std.mem.indexOf(u8, script, "7337;set-path;") != null);
    // Must contain OSC 7 for CWD reporting
    try testing.expect(std.mem.indexOf(u8, script, "]7;file://") != null);
    // Must handle __ATTYX_BIN_DIR
    try testing.expect(std.mem.indexOf(u8, script, "__ATTYX_BIN_DIR") != null);
    // Must handle startup command
    try testing.expect(std.mem.indexOf(u8, script, "__ATTYX_STARTUP_CMD") != null);
}

test "cmd.exe PROMPT string contains OSC 7" {
    const testing = std.testing;
    const prompt = getCmdPromptString();
    // Must contain OSC 7 escape for CWD
    try testing.expect(std.mem.indexOf(u8, prompt, "$e]7;file://") != null);
    // Must contain $p for current directory
    try testing.expect(std.mem.indexOf(u8, prompt, "$p") != null);
    // Must contain PATH reporting via OSC 7337
    try testing.expect(std.mem.indexOf(u8, prompt, "7337;set-path;") != null);
}

test "windowsScriptPath generates correct paths" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;

    const ps_path = windowsScriptPath(&buf, .powershell);
    try testing.expect(ps_path != null);
    try testing.expect(std.mem.endsWith(u8, ps_path.?, "attyx.ps1"));
    try testing.expect(std.mem.indexOf(u8, ps_path.?, "powershell") != null);

    const cmd_path = windowsScriptPath(&buf, .cmd);
    try testing.expect(cmd_path != null);
    try testing.expect(std.mem.endsWith(u8, cmd_path.?, "attyx_prompt.cmd"));

    const bash_path = windowsScriptPath(&buf, .bash);
    try testing.expect(bash_path != null);
    try testing.expect(std.mem.endsWith(u8, bash_path.?, "bashrc"));
    try testing.expect(std.mem.indexOf(u8, bash_path.?, "bash") != null);

    const zsh_path = windowsScriptPath(&buf, .zsh);
    try testing.expect(zsh_path != null);
    try testing.expect(std.mem.endsWith(u8, zsh_path.?, ".zshenv"));

    // Non-Windows shells return null
    try testing.expectEqual(@as(?[]const u8, null), windowsScriptPath(&buf, .fish));
}

test "PowerShell script uses semicolons for PATH separator" {
    const testing = std.testing;
    const script = getPowerShellScript();
    // Windows PATH uses semicolons, not colons
    try testing.expect(std.mem.indexOf(u8, script, "$env:__ATTYX_BIN_DIR;$env:PATH") != null);
}
