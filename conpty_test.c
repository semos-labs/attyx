#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>

// ConPTY APIs (Windows 10 1809+)
typedef HRESULT (WINAPI *PFN_CreatePseudoConsole)(COORD, HANDLE, HANDLE, DWORD, HPCON*);
typedef void    (WINAPI *PFN_ClosePseudoConsole)(HPCON);

int main(void) {
    // Dynamically load ConPTY functions (avoids link errors on older SDKs)
    HMODULE k32 = GetModuleHandleW(L"kernel32.dll");
    PFN_CreatePseudoConsole pCreatePC = (PFN_CreatePseudoConsole)GetProcAddress(k32, "CreatePseudoConsole");
    PFN_ClosePseudoConsole pClosePC  = (PFN_ClosePseudoConsole)GetProcAddress(k32, "ClosePseudoConsole");
    if (!pCreatePC || !pClosePC) {
        printf("ConPTY not available\n");
        return 1;
    }

    printf("Creating pipes...\n");
    HANDLE in_r, in_w, out_r, out_w;
    if (!CreatePipe(&in_r, &in_w, NULL, 0)) { printf("Pipe1 failed\n"); return 1; }
    if (!CreatePipe(&out_r, &out_w, NULL, 0)) { printf("Pipe2 failed\n"); return 1; }

    printf("Creating pseudo console...\n");
    COORD size = { 80, 24 };
    HPCON hpc = NULL;
    HRESULT hr = pCreatePC(size, in_r, out_w, 0, &hpc);
    if (FAILED(hr)) {
        printf("CreatePseudoConsole FAILED: hr=0x%lx\n", hr);
        return 1;
    }
    printf("ConPTY created OK, hpc=%p\n", hpc);

    // Close the ConPTY-side pipe ends (ConPTY has its own copies)
    CloseHandle(in_r);
    CloseHandle(out_w);

    // Build attribute list
    SIZE_T attr_size = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &attr_size);
    printf("Attr list size: %zu\n", attr_size);

    LPPROC_THREAD_ATTRIBUTE_LIST attr_list = (LPPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(GetProcessHeap(), 0, attr_size);
    if (!InitializeProcThreadAttributeList(attr_list, 1, 0, &attr_size)) {
        printf("InitAttrList FAILED: %lu\n", GetLastError());
        return 1;
    }

    if (!UpdateProcThreadAttribute(attr_list, 0,
            PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc, sizeof(HPCON), NULL, NULL)) {
        printf("UpdateAttr FAILED: %lu\n", GetLastError());
        return 1;
    }
    printf("Attribute list OK\n");

    // Spawn cmd.exe
    WCHAR cmd[] = L"cmd.exe";
    STARTUPINFOEXW si;
    ZeroMemory(&si, sizeof(si));
    si.StartupInfo.cb = sizeof(STARTUPINFOEXW);
    si.lpAttributeList = attr_list;

    PROCESS_INFORMATION pi;
    if (!CreateProcessW(NULL, cmd, NULL, NULL, FALSE,
            EXTENDED_STARTUPINFO_PRESENT, NULL, NULL,
            (STARTUPINFOW*)&si, &pi)) {
        printf("CreateProcessW FAILED: %lu\n", GetLastError());
        return 1;
    }
    printf("Process created: pid=%lu\n", pi.dwProcessId);
    CloseHandle(pi.hThread);

    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    printf("Exit code: %lu (259=alive)\n", code);

    printf("Waiting 2s for output...\n");
    Sleep(2000);

    DWORD avail = 0;
    PeekNamedPipe(out_r, NULL, 0, NULL, &avail, NULL);
    printf("PeekNamedPipe: avail=%lu lastErr=%lu\n", avail, GetLastError());

    if (avail > 0) {
        char buf[4096];
        DWORD bytes_read = 0;
        ReadFile(out_r, buf, sizeof(buf) - 1, &bytes_read, NULL);
        buf[bytes_read] = '\0';
        printf("Read %lu bytes:\n%s\n", bytes_read, buf);
    } else {
        printf("No data. Writing 'dir\\r\\n'...\n");
        DWORD written = 0;
        WriteFile(in_w, "dir\r\n", 5, &written, NULL);
        printf("Wrote %lu bytes\n", written);

        Sleep(1000);
        PeekNamedPipe(out_r, NULL, 0, NULL, &avail, NULL);
        printf("After write - avail=%lu\n", avail);

        if (avail > 0) {
            char buf2[4096];
            DWORD br2 = 0;
            ReadFile(out_r, buf2, sizeof(buf2) - 1, &br2, NULL);
            buf2[br2] = '\0';
            printf("Read %lu bytes:\n%s\n", br2, buf2);
        }
    }

    pClosePC(hpc);
    CloseHandle(pi.hProcess);
    CloseHandle(in_w);
    CloseHandle(out_r);
    DeleteProcThreadAttributeList(attr_list);
    HeapFree(GetProcessHeap(), 0, attr_list);
    printf("Done.\n");
    return 0;
}
