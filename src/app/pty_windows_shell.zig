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

    // Get current PATH.
    const path_name = comptime toUtf16Literal("PATH");
    var old_path: [32768]u16 = undefined;
    const old_len = GetEnvironmentVariableW(&path_name, &old_path, @intCast(old_path.len));

    // Build new PATH: exe_dir + ";" + old_path.
    var new_path: [32768]u16 = undefined;
    var pos: usize = 0;
    @memcpy(new_path[0..dir_len], exe_path[0..dir_len]);
    pos = dir_len;
    if (old_len > 0) {
        new_path[pos] = ';';
        pos += 1;
        const copy_len = @min(old_len, new_path.len - pos - 1);
        @memcpy(new_path[pos .. pos + copy_len], old_path[0..copy_len]);
        pos += copy_len;
    }
    new_path[pos] = 0;
    _ = SetEnvironmentVariableW(&path_name, new_path[0..pos :0]);
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

    const shell = shell_integration.detectShell(cmd_utf8);
    switch (shell) {
        .cmd => {
            setEnvW("PROMPT", shell_integration.cmd_prompt_string);
        },
        .powershell => {
            const script = shell_integration.getPowerShellScript();
            const script_path = writeIntegrationScript("powershell\\attyx.ps1", script) orelse return;
            appendPowerShellArgs(cmd_line, script_path);
        },
        .bash => {
            // Git Bash needs --login for proper MSYS2 profile setup (PS1, PATH, etc).
            // --rcfile conflicts with --login and causes cursor/clear issues under ConPTY.
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

/// Append " -ExecutionPolicy Bypass -NoExit -File \"<script_path>\"" to the
/// PowerShell command line. -ExecutionPolicy Bypass is scoped to this process
/// only and avoids the default Restricted policy blocking our integration script.
fn appendPowerShellArgs(cmd_line: [*:0]u16, script_path: [*:0]const u16) void {
    var pos: usize = 0;
    while (cmd_line[pos] != 0) : (pos += 1) {}

    const args = comptime toUtf16Literal(" -ExecutionPolicy Bypass -NoExit -File \"");
    const quote = comptime toUtf16Literal("\"");

    var sp_len: usize = 0;
    while (script_path[sp_len] != 0) : (sp_len += 1) {}

    // Check we have room (4096 buf in buildCommandLine).
    if (pos + args.len + sp_len + quote.len >= 4095) return;

    @memcpy(cmd_line[pos .. pos + args.len], &args);
    pos += args.len;
    @memcpy(cmd_line[pos .. pos + sp_len], script_path[0..sp_len]);
    pos += sp_len;
    @memcpy(cmd_line[pos .. pos + quote.len], &quote);
    pos += quote.len;
    cmd_line[pos] = 0;
}

// ── Tests ──

test "toUtf16Literal basic" {
    const w = toUtf16Literal("hello");
    try std.testing.expectEqual(@as(u16, 'h'), w[0]);
    try std.testing.expectEqual(@as(u16, 'o'), w[4]);
    try std.testing.expectEqual(@as(u16, 0), w[5]);
}
