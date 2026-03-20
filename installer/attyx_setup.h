// Attyx — Shared helpers for installer and uninstaller
// Requires: windows.h, shellapi.h, tlhelp32.h

#ifndef ATTYX_SETUP_H
#define ATTYX_SETUP_H

#include <stdbool.h>
#include <tlhelp32.h>

// Check if any Attyx processes are running (GUI, daemon, or host).
static bool IsAttyxRunning(void) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return false;
    PROCESSENTRY32W pe = { .dwSize = sizeof(pe) };
    bool found = false;
    if (Process32FirstW(snap, &pe)) {
        do {
            if (_wcsnicmp(pe.szExeFile, L"attyx", 5) == 0) {
                found = true;
                break;
            }
        } while (Process32NextW(snap, &pe));
    }
    CloseHandle(snap);
    return found;
}

// Kill all Attyx processes: GUI, daemon, and host processes.
// Matches any process whose exe name starts with "attyx" (covers
// attyx.exe, attyx.exe.old, attyx.exe.old.12345, etc.)
// Skips the calling process.
static void KillAttyxAll(void) {
    DWORD myPid = GetCurrentProcessId();
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return;
    PROCESSENTRY32W pe = { .dwSize = sizeof(pe) };
    if (Process32FirstW(snap, &pe)) {
        do {
            if (pe.th32ProcessID == myPid) continue;
            if (_wcsnicmp(pe.szExeFile, L"attyx", 5) == 0) {
                HANDLE hProc = OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, FALSE, pe.th32ProcessID);
                if (hProc) {
                    TerminateProcess(hProc, 0);
                    WaitForSingleObject(hProc, 5000);
                    CloseHandle(hProc);
                }
            }
        } while (Process32NextW(snap, &pe));
    }
    CloseHandle(snap);
}

// Close all running Attyx GUI windows and wait for the processes to exit.
// Returns true if any windows were found and closed.
static bool CloseAttyxGui(void) {
    bool found = false;
    HWND hw;
    while ((hw = FindWindowW(L"AttyxWindow", NULL)) != NULL) {
        found = true;
        DWORD pid = 0;
        GetWindowThreadProcessId(hw, &pid);
        HANDLE hProc = pid ? OpenProcess(SYNCHRONIZE, FALSE, pid) : NULL;
        DWORD_PTR result = 0;
        SendMessageTimeoutW(hw, WM_CLOSE, 0, 0, SMTO_ABORTIFHUNG, 5000, &result);
        if (hProc) {
            WaitForSingleObject(hProc, 10000);
            CloseHandle(hProc);
        }
    }
    return found;
}

// Delete a directory tree recursively. Safe to call with NULL or empty path.
static void DeleteDirTree(const wchar_t* dir) {
    if (!dir || dir[0] == 0) return;
    wchar_t from[MAX_PATH + 2];
    wcscpy(from, dir);
    from[wcslen(from) + 1] = 0; // double-null for SHFileOperation
    SHFILEOPSTRUCTW op = {0};
    op.wFunc = FO_DELETE;
    op.pFrom = from;
    op.fFlags = FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT;
    SHFileOperationW(&op);
}

#endif // ATTYX_SETUP_H
