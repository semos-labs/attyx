// Attyx — Self-extracting installer support
// Extracts an appended zip payload from the running exe.
// Requires: miniz, windows.h, shellapi.h, shlobj.h, shlwapi.h

#ifndef ATTYX_SFX_H
#define ATTYX_SFX_H

#include <stdbool.h>
#include "attyx_setup.h"
#include "miniz.h"

// Extract appended zip from exePath into destDir.
// Returns true if a valid zip was found and extracted successfully.
// Returns false if no zip payload is appended (normal exe), allowing fallback.
static bool SfxExtract(const wchar_t* exePath, const wchar_t* destDir) {
    HANDLE hFile = CreateFileW(exePath, GENERIC_READ, FILE_SHARE_READ,
                               NULL, OPEN_EXISTING, 0, NULL);
    if (hFile == INVALID_HANDLE_VALUE) return false;

    DWORD fileSize = GetFileSize(hFile, NULL);
    if (fileSize == INVALID_FILE_SIZE || fileSize < 64) {
        CloseHandle(hFile);
        return false;
    }

    void* data = VirtualAlloc(NULL, fileSize, MEM_COMMIT, PAGE_READWRITE);
    if (!data) { CloseHandle(hFile); return false; }

    DWORD bytesRead = 0;
    BOOL ok = ReadFile(hFile, data, fileSize, &bytesRead, NULL);
    CloseHandle(hFile);
    if (!ok || bytesRead != fileSize) { VirtualFree(data, 0, MEM_RELEASE); return false; }

    // miniz scans for the End of Central Directory record,
    // which works even when the zip is appended after exe bytes
    mz_zip_archive zip = {0};
    if (!mz_zip_reader_init_mem(&zip, data, fileSize, 0)) {
        VirtualFree(data, 0, MEM_RELEASE);
        return false;
    }

    int numFiles = (int)mz_zip_reader_get_num_files(&zip);
    if (numFiles == 0) {
        mz_zip_reader_end(&zip);
        VirtualFree(data, 0, MEM_RELEASE);
        return false;
    }

    bool success = true;
    for (int i = 0; i < numFiles; i++) {
        mz_zip_archive_file_stat stat;
        if (!mz_zip_reader_file_stat(&zip, i, &stat)) { success = false; break; }

        wchar_t relPath[MAX_PATH];
        MultiByteToWideChar(CP_UTF8, 0, stat.m_filename, -1, relPath, MAX_PATH);
        wchar_t fullPath[MAX_PATH];
        swprintf(fullPath, MAX_PATH, L"%s\\%s", destDir, relPath);
        for (wchar_t* p = fullPath; *p; p++) if (*p == L'/') *p = L'\\';

        if (stat.m_is_directory) {
            SHCreateDirectoryExW(NULL, fullPath, NULL);
            continue;
        }

        // Ensure parent directories exist
        wchar_t parentDir[MAX_PATH];
        wcscpy(parentDir, fullPath);
        PathRemoveFileSpecW(parentDir);
        SHCreateDirectoryExW(NULL, parentDir, NULL);

        // Extract to memory, then write via wide-path CreateFileW
        size_t uncomp_size = (size_t)stat.m_uncomp_size;
        void* buf = NULL;
        if (uncomp_size > 0) {
            buf = VirtualAlloc(NULL, uncomp_size, MEM_COMMIT, PAGE_READWRITE);
            if (!buf) { success = false; break; }
            if (!mz_zip_reader_extract_to_mem(&zip, i, buf, uncomp_size, 0)) {
                VirtualFree(buf, 0, MEM_RELEASE);
                success = false;
                break;
            }
        }

        HANDLE hOut = CreateFileW(fullPath, GENERIC_WRITE, 0, NULL,
                                  CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (hOut == INVALID_HANDLE_VALUE) {
            if (buf) VirtualFree(buf, 0, MEM_RELEASE);
            success = false;
            break;
        }

        DWORD written = 0;
        if (uncomp_size > 0)
            WriteFile(hOut, buf, (DWORD)uncomp_size, &written, NULL);
        CloseHandle(hOut);
        if (buf) VirtualFree(buf, 0, MEM_RELEASE);

        if (uncomp_size > 0 && written != (DWORD)uncomp_size) {
            success = false;
            break;
        }
    }

    mz_zip_reader_end(&zip);
    VirtualFree(data, 0, MEM_RELEASE);
    return success;
}

#endif // ATTYX_SFX_H
