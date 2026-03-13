// Attyx — Windows clipboard handling
// UTF-8 ↔ UTF-16 conversion for Win32 clipboard API.

#ifdef _WIN32

#include "windows_internal.h"

// ---------------------------------------------------------------------------
// Copy UTF-8 text to Windows clipboard (CF_UNICODETEXT)
// ---------------------------------------------------------------------------

void windows_clipboard_copy(const char* text, int len) {
    if (!text || len <= 0) return;

    // Convert UTF-8 → UTF-16
    int wlen = MultiByteToWideChar(CP_UTF8, 0, text, len, NULL, 0);
    if (wlen <= 0) return;

    // Allocate global memory for clipboard (includes null terminator)
    HGLOBAL hMem = GlobalAlloc(GMEM_MOVEABLE, (wlen + 1) * sizeof(WCHAR));
    if (!hMem) return;

    WCHAR* wbuf = (WCHAR*)GlobalLock(hMem);
    if (!wbuf) {
        GlobalFree(hMem);
        return;
    }

    MultiByteToWideChar(CP_UTF8, 0, text, len, wbuf, wlen);
    wbuf[wlen] = 0;
    GlobalUnlock(hMem);

    if (OpenClipboard(g_hwnd)) {
        EmptyClipboard();
        SetClipboardData(CF_UNICODETEXT, hMem);
        CloseClipboard();
        ATTYX_LOG_DEBUG("clipboard", "copy: %d bytes → %d wchars", len, wlen);
    } else {
        GlobalFree(hMem);
        ATTYX_LOG_WARN("clipboard", "copy: failed to open clipboard");
    }
}

// ---------------------------------------------------------------------------
// Bridge: attyx_clipboard_copy (called from Zig via bridge.h)
// ---------------------------------------------------------------------------

void attyx_clipboard_copy(const char* text, int len) {
    windows_clipboard_copy(text, len);
}

// ---------------------------------------------------------------------------
// Read UTF-16 from clipboard and return as UTF-8
// Caller must NOT free the returned pointer (uses static buffer).
// ---------------------------------------------------------------------------

static char g_paste_buf[65536];

char* windows_clipboard_paste(void) {
    g_paste_buf[0] = '\0';

    if (!OpenClipboard(g_hwnd)) {
        ATTYX_LOG_DEBUG("clipboard", "paste: failed to open clipboard");
        return g_paste_buf;
    }

    HANDLE hData = GetClipboardData(CF_UNICODETEXT);
    if (!hData) {
        CloseClipboard();
        ATTYX_LOG_DEBUG("clipboard", "paste: no CF_UNICODETEXT data");
        return g_paste_buf;
    }

    WCHAR* wbuf = (WCHAR*)GlobalLock(hData);
    if (!wbuf) {
        CloseClipboard();
        return g_paste_buf;
    }

    int wlen = (int)wcslen(wbuf);
    int utf8_len = WideCharToMultiByte(CP_UTF8, 0, wbuf, wlen, NULL, 0, NULL, NULL);
    if (utf8_len > 0 && utf8_len < (int)sizeof(g_paste_buf)) {
        WideCharToMultiByte(CP_UTF8, 0, wbuf, wlen, g_paste_buf, (int)sizeof(g_paste_buf), NULL, NULL);
        g_paste_buf[utf8_len] = '\0';
    }

    GlobalUnlock(hData);
    CloseClipboard();
    return g_paste_buf;
}

// ---------------------------------------------------------------------------
// Platform copy/paste (called from dispatch.zig via bridge.h)
// ---------------------------------------------------------------------------

void attyx_platform_copy(void) {
    attyx_copy_selection();
}

void attyx_platform_paste(void) {
    char* text = windows_clipboard_paste();
    if (!text || !*text) {
        ATTYX_LOG_DEBUG("clipboard", "paste: clipboard is empty");
        return;
    }
    int len = (int)strlen(text);
    void (*send_fn)(const uint8_t*, int) =
        g_popup_active ? attyx_popup_send_input : attyx_send_input;
    if (g_bracketed_paste) {
        send_fn((const uint8_t*)"\x1b[200~", 6);
        send_fn((const uint8_t*)text, len);
        send_fn((const uint8_t*)"\x1b[201~", 6);
    } else {
        send_fn((const uint8_t*)text, len);
    }
    ATTYX_LOG_DEBUG("clipboard", "paste: sent %d bytes to PTY", len);
}

#endif // _WIN32
