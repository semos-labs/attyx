// Attyx — Custom Windows Installer
// Dark-themed installer with branded UI.

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

#define WIN_W       560
#define WIN_H       440
#define BG           RGB(18, 18, 18)       // #121212
#define CARD_BG      RGB(24, 24, 24)       // #181818
#define CARD_BORDER  RGB(42, 42, 42)       // #2a2a2a
#define TEXT_PRI     RGB(230, 230, 230)    // #e6e6e6
#define TEXT_SEC     RGB(110, 110, 110)    // #6e6e6e
#define TEXT_TER     RGB(60, 60, 60)       // #3c3c3c
#define ACCENT       RGB(230, 230, 230)   // white — matches website
#define ACCENT_HOV   RGB(255, 255, 255)   // bright white
#define ACCENT_DIM   RGB(160, 160, 160)   // muted
#define INPUT_BG     RGB(28, 28, 28)      // #1c1c1c
#define INPUT_BORDER RGB(50, 50, 50)      // #323232
#define ERR_COLOR    RGB(200, 80, 80)     // red
#define PROGRESS_BG  RGB(34, 34, 34)      // #222222
#define CHECK_BG     RGB(34, 34, 34)
#define PAD          40                    // outer padding
#define BTN_H        42
#define LINE_H       22
#define CHECK_SZ     18
#define RADIUS       8

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

static HWND g_hwnd;
static HFONT g_font_hero, g_font_title, g_font_body, g_font_small, g_font_btn;
static HICON g_icon;
static wchar_t g_install_dir[MAX_PATH];
static bool g_opt_path     = true;
static bool g_opt_desktop  = false;
static bool g_opt_context  = true;
static bool g_installing   = false;
static bool g_done         = false;
static bool g_failed       = false;
static int  g_progress     = 0;
static wchar_t g_status[256] = L"";
static int  g_hover_btn    = 0;    // 0=none 1=install 2=browse 3=launch 4=close
static wchar_t g_version[32] = L"";

static RECT g_rc_install, g_rc_browse, g_rc_launch, g_rc_close;
static RECT g_rc_chk_path, g_rc_chk_desktop, g_rc_chk_context;

static wchar_t g_payload_dir[MAX_PATH];
static wchar_t g_exe_dir[MAX_PATH];

// ---------------------------------------------------------------------------
// Forward declarations
// ---------------------------------------------------------------------------

static void DoPaint(HWND hwnd);
static void DoInstall(void);
static DWORD WINAPI InstallThread(LPVOID param);
static int  HitTest(int x, int y);
static bool CopyDirRecursive(const wchar_t* src, const wchar_t* dst);
static bool CreateShortcutLink(const wchar_t* lnkPath, const wchar_t* target,
                                const wchar_t* desc, const wchar_t* iconPath);
static void ApplyPostInstallOptions(void);

// ---------------------------------------------------------------------------
// Drawing primitives
// ---------------------------------------------------------------------------

static void FillRoundRect(HDC hdc, RECT* rc, int r, COLORREF fill) {
    HBRUSH br = CreateSolidBrush(fill);
    HPEN pen = CreatePen(PS_SOLID, 1, fill);
    HGDIOBJ oldBr = SelectObject(hdc, br);
    HGDIOBJ oldPen = SelectObject(hdc, pen);
    RoundRect(hdc, rc->left, rc->top, rc->right, rc->bottom, r, r);
    SelectObject(hdc, oldBr);
    SelectObject(hdc, oldPen);
    DeleteObject(br);
    DeleteObject(pen);
}

static void StrokeRoundRect(HDC hdc, RECT* rc, int r, COLORREF color) {
    HPEN pen = CreatePen(PS_SOLID, 1, color);
    HGDIOBJ oldPen = SelectObject(hdc, pen);
    SelectObject(hdc, GetStockObject(NULL_BRUSH));
    RoundRect(hdc, rc->left, rc->top, rc->right, rc->bottom, r, r);
    SelectObject(hdc, oldPen);
    DeleteObject(pen);
}

static void DrawBtn(HDC hdc, RECT* rc, const wchar_t* text, bool hover, bool filled) {
    COLORREF bg, fg, border;
    if (filled) {
        bg = hover ? ACCENT_HOV : ACCENT;
        fg = RGB(18, 18, 18);
        border = bg;
    } else {
        bg = BG;
        fg = hover ? TEXT_PRI : TEXT_SEC;
        border = hover ? RGB(80,80,80) : CARD_BORDER;
    }
    FillRoundRect(hdc, rc, RADIUS, bg);
    StrokeRoundRect(hdc, rc, RADIUS, border);
    SelectObject(hdc, g_font_btn);
    SetTextColor(hdc, fg);
    DrawTextW(hdc, text, -1, rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
}

static void DrawCheck(HDC hdc, int x, int y, const wchar_t* text, bool checked, RECT* hit, int maxRight) {
    *hit = (RECT){ x, y, maxRight, y + LINE_H + 4 };
    int by = y + 1;
    RECT box = { x, by, x + CHECK_SZ, by + CHECK_SZ };
    if (checked) {
        HBRUSH br = CreateSolidBrush(ACCENT);
        FillRect(hdc, &box, br);
        DeleteObject(br);
        // Checkmark
        HPEN pen = CreatePen(PS_SOLID, 2, RGB(14,14,14));
        HGDIOBJ old = SelectObject(hdc, pen);
        MoveToEx(hdc, x + 4, by + CHECK_SZ/2, NULL);
        LineTo(hdc, x + CHECK_SZ/2 - 1, by + CHECK_SZ - 4);
        LineTo(hdc, x + CHECK_SZ - 3, by + 4);
        SelectObject(hdc, old);
        DeleteObject(pen);
    } else {
        HPEN pen = CreatePen(PS_SOLID, 1, INPUT_BORDER);
        HGDIOBJ old = SelectObject(hdc, pen);
        SelectObject(hdc, GetStockObject(NULL_BRUSH));
        Rectangle(hdc, box.left, box.top, box.right, box.bottom);
        SelectObject(hdc, old);
        DeleteObject(pen);
    }
    SelectObject(hdc, g_font_body);
    SetTextColor(hdc, TEXT_PRI);
    RECT lr = { x + CHECK_SZ + 10, y + 1, maxRight, y + 1 + LINE_H };
    DrawTextW(hdc, text, -1, &lr, DT_LEFT | DT_SINGLELINE);
}

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

// Translate a Win32 error code into a short human-readable reason.
static const wchar_t* DescribeError(DWORD code) {
    switch (code) {
    case ERROR_ACCESS_DENIED:       return L"Access denied. Try a different folder or close any programs using Attyx.";
    case ERROR_SHARING_VIOLATION:   return L"The file is in use by another program. Close Attyx and try again.";
    case ERROR_DISK_FULL:           return L"Not enough disk space. Free some space and try again.";
    case ERROR_PATH_NOT_FOUND:      return L"The install path does not exist and could not be created.";
    case ERROR_FILE_NOT_FOUND:      return L"A required file is missing from the installer package.";
    case ERROR_WRITE_PROTECT:       return L"The disk is write-protected.";
    case ERROR_DIRECTORY:           return L"The directory name is invalid.";
    case ERROR_ALREADY_EXISTS:      return L"A file with that name already exists.";
    case ERROR_INVALID_NAME:        return L"The folder path contains invalid characters.";
    default: {
        // Ask Windows for a description
        static wchar_t buf[256];
        DWORD len = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                                    NULL, code, 0, buf, 256, NULL);
        if (len > 0) {
            // Trim trailing \r\n
            while (len > 0 && (buf[len-1] == '\n' || buf[len-1] == '\r')) buf[--len] = 0;
            return buf;
        }
        swprintf(buf, 256, L"Unexpected error (code %lu).", code);
        return buf;
    }
    }
}

static void InitPaths(void) {
    GetModuleFileNameW(NULL, g_exe_dir, MAX_PATH);
    PathRemoveFileSpecW(g_exe_dir);
    swprintf(g_payload_dir, MAX_PATH, L"%s\\dist", g_exe_dir);
    if (!PathFileExistsW(g_payload_dir))
        wcscpy(g_payload_dir, g_exe_dir);
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

    HDC mem = CreateCompatibleDC(hdc);
    HBITMAP bmp = CreateCompatibleBitmap(hdc, W, H);
    SelectObject(mem, bmp);
    SetBkMode(mem, TRANSPARENT);

    // Background
    HBRUSH bgBr = CreateSolidBrush(BG);
    FillRect(mem, &cr, bgBr);
    DeleteObject(bgBr);

    // ── Header area ──
    int y = PAD;

    // Icon
    int iconSz = 48;
    if (g_icon)
        DrawIconEx(mem, PAD, y, g_icon, iconSz, iconSz, 0, NULL, DI_NORMAL);

    // Title — vertically centered with icon
    SelectObject(mem, g_font_hero);
    SetTextColor(mem, TEXT_PRI);
    RECT tr = { PAD + iconSz + 14, y + 6, W - PAD, y + iconSz };
    DrawTextW(mem, L"Attyx", -1, &tr, DT_LEFT | DT_VCENTER | DT_SINGLELINE);

    // Version badge
    if (g_version[0]) {
        SelectObject(mem, g_font_small);
        SetTextColor(mem, TEXT_TER);
        RECT vr = { PAD + iconSz + 120, y + 18, W - PAD, y + 36 };
        DrawTextW(mem, g_version, -1, &vr, DT_LEFT | DT_SINGLELINE);
    }
    y += iconSz + 8;

    // Tagline
    SelectObject(mem, g_font_body);
    SetTextColor(mem, TEXT_SEC);
    RECT tg = { PAD, y, W - PAD, y + LINE_H };
    DrawTextW(mem, L"Your terminal, without the duct tape.", -1, &tg, DT_LEFT | DT_SINGLELINE);
    y += LINE_H + 24;

    // ── Separator ──
    RECT sep = { PAD, y, W - PAD, y + 1 };
    HBRUSH sepBr = CreateSolidBrush(CARD_BORDER);
    FillRect(mem, &sep, sepBr);
    DeleteObject(sepBr);
    y += 24;

    // ── Content area ──
    if (!g_done && !g_installing) {
        // INSTALL SCREEN
        SelectObject(mem, g_font_small);
        SetTextColor(mem, TEXT_SEC);
        RECT lb = { PAD, y, W - PAD, y + LINE_H };
        DrawTextW(mem, L"INSTALL LOCATION", -1, &lb, DT_LEFT | DT_SINGLELINE);
        y += LINE_H + 6;

        // Path input with card styling
        int pathRight = W - PAD - 90;
        RECT pathCard = { PAD, y, pathRight, y + 40 };
        FillRoundRect(mem, &pathCard, 6, INPUT_BG);
        StrokeRoundRect(mem, &pathCard, 6, INPUT_BORDER);

        SelectObject(mem, g_font_body);
        SetTextColor(mem, TEXT_PRI);
        RECT pathText = { PAD + 14, y + 10, pathRight - 8, y + 30 };
        DrawTextW(mem, g_install_dir, -1, &pathText,
                  DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);

        // Browse button
        g_rc_browse = (RECT){ pathRight + 8, y, W - PAD, y + 40 };
        DrawBtn(mem, &g_rc_browse, L"...", g_hover_btn == 2, false);
        y += 60;

        // Install button (full width, prominent)
        g_rc_install = (RECT){ PAD, y, W - PAD, y + BTN_H };
        DrawBtn(mem, &g_rc_install, L"Install", g_hover_btn == 1, true);

        // Disk space hint
        y += BTN_H + 12;
        SelectObject(mem, g_font_small);
        SetTextColor(mem, TEXT_TER);
        RECT hint = { PAD, y, W - PAD, y + LINE_H };
        DrawTextW(mem, L"No admin rights required", -1, &hint, DT_LEFT | DT_SINGLELINE);
    }

    if (g_installing && !g_done) {
        // PROGRESS SCREEN
        int py = y + 40;

        // Status text above progress
        SelectObject(mem, g_font_body);
        SetTextColor(mem, TEXT_SEC);
        RECT sr = { PAD, py, W - PAD, py + LINE_H };
        DrawTextW(mem, g_status, -1, &sr, DT_LEFT | DT_SINGLELINE);
        py += LINE_H + 12;

        // Progress bar (rounded, thick)
        RECT pbg = { PAD, py, W - PAD, py + 8 };
        FillRoundRect(mem, &pbg, 4, PROGRESS_BG);
        if (g_progress > 0) {
            int pw = (W - 2 * PAD) * g_progress / 100;
            if (pw < 8) pw = 8;
            RECT pfg = { PAD, py, PAD + pw, py + 8 };
            FillRoundRect(mem, &pfg, 4, ACCENT);
        }

        // Percentage
        py += 20;
        wchar_t pct[8];
        swprintf(pct, 8, L"%d%%", g_progress);
        SelectObject(mem, g_font_small);
        SetTextColor(mem, TEXT_SEC);
        RECT pr = { PAD, py, W - PAD, py + LINE_H };
        DrawTextW(mem, pct, -1, &pr, DT_LEFT | DT_SINGLELINE);
    }

    if (g_done && g_failed) {
        // ERROR SCREEN
        int ey = y + 20;
        SelectObject(mem, g_font_title);
        SetTextColor(mem, ERR_COLOR);
        RECT er = { PAD, ey, W - PAD, ey + 30 };
        DrawTextW(mem, L"Installation failed", -1, &er, DT_LEFT | DT_SINGLELINE);
        ey += 36;

        SelectObject(mem, g_font_body);
        SetTextColor(mem, TEXT_SEC);
        RECT sr = { PAD, ey, W - PAD, ey + LINE_H * 3 };
        DrawTextW(mem, g_status, -1, &sr, DT_LEFT | DT_WORDBREAK);
    }

    if (g_done && !g_failed) {
        // SUCCESS SCREEN
        int sy = y;

        // Success message
        SelectObject(mem, g_font_title);
        SetTextColor(mem, TEXT_PRI);
        RECT sr = { PAD, sy, W - PAD, sy + 30 };
        DrawTextW(mem, L"Installed successfully", -1, &sr, DT_LEFT | DT_SINGLELINE);
        sy += 40;

        // Options
        SelectObject(mem, g_font_small);
        SetTextColor(mem, TEXT_SEC);
        RECT ol = { PAD, sy, W - PAD, sy + LINE_H };
        DrawTextW(mem, L"OPTIONS", -1, &ol, DT_LEFT | DT_SINGLELINE);
        sy += LINE_H + 8;

        DrawCheck(mem, PAD, sy, L"Add to PATH", g_opt_path, &g_rc_chk_path, W - PAD);
        sy += LINE_H + 8;
        DrawCheck(mem, PAD, sy, L"Create desktop shortcut", g_opt_desktop, &g_rc_chk_desktop, W - PAD);
        sy += LINE_H + 8;
        DrawCheck(mem, PAD, sy, L"Add \"Open Attyx Here\" to context menu", g_opt_context, &g_rc_chk_context, W - PAD);
        sy += LINE_H + 24;

        // Buttons
        int btnW = (W - 2 * PAD - 12) / 2;
        g_rc_launch = (RECT){ PAD, sy, PAD + btnW, sy + BTN_H };
        DrawBtn(mem, &g_rc_launch, L"Launch Attyx", g_hover_btn == 3, true);

        g_rc_close = (RECT){ PAD + btnW + 12, sy, W - PAD, sy + BTN_H };
        DrawBtn(mem, &g_rc_close, L"Close", g_hover_btn == 4, false);
    }

    BitBlt(hdc, 0, 0, W, H, mem, 0, 0, SRCCOPY);
    DeleteObject(bmp);
    DeleteDC(mem);
    EndPaint(hwnd, &ps);
}

// ---------------------------------------------------------------------------
// Hit testing
// ---------------------------------------------------------------------------

static int HitTest(int x, int y) {
    POINT pt = { x, y };
    if (!g_installing && !g_done && PtInRect(&g_rc_install, pt)) return 1;
    if (!g_installing && !g_done && PtInRect(&g_rc_browse, pt))  return 2;
    if (g_done && !g_failed && PtInRect(&g_rc_launch, pt))       return 3;
    if (g_done && !g_failed && PtInRect(&g_rc_close, pt))        return 4;
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
        // Cursor: hand on buttons
        SetCursor(LoadCursorW(NULL, g_hover_btn ? IDC_HAND : IDC_ARROW));
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
            ApplyPostInstallOptions();
            wchar_t exe[MAX_PATH];
            swprintf(exe, MAX_PATH, L"%s\\attyx.exe", g_install_dir);
            ShellExecuteW(NULL, L"open", exe, NULL, NULL, SW_SHOWNORMAL);
            PostQuitMessage(0);
        }
        if (hit == 4) {
            ApplyPostInstallOptions();
            PostQuitMessage(0);
        }
        // Checkbox toggles
        if (g_done && !g_failed) {
            if (PtInRect(&g_rc_chk_path, pt))    { g_opt_path = !g_opt_path; InvalidateRect(hwnd, NULL, FALSE); }
            if (PtInRect(&g_rc_chk_desktop, pt))  { g_opt_desktop = !g_opt_desktop; InvalidateRect(hwnd, NULL, FALSE); }
            if (PtInRect(&g_rc_chk_context, pt))  { g_opt_context = !g_opt_context; InvalidateRect(hwnd, NULL, FALSE); }
        }
        return 0;
    }

    case WM_ERASEBKGND:
        return 1;

    case WM_CLOSE:
        if (g_installing) return 0;
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

    SetStatus(L"Creating directory...");
    g_progress = 5;
    int dirErr = SHCreateDirectoryExW(NULL, g_install_dir, NULL);
    if (dirErr != ERROR_SUCCESS && dirErr != ERROR_ALREADY_EXISTS
        && dirErr != ERROR_FILE_EXISTS) {
        wchar_t msg[512];
        swprintf(msg, 512, L"Could not create folder: %s", DescribeError((DWORD)dirErr));
        SetStatus(msg);
        g_failed = true; g_done = true; g_installing = false;
        return 1;
    }

    SetStatus(L"Copying files...");
    g_progress = 10;
    wchar_t src[MAX_PATH], dst[MAX_PATH];
    swprintf(src, MAX_PATH, L"%s\\attyx.exe", g_payload_dir);
    swprintf(dst, MAX_PATH, L"%s\\attyx.exe", g_install_dir);
    if (!CopyFileW(src, dst, FALSE)) {
        DWORD err = GetLastError();
        wchar_t msg[512];
        swprintf(msg, 512, L"Could not install attyx.exe: %s", DescribeError(err));
        SetStatus(msg);
        g_failed = true; g_done = true; g_installing = false;
        return 1;
    }

    swprintf(src, MAX_PATH, L"%s\\attyx.pdb", g_payload_dir);
    if (PathFileExistsW(src)) {
        swprintf(dst, MAX_PATH, L"%s\\attyx.pdb", g_install_dir);
        CopyFileW(src, dst, FALSE);
    }
    g_progress = 20;

    SetStatus(L"Setting up shell environment...");
    swprintf(src, MAX_PATH, L"%s\\share\\msys2", g_payload_dir);
    if (PathFileExistsW(src)) {
        swprintf(dst, MAX_PATH, L"%s\\share\\msys2", g_install_dir);
        wchar_t shareDir[MAX_PATH];
        swprintf(shareDir, MAX_PATH, L"%s\\share", g_install_dir);
        CreateDirectoryW(shareDir, NULL);
        CopyDirRecursive(src, dst);
    }
    g_progress = 70;

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
    g_progress = 90;

    SetStatus(L"Registering...");
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
        if (g_version[0])
            RegSetValueExW(hKey, L"DisplayVersion", 0, REG_SZ, (BYTE*)g_version,
                           (DWORD)((wcslen(g_version) + 1) * sizeof(wchar_t)));
        DWORD noModify = 1;
        RegSetValueExW(hKey, L"NoModify", 0, REG_DWORD, (BYTE*)&noModify, sizeof(DWORD));
        RegSetValueExW(hKey, L"NoRepair", 0, REG_DWORD, (BYTE*)&noModify, sizeof(DWORD));
        RegSetValueExW(hKey, L"InstallLocation", 0, REG_SZ, (BYTE*)g_install_dir,
                       (DWORD)((wcslen(g_install_dir) + 1) * sizeof(wchar_t)));
        RegCloseKey(hKey);
    }
    g_progress = 100;
    g_done = true;
    g_installing = false;
    SetStatus(L"");
    return 0;
}

// ---------------------------------------------------------------------------
// Post-install options
// ---------------------------------------------------------------------------

static void ApplyPostInstallOptions(void) {
    wchar_t dst[MAX_PATH];

    if (g_opt_path) {
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

    if (g_opt_desktop) {
        wchar_t desktop[MAX_PATH];
        if (SHGetFolderPathW(NULL, CSIDL_DESKTOPDIRECTORY, NULL, 0, desktop) == S_OK) {
            wchar_t lnk[MAX_PATH];
            swprintf(lnk, MAX_PATH, L"%s\\Attyx.lnk", desktop);
            swprintf(dst, MAX_PATH, L"%s\\attyx.exe", g_install_dir);
            CreateShortcutLink(lnk, dst, L"Attyx Terminal", dst);
        }
    }

    if (g_opt_context) {
        HKEY hKey;
        swprintf(dst, MAX_PATH, L"\"%s\\attyx.exe\" \"%%V\"", g_install_dir);
        wchar_t iconVal[MAX_PATH];
        swprintf(iconVal, MAX_PATH, L"\"%s\\attyx.exe\"", g_install_dir);
        RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Classes\\Directory\\Background\\shell\\Attyx",
                        0, NULL, 0, KEY_WRITE, NULL, &hKey, NULL);
        RegSetValueExW(hKey, NULL, 0, REG_SZ, (BYTE*)L"Open Attyx Here", 16 * sizeof(wchar_t));
        RegSetValueExW(hKey, L"Icon", 0, REG_SZ, (BYTE*)iconVal,
                       (DWORD)((wcslen(iconVal) + 1) * sizeof(wchar_t)));
        RegCloseKey(hKey);
        RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Classes\\Directory\\Background\\shell\\Attyx\\command",
                        0, NULL, 0, KEY_WRITE, NULL, &hKey, NULL);
        RegSetValueExW(hKey, NULL, 0, REG_SZ, (BYTE*)dst, (DWORD)((wcslen(dst)+1)*sizeof(wchar_t)));
        RegCloseKey(hKey);
        RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Classes\\Directory\\shell\\Attyx",
                        0, NULL, 0, KEY_WRITE, NULL, &hKey, NULL);
        RegSetValueExW(hKey, NULL, 0, REG_SZ, (BYTE*)L"Open Attyx Here", 16 * sizeof(wchar_t));
        RegSetValueExW(hKey, L"Icon", 0, REG_SZ, (BYTE*)iconVal,
                       (DWORD)((wcslen(iconVal) + 1) * sizeof(wchar_t)));
        RegCloseKey(hKey);
        RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Classes\\Directory\\shell\\Attyx\\command",
                        0, NULL, 0, KEY_WRITE, NULL, &hKey, NULL);
        RegSetValueExW(hKey, NULL, 0, REG_SZ, (BYTE*)dst, (DWORD)((wcslen(dst)+1)*sizeof(wchar_t)));
        RegCloseKey(hKey);
    }
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
        if (wcscmp(fd.cFileName, L".") == 0 || wcscmp(fd.cFileName, L"..") == 0) continue;
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

    if (cmdLine && wcsstr(cmdLine, L"/version=")) {
        const wchar_t* v = wcsstr(cmdLine, L"/version=") + 9;
        int i = 0;
        while (*v && *v != ' ' && i < 30) g_version[i++] = *v++;
        g_version[i] = 0;
    }

    InitPaths();

    g_font_hero  = CreateFontW(-30, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET,
        0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    g_font_title = CreateFontW(-20, 0, 0, 0, FW_SEMIBOLD, 0, 0, 0, DEFAULT_CHARSET,
        0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    g_font_body  = CreateFontW(-14, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
        0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    g_font_small = CreateFontW(-12, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
        0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    g_font_btn   = CreateFontW(-14, 0, 0, 0, FW_SEMIBOLD, 0, 0, 0, DEFAULT_CHARSET,
        0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    // Load high-res icon (48x48) from the embedded ICO resource
    g_icon = (HICON)LoadImageW(hInst, MAKEINTRESOURCEW(1), IMAGE_ICON, 48, 48, LR_DEFAULTCOLOR);
    if (!g_icon) g_icon = LoadIconW(hInst, MAKEINTRESOURCEW(1));

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

    int sx = GetSystemMetrics(SM_CXSCREEN);
    int sy = GetSystemMetrics(SM_CYSCREEN);
    RECT wr = { 0, 0, WIN_W, WIN_H };
    DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU;
    AdjustWindowRect(&wr, style, FALSE);
    int ww = wr.right - wr.left, wh = wr.bottom - wr.top;

    g_hwnd = CreateWindowExW(0, L"AttyxInstaller", L"Attyx Setup", style,
        (sx - ww) / 2, (sy - wh) / 2, ww, wh,
        NULL, NULL, hInst, NULL);

    // Dark title bar
    HMODULE dwm = LoadLibraryW(L"dwmapi.dll");
    if (dwm) {
        typedef HRESULT (WINAPI *PFN)(HWND, DWORD, const void*, DWORD);
        PFN fn = (PFN)GetProcAddress(dwm, "DwmSetWindowAttribute");
        if (fn) {
            BOOL dark = TRUE;
            fn(g_hwnd, 20, &dark, sizeof(dark));
        }
    }

    ShowWindow(g_hwnd, SW_SHOW);
    UpdateWindow(g_hwnd);

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    DeleteObject(g_font_hero);
    DeleteObject(g_font_title);
    DeleteObject(g_font_body);
    DeleteObject(g_font_small);
    DeleteObject(g_font_btn);
    CoUninitialize();
    return 0;
}
