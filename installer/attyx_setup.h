// Attyx — Shared helpers for installer and uninstaller
// Requires: windows.h

#ifndef ATTYX_SETUP_H
#define ATTYX_SETUP_H

#include <stdbool.h>

// Close all running Attyx GUI windows (leaves daemon and host processes alive).
// Returns true if any windows were found and closed.
static bool CloseAttyxGui(void) {
    bool found = false;
    HWND hw;
    while ((hw = FindWindowW(L"AttyxWindow", NULL)) != NULL) {
        found = true;
        DWORD_PTR result = 0;
        SendMessageTimeoutW(hw, WM_CLOSE, 0, 0, SMTO_ABORTIFHUNG, 5000, &result);
    }
    if (found) Sleep(500); // Brief pause for process cleanup
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
