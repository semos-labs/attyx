// Attyx — Windows Uninstaller
// Dark-themed, single-page uninstaller matching the installer design.
// Reverses everything the installer did: PATH, shortcuts, context menu,
// registry, state/config dirs, install directory.
//
// Registered as UninstallString in Add/Remove Programs.
// Also invokable directly: attyx-uninstall.exe [/silent]

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <stdio.h>
#include <stdbool.h>
#include "attyx_setup.h"

#pragma comment(lib, "shlwapi.lib")

// ---------------------------------------------------------------------------
// Layout & colors (matches installer)
// ---------------------------------------------------------------------------
#define WIN_W       440
#define WIN_H       260
#define BG_COLOR    RGB(26, 26, 26)
#define TEXT_COLOR   RGB(224, 224, 224)
#define DIM_COLOR    RGB(128, 128, 128)
#define BTN_BG       RGB(40, 40, 40)
#define BTN_BORDER   RGB(80, 80, 80)
#define BTN_HOVER    RGB(55, 55, 55)
#define BTN_ACTIVE   RGB(200, 80, 80)
#define PROGRESS_BG  RGB(50, 50, 50)
#define PROGRESS_FG  RGB(200, 80, 80)
#define MARGIN       32
#define BTN_H        38
#define LINE_H       24

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
static HWND g_hwnd;
static HFONT g_font_title, g_font_body, g_font_btn;
static HICON g_icon;
static wchar_t g_install_dir[MAX_PATH];
static bool g_uninstalling = false;
static bool g_done = false;
static bool g_silent = false;
static int g_progress = 0;
static wchar_t g_status[256] = L"";
static int g_hover_btn = 0;
static RECT g_rc_uninstall, g_rc_cancel;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static void SetStatus(const wchar_t *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    vswprintf(g_status, 256, fmt, ap);
    va_end(ap);
    if (g_hwnd) InvalidateRect(g_hwnd, NULL, FALSE);
}

static void InitInstallDir(void) {
    // Uninstaller lives in the install dir
    GetModuleFileNameW(NULL, g_install_dir, MAX_PATH);
    PathRemoveFileSpecW(g_install_dir);
}

// ---------------------------------------------------------------------------
// Uninstall logic
// ---------------------------------------------------------------------------
static DWORD WINAPI UninstallThread(LPVOID param) {
    (void)param;

    // Close running Attyx GUI (keeps daemon alive for now — we kill it below)
    if (FindWindowW(L"AttyxWindow", NULL)) {
        SetStatus(L"Closing Attyx...");
        CloseAttyxGui();
    }

    // 1. Remove from user PATH
    SetStatus(L"Removing from PATH...");
    g_progress = 10;
    {
        HKEY hKey;
        if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Environment", 0,
                          KEY_READ | KEY_WRITE, &hKey) == ERROR_SUCCESS) {
            wchar_t path[8192] = L"";
            DWORD sz = sizeof(path), type = 0;
            RegQueryValueExW(hKey, L"Path", NULL, &type, (BYTE*)path, &sz);
            // Remove g_install_dir from the PATH string
            wchar_t new_path[8192] = L"";
            wchar_t *ctx = NULL;
            wchar_t *tok = wcstok(path, L";", &ctx);
            bool first = true;
            while (tok) {
                if (_wcsicmp(tok, g_install_dir) != 0) {
                    if (!first) wcscat(new_path, L";");
                    wcscat(new_path, tok);
                    first = false;
                }
                tok = wcstok(NULL, L";", &ctx);
            }
            RegSetValueExW(hKey, L"Path", 0, REG_EXPAND_SZ, (BYTE*)new_path,
                           (DWORD)((wcslen(new_path) + 1) * sizeof(wchar_t)));
            RegCloseKey(hKey);
            // Notify other processes of env change
            SendMessageTimeoutW(HWND_BROADCAST, WM_SETTINGCHANGE, 0,
                                (LPARAM)L"Environment", SMTO_ABORTIFHUNG, 5000, NULL);
        }
    }
    g_progress = 25;

    // 2. Remove context menu entries
    SetStatus(L"Removing context menu...");
    RegDeleteTreeW(HKEY_CURRENT_USER, L"Software\\Classes\\Directory\\Background\\shell\\Attyx");
    RegDeleteTreeW(HKEY_CURRENT_USER, L"Software\\Classes\\Directory\\shell\\Attyx");
    g_progress = 40;

    // 3. Remove shortcuts
    SetStatus(L"Removing shortcuts...");
    {
        wchar_t startMenu[MAX_PATH];
        if (SHGetFolderPathW(NULL, CSIDL_PROGRAMS, NULL, 0, startMenu) == S_OK) {
            wcscat(startMenu, L"\\Attyx");
            DeleteDirTree(startMenu);
        }
        wchar_t desktop[MAX_PATH];
        if (SHGetFolderPathW(NULL, CSIDL_DESKTOPDIRECTORY, NULL, 0, desktop) == S_OK) {
            wcscat(desktop, L"\\Attyx.lnk");
            DeleteFileW(desktop);
        }
    }
    g_progress = 55;

    // 4. Remove Add/Remove Programs entry
    SetStatus(L"Removing registry entries...");
    RegDeleteTreeW(HKEY_CURRENT_USER,
        L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Attyx");
    g_progress = 65;

    // 5. Remove state dir (%LOCALAPPDATA%\attyx)
    SetStatus(L"Removing data...");
    {
        wchar_t appdata[MAX_PATH];
        if (SHGetFolderPathW(NULL, CSIDL_LOCAL_APPDATA, NULL, 0, appdata) == S_OK) {
            wcscat(appdata, L"\\attyx");
            DeleteDirTree(appdata);
        }
    }
    g_progress = 75;

    // 6. Remove config dir (%APPDATA%\attyx)
    {
        wchar_t appdata[MAX_PATH];
        if (SHGetFolderPathW(NULL, CSIDL_APPDATA, NULL, 0, appdata) == S_OK) {
            wcscat(appdata, L"\\attyx");
            DeleteDirTree(appdata);
        }
    }
    g_progress = 85;

    // 7. Schedule install dir removal (can't delete running exe)
    SetStatus(L"Scheduling cleanup...");
    {
        wchar_t cmd[1024];
        swprintf(cmd, 1024,
            L"cmd.exe /c \"timeout /t 2 /nobreak >nul & rmdir /s /q \"%s\"\"",
            g_install_dir);
        STARTUPINFOW si = {0};
        si.cb = sizeof(si);
        si.dwFlags = STARTF_USESHOWWINDOW;
        si.wShowWindow = SW_HIDE;
        PROCESS_INFORMATION pi;
        CreateProcessW(NULL, cmd, NULL, NULL, FALSE,
            CREATE_NO_WINDOW, NULL, NULL, &si, &pi);
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }
    g_progress = 100;

    g_done = true;
    SetStatus(L"Attyx has been uninstalled.");

    if (g_silent) PostQuitMessage(0);
    return 0;
}

// ---------------------------------------------------------------------------
// Paint
// ---------------------------------------------------------------------------
static void DrawButton(HDC hdc, RECT *rc, const wchar_t *text, bool hover, bool accent) {
    COLORREF bg = hover ? BTN_HOVER : BTN_BG;
    COLORREF border = accent ? BTN_ACTIVE : BTN_BORDER;
    HBRUSH br = CreateSolidBrush(bg);
    FillRect(hdc, rc, br); DeleteObject(br);
    HPEN pen = CreatePen(PS_SOLID, accent ? 2 : 1, border);
    SelectObject(hdc, pen); SelectObject(hdc, GetStockObject(NULL_BRUSH));
    RoundRect(hdc, rc->left, rc->top, rc->right, rc->bottom, 6, 6);
    DeleteObject(pen);
    SelectObject(hdc, g_font_btn);
    SetTextColor(hdc, TEXT_COLOR);
    DrawTextW(hdc, text, -1, rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
}

static void DoPaint(HWND hwnd) {
    PAINTSTRUCT ps;
    HDC hdc = BeginPaint(hwnd, &ps);
    RECT cr; GetClientRect(hwnd, &cr);
    int W = cr.right, H = cr.bottom;

    HDC mem = CreateCompatibleDC(hdc);
    HBITMAP bmp = CreateCompatibleBitmap(hdc, W, H);
    SelectObject(mem, bmp);

    HBRUSH bgBr = CreateSolidBrush(BG_COLOR);
    FillRect(mem, &cr, bgBr); DeleteObject(bgBr);
    SetBkMode(mem, TRANSPARENT);

    int y = MARGIN;

    // Title
    SelectObject(mem, g_font_title);
    SetTextColor(mem, TEXT_COLOR);
    RECT tr = { MARGIN, y, W - MARGIN, y + 32 };
    DrawTextW(mem, L"Uninstall Attyx", -1, &tr, DT_LEFT | DT_SINGLELINE);
    y += 40;

    // Subtitle
    SelectObject(mem, g_font_body);
    SetTextColor(mem, DIM_COLOR);
    if (!g_done && !g_uninstalling) {
        RECT sr = { MARGIN, y, W - MARGIN, y + LINE_H * 2 };
        DrawTextW(mem, L"This will remove Attyx, its settings,\nand all associated data from your computer.", -1, &sr, DT_LEFT | DT_WORDBREAK);
    }
    y += LINE_H * 2 + 16;

    // Progress
    if (g_uninstalling || g_done) {
        int py = H - 90;
        if (g_progress > 0) {
            RECT pbg = { MARGIN, py, W - MARGIN, py + 6 };
            HBRUSH pBg = CreateSolidBrush(PROGRESS_BG);
            FillRect(mem, &pbg, pBg); DeleteObject(pBg);
            int pw = (W - 2 * MARGIN) * g_progress / 100;
            RECT pfg = { MARGIN, py, MARGIN + pw, py + 6 };
            HBRUSH pFg = CreateSolidBrush(PROGRESS_FG);
            FillRect(mem, &pfg, pFg); DeleteObject(pFg);
        }
        SelectObject(mem, g_font_body);
        SetTextColor(mem, DIM_COLOR);
        RECT sr = { MARGIN, H - 78, W - MARGIN, H - 60 };
        DrawTextW(mem, g_status, -1, &sr, DT_LEFT | DT_SINGLELINE);

        if (g_done) {
            g_rc_cancel = (RECT){ W - MARGIN - 80, H - 54, W - MARGIN, H - 54 + BTN_H };
            DrawButton(mem, &g_rc_cancel, L"Close", g_hover_btn == 2, false);
        }
    } else {
        // Buttons
        g_rc_uninstall = (RECT){ MARGIN, y, MARGIN + 160, y + BTN_H };
        DrawButton(mem, &g_rc_uninstall, L"Uninstall", g_hover_btn == 1, true);

        g_rc_cancel = (RECT){ MARGIN + 172, y, MARGIN + 252, y + BTN_H };
        DrawButton(mem, &g_rc_cancel, L"Cancel", g_hover_btn == 2, false);
    }

    BitBlt(hdc, 0, 0, W, H, mem, 0, 0, SRCCOPY);
    DeleteObject(bmp); DeleteDC(mem);
    EndPaint(hwnd, &ps);
}

// ---------------------------------------------------------------------------
// Window procedure
// ---------------------------------------------------------------------------
static int HitTest(int x, int y) {
    POINT pt = { x, y };
    if (!g_uninstalling && !g_done && PtInRect(&g_rc_uninstall, pt)) return 1;
    if ((!g_uninstalling || g_done) && PtInRect(&g_rc_cancel, pt)) return 2;
    return 0;
}

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_PAINT: DoPaint(hwnd); return 0;
    case WM_ERASEBKGND: return 1;
    case WM_MOUSEMOVE: {
        int old = g_hover_btn;
        g_hover_btn = HitTest(LOWORD(lParam), HIWORD(lParam));
        if (g_hover_btn != old) InvalidateRect(hwnd, NULL, FALSE);
        TRACKMOUSEEVENT tme = { sizeof(tme), TME_LEAVE, hwnd, 0 };
        TrackMouseEvent(&tme);
        return 0;
    }
    case WM_MOUSELEAVE:
        if (g_hover_btn) { g_hover_btn = 0; InvalidateRect(hwnd, NULL, FALSE); }
        return 0;
    case WM_LBUTTONDOWN: {
        int hit = HitTest(LOWORD(lParam), HIWORD(lParam));
        if (hit == 1 && !g_uninstalling) {
            g_uninstalling = true;
            InvalidateRect(hwnd, NULL, FALSE);
            CreateThread(NULL, 0, UninstallThread, NULL, 0, NULL);
        }
        if (hit == 2) PostQuitMessage(0);
        return 0;
    }
    case WM_CLOSE:
        if (g_uninstalling && !g_done) return 0;
        PostQuitMessage(0); return 0;
    case WM_DESTROY: PostQuitMessage(0); return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------
int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmdLineA, int cmdShow) {
    (void)hPrev; (void)cmdShow;
    InitInstallDir();

    // Check for /silent flag
    LPWSTR cmdLine = GetCommandLineW();
    if (cmdLine && wcsstr(cmdLine, L"/silent")) g_silent = true;

    if (g_silent) {
        // Run without UI
        UninstallThread(NULL);
        return 0;
    }

    // Fonts
    g_font_title = CreateFontW(-22, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET,
        0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    g_font_body = CreateFontW(-14, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
        0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    g_font_btn = CreateFontW(-14, 0, 0, 0, FW_SEMIBOLD, 0, 0, 0, DEFAULT_CHARSET,
        0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    g_icon = LoadIconW(hInst, MAKEINTRESOURCEW(1));

    WNDCLASSEXW wc = {
        .cbSize = sizeof(wc), .lpfnWndProc = WndProc, .hInstance = hInst,
        .hCursor = LoadCursorW(NULL, IDC_ARROW), .hIcon = g_icon, .hIconSm = g_icon,
        .lpszClassName = L"AttyxUninstaller",
    };
    RegisterClassExW(&wc);

    int sx = GetSystemMetrics(SM_CXSCREEN), sy = GetSystemMetrics(SM_CYSCREEN);
    RECT wr = { 0, 0, WIN_W, WIN_H };
    AdjustWindowRect(&wr, WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU, FALSE);
    int ww = wr.right - wr.left, wh = wr.bottom - wr.top;

    g_hwnd = CreateWindowExW(0, L"AttyxUninstaller", L"Uninstall Attyx",
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
        (sx - ww) / 2, (sy - wh) / 2, ww, wh, NULL, NULL, hInst, NULL);

    // Dark title bar
    HMODULE dwm = LoadLibraryW(L"dwmapi.dll");
    if (dwm) {
        typedef HRESULT (WINAPI *PFN)(HWND, DWORD, const void*, DWORD);
        PFN fn = (PFN)GetProcAddress(dwm, "DwmSetWindowAttribute");
        if (fn) { BOOL dark = TRUE; fn(g_hwnd, 20, &dark, sizeof(dark)); }
    }

    ShowWindow(g_hwnd, SW_SHOW);
    UpdateWindow(g_hwnd);

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0)) {
        TranslateMessage(&msg); DispatchMessageW(&msg);
    }

    DeleteObject(g_font_title); DeleteObject(g_font_body); DeleteObject(g_font_btn);
    return 0;
}
