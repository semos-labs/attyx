// Attyx — Auto-update (Windows)
// Native Win32 update window with download progress.
// Mirrors the macOS updater (macos_updater.m) but uses Win32 + WinHTTP.
// Fetches the unified appcast, shows an update window with release notes,
// downloads the new binary to the staging path for the daemon to hot-swap.

#ifdef _WIN32

#include <windows.h>
#include <winhttp.h>
#include <shlobj.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "winhttp.lib")

// ---------------------------------------------------------------------------
// Forward declarations
// ---------------------------------------------------------------------------
static void updateLog(const char *msg);

// ---------------------------------------------------------------------------
// Externals
// ---------------------------------------------------------------------------
extern HWND g_hwnd;  // Main terminal window handle (platform_windows.c)

// Current version — set by attyx_updater_init_with_version().
static char g_current_version[64] = "0.0.0";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------
static wchar_t g_appcast_host[256] = L"semos.sh";
static wchar_t g_appcast_path[512] = L"/appcast.xml";
static int g_appcast_port = 443;
static int g_appcast_secure = 1;
static const char *TARGET_OS = "windows";

#if defined(_M_ARM64) || defined(__aarch64__)
static const char *TARGET_ARCH = "arm64";
#else
static const char *TARGET_ARCH = "x86_64";
#endif

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
static char g_new_version[64];
static char g_download_url[2048];
static char g_notes_url[2048];
static char g_release_notes[16384];
static HWND g_update_hwnd = NULL;
static volatile int g_downloading = 0;
static int g_dl_progress = 0;
static char g_dl_status[256] = "";

// ---------------------------------------------------------------------------
// Version comparison
// ---------------------------------------------------------------------------
static int parse_version(const char *s, int parts[3]) {
    parts[0] = parts[1] = parts[2] = 0;
    sscanf(s, "%d.%d.%d", &parts[0], &parts[1], &parts[2]);
    return 1;
}

static int is_newer(const char *remote, const char *local) {
    int r[3], l[3];
    parse_version(remote, r);
    parse_version(local, l);
    if (r[0] != l[0]) return r[0] > l[0];
    if (r[1] != l[1]) return r[1] > l[1];
    return r[2] > l[2];
}

// ---------------------------------------------------------------------------
// Minimal XML attribute extraction
// ---------------------------------------------------------------------------
static const char *find_attr(const char *tag, const char *name, char *buf, int buf_len) {
    char needle[128];
    snprintf(needle, sizeof(needle), "%s=\"", name);
    const char *p = strstr(tag, needle);
    if (!p) return NULL;
    p += strlen(needle);
    const char *q = strchr(p, '"');
    if (!q || (q - p) >= buf_len) return NULL;
    memcpy(buf, p, q - p);
    buf[q - p] = '\0';
    return buf;
}

// ---------------------------------------------------------------------------
// WinHTTP helpers
// ---------------------------------------------------------------------------
static int http_get_ex(const wchar_t *host, int port, const wchar_t *path, int secure, char *buf, int buf_size) {
    HINTERNET session = WinHttpOpen(L"Attyx-Updater/1.0",
        WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, NULL, NULL, 0);
    if (!session) return 0;

    HINTERNET conn = WinHttpConnect(session, host, (INTERNET_PORT)port, 0);
    if (!conn) {
        char dbg[128]; snprintf(dbg, sizeof(dbg), "http_get: Connect failed, error=%lu", GetLastError());
        updateLog(dbg);
        WinHttpCloseHandle(session); return 0;
    }

    DWORD flags = secure ? WINHTTP_FLAG_SECURE : 0;
    HINTERNET req = WinHttpOpenRequest(conn, L"GET", path, NULL,
        WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (!req) {
        char dbg[128]; snprintf(dbg, sizeof(dbg), "http_get: OpenRequest failed, error=%lu", GetLastError());
        updateLog(dbg);
        WinHttpCloseHandle(conn); WinHttpCloseHandle(session); return 0;
    }

    if (!WinHttpSendRequest(req, NULL, 0, NULL, 0, 0, 0)) {
        char dbg[128]; snprintf(dbg, sizeof(dbg), "http_get: SendRequest failed, error=%lu", GetLastError());
        updateLog(dbg);
        WinHttpCloseHandle(req); WinHttpCloseHandle(conn); WinHttpCloseHandle(session);
        return 0;
    }
    if (!WinHttpReceiveResponse(req, NULL)) {
        char dbg[128]; snprintf(dbg, sizeof(dbg), "http_get: ReceiveResponse failed, error=%lu", GetLastError());
        updateLog(dbg);
        WinHttpCloseHandle(req); WinHttpCloseHandle(conn); WinHttpCloseHandle(session);
        return 0;
    }

    int total = 0;
    DWORD bytes_read;
    while (total < buf_size - 1) {
        if (!WinHttpReadData(req, buf + total, buf_size - 1 - total, &bytes_read) || bytes_read == 0)
            break;
        total += bytes_read;
    }
    buf[total] = '\0';

    WinHttpCloseHandle(req);
    WinHttpCloseHandle(conn);
    WinHttpCloseHandle(session);
    return total;
}

static int http_get(const wchar_t *host, const wchar_t *path, char *buf, int buf_size) {
    return http_get_ex(host, INTERNET_DEFAULT_HTTPS_PORT, path, 1, buf, buf_size);
}

// ---------------------------------------------------------------------------
// Appcast check
// ---------------------------------------------------------------------------
static int check_appcast(void) {
    char xml[32768];
    updateLog("check_appcast: fetching...");
    int xml_len = http_get_ex(g_appcast_host, g_appcast_port, g_appcast_path, g_appcast_secure, xml, sizeof(xml));
    if (xml_len <= 0) {
        updateLog("check_appcast: fetch failed or empty response");
        return 0;
    }
    char dbg[128];
    snprintf(dbg, sizeof(dbg), "check_appcast: got %d bytes", xml_len);
    updateLog(dbg);

    // Find matching enclosure
    const char *pos = xml;
    while ((pos = strstr(pos, "<enclosure")) != NULL) {
        const char *end = strstr(pos, "/>");
        if (!end) end = strstr(pos, ">");
        if (!end) break;

        // Extract tag into buffer
        int tag_len = (int)(end - pos + 2);
        if (tag_len > 4096) { pos = end + 1; continue; }
        char tag[4096];
        memcpy(tag, pos, tag_len);
        tag[tag_len] = '\0';

        char os_buf[32], arch_buf[32];
        const char *os = find_attr(tag, "os", os_buf, sizeof(os_buf));
        const char *arch = find_attr(tag, "arch", arch_buf, sizeof(arch_buf));

        if (os && strcmp(os, TARGET_OS) != 0) { pos = end + 1; continue; }
        if (arch && strcmp(arch, TARGET_ARCH) != 0) { pos = end + 1; continue; }

        char ver_buf[64], url_buf[2048];
        const char *ver = find_attr(tag, "sparkle:version", ver_buf, sizeof(ver_buf));
        const char *url = find_attr(tag, "url", url_buf, sizeof(url_buf));
        if (!ver || !url) { pos = end + 1; continue; }

        if (!is_newer(ver, g_current_version)) return 0;

        strncpy(g_new_version, ver, sizeof(g_new_version) - 1);
        strncpy(g_download_url, url, sizeof(g_download_url) - 1);

        // Look for release notes URL in parent <item>
        const char *notes = strstr(xml, "<sparkle:releaseNotesLink>");
        if (notes) {
            notes += strlen("<sparkle:releaseNotesLink>");
            const char *notes_end = strstr(notes, "</sparkle:releaseNotesLink>");
            if (notes_end) {
                int nlen = (int)(notes_end - notes);
                if (nlen < (int)sizeof(g_notes_url)) {
                    memcpy(g_notes_url, notes, nlen);
                    g_notes_url[nlen] = '\0';
                    // Trim whitespace
                    while (g_notes_url[0] == ' ' || g_notes_url[0] == '\n')
                        memmove(g_notes_url, g_notes_url + 1, strlen(g_notes_url));
                    char *e = g_notes_url + strlen(g_notes_url) - 1;
                    while (e > g_notes_url && (*e == ' ' || *e == '\n')) *e-- = '\0';
                }
            }
        }
        return 1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Fetch release notes (strip HTML to plain text)
// ---------------------------------------------------------------------------
static void fetch_release_notes(void) {
    g_release_notes[0] = '\0';
    if (g_notes_url[0] == '\0') {
        snprintf(g_release_notes, sizeof(g_release_notes), "Version %s is available.", g_new_version);
        return;
    }

    // Parse host/path from URL
    const char *url = g_notes_url;
    const char *scheme_end = strstr(url, "://");
    if (!scheme_end) return;
    const char *host_start = scheme_end + 3;
    const char *path_start = strchr(host_start, '/');
    if (!path_start) return;

    int host_len = (int)(path_start - host_start);
    wchar_t host_w[256];
    for (int i = 0; i < host_len && i < 255; i++) host_w[i] = host_start[i];
    host_w[host_len] = 0;

    int path_len = (int)strlen(path_start);
    wchar_t path_w[2048];
    for (int i = 0; i < path_len && i < 2047; i++) path_w[i] = path_start[i];
    path_w[path_len] = 0;

    char html[16384];
    int len = http_get(host_w, path_w, html, sizeof(html));
    if (len <= 0) {
        snprintf(g_release_notes, sizeof(g_release_notes), "Version %s is available.", g_new_version);
        return;
    }

    // Basic HTML → plain text: strip tags, decode common entities
    int out = 0;
    int in_tag = 0;
    for (int i = 0; i < len && out < (int)sizeof(g_release_notes) - 2; i++) {
        if (html[i] == '<') { in_tag = 1; continue; }
        if (html[i] == '>') {
            in_tag = 0;
            // Add newline after block elements
            if (i >= 2 && (html[i-1] == 'p' || html[i-1] == 'r' ||
                html[i-1] == 'i' || html[i-1] == 'l'))
                if (out > 0 && g_release_notes[out-1] != '\n')
                    g_release_notes[out++] = '\n';
            continue;
        }
        if (in_tag) continue;
        if (html[i] == '&') {
            if (strncmp(html + i, "&amp;", 5) == 0) { g_release_notes[out++] = '&'; i += 4; continue; }
            if (strncmp(html + i, "&lt;", 4) == 0) { g_release_notes[out++] = '<'; i += 3; continue; }
            if (strncmp(html + i, "&gt;", 4) == 0) { g_release_notes[out++] = '>'; i += 3; continue; }
            if (strncmp(html + i, "&quot;", 6) == 0) { g_release_notes[out++] = '"'; i += 5; continue; }
            if (strncmp(html + i, "&#8212;", 7) == 0) { g_release_notes[out++] = '-'; i += 6; continue; }
            if (strncmp(html + i, "&nbsp;", 6) == 0) { g_release_notes[out++] = ' '; i += 5; continue; }
        }
        g_release_notes[out++] = html[i];
    }
    g_release_notes[out] = '\0';

    // Collapse multiple newlines
    char *r = g_release_notes, *w = g_release_notes;
    int nl_count = 0;
    while (*r) {
        if (*r == '\n') { nl_count++; if (nl_count <= 2) *w++ = '\n'; }
        else { nl_count = 0; *w++ = *r; }
        r++;
    }
    *w = '\0';
}

// ---------------------------------------------------------------------------
// Staging path
// ---------------------------------------------------------------------------
static int get_staging_path(wchar_t *buf, int buf_len) {
    wchar_t appdata[MAX_PATH];
    if (FAILED(SHGetFolderPathW(NULL, CSIDL_LOCAL_APPDATA, NULL, 0, appdata)))
        return 0;
    _snwprintf(buf, buf_len, L"%s\\attyx\\upgrade-dev.exe", appdata);
    return 1;
}

// ---------------------------------------------------------------------------
// Download with progress (runs on background thread)
// ---------------------------------------------------------------------------
static DWORD WINAPI download_thread(LPVOID param) {
    (void)param;

    // Parse URL
    const char *url = g_download_url;
    const char *se = strstr(url, "://");
    if (!se) { g_downloading = 0; return 1; }
    const char *hs = se + 3;
    const char *ps = strchr(hs, '/');
    if (!ps) { g_downloading = 0; return 1; }

    int hl = (int)(ps - hs);
    wchar_t host_w[256];
    for (int i = 0; i < hl && i < 255; i++) host_w[i] = hs[i];
    host_w[hl] = 0;

    int pl = (int)strlen(ps);
    wchar_t path_w[2048];
    for (int i = 0; i < pl && i < 2047; i++) path_w[i] = ps[i];
    path_w[pl] = 0;

    wchar_t staging[MAX_PATH];
    if (!get_staging_path(staging, MAX_PATH)) { g_downloading = 0; return 1; }

    wchar_t tmp[MAX_PATH + 4];
    _snwprintf(tmp, MAX_PATH + 4, L"%s.tmp", staging);

    HANDLE file = CreateFileW(tmp, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    if (file == INVALID_HANDLE_VALUE) { g_downloading = 0; return 1; }

    HINTERNET session = WinHttpOpen(L"Attyx-Updater/1.0",
        WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, NULL, NULL, 0);
    if (!session) { CloseHandle(file); g_downloading = 0; return 1; }

    HINTERNET conn = WinHttpConnect(session, host_w, INTERNET_DEFAULT_HTTPS_PORT, 0);
    if (!conn) { WinHttpCloseHandle(session); CloseHandle(file); g_downloading = 0; return 1; }

    HINTERNET req = WinHttpOpenRequest(conn, L"GET", path_w, NULL,
        WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE);
    if (!req) { WinHttpCloseHandle(conn); WinHttpCloseHandle(session); CloseHandle(file); g_downloading = 0; return 1; }

    if (!WinHttpSendRequest(req, NULL, 0, NULL, 0, 0, 0) ||
        !WinHttpReceiveResponse(req, NULL)) {
        WinHttpCloseHandle(req); WinHttpCloseHandle(conn); WinHttpCloseHandle(session);
        CloseHandle(file); g_downloading = 0; return 1;
    }

    // Get content length for progress
    DWORD content_length = 0;
    DWORD cl_size = sizeof(content_length);
    WinHttpQueryHeaders(req, WINHTTP_QUERY_CONTENT_LENGTH | WINHTTP_QUERY_FLAG_NUMBER,
        NULL, &content_length, &cl_size, NULL);

    DWORD total = 0;
    char chunk[65536];
    DWORD bytes_read;
    while (WinHttpReadData(req, chunk, sizeof(chunk), &bytes_read) && bytes_read > 0) {
        DWORD written;
        WriteFile(file, chunk, bytes_read, &written, NULL);
        total += bytes_read;

        // Update progress
        if (content_length > 0)
            g_dl_progress = (int)((LONGLONG)total * 100 / content_length);
        if (content_length > 0)
            snprintf(g_dl_status, sizeof(g_dl_status), "Downloading... %.1f / %.1f MB",
                total / 1048576.0, content_length / 1048576.0);
        else
            snprintf(g_dl_status, sizeof(g_dl_status), "Downloading... %.1f MB", total / 1048576.0);
        if (g_update_hwnd) InvalidateRect(g_update_hwnd, NULL, FALSE);
    }

    WinHttpCloseHandle(req);
    WinHttpCloseHandle(conn);
    WinHttpCloseHandle(session);
    CloseHandle(file);

    // Atomic rename
    MoveFileExW(tmp, staging, MOVEFILE_REPLACE_EXISTING);

    // Update UI
    g_dl_progress = 100;
    strcpy(g_dl_status, "Update downloaded. Restarting...");
    if (g_update_hwnd) InvalidateRect(g_update_hwnd, NULL, FALSE);

    // The daemon will detect the staged binary and hot-upgrade
    g_downloading = 0;
    return 0;
}

// ---------------------------------------------------------------------------
// Update window — custom-painted dark theme (matches installer design)
// ---------------------------------------------------------------------------
#define UPD_W       520
#define UPD_H       440
#define UPD_BG      RGB(26, 26, 26)
#define UPD_TEXT     RGB(224, 224, 224)
#define UPD_DIM      RGB(128, 128, 128)
#define UPD_BTN_BG   RGB(40, 40, 40)
#define UPD_BTN_BD   RGB(80, 80, 80)
#define UPD_BTN_HV   RGB(55, 55, 55)
#define UPD_BTN_AC   RGB(70, 130, 180)
#define UPD_PROG_BG  RGB(50, 50, 50)
#define UPD_PROG_FG  RGB(70, 130, 180)
#define UPD_MARGIN   32
#define UPD_BTN_H    38
#define UPD_LINE_H   20

static HFONT g_uf_title, g_uf_body, g_uf_notes, g_uf_btn;
static int g_upd_hover = 0;  // 0=none, 1=install, 2=later
static RECT g_rc_upd_install, g_rc_upd_later;
static void DrawUpdButton(HDC hdc, RECT *rc, const wchar_t *text, int hover, int accent) {
    COLORREF bg = hover ? UPD_BTN_HV : UPD_BTN_BG;
    COLORREF bd = accent ? UPD_BTN_AC : UPD_BTN_BD;
    HBRUSH br = CreateSolidBrush(bg);
    FillRect(hdc, rc, br);
    DeleteObject(br);
    HPEN pen = CreatePen(PS_SOLID, accent ? 2 : 1, bd);
    SelectObject(hdc, pen);
    SelectObject(hdc, GetStockObject(NULL_BRUSH));
    RoundRect(hdc, rc->left, rc->top, rc->right, rc->bottom, 6, 6);
    DeleteObject(pen);
    SelectObject(hdc, g_uf_btn);
    SetTextColor(hdc, UPD_TEXT);
    DrawTextW(hdc, text, -1, rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
}

static void DoPaintUpdate(HWND hwnd) {
    PAINTSTRUCT ps;
    HDC hdc = BeginPaint(hwnd, &ps);
    RECT cr;
    GetClientRect(hwnd, &cr);
    int W = cr.right, H = cr.bottom;

    HDC mem = CreateCompatibleDC(hdc);
    HBITMAP bmp = CreateCompatibleBitmap(hdc, W, H);
    SelectObject(mem, bmp);

    // Background
    HBRUSH bgBr = CreateSolidBrush(UPD_BG);
    FillRect(mem, &cr, bgBr);
    DeleteObject(bgBr);
    SetBkMode(mem, TRANSPARENT);

    int y = UPD_MARGIN;

    // Title: "Attyx v0.2.48 is available!"
    SelectObject(mem, g_uf_title);
    SetTextColor(mem, UPD_TEXT);
    {
        wchar_t title[128];
        _snwprintf(title, 128, L"Attyx %hs is available!", g_new_version);
        RECT tr = { UPD_MARGIN, y, W - UPD_MARGIN, y + 32 };
        DrawTextW(mem, title, -1, &tr, DT_LEFT | DT_SINGLELINE);
    }
    y += 36;

    // Subtitle
    SelectObject(mem, g_uf_body);
    SetTextColor(mem, UPD_DIM);
    {
        wchar_t sub[128];
        _snwprintf(sub, 128, L"You have version %hs", g_current_version);
        RECT sr = { UPD_MARGIN, y, W - UPD_MARGIN, y + UPD_LINE_H };
        DrawTextW(mem, sub, -1, &sr, DT_LEFT | DT_SINGLELINE);
    }
    y += UPD_LINE_H + 16;

    // "Release Notes:" label
    SetTextColor(mem, UPD_DIM);
    {
        RECT lr = { UPD_MARGIN, y, W - UPD_MARGIN, y + UPD_LINE_H };
        DrawTextW(mem, L"Release Notes:", -1, &lr, DT_LEFT | DT_SINGLELINE);
    }
    y += UPD_LINE_H + 4;

    // Release notes box (dark inset)
    int notes_h = H - y - 90;
    {
        RECT box = { UPD_MARGIN, y, W - UPD_MARGIN, y + notes_h };
        HBRUSH nbg = CreateSolidBrush(UPD_BTN_BG);
        FillRect(mem, &box, nbg);
        DeleteObject(nbg);
        HPEN bp = CreatePen(PS_SOLID, 1, UPD_BTN_BD);
        SelectObject(mem, bp);
        SelectObject(mem, GetStockObject(NULL_BRUSH));
        Rectangle(mem, box.left, box.top, box.right, box.bottom);
        DeleteObject(bp);

        SelectObject(mem, g_uf_notes);
        SetTextColor(mem, UPD_TEXT);
        RECT nr = { UPD_MARGIN + 10, y + 8, W - UPD_MARGIN - 10, y + notes_h - 8 };
        wchar_t notes_w[8192];
        MultiByteToWideChar(CP_UTF8, 0, g_release_notes, -1, notes_w, 8192);
        DrawTextW(mem, notes_w, -1, &nr, DT_LEFT | DT_WORDBREAK | DT_NOPREFIX);
    }
    y += notes_h + 8;

    // Progress bar
    if (g_downloading || g_dl_progress > 0) {
        RECT pbg = { UPD_MARGIN, y, W - UPD_MARGIN, y + 5 };
        HBRUSH pBg = CreateSolidBrush(UPD_PROG_BG);
        FillRect(mem, &pbg, pBg);
        DeleteObject(pBg);
        if (g_dl_progress > 0) {
            int pw = (W - 2 * UPD_MARGIN) * g_dl_progress / 100;
            RECT pfg = { UPD_MARGIN, y, UPD_MARGIN + pw, y + 5 };
            HBRUSH pFg = CreateSolidBrush(UPD_PROG_FG);
            FillRect(mem, &pfg, pFg);
            DeleteObject(pFg);
        }
    }
    y += 10;

    // Status text
    if (g_dl_status[0]) {
        SelectObject(mem, g_uf_body);
        SetTextColor(mem, UPD_DIM);
        wchar_t sw[256];
        MultiByteToWideChar(CP_UTF8, 0, g_dl_status, -1, sw, 256);
        RECT sr = { UPD_MARGIN, y, W - UPD_MARGIN - 240, y + UPD_LINE_H };
        DrawTextW(mem, sw, -1, &sr, DT_LEFT | DT_SINGLELINE);
    }

    // Buttons
    int btn_w = 140;
    g_rc_upd_install = (RECT){ W - UPD_MARGIN - btn_w, y - 2, W - UPD_MARGIN, y - 2 + UPD_BTN_H };
    g_rc_upd_later = (RECT){ W - UPD_MARGIN - btn_w - 12 - 80, y - 2, W - UPD_MARGIN - btn_w - 12, y - 2 + UPD_BTN_H };

    if (!g_downloading) {
        DrawUpdButton(mem, &g_rc_upd_install, L"Install Update", g_upd_hover == 1, 1);
        DrawUpdButton(mem, &g_rc_upd_later, L"Later", g_upd_hover == 2, 0);
    }

    BitBlt(hdc, 0, 0, W, H, mem, 0, 0, SRCCOPY);
    DeleteObject(bmp);
    DeleteDC(mem);
    EndPaint(hwnd, &ps);
}

static int UpdHitTest(int x, int y) {
    POINT pt = { x, y };
    if (!g_downloading && PtInRect(&g_rc_upd_install, pt)) return 1;
    if (!g_downloading && PtInRect(&g_rc_upd_later, pt)) return 2;
    return 0;
}

static LRESULT CALLBACK UpdateWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_PAINT:
        DoPaintUpdate(hwnd);
        return 0;
    case WM_ERASEBKGND:
        return 1;
    case WM_MOUSEMOVE: {
        int old = g_upd_hover;
        g_upd_hover = UpdHitTest(LOWORD(lParam), HIWORD(lParam));
        if (g_upd_hover != old) InvalidateRect(hwnd, NULL, FALSE);
        TRACKMOUSEEVENT tme = { sizeof(tme), TME_LEAVE, hwnd, 0 };
        TrackMouseEvent(&tme);
        return 0;
    }
    case WM_MOUSELEAVE:
        if (g_upd_hover) { g_upd_hover = 0; InvalidateRect(hwnd, NULL, FALSE); }
        return 0;
    case WM_LBUTTONDOWN: {
        int hit = UpdHitTest(LOWORD(lParam), HIWORD(lParam));
        if (hit == 1 && !g_downloading) {
            g_downloading = 1;
            strcpy(g_dl_status, "Downloading...");
            InvalidateRect(hwnd, NULL, FALSE);
            CreateThread(NULL, 0, download_thread, NULL, 0, NULL);
        }
        if (hit == 2) DestroyWindow(hwnd);
        return 0;
    }
    case WM_DESTROY:
        g_update_hwnd = NULL;
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

static void show_update_window(void) {
    if (g_update_hwnd) {
        SetForegroundWindow(g_update_hwnd);
        return;
    }

    // Fonts
    if (!g_uf_title) {
        g_uf_title = CreateFontW(-22, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET,
            0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
        g_uf_body = CreateFontW(-14, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
            0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
        g_uf_notes = CreateFontW(-13, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
            0, 0, CLEARTYPE_QUALITY, 0, L"Cascadia Mono");
        g_uf_btn = CreateFontW(-14, 0, 0, 0, FW_SEMIBOLD, 0, 0, 0, DEFAULT_CHARSET,
            0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    }

    // Register class
    static int registered = 0;
    if (!registered) {
        WNDCLASSW wc = { .lpfnWndProc = UpdateWndProc, .hInstance = GetModuleHandleW(NULL),
            .lpszClassName = L"AttyxUpdateWindow", .hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW) };
        RegisterClassW(&wc);
        registered = 1;
    }

    RECT wr = { 0, 0, UPD_W, UPD_H };
    AdjustWindowRect(&wr, WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU, FALSE);
    int sx = GetSystemMetrics(SM_CXSCREEN), sy = GetSystemMetrics(SM_CYSCREEN);
    int ww = wr.right - wr.left, wh = wr.bottom - wr.top;

    g_update_hwnd = CreateWindowExW(0, L"AttyxUpdateWindow", L"Software Update",
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
        (sx - ww) / 2, (sy - wh) / 2, ww, wh,
        NULL, NULL, GetModuleHandleW(NULL), NULL);
    if (!g_update_hwnd) return;

    // Dark title bar (Windows 10 1809+)
    HMODULE dwm = LoadLibraryW(L"dwmapi.dll");
    if (dwm) {
        typedef HRESULT (WINAPI *PFN)(HWND, DWORD, const void*, DWORD);
        PFN fn = (PFN)GetProcAddress(dwm, "DwmSetWindowAttribute");
        if (fn) { BOOL dark = TRUE; fn(g_update_hwnd, 20, &dark, sizeof(dark)); }
    }

    g_dl_progress = 0;
    g_dl_status[0] = '\0';
    ShowWindow(g_update_hwnd, SW_SHOW);
    UpdateWindow(g_update_hwnd);
}

// ---------------------------------------------------------------------------
// Background check (called from timer)
// ---------------------------------------------------------------------------
static DWORD WINAPI check_thread(LPVOID param) {
    int interactive = (int)(INT_PTR)param;
    updateLog("check_thread: starting");

    char dbg[512];
    snprintf(dbg, sizeof(dbg), "check_thread: host=%ls port=%d path=%ls secure=%d version=%s",
        g_appcast_host, g_appcast_port, g_appcast_path, g_appcast_secure, g_current_version);
    updateLog(dbg);

    if (!check_appcast()) {
        updateLog("check_thread: no update found (or fetch failed)");
        if (interactive && g_update_hwnd) {
            SetWindowTextA(g_status_label, "You're up to date!");
        }
        return 0;
    }

    snprintf(dbg, sizeof(dbg), "check_thread: update found! version=%s url=%s", g_new_version, g_download_url);
    updateLog(dbg);

    fetch_release_notes();

    // Show window on main thread
    if (g_hwnd) {
        updateLog("check_thread: posting WM_APP+1 to show window");
        PostMessageW(g_hwnd, WM_APP + 1, 0, 0);
    } else {
        updateLog("check_thread: ERROR g_hwnd is NULL");
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Public API (called from platform_windows.c)
// ---------------------------------------------------------------------------

void attyx_updater_init(const char *current_version) {
    if (current_version)
        strncpy(g_current_version, current_version, sizeof(g_current_version) - 1);

    // Override feed URL for local testing:
    //   set ATTYX_FEED_URL=http://localhost:8089/appcast.xml
    const char *env_url = getenv("ATTYX_FEED_URL");
    if (env_url && strlen(env_url) > 7) {
        // Parse: http[s]://host[:port]/path
        int is_https = (strncmp(env_url, "https://", 8) == 0);
        const char *hs = env_url + (is_https ? 8 : 7);
        const char *ps = strchr(hs, '/');
        if (ps) {
            int hl = (int)(ps - hs);
            // Check for :port
            const char *colon = memchr(hs, ':', hl);
            int name_len = colon ? (int)(colon - hs) : hl;
            for (int i = 0; i < name_len && i < 255; i++) g_appcast_host[i] = hs[i];
            g_appcast_host[name_len] = 0;
            g_appcast_port = colon ? atoi(colon + 1) : (is_https ? 443 : 80);
            g_appcast_secure = is_https;
            int pl = (int)strlen(ps);
            for (int i = 0; i < pl && i < 511; i++) g_appcast_path[i] = ps[i];
            g_appcast_path[pl < 511 ? pl : 511] = 0;
        }
    }

    char dbg[512];
    snprintf(dbg, sizeof(dbg), "init: version=%s host=%ls port=%d secure=%d hwnd=%p",
        g_current_version, g_appcast_host, g_appcast_port, g_appcast_secure, (void*)g_hwnd);
    updateLog(dbg);

    // Schedule first check 5 seconds after launch
    SetTimer(g_hwnd, 42, 5000, NULL);
}

/// Called from WM_TIMER with timer ID 42.
/// Returns 1 if consumed.
int attyx_updater_tick(UINT_PTR timer_id) {
    if (timer_id != 42) return 0;
    KillTimer(g_hwnd, 42);  // One-shot; re-schedule for 6h after check
    CreateThread(NULL, 0, check_thread, (LPVOID)0, 0, NULL);
    // Re-schedule next check in 6 hours
    SetTimer(g_hwnd, 42, 6 * 60 * 60 * 1000, NULL);
    return 1;
}

/// Show the update window if an update was found (called from WM_APP+1).
void attyx_updater_show(void) {
    show_update_window();
}

/// Manual "Check for Updates" from menu.
void attyx_updater_check(void) {
    CreateThread(NULL, 0, check_thread, (LPVOID)1, 0, NULL);
}

int attyx_updater_available(void) {
    return 1;
}

// ---------------------------------------------------------------------------
// Debug logging
// ---------------------------------------------------------------------------
static void updateLog(const char *msg) {
    wchar_t appdata[MAX_PATH];
    if (FAILED(SHGetFolderPathW(NULL, CSIDL_LOCAL_APPDATA, NULL, 0, appdata))) return;
    wchar_t path[MAX_PATH + 64];
    _snwprintf(path, MAX_PATH + 64, L"%s\\attyx\\updater-debug.log", appdata);

    HANDLE f = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ, NULL, OPEN_ALWAYS, 0, NULL);
    if (f == INVALID_HANDLE_VALUE) return;
    DWORD written;
    WriteFile(f, "[updater] ", 10, &written, NULL);
    WriteFile(f, msg, (DWORD)strlen(msg), &written, NULL);
    WriteFile(f, "\r\n", 2, &written, NULL);
    CloseHandle(f);
}

#endif // _WIN32
