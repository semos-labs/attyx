// Attyx — Self-extracting installer support
// Extracts an appended zip payload from the running exe.
// Requires: miniz, windows.h, shellapi.h, shlobj.h, shlwapi.h

#ifndef ATTYX_SFX_H
#define ATTYX_SFX_H

#include <stdbool.h>
#include "attyx_setup.h"
#include "miniz.h"

// Find the start of an appended zip within a buffer by locating the EOCD record.
// Returns the byte offset where the zip begins, or 0 if the buffer is a standalone zip.
// miniz's mz_zip_reader_init_mem doesn't handle SFX-style exe+zip concatenation
// (it only adjusts offsets for FILE-backed archives), so we strip the exe prefix first.
static DWORD SfxFindZipStart(const unsigned char* buf, DWORD size) {
    if (size < 22) return 0;
    // Search backward for EOCD signature (PK\x05\x06).  Max zip comment is 65535 bytes.
    DWORD searchFrom = (size > 65557) ? size - 65557 : 0;
    for (DWORD i = size - 22; ; i--) {
        if (buf[i] == 0x50 && buf[i+1] == 0x4B && buf[i+2] == 0x05 && buf[i+3] == 0x06) {
            // Read central directory size and offset (little-endian, unaligned)
            DWORD cdirSize = buf[i+12] | ((DWORD)buf[i+13]<<8) | ((DWORD)buf[i+14]<<16) | ((DWORD)buf[i+15]<<24);
            DWORD cdirOfs  = buf[i+16] | ((DWORD)buf[i+17]<<8) | ((DWORD)buf[i+18]<<16) | ((DWORD)buf[i+19]<<24);
            if (i >= cdirOfs + cdirSize)
                return (DWORD)(i - cdirOfs - cdirSize);
            return 0;
        }
        if (i <= searchFrom) break;
    }
    return 0;
}

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

    // Read entire file (loop to handle partial reads)
    DWORD totalRead = 0;
    while (totalRead < fileSize) {
        DWORD chunk = 0;
        if (!ReadFile(hFile, (char*)data + totalRead, fileSize - totalRead, &chunk, NULL) || chunk == 0)
            break;
        totalRead += chunk;
    }
    CloseHandle(hFile);
    if (totalRead != fileSize) { VirtualFree(data, 0, MEM_RELEASE); return false; }

    // Find where the appended zip starts (skip the exe prefix)
    DWORD zipStart = SfxFindZipStart((const unsigned char*)data, fileSize);

    mz_zip_archive zip = {0};
    if (!mz_zip_reader_init_mem(&zip, (char*)data + zipStart, fileSize - zipStart, 0)) {
        VirtualFree(data, 0, MEM_RELEASE);
        return false;
    }

    int numFiles = (int)mz_zip_reader_get_num_files(&zip);
    if (numFiles == 0) {
        mz_zip_reader_end(&zip);
        VirtualFree(data, 0, MEM_RELEASE);
        return false;
    }

    bool gotExe = false;
    for (int i = 0; i < numFiles; i++) {
        mz_zip_archive_file_stat stat;
        if (!mz_zip_reader_file_stat(&zip, i, &stat)) continue;

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
            if (!buf) continue;
            if (!mz_zip_reader_extract_to_mem(&zip, i, buf, uncomp_size, 0)) {
                VirtualFree(buf, 0, MEM_RELEASE);
                continue;
            }
        }

        HANDLE hOut = CreateFileW(fullPath, GENERIC_WRITE, 0, NULL,
                                  CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (hOut == INVALID_HANDLE_VALUE) {
            if (buf) VirtualFree(buf, 0, MEM_RELEASE);
            continue;
        }

        DWORD written = 0;
        if (uncomp_size > 0)
            WriteFile(hOut, buf, (DWORD)uncomp_size, &written, NULL);
        CloseHandle(hOut);
        if (buf) VirtualFree(buf, 0, MEM_RELEASE);

        if (uncomp_size > 0 && written != (DWORD)uncomp_size) {
            DeleteFileW(fullPath);  // partial write, clean up
            continue;
        }

        // Track whether we got the critical file
        if (_wcsicmp(relPath, L"attyx.exe") == 0) gotExe = true;
    }

    mz_zip_reader_end(&zip);
    VirtualFree(data, 0, MEM_RELEASE);
    return gotExe;
}

#endif // ATTYX_SFX_H
