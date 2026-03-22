// Attyx — Windows native scrollbar (WS_VSCROLL + SetScrollInfo)

#ifdef _WIN32

#include "windows_internal.h"

// Cache previous values to avoid redundant SetScrollInfo calls
static int s_prev_sb   = -1;
static int s_prev_vp   = -1;
static int s_prev_rows = -1;
static int s_prev_alt  = -1;

void windows_scrollbar_update(HWND hwnd) {
    int sb   = g_scrollback_count;
    int vp   = g_viewport_offset;
    int rows = g_rows;
    int alt  = g_alt_screen;

    if (sb == s_prev_sb && vp == s_prev_vp &&
        rows == s_prev_rows && alt == s_prev_alt)
        return;

    s_prev_sb   = sb;
    s_prev_vp   = vp;
    s_prev_rows = rows;
    s_prev_alt  = alt;

    if (sb <= 0 || alt) {
        ShowScrollBar(hwnd, SB_VERT, FALSE);
        return;
    }

    ShowScrollBar(hwnd, SB_VERT, TRUE);

    SCROLLINFO si = {0};
    si.cbSize = sizeof(si);
    si.fMask  = SIF_RANGE | SIF_PAGE | SIF_POS;
    si.nMin   = 0;
    si.nMax   = sb + rows - 1;
    si.nPage  = (UINT)rows;
    si.nPos   = sb - vp;
    SetScrollInfo(hwnd, SB_VERT, &si, TRUE);
}

BOOL windows_scrollbar_handle(HWND hwnd, WPARAM wParam) {
    int sb   = g_scrollback_count;
    int rows = g_rows;
    if (sb <= 0) return FALSE;

    int delta = 0;
    switch (LOWORD(wParam)) {
        case SB_LINEUP:        delta = 1;     break;
        case SB_LINEDOWN:      delta = -1;    break;
        case SB_PAGEUP:        delta = rows;  break;
        case SB_PAGEDOWN:      delta = -rows; break;
        case SB_THUMBTRACK:
        case SB_THUMBPOSITION: {
            SCROLLINFO si = {0};
            si.cbSize = sizeof(si);
            si.fMask  = SIF_TRACKPOS;
            GetScrollInfo(hwnd, SB_VERT, &si);
            int newVp = sb - si.nTrackPos;
            delta = newVp - g_viewport_offset;
            break;
        }
        case SB_TOP:    delta = sb;  break;
        case SB_BOTTOM: delta = -sb; break;
        default: return FALSE;
    }

    if (delta != 0) attyx_scroll_viewport(delta);
    return TRUE;
}

#endif // _WIN32
