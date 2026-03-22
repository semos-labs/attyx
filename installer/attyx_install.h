// Attyx — Shared install/update logic for Windows
// Used by both the installer (attyx-setup.exe) and the in-app updater.
// Requires: windows.h, shellapi.h, shlobj.h, shlwapi.h, stdbool.h

#ifndef ATTYX_INSTALL_H
#define ATTYX_INSTALL_H

#include "attyx_setup.h"

// ---------------------------------------------------------------------------
// Detection
// ---------------------------------------------------------------------------

// Check if Attyx is installed by looking for the uninstall registry key.
// If installed, fills installDir with the InstallLocation (if available).
static bool AttyxIsInstalled(wchar_t* installDir, int maxLen) {
    HKEY hKey;
    if (RegOpenKeyExW(HKEY_CURRENT_USER,
            L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Attyx",
            0, KEY_READ, &hKey) != ERROR_SUCCESS)
        return false;

    if (installDir && maxLen > 0) {
        DWORD sz = (DWORD)(maxLen * sizeof(wchar_t));
        DWORD type = 0;
        if (RegQueryValueExW(hKey, L"InstallLocation", NULL, &type,
                             (BYTE*)installDir, &sz) != ERROR_SUCCESS)
            installDir[0] = 0;
    }
    RegCloseKey(hKey);
    return true;
}

// ---------------------------------------------------------------------------
// Binary swap (safe for running exe)
// ---------------------------------------------------------------------------

// Replace the installed attyx.exe with a new one from srcExe.
// Uses rename trick: exe → exe.old, copy new → exe, delete old.
// Returns true on success. On failure, rolls back.
static bool AttyxSwapBinary(const wchar_t* installDir, const wchar_t* srcExe) {
    wchar_t exePath[MAX_PATH];
    swprintf(exePath, MAX_PATH, L"%s\\attyx.exe", installDir);

    // If the target doesn't exist yet (fresh install), just copy
    if (!PathFileExistsW(exePath))
        return CopyFileW(srcExe, exePath, FALSE) != 0;

    // Kill everything — GUI, daemon, host processes.
    // On Windows there's no reliable way to hot-swap with a running daemon.
    KillAttyxAll();

    // Clean up old binaries now that nothing holds them
    WIN32_FIND_DATAW fd;
    wchar_t pattern[MAX_PATH];
    swprintf(pattern, MAX_PATH, L"%s\\attyx.exe.old*", installDir);
    HANDLE hFind = FindFirstFileW(pattern, &fd);
    if (hFind != INVALID_HANDLE_VALUE) {
        do {
            wchar_t victim[MAX_PATH];
            swprintf(victim, MAX_PATH, L"%s\\%s", installDir, fd.cFileName);
            DeleteFileW(victim);
        } while (FindNextFileW(hFind, &fd));
        FindClose(hFind);
    }

    // Rename old exe out of the way, then copy new one in.
    // If copy fails, roll back so the user still has a working binary.
    wchar_t oldPath[MAX_PATH];
    swprintf(oldPath, MAX_PATH, L"%s\\attyx.exe.old", installDir);
    if (!MoveFileW(exePath, oldPath)) {
        // Can't move — try direct overwrite as last resort
        return CopyFileW(srcExe, exePath, FALSE) != 0;
    }
    if (!CopyFileW(srcExe, exePath, FALSE)) {
        // Copy failed — roll back
        MoveFileW(oldPath, exePath);
        return false;
    }
    DeleteFileW(oldPath);
    return true;
}

// ---------------------------------------------------------------------------
// Full install (fresh system)
// ---------------------------------------------------------------------------

// Error reporting: if non-NULL, receives a human-readable error on failure.
static wchar_t g_install_error[512];

typedef bool (*AttyxInstallProgressFn)(const wchar_t* status, int progress);

// Install all files from payloadDir into installDir.
// Calls progressFn (if non-NULL) with status updates.
// On failure, g_install_error contains details.
static bool AttyxInstallFiles(const wchar_t* installDir, const wchar_t* payloadDir,
                              AttyxInstallProgressFn progressFn) {
    wchar_t src[MAX_PATH], dst[MAX_PATH];
    g_install_error[0] = 0;

    // Create install directory
    if (progressFn) progressFn(L"Creating directory...", 5);
    int dirErr = SHCreateDirectoryExW(NULL, installDir, NULL);
    if (dirErr != ERROR_SUCCESS && dirErr != ERROR_ALREADY_EXISTS
        && dirErr != ERROR_FILE_EXISTS) {
        swprintf(g_install_error, 512, L"Could not create directory: error %d", dirErr);
        return false;
    }

    // Copy attyx.exe (kills all Attyx processes if needed)
    if (progressFn) progressFn(L"Copying files...", 10);
    swprintf(src, MAX_PATH, L"%s\\attyx.exe", payloadDir);
    if (!PathFileExistsW(src)) {
        swprintf(g_install_error, 512, L"Payload not found: %s", src);
        return false;
    }
    if (!AttyxSwapBinary(installDir, src)) {
        DWORD err = GetLastError();
        wchar_t desc[256];
        DWORD len = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                                    NULL, err, 0, desc, 256, NULL);
        if (len > 0) {
            while (len > 0 && (desc[len-1] == '\n' || desc[len-1] == '\r')) desc[--len] = 0;
            swprintf(g_install_error, 512, L"Could not install attyx.exe: %s", desc);
        } else {
            swprintf(g_install_error, 512, L"Could not install attyx.exe (error %lu)", err);
        }
        return false;
    }

    // Copy uninstaller if present
    swprintf(src, MAX_PATH, L"%s\\attyx-uninstall.exe", payloadDir);
    if (PathFileExistsW(src)) {
        swprintf(dst, MAX_PATH, L"%s\\attyx-uninstall.exe", installDir);
        CopyFileW(src, dst, FALSE);
    }

    // Copy PDB if present
    swprintf(src, MAX_PATH, L"%s\\attyx.pdb", payloadDir);
    if (PathFileExistsW(src)) {
        swprintf(dst, MAX_PATH, L"%s\\attyx.pdb", installDir);
        CopyFileW(src, dst, FALSE);
    }
    if (progressFn) progressFn(L"Setting up shell environment...", 20);

    // Copy MSYS2 sysroot if present
    swprintf(src, MAX_PATH, L"%s\\share\\msys2", payloadDir);
    if (PathFileExistsW(src)) {
        swprintf(dst, MAX_PATH, L"%s\\share", installDir);
        SHCreateDirectoryExW(NULL, dst, NULL);
        swprintf(dst, MAX_PATH, L"%s\\share\\msys2", installDir);
        // Recursive copy using SHFileOperation
        wchar_t fromBuf[MAX_PATH + 2];
        wcscpy(fromBuf, src);
        fromBuf[wcslen(fromBuf) + 1] = 0;
        wchar_t toBuf[MAX_PATH + 2];
        wcscpy(toBuf, dst);
        toBuf[wcslen(toBuf) + 1] = 0;
        SHFILEOPSTRUCTW op = {0};
        op.wFunc = FO_COPY;
        op.pFrom = fromBuf;
        op.pTo = toBuf;
        op.fFlags = FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT;
        SHFileOperationW(&op);
    }
    if (progressFn) progressFn(L"Copying files...", 70);

    return true;
}

// ---------------------------------------------------------------------------
// Registration (shortcuts, PATH, context menu, Add/Remove Programs)
// ---------------------------------------------------------------------------

typedef struct {
    bool addToPath;
    bool desktopShortcut;
    bool contextMenu;
    const wchar_t* version;   // may be NULL
} AttyxRegisterOpts;

// Helper: create IShellLink shortcut
static bool AttyxCreateShortcut(const wchar_t* lnkPath, const wchar_t* target,
                                const wchar_t* desc, const wchar_t* iconPath) {
    IShellLinkW* sl = NULL;
    HRESULT hr = CoCreateInstance(&CLSID_ShellLink, NULL, CLSCTX_INPROC_SERVER,
                                  &IID_IShellLinkW, (void**)&sl);
    if (FAILED(hr)) return false;
    IShellLinkW_SetPath(sl, target);
    IShellLinkW_SetDescription(sl, desc);
    IShellLinkW_SetIconLocation(sl, iconPath, 0);
    IPersistFile* pf = NULL;
    hr = IShellLinkW_QueryInterface(sl, &IID_IPersistFile, (void**)&pf);
    if (SUCCEEDED(hr)) {
        IPersistFile_Save(pf, lnkPath, TRUE);
        IPersistFile_Release(pf);
    }
    IShellLinkW_Release(sl);
    return SUCCEEDED(hr);
}

static void AttyxRegister(const wchar_t* installDir, const AttyxRegisterOpts* opts) {
    wchar_t dst[MAX_PATH];

    // Start Menu shortcut (always)
    {
        wchar_t startMenu[MAX_PATH];
        if (SHGetFolderPathW(NULL, CSIDL_PROGRAMS, NULL, 0, startMenu) == S_OK) {
            wcscat(startMenu, L"\\Attyx");
            CreateDirectoryW(startMenu, NULL);
            wchar_t lnk[MAX_PATH];
            swprintf(lnk, MAX_PATH, L"%s\\Attyx.lnk", startMenu);
            swprintf(dst, MAX_PATH, L"%s\\attyx.exe", installDir);
            AttyxCreateShortcut(lnk, dst, L"Attyx Terminal", dst);
        }
    }

    // Add/Remove Programs
    {
        HKEY hKey;
        RegCreateKeyExW(HKEY_CURRENT_USER,
            L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Attyx",
            0, NULL, 0, KEY_WRITE, NULL, &hKey, NULL);
        RegSetValueExW(hKey, L"DisplayName", 0, REG_SZ, (BYTE*)L"Attyx",
                       6 * sizeof(wchar_t));
        swprintf(dst, MAX_PATH, L"\"%s\\attyx-uninstall.exe\"", installDir);
        RegSetValueExW(hKey, L"UninstallString", 0, REG_SZ, (BYTE*)dst,
                       (DWORD)((wcslen(dst) + 1) * sizeof(wchar_t)));
        swprintf(dst, MAX_PATH, L"%s\\attyx.exe", installDir);
        RegSetValueExW(hKey, L"DisplayIcon", 0, REG_SZ, (BYTE*)dst,
                       (DWORD)((wcslen(dst) + 1) * sizeof(wchar_t)));
        RegSetValueExW(hKey, L"Publisher", 0, REG_SZ, (BYTE*)L"Attyx",
                       6 * sizeof(wchar_t));
        if (opts->version && opts->version[0])
            RegSetValueExW(hKey, L"DisplayVersion", 0, REG_SZ, (BYTE*)opts->version,
                           (DWORD)((wcslen(opts->version) + 1) * sizeof(wchar_t)));
        DWORD noModify = 1;
        RegSetValueExW(hKey, L"NoModify", 0, REG_DWORD, (BYTE*)&noModify, sizeof(DWORD));
        RegSetValueExW(hKey, L"NoRepair", 0, REG_DWORD, (BYTE*)&noModify, sizeof(DWORD));
        RegSetValueExW(hKey, L"InstallLocation", 0, REG_SZ, (BYTE*)installDir,
                       (DWORD)((wcslen(installDir) + 1) * sizeof(wchar_t)));
        RegCloseKey(hKey);
    }

    // PATH
    if (opts->addToPath) {
        HKEY hKey;
        if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Environment", 0,
                          KEY_READ | KEY_WRITE, &hKey) == ERROR_SUCCESS) {
            wchar_t path[8192] = L"";
            DWORD sz = sizeof(path), type = 0;
            RegQueryValueExW(hKey, L"Path", NULL, &type, (BYTE*)path, &sz);
            if (!wcsstr(path, installDir)) {
                if (wcslen(path) > 0) wcscat(path, L";");
                wcscat(path, installDir);
                RegSetValueExW(hKey, L"Path", 0, REG_EXPAND_SZ, (BYTE*)path,
                               (DWORD)((wcslen(path) + 1) * sizeof(wchar_t)));
                SendMessageTimeoutW(HWND_BROADCAST, WM_SETTINGCHANGE, 0,
                                    (LPARAM)L"Environment", SMTO_ABORTIFHUNG, 5000, NULL);
            }
            RegCloseKey(hKey);
        }
    }

    // Desktop shortcut
    if (opts->desktopShortcut) {
        wchar_t desktop[MAX_PATH];
        if (SHGetFolderPathW(NULL, CSIDL_DESKTOPDIRECTORY, NULL, 0, desktop) == S_OK) {
            wchar_t lnk[MAX_PATH];
            swprintf(lnk, MAX_PATH, L"%s\\Attyx.lnk", desktop);
            swprintf(dst, MAX_PATH, L"%s\\attyx.exe", installDir);
            AttyxCreateShortcut(lnk, dst, L"Attyx Terminal", dst);
        }
    }

    // Context menu
    if (opts->contextMenu) {
        HKEY hKey;
        swprintf(dst, MAX_PATH, L"\"%s\\attyx.exe\" \"%%V\"", installDir);
        wchar_t iconVal[MAX_PATH];
        swprintf(iconVal, MAX_PATH, L"\"%s\\attyx.exe\"", installDir);
        RegCreateKeyExW(HKEY_CURRENT_USER,
            L"Software\\Classes\\Directory\\Background\\shell\\Attyx",
            0, NULL, 0, KEY_WRITE, NULL, &hKey, NULL);
        RegSetValueExW(hKey, NULL, 0, REG_SZ, (BYTE*)L"Open Attyx Here",
                       16 * sizeof(wchar_t));
        RegSetValueExW(hKey, L"Icon", 0, REG_SZ, (BYTE*)iconVal,
                       (DWORD)((wcslen(iconVal) + 1) * sizeof(wchar_t)));
        RegCloseKey(hKey);
        RegCreateKeyExW(HKEY_CURRENT_USER,
            L"Software\\Classes\\Directory\\Background\\shell\\Attyx\\command",
            0, NULL, 0, KEY_WRITE, NULL, &hKey, NULL);
        RegSetValueExW(hKey, NULL, 0, REG_SZ, (BYTE*)dst,
                       (DWORD)((wcslen(dst) + 1) * sizeof(wchar_t)));
        RegCloseKey(hKey);
        RegCreateKeyExW(HKEY_CURRENT_USER,
            L"Software\\Classes\\Directory\\shell\\Attyx",
            0, NULL, 0, KEY_WRITE, NULL, &hKey, NULL);
        RegSetValueExW(hKey, NULL, 0, REG_SZ, (BYTE*)L"Open Attyx Here",
                       16 * sizeof(wchar_t));
        RegSetValueExW(hKey, L"Icon", 0, REG_SZ, (BYTE*)iconVal,
                       (DWORD)((wcslen(iconVal) + 1) * sizeof(wchar_t)));
        RegCloseKey(hKey);
        RegCreateKeyExW(HKEY_CURRENT_USER,
            L"Software\\Classes\\Directory\\shell\\Attyx\\command",
            0, NULL, 0, KEY_WRITE, NULL, &hKey, NULL);
        RegSetValueExW(hKey, NULL, 0, REG_SZ, (BYTE*)dst,
                       (DWORD)((wcslen(dst) + 1) * sizeof(wchar_t)));
        RegCloseKey(hKey);
    }
}

#endif // ATTYX_INSTALL_H
