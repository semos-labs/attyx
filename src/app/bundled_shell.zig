/// Bundled zsh shell discovery and MSYS2 environment setup for Windows.
///
/// Attyx ships a minimal MSYS2 sysroot alongside the binary:
///   <exe_dir>/share/msys2/usr/bin/zsh.exe
///   <exe_dir>/share/msys2/usr/bin/msys-2.0.dll
///   ...
///
/// This module finds the sysroot and configures the process environment
/// so zsh runs correctly under ConPTY.
const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

const DWORD = if (is_windows) std.os.windows.DWORD else u32;
const HANDLE = if (is_windows) std.os.windows.HANDLE else *anyopaque;
const LPCWSTR = [*:0]const u16;

// Windows API imports (guarded)
const win = if (is_windows) struct {
    extern "kernel32" fn GetModuleFileNameW(
        hModule: ?HANDLE,
        lpFilename: [*]u16,
        nSize: DWORD,
    ) callconv(.winapi) DWORD;

    extern "kernel32" fn GetFileAttributesW(
        lpFileName: LPCWSTR,
    ) callconv(.winapi) DWORD;

    extern "kernel32" fn SetEnvironmentVariableW(
        lpName: LPCWSTR,
        lpValue: ?LPCWSTR,
    ) callconv(.winapi) std.os.windows.BOOL;

    extern "kernel32" fn GetEnvironmentVariableW(
        lpName: LPCWSTR,
        lpBuffer: ?[*]u16,
        nSize: DWORD,
    ) callconv(.winapi) DWORD;

    const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFFFFFF;
} else struct {};

// ── Public API ──

/// Result of finding the bundled zsh shell.
pub const BundledZsh = struct {
    /// Full path to zsh.exe as a null-terminated UTF-16 string.
    zsh_path: [*:0]const u16,
    /// Length of the path in UTF-16 code units.
    zsh_len: usize,
};

/// Find the bundled zsh.exe inside the MSYS2 sysroot next to the attyx binary.
/// Returns null if the sysroot or zsh.exe doesn't exist.
pub fn findBundledZsh() ?BundledZsh {
    if (comptime !is_windows) return null;

    const S = struct {
        var zsh_buf: [1024:0]u16 = undefined;
    };

    // Get attyx.exe directory.
    var exe_path: [std.fs.max_path_bytes]u16 = undefined;
    const exe_len = win.GetModuleFileNameW(null, &exe_path, @intCast(exe_path.len));
    if (exe_len == 0) return null;

    // Find last backslash to get directory.
    var dir_len: usize = 0;
    for (0..exe_len) |i| {
        if (exe_path[i] == '\\') dir_len = i;
    }
    if (dir_len == 0) return null;

    // Build path: <exe_dir>\share\msys2\usr\bin\zsh.exe
    const suffix = comptime toUtf16Literal("\\share\\msys2\\usr\\bin\\zsh.exe");
    const total = dir_len + suffix.len;
    if (total >= S.zsh_buf.len) return null;

    @memcpy(S.zsh_buf[0..dir_len], exe_path[0..dir_len]);
    @memcpy(S.zsh_buf[dir_len..total], &suffix);
    S.zsh_buf[total] = 0;

    // Check if zsh.exe actually exists.
    if (win.GetFileAttributesW(&S.zsh_buf) == win.INVALID_FILE_ATTRIBUTES) return null;

    return .{ .zsh_path = &S.zsh_buf, .zsh_len = total };
}

/// Set MSYS2 environment variables required for zsh to function correctly
/// under ConPTY. Must be called before CreateProcessW.
pub fn setupMsysEnv() void {
    if (comptime !is_windows) return;

    // Get attyx.exe directory for sysroot path.
    var exe_path: [std.fs.max_path_bytes]u16 = undefined;
    const exe_len = win.GetModuleFileNameW(null, &exe_path, @intCast(exe_path.len));
    if (exe_len == 0) return;

    var dir_len: usize = 0;
    for (0..exe_len) |i| {
        if (exe_path[i] == '\\') dir_len = i;
    }
    if (dir_len == 0) return;

    // MSYSTEM=MSYS — tells MSYS2 to use the base MSYS environment.
    setEnvW("MSYSTEM", "MSYS");

    // MSYS2_PATH_TYPE=inherit — keeps the Windows PATH visible inside MSYS2.
    setEnvW("MSYS2_PATH_TYPE", "inherit");

    // CHERE_INVOKING=1 — prevents /etc/profile from cd'ing to $HOME.
    setEnvW("CHERE_INVOKING", "1");

    // MSYS=enable_pcon — enable pseudo-console support in msys-2.0.dll.
    setEnvW("MSYS", "enable_pcon");

    // HOME — set to USERPROFILE if not already set, so zsh has a valid ~.
    {
        const home_name = comptime toUtf16Literal("HOME");
        var home_buf: [512]u16 = undefined;
        const home_len = win.GetEnvironmentVariableW(&home_name, &home_buf, @intCast(home_buf.len));
        if (home_len == 0) {
            const userprofile = comptime toUtf16Literal("USERPROFILE");
            var up_buf: [512]u16 = undefined;
            const up_len = win.GetEnvironmentVariableW(&userprofile, &up_buf, @intCast(up_buf.len));
            if (up_len > 0 and up_len < up_buf.len) {
                up_buf[up_len] = 0;
                _ = win.SetEnvironmentVariableW(&home_name, up_buf[0..up_len :0]);
            }
        }
    }

    // Prepend sysroot/usr/bin to PATH so zsh can find coreutils, etc.
    // Also add Git for Windows' usr/bin if installed — provides vi, less,
    // nano, ssh, and other tools that the minimal sysroot doesn't bundle.
    {
        const suffix = comptime toUtf16Literal("\\share\\msys2\\usr\\bin");
        const sysroot_bin_len = dir_len + suffix.len;
        var sysroot_bin: [1024:0]u16 = undefined;
        if (sysroot_bin_len < sysroot_bin.len) {
            @memcpy(sysroot_bin[0..dir_len], exe_path[0..dir_len]);
            @memcpy(sysroot_bin[dir_len..sysroot_bin_len], &suffix);
            sysroot_bin[sysroot_bin_len] = 0;

            const path_name = comptime toUtf16Literal("PATH");
            const P = struct {
                var old_path: [32768]u16 = undefined;
                var new_path: [32768]u16 = undefined;
            };
            const old_len = win.GetEnvironmentVariableW(&path_name, &P.old_path, @intCast(P.old_path.len));

            @memcpy(P.new_path[0..sysroot_bin_len], sysroot_bin[0..sysroot_bin_len]);
            var pos: usize = sysroot_bin_len;

            // Append Git for Windows usr/bin (vi, less, nano, ssh, etc.)
            const git_usr_bin_len = findGitUsrBin(P.new_path[pos + 1 ..]);
            if (git_usr_bin_len > 0) {
                P.new_path[pos] = ';';
                pos += 1 + git_usr_bin_len;
            }

            if (old_len > 0) {
                P.new_path[pos] = ';';
                pos += 1;
                const copy_len = @min(old_len, P.new_path.len - pos - 1);
                @memcpy(P.new_path[pos .. pos + copy_len], P.old_path[0..copy_len]);
                pos += copy_len;
            }
            P.new_path[pos] = 0;
            _ = win.SetEnvironmentVariableW(&path_name, P.new_path[0..pos :0]);
        }
    }
}

/// Get the bundled zsh path as a UTF-8 string. Used by popup spawn.
pub fn findBundledZshUtf8() ?[]const u8 {
    const S = struct {
        var utf8_buf: [1024]u8 = undefined;
    };
    const result = findBundledZsh() orelse return null;
    var utf8_len: usize = 0;
    for (0..result.zsh_len) |i| {
        const cp: u21 = result.zsh_path[i];
        const n = std.unicode.utf8Encode(cp, S.utf8_buf[utf8_len..]) catch return null;
        utf8_len += n;
    }
    return S.utf8_buf[0..utf8_len];
}

// ── Internals ──

/// Find Git for Windows' usr\bin directory (contains vi, less, nano, ssh, etc.)
/// Writes the path as UTF-16 into `buf` and returns the length, or 0 if not found.
fn findGitUsrBin(buf: []u16) usize {
    if (comptime !is_windows) return 0;

    // Check GIT_INSTALL_ROOT env var first.
    const git_root_name = comptime toUtf16Literal("GIT_INSTALL_ROOT");
    var git_root: [1024]u16 = undefined;
    const git_root_len = win.GetEnvironmentVariableW(&git_root_name, &git_root, @intCast(git_root.len));
    if (git_root_len > 0 and git_root_len < git_root.len) {
        const usr_bin = comptime toUtf16Literal("\\usr\\bin");
        const total = git_root_len + usr_bin.len;
        if (total < buf.len) {
            @memcpy(buf[0..git_root_len], git_root[0..git_root_len]);
            @memcpy(buf[git_root_len..total], &usr_bin);
            buf[total] = 0;
            if (win.GetFileAttributesW(@ptrCast(buf[0..total :0])) != win.INVALID_FILE_ATTRIBUTES)
                return total;
        }
    }

    // Try standard install locations.
    return tryGitUsrBinPath(buf, "C:\\Program Files\\Git\\usr\\bin") orelse
        tryGitUsrBinPath(buf, "C:\\Program Files (x86)\\Git\\usr\\bin") orelse 0;
}

fn tryGitUsrBinPath(buf: []u16, comptime path: []const u8) ?usize {
    if (comptime !is_windows) return null;
    const wide = comptime toUtf16Literal(path);
    if (wide.len >= buf.len) return null;
    @memcpy(buf[0..wide.len], &wide);
    buf[wide.len] = 0;
    if (win.GetFileAttributesW(@ptrCast(buf[0..wide.len :0])) != win.INVALID_FILE_ATTRIBUTES)
        return wide.len;
    return null;
}

fn setEnvW(comptime name: []const u8, comptime value: []const u8) void {
    if (comptime !is_windows) return;
    const name_w = comptime toUtf16Literal(name);
    const value_w = comptime toUtf16Literal(value);
    _ = win.SetEnvironmentVariableW(&name_w, &value_w);
}

fn toUtf16Literal(comptime s: []const u8) [s.len:0]u16 {
    comptime {
        var result: [s.len:0]u16 = undefined;
        for (s, 0..) |c, i| {
            result[i] = c;
        }
        return result;
    }
}

// ── Tests ──

test "BundledZsh struct layout" {
    const info = @typeInfo(BundledZsh);
    const fields = info.@"struct".fields;
    comptime {
        var found_path = false;
        var found_len = false;
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, "zsh_path")) found_path = true;
            if (std.mem.eql(u8, f.name, "zsh_len")) found_len = true;
        }
        if (!found_path) @compileError("missing zsh_path field");
        if (!found_len) @compileError("missing zsh_len field");
    }
}

test "findBundledZsh returns null on non-Windows" {
    if (comptime !is_windows) {
        try std.testing.expectEqual(@as(?BundledZsh, null), findBundledZsh());
    }
}
