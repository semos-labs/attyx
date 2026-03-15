// Attyx — Custom Windows Installer
// Dark-themed, single-page installer with branded UI.
// Compile: zig cc installer.c installer.rc -o attyx-setup.exe -lkernel32 -luser32
//          -lgdi32 -lshell32 -lole32 -ladvapi32 -lshlwapi -mwindows

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef COBJMACROS
#define COBJMACROS
#endif
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <shobjidl.h>
#include <objbase.h>
#include <stdio.h>
#include <stdbool.h>

// ---------------------------------------------------------------------------
// Layout & colors
// ---------------------------------------------------------------------------

#define WIN_W       520
#define WIN_H       420
#define BG_COLOR    RGB(26, 26, 26)      // #1a1a1a
#define TEXT_COLOR   RGB(224, 224, 224)   // #e0e0e0
#define DIM_COLOR    RGB(128, 128, 128)  // #808080
#define BTN_BG       RGB(40, 40, 40)     // #282828
#define BTN_BORDER   RGB(80, 80, 80)     // #505050
#define BTN_HOVER    RGB(55, 55, 55)     // #373737
#define BTN_ACTIVE   RGB(70, 130, 180)   // steel blue accent
#define CHECK_COLOR  RGB(120, 200, 120)  // green check
#define PROGRESS_BG  RGB(50, 50, 50)
#define PROGRESS_FG  RGB(120, 200, 120)
#define MARGIN       32
#define BTN_H        38
#define LINE_H       24
#define CHECK_SZ     16

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

static HWND g_hwnd;
static HFONT g_font_title, g_font_body, g_font_mono, g_font_btn;
static HICON g_icon;
static wchar_t g_install_dir[MAX_PATH];
static bool g_opt_path     = true;
static bool g_opt_desktop  = false;
static bool g_opt_context  = true;
static bool g_installing   = false;
static bool g_done         = false;
static bool g_failed       = false;
static int  g_progress     = 0;    // 0-100
static wchar_t g_status[256] = L"";
static int  g_hover_btn    = 0;    // 0=none, 1=install, 2=browse, 3=launch
static wchar_t g_version[32] = L"";

// Hit rects
static RECT g_rc_install, g_rc_browse, g_rc_launch;
static RECT g_rc_chk_path, g_rc_chk_desktop, g_rc_chk_context;

// Payload directory (next to installer exe)
static wchar_t g_payload_dir[MAX_PATH];
static wchar_t g_exe_dir[MAX_PATH];

// ---------------------------------------------------------------------------
// Forward declarations
// ---------------------------------------------------------------------------

static void DoPaint(HWND hwnd);
static void DoInstall(void);
static DWORD WINAPI InstallThread(LPVOID param);
static void DrawButton(HDC hdc, RECT* rc, const wchar_t* text, bool hover, bool accent);
static void DrawCheckbox(HDC hdc, int x, int y, const wchar_t* text, bool checked, RECT* hitOut);
static int  HitTest(int x, int y);
static bool CopyDirRecursive(const wchar_t* src, const wchar_t* dst);
static bool CreateShortcutLink(const wchar_t* lnkPath, const wchar_t* target,
                                const wchar_t* desc, const wchar_t* iconPath);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static void SetStatus(const wchar_t* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vswprintf(g_status, 256, fmt, ap);
    va_end(ap);
    InvalidateRect(g_hwnd, NULL, FALSE);
}

static void InitPaths(void) {
    // Get installer exe directory
    GetModuleFileNameW(NULL, g_exe_dir, MAX_PATH);
    PathRemoveFileSpecW(g_exe_dir);

    // Payload is in dist/ next to installer
    swprintf(g_payload_dir, MAX_PATH, L"%s\\dist", g_exe_dir);
    if (!PathFileExistsW(g_payload_dir)) {
        // Try same directory (flat layout)
        wcscpy(g_payload_dir, g_exe_dir);
    }


    // Default install dir — use LocalAppData (no admin needed)
    wchar_t localApp[MAX_PATH];
    if (SHGetFolderPathW(NULL, CSIDL_LOCAL_APPDATA, NULL, 0, localApp) == S_OK)
        swprintf(g_install_dir, MAX_PATH, L"%s\\Attyx", localApp);
    else
        wcscpy(g_install_dir, L"C:\\Program Files\\Attyx");
}

// ---------------------------------------------------------------------------
// Paint
// ---------------------------------------------------------------------------

static void DoPaint(HWND hwnd) {
    PAINTSTRUCT ps;
    HDC hdc = BeginPaint(hwnd, &ps);
    RECT cr;
    GetClientRect(hwnd, &cr);
    int W = cr.right, H = cr.bottom;

    // Double buffer
    HDC mem = CreateCompatibleDC(hdc);
    HBITMAP bmp = CreateCompatibleBitmap(hdc, W, H);
    SelectObject(mem, bmp);

    // Background
    HBRUSH bgBr = CreateSolidBrush(BG_COLOR);
    FillRect(mem, &cr, bgBr);
    DeleteObject(bgBr);

    SetBkMode(mem, TRANSPARENT);
    int y = MARGIN;

    // Icon + title
    if (g_icon)
        DrawIconEx(mem, MARGIN, y, g_icon, 36, 36, 0, NULL, DI_NORMAL);
    SelectObject(mem, g_font_title);
    SetTextColor(mem, TEXT_COLOR);
    RECT tr = { MARGIN + 44, y + 4, W - MARGIN, y + 40 };
    DrawTextW(mem, L"Attyx", -1, &tr, DT_LEFT | DT_SINGLELINE);
    y += 52;

    // Tagline
    SelectObject(mem, g_font_mono);
    SetTextColor(mem, DIM_COLOR);
    RECT tg = { MARGIN, y, W - MARGIN, y + LINE_H * 2 };
    DrawTextW(mem, L"Your terminal, without the duct tape.", -1, &tg,
              DT_LEFT | DT_WORDBREAK);
    y += LINE_H * 2 + 12;

    if (!g_done) {
        // Install path
        SelectObject(mem, g_font_body);
        SetTextColor(mem, DIM_COLOR);
        RECT lb = { MARGIN, y, W - MARGIN, y + LINE_H };
        DrawTextW(mem, L"Install to:", -1, &lb, DT_LEFT | DT_SINGLELINE);
        y += LINE_H + 2;

        // Path box
        RECT pathRc = { MARGIN, y, W - MARGIN - 80, y + 30 };
        HBRUSH pathBg = CreateSolidBrush(BTN_BG);
        FillRect(mem, &pathRc, pathBg);
        DeleteObject(pathBg);
        HPEN borderPen = CreatePen(PS_SOLID, 1, BTN_BORDER);
        SelectObject(mem, borderPen);
        SelectObject(mem, GetStockObject(NULL_BRUSH));
        Rectangle(mem, pathRc.left, pathRc.top, pathRc.right, pathRc.bottom);
        DeleteObject(borderPen);
        SetTextColor(mem, TEXT_COLOR);
        RECT pathText = { MARGIN + 8, y + 6, W - MARGIN - 88, y + 26 };
        DrawTextW(mem, g_install_dir, -1, &pathText,
                  DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);

        // Browse button
        g_rc_browse = (RECT){ W - MARGIN - 72, y, W - MARGIN, y + 30 };
        DrawButton(mem, &g_rc_browse, L"Browse", g_hover_btn == 2, false);
        y += 40;

        // Checkboxes
        SelectObject(mem, g_font_body);
        DrawCheckbox(mem, MARGIN, y, L"Add to PATH", g_opt_path, &g_rc_chk_path);
        y += LINE_H + 4;
        DrawCheckbox(mem, MARGIN, y, L"Desktop shortcut", g_opt_desktop, &g_rc_chk_desktop);
        y += LINE_H + 4;
        DrawCheckbox(mem, MARGIN, y, L"\"Open Attyx Here\" context menu", g_opt_context, &g_rc_chk_context);
        y += LINE_H + 20;

        if (!g_installing) {
            // Install button
            g_rc_install = (RECT){ MARGIN, y, W - MARGIN, y + BTN_H };
            DrawButton(mem, &g_rc_install, L"Install", g_hover_btn == 1, true);
        }
    }

    // Progress bar + status
    if (g_installing || g_done) {
        int py = H - 90;
        if (g_progress > 0 || g_installing) {
            RECT pbg = { MARGIN, py, W - MARGIN, py + 6 };
            HBRUSH pBg = CreateSolidBrush(PROGRESS_BG);
            FillRect(mem, &pbg, pBg);
            DeleteObject(pBg);
            if (g_progress > 0) {
                int pw = (W - 2 * MARGIN) * g_progress / 100;
                RECT pfg = { MARGIN, py, MARGIN + pw, py + 6 };
                HBRUSH pFg = CreateSolidBrush(g_failed ? RGB(200, 80, 80) : PROGRESS_FG);
                FillRect(mem, &pfg, pFg);
                DeleteObject(pFg);
            }
        }
        // Status text
        SelectObject(mem, g_font_body);
        SetTextColor(mem, g_failed ? RGB(200, 80, 80) : DIM_COLOR);
        RECT sr = { MARGIN, py + 14, W - MARGIN, py + 14 + LINE_H };
        DrawTextW(mem, g_status, -1, &sr, DT_LEFT | DT_SINGLELINE);

        if (g_done && !g_failed) {
            int by = py + 40;
            g_rc_launch = (RECT){ MARGIN, by, MARGIN + 160, by + BTN_H };
            DrawButton(mem, &g_rc_launch, L"Launch Attyx", g_hover_btn == 3, true);

            // Close text link
            SelectObject(mem, g_font_body);
            SetTextColor(mem, DIM_COLOR);
            RECT clr = { MARGIN + 180, by + 8, W - MARGIN, by + 8 + LINE_H };
            DrawTextW(mem, L"Close", -1, &clr, DT_LEFT | DT_SINGLELINE);
        }
    }

    // Version at bottom-right
    if (g_version[0]) {
        SelectObject(mem, g_font_body);
        SetTextColor(mem, RGB(60, 60, 60));
        RECT vr = { W - 120, H - 24, W - 8, H - 4 };
        DrawTextW(mem, g_version, -1, &vr, DT_RIGHT | DT_SINGLELINE);
    }

    BitBlt(hdc, 0, 0, W, H, mem, 0, 0, SRCCOPY);
    DeleteObject(bmp);
    DeleteDC(mem);
    EndPaint(hwnd, &ps);
}

// ---------------------------------------------------------------------------
// Drawing helpers
// ---------------------------------------------------------------------------

static void DrawButton(HDC hdc, RECT* rc, const wchar_t* text, bool hover, bool accent) {
    COLORREF bg = hover ? BTN_HOVER : BTN_BG;
    COLORREF border = accent ? BTN_ACTIVE : BTN_BORDER;
    HBRUSH br = CreateSolidBrush(bg);
    FillRect(hdc, rc, br);
    DeleteObject(br);
    HPEN pen = CreatePen(PS_SOLID, accent ? 2 : 1, border);
    SelectObject(hdc, pen);
    SelectObject(hdc, GetStockObject(NULL_BRUSH));
    RoundRect(hdc, rc->left, rc->top, rc->right, rc->bottom, 6, 6);
    DeleteObject(pen);
    SelectObject(hdc, g_font_btn);
    SetTextColor(hdc, TEXT_COLOR);
    DrawTextW(hdc, text, -1, rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
}

static void DrawCheckbox(HDC hdc, int x, int y, const wchar_t* text, bool checked, RECT* hitOut) {
    *hitOut = (RECT){ x, y, x + 300, y + LINE_H };
    // Box
    HPEN pen = CreatePen(PS_SOLID, 1, BTN_BORDER);
    SelectObject(hdc, pen);
    SelectObject(hdc, GetStockObject(NULL_BRUSH));
    Rectangle(hdc, x, y + 3, x + CHECK_SZ, y + 3 + CHECK_SZ);
    DeleteObject(pen);
    if (checked) {
        // Checkmark
        HPEN chk = CreatePen(PS_SOLID, 2, CHECK_COLOR);
        SelectObject(hdc, chk);
        MoveToEx(hdc, x + 3, y + 3 + CHECK_SZ / 2, NULL);
        LineTo(hdc, x + CHECK_SZ / 2, y + 3 + CHECK_SZ - 3);
        LineTo(hdc, x + CHECK_SZ - 2, y + 5);
        DeleteObject(chk);
    }
    // Label
    SetTextColor(hdc, TEXT_COLOR);
    RECT lr = { x + CHECK_SZ + 8, y + 2, x + 400, y + 2 + LINE_H };
    DrawTextW(hdc, text, -1, &lr, DT_LEFT | DT_SINGLELINE);
}

// ---------------------------------------------------------------------------
// Hit testing
// ---------------------------------------------------------------------------

static int HitTest(int x, int y) {
    POINT pt = { x, y };
    if (!g_installing && !g_done && PtInRect(&g_rc_install, pt)) return 1;
    if (!g_installing && !g_done && PtInRect(&g_rc_browse, pt))  return 2;
    if (g_done && !g_failed && PtInRect(&g_rc_launch, pt))       return 3;
    return 0;
}

// ---------------------------------------------------------------------------
// Window procedure
// ---------------------------------------------------------------------------

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_PAINT:
        DoPaint(hwnd);
        return 0;

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
        POINT pt = { (short)LOWORD(lParam), (short)HIWORD(lParam) };
        int hit = HitTest(pt.x, pt.y);
        if (hit == 1) DoInstall();
        if (hit == 2) {
            // Browse for folder
            BROWSEINFOW bi = { .hwndOwner = hwnd, .lpszTitle = L"Select install folder",
                               .ulFlags = BIF_NEWDIALOGSTYLE };
            LPITEMIDLIST pidl = SHBrowseForFolderW(&bi);
            if (pidl) {
                SHGetPathFromIDListW(pidl, g_install_dir);
                CoTaskMemFree(pidl);
                InvalidateRect(hwnd, NULL, FALSE);
            }
        }
        if (hit == 3) {
            // Launch attyx
            wchar_t exe[MAX_PATH];
            swprintf(exe, MAX_PATH, L"%s\\attyx.exe", g_install_dir);
            ShellExecuteW(NULL, L"open", exe, NULL, NULL, SW_SHOWNORMAL);
            PostQuitMessage(0);
        }
        // Checkbox toggles
        if (!g_installing && !g_done) {
            if (PtInRect(&g_rc_chk_path, pt))    { g_opt_path = !g_opt_path; InvalidateRect(hwnd, NULL, FALSE); }
            if (PtInRect(&g_rc_chk_desktop, pt))  { g_opt_desktop = !g_opt_desktop; InvalidateRect(hwnd, NULL, FALSE); }
            if (PtInRect(&g_rc_chk_context, pt))  { g_opt_context = !g_opt_context; InvalidateRect(hwnd, NULL, FALSE); }
        }
        // Close link
        if (g_done) {
            RECT closeRc = { MARGIN + 180, 0, MARGIN + 280, 9999 };
            if (PtInRect(&closeRc, pt)) PostQuitMessage(0);
        }
        return 0;
    }

    case WM_ERASEBKGND:
        return 1; // Prevent flicker

    case WM_CLOSE:
        if (g_installing) return 0; // Don't close during install
        PostQuitMessage(0);
        return 0;

    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

// ---------------------------------------------------------------------------
// Install logic
// ---------------------------------------------------------------------------

static void DoInstall(void) {
    if (g_installing) return;
    g_installing = true;
    InvalidateRect(g_hwnd, NULL, FALSE);
    CreateThread(NULL, 0, InstallThread, NULL, 0, NULL);
}

static DWORD WINAPI InstallThread(LPVOID param) {
    (void)param;

    // Step 1: Create install directory (may need to create parent too)
    SetStatus(L"Creating directory...");
    g_progress = 5;
    // SHCreateDirectoryExW creates intermediate dirs and succeeds if exists
    int dirErr = SHCreateDirectoryExW(NULL, g_install_dir, NULL);
    if (dirErr != ERROR_SUCCESS && dirErr != ERROR_ALREADY_EXISTS
        && dirErr != ERROR_FILE_EXISTS) {
        wchar_t msg[512];
        swprintf(msg, 512, L"Error: could not create %s (code %d). Try a different path or run as admin.",
                 g_install_dir, dirErr);
        SetStatus(msg);
        g_failed = true; g_done = true;
        return 1;
    }

    // Step 2: Copy attyx.exe
    SetStatus(L"Copying attyx.exe...");
    g_progress = 10;
    wchar_t src[MAX_PATH], dst[MAX_PATH];
    swprintf(src, MAX_PATH, L"%s\\attyx.exe", g_payload_dir);
    swprintf(dst, MAX_PATH, L"%s\\attyx.exe", g_install_dir);
    if (!CopyFileW(src, dst, FALSE)) {
        DWORD err = GetLastError();
        wchar_t msg[512];
        swprintf(msg, 512, L"Error: could not copy attyx.exe (code %lu)", err);
        SetStatus(msg);
        g_failed = true; g_done = true;
        return 1;
    }

    // Step 3: Copy PDB if present
    swprintf(src, MAX_PATH, L"%s\\attyx.pdb", g_payload_dir);
    if (PathFileExistsW(src)) {
        swprintf(dst, MAX_PATH, L"%s\\attyx.pdb", g_install_dir);
        CopyFileW(src, dst, FALSE);
    }
    g_progress = 20;

    // Step 4: Copy MSYS2 sysroot
    SetStatus(L"Copying shell environment...");
    swprintf(src, MAX_PATH, L"%s\\share\\msys2", g_payload_dir);
    if (PathFileExistsW(src)) {
        swprintf(dst, MAX_PATH, L"%s\\share\\msys2", g_install_dir);
        CreateDirectoryW(g_install_dir, NULL);
        wchar_t shareDir[MAX_PATH];
        swprintf(shareDir, MAX_PATH, L"%s\\share", g_install_dir);
        CreateDirectoryW(shareDir, NULL);
        CopyDirRecursive(src, dst);
    }
    g_progress = 60;

    // Step 5: Add to PATH
    if (g_opt_path) {
        SetStatus(L"Adding to PATH...");
        HKEY hKey;
        if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Environment", 0, KEY_READ | KEY_WRITE, &hKey) == ERROR_SUCCESS) {
            wchar_t path[8192] = L"";
            DWORD sz = sizeof(path), type = 0;
            RegQueryValueExW(hKey, L"Path", NULL, &type, (BYTE*)path, &sz);
            if (!wcsstr(path, g_install_dir)) {
                if (wcslen(path) > 0) wcscat(path, L";");
                wcscat(path, g_install_dir);
                RegSetValueExW(hKey, L"Path", 0, REG_EXPAND_SZ, (BYTE*)path,
                               (DWORD)((wcslen(path) + 1) * sizeof(wchar_t)));
                SendMessageTimeoutW(HWND_BROADCAST, WM_SETTINGCHANGE, 0,
                                    (LPARAM)L"Environment", SMTO_ABORTIFHUNG, 5000, NULL);
            }
            RegCloseKey(hKey);
        }
    }
    g_progress = 70;

    // Step 6: Start Menu shortcut
    SetStatus(L"Creating shortcuts...");
    {
        wchar_t startMenu[MAX_PATH];
        if (SHGetFolderPathW(NULL, CSIDL_PROGRAMS, NULL, 0, startMenu) == S_OK) {
            wcscat(startMenu, L"\\Attyx");
            CreateDirectoryW(startMenu, NULL);
            wchar_t lnk[MAX_PATH];
            swprintf(lnk, MAX_PATH, L"%s\\Attyx.lnk", startMenu);
            swprintf(dst, MAX_PATH, L"%s\\attyx.exe", g_install_dir);
            CreateShortcutLink(lnk, dst, L"Attyx Terminal", dst);
        }
    }
    g_progress = 80;

    // Step 7: Desktop shortcut
    if (g_opt_desktop) {
        wchar_t desktop[MAX_PATH];
        if (SHGetFolderPathW(NULL, CSIDL_DESKTOPDIRECTORY, NULL, 0, desktop) == S_OK) {
            wchar_t lnk[MAX_PATH];
            swprintf(lnk, MAX_PATH, L"%s\\Attyx.lnk", desktop);
            swprintf(dst, MAX_PATH, L"%s\\attyx.exe", g_install_dir);
            CreateShortcutLink(lnk, dst, L"Attyx Terminal", dst);
        }
    }

    // Step 8: Context menu
    if (g_opt_context) {
        SetStatus(L"Registering context menu...");
        HKEY hKey;
        swprintf(dst, MAX_PATH, L"\"%s\\attyx.exe\" \"%%V\"", g_install_dir);
        // Folder background
        RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Classes\\Directory\\Background\\shell\\Attyx",
                        0, NULL, 0, KEY_WRITE, NULL, &hKey, NULL);
        RegSetValueExW(hKey, NULL, 0, REG_SZ, (BYTE*)L"Open Attyx Here",
                       (DWORD)(16 * sizeof(wchar_t)));
        wchar_t iconVal[MAX_PATH];
        swprintf(iconVal, MAX_PATH, L"\"%s\\attyx.exe\"", g_install_dir);
        RegSetValueExW(hKey, L"Icon", 0, REG_SZ, (BYTE*)iconVal,
                       (DWORD)((wcslen(iconVal) + 1) * sizeof(wchar_t)));
        RegCloseKey(hKey);
        RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Classes\\Directory\\Background\\shell\\Attyx\\command",
                        0, NULL, 0, KEY_WRITE, NULL, &hKey, NULL);
        RegSetValueExW(hKey, NULL, 0, REG_SZ, (BYTE*)dst,
                       (DWORD)((wcslen(dst) + 1) * sizeof(wchar_t)));
        RegCloseKey(hKey);
        // Folder right-click
        RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Classes\\Directory\\shell\\Attyx",
                        0, NULL, 0, KEY_WRITE, NULL, &hKey, NULL);
        RegSetValueExW(hKey, NULL, 0, REG_SZ, (BYTE*)L"Open Attyx Here",
                       (DWORD)(16 * sizeof(wchar_t)));
        RegSetValueExW(hKey, L"Icon", 0, REG_SZ, (BYTE*)iconVal,
                       (DWORD)((wcslen(iconVal) + 1) * sizeof(wchar_t)));
        RegCloseKey(hKey);
        RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Classes\\Directory\\shell\\Attyx\\command",
                        0, NULL, 0, KEY_WRITE, NULL, &hKey, NULL);
        RegSetValueExW(hKey, NULL, 0, REG_SZ, (BYTE*)dst,
                       (DWORD)((wcslen(dst) + 1) * sizeof(wchar_t)));
        RegCloseKey(hKey);
    }
    g_progress = 90;

    // Step 9: Add/Remove Programs entry
    SetStatus(L"Registering uninstaller...");
    {
        HKEY hKey;
        RegCreateKeyExW(HKEY_CURRENT_USER,
            L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Attyx",
            0, NULL, 0, KEY_WRITE, NULL, &hKey, NULL);
        RegSetValueExW(hKey, L"DisplayName", 0, REG_SZ, (BYTE*)L"Attyx",
                       6 * sizeof(wchar_t));
        swprintf(dst, MAX_PATH, L"\"%s\\attyx.exe\" uninstall", g_install_dir);
        RegSetValueExW(hKey, L"UninstallString", 0, REG_SZ, (BYTE*)dst,
                       (DWORD)((wcslen(dst) + 1) * sizeof(wchar_t)));
        swprintf(dst, MAX_PATH, L"%s\\attyx.exe", g_install_dir);
        RegSetValueExW(hKey, L"DisplayIcon", 0, REG_SZ, (BYTE*)dst,
                       (DWORD)((wcslen(dst) + 1) * sizeof(wchar_t)));
        RegSetValueExW(hKey, L"Publisher", 0, REG_SZ, (BYTE*)L"Attyx",
                       6 * sizeof(wchar_t));
        if (g_version[0]) {
            RegSetValueExW(hKey, L"DisplayVersion", 0, REG_SZ, (BYTE*)g_version,
                           (DWORD)((wcslen(g_version) + 1) * sizeof(wchar_t)));
        }
        DWORD noModify = 1;
        RegSetValueExW(hKey, L"NoModify", 0, REG_DWORD, (BYTE*)&noModify, sizeof(DWORD));
        RegSetValueExW(hKey, L"NoRepair", 0, REG_DWORD, (BYTE*)&noModify, sizeof(DWORD));
        RegSetValueExW(hKey, L"InstallLocation", 0, REG_SZ, (BYTE*)g_install_dir,
                       (DWORD)((wcslen(g_install_dir) + 1) * sizeof(wchar_t)));
        RegCloseKey(hKey);
    }
    g_progress = 100;

    g_done = true;
    SetStatus(L"Installation complete!");
    return 0;
}

// ---------------------------------------------------------------------------
// File helpers
// ---------------------------------------------------------------------------

static bool CopyDirRecursive(const wchar_t* src, const wchar_t* dst) {
    CreateDirectoryW(dst, NULL);
    wchar_t search[MAX_PATH];
    swprintf(search, MAX_PATH, L"%s\\*", src);
    WIN32_FIND_DATAW fd;
    HANDLE hFind = FindFirstFileW(search, &fd);
    if (hFind == INVALID_HANDLE_VALUE) return false;
    do {
        if (wcscmp(fd.cFileName, L".") == 0 || wcscmp(fd.cFileName, L"..") == 0)
            continue;
        wchar_t srcPath[MAX_PATH], dstPath[MAX_PATH];
        swprintf(srcPath, MAX_PATH, L"%s\\%s", src, fd.cFileName);
        swprintf(dstPath, MAX_PATH, L"%s\\%s", dst, fd.cFileName);
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
            CopyDirRecursive(srcPath, dstPath);
        else
            CopyFileW(srcPath, dstPath, FALSE);
    } while (FindNextFileW(hFind, &fd));
    FindClose(hFind);
    return true;
}

static bool CreateShortcutLink(const wchar_t* lnkPath, const wchar_t* target,
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

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmdLineA, int cmdShow) {
    (void)hPrev; (void)cmdLineA; (void)cmdShow;
    LPWSTR cmdLine = GetCommandLineW();
    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);

    // Parse /version=X.Y.Z from command line
    if (cmdLine && wcsstr(cmdLine, L"/version=")) {
        const wchar_t* v = wcsstr(cmdLine, L"/version=") + 9;
        int i = 0;
        while (*v && *v != ' ' && i < 30) g_version[i++] = *v++;
        g_version[i] = 0;
    }

    InitPaths();

    // Fonts
    g_font_title = CreateFontW(-24, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET,
        0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    g_font_body = CreateFontW(-14, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
        0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    g_font_mono = CreateFontW(-15, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
        0, 0, CLEARTYPE_QUALITY, 0, L"Cascadia Mono");
    g_font_btn = CreateFontW(-14, 0, 0, 0, FW_SEMIBOLD, 0, 0, 0, DEFAULT_CHARSET,
        0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    g_icon = LoadIconW(hInst, MAKEINTRESOURCEW(1));

    // Window class
    WNDCLASSEXW wc = {
        .cbSize = sizeof(wc),
        .lpfnWndProc = WndProc,
        .hInstance = hInst,
        .hCursor = LoadCursorW(NULL, IDC_ARROW),
        .hIcon = g_icon,
        .hIconSm = g_icon,
        .lpszClassName = L"AttyxInstaller",
    };
    RegisterClassExW(&wc);

    // Center on screen
    int sx = GetSystemMetrics(SM_CXSCREEN);
    int sy = GetSystemMetrics(SM_CYSCREEN);
    RECT wr = { 0, 0, WIN_W, WIN_H };
    AdjustWindowRect(&wr, WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU, FALSE);
    int ww = wr.right - wr.left, wh = wr.bottom - wr.top;

    g_hwnd = CreateWindowExW(0, L"AttyxInstaller",
        L"Attyx Setup",
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
        (sx - ww) / 2, (sy - wh) / 2, ww, wh,
        NULL, NULL, hInst, NULL);

    // Dark title bar (Windows 10 1809+)
    HMODULE dwm = LoadLibraryW(L"dwmapi.dll");
    if (dwm) {
        typedef HRESULT (WINAPI *PFN)(HWND, DWORD, const void*, DWORD);
        PFN fn = (PFN)GetProcAddress(dwm, "DwmSetWindowAttribute");
        if (fn) {
            BOOL dark = TRUE;
            fn(g_hwnd, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, &dark, sizeof(dark));
        }
    }

    ShowWindow(g_hwnd, SW_SHOW);
    UpdateWindow(g_hwnd);

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    DeleteObject(g_font_title);
    DeleteObject(g_font_body);
    DeleteObject(g_font_mono);
    DeleteObject(g_font_btn);
    CoUninitialize();
    return 0;
}
