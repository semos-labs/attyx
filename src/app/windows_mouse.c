// Attyx — Windows mouse input handling
// Mouse button, motion, scroll, selection, and split drag for Win32.

#ifdef _WIN32

#include "windows_internal.h"

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static inline int clampInt(int val, int lo, int hi) {
    if (val < lo) return lo;
    if (val > hi) return hi;
    return val;
}

// Mouse modifier bits for SGR protocol
static int mouseModifiers(void) {
    int m = 0;
    if (GetKeyState(VK_SHIFT)   & 0x8000) m |= 4;
    if (GetKeyState(VK_MENU)    & 0x8000) m |= 8;
    if (GetKeyState(VK_CONTROL) & 0x8000) m |= 16;
    return m;
}

// ---------------------------------------------------------------------------
// Mouse coordinate conversion
// ---------------------------------------------------------------------------

void mouseToCell(int px, int py, int* outCol, int* outRow) {
    float cellW = g_cell_px_w / g_content_scale;
    float cellH = g_cell_px_h / g_content_scale;
    RECT rc;
    GetClientRect(g_hwnd, &rc);
    float winW = (float)(rc.right - rc.left);
    float availW = winW - g_padding_left - g_padding_right;
    float cx = floorf((availW - g_cols * cellW) * 0.5f);
    if (cx < 0) cx = 0;
    float offX = g_padding_left + cx;
    float offY = g_padding_top;
    *outCol = clampInt((int)(((float)px - offX) / cellW), 0, g_cols - 1);
    *outRow = clampInt((int)(((float)py - offY) / cellH), 0, g_rows - 1);
}

void mouseToCell1(int px, int py, int* outCol, int* outRow) {
    float cellW = g_cell_px_w / g_content_scale;
    float cellH = g_cell_px_h / g_content_scale;
    RECT rc;
    GetClientRect(g_hwnd, &rc);
    float winW = (float)(rc.right - rc.left);
    float availW = winW - g_padding_left - g_padding_right;
    float cx = floorf((availW - g_cols * cellW) * 0.5f);
    if (cx < 0) cx = 0;
    float offX = g_padding_left + cx;
    float offY = g_padding_top;
    *outCol = clampInt((int)(((float)px - offX) / cellW) + 1, 1, g_cols);
    *outRow = clampInt((int)(((float)py - offY) / cellH) + 1, 1, g_rows);
}

// ---------------------------------------------------------------------------
// SGR mouse protocol helpers
// ---------------------------------------------------------------------------

static void sendSgrMouse(int button, int col, int row, int press) {
    // Adjust row from screen-space to content-space: subtract the grid top
    // offset (statusbar / tab bar rows) so TUI apps receive correct coords.
    row -= g_grid_top_offset;
    if (row < 1) row = 1;
    char buf[32];
    int len = snprintf(buf, sizeof(buf), "\x1b[<%d;%d;%d%c",
                       button, col, row, press ? 'M' : 'm');
    attyx_send_input((const uint8_t*)buf, len);
}

static void sendSgrMousePopup(int button, int col, int row, int press) {
    char buf[32];
    int len = snprintf(buf, sizeof(buf), "\x1b[<%d;%d;%d%c",
                       button, col, row, press ? 'M' : 'm');
    attyx_popup_send_input((const uint8_t*)buf, len);
}

static int popupHitTest(int col, int row, int *outCol, int *outRow) {
    AttyxPopupDesc d = g_popup_desc;
    if (!d.active) return 0;
    int vis_row = d.row + g_grid_top_offset;
    if (col < d.col || col >= d.col + d.width) return 0;
    if (row < vis_row || row >= vis_row + d.height) return 0;
    int inner_col = col - d.col - d.content_col_off + 1;
    int inner_row = row - vis_row - d.content_row_off + 1;
    if (inner_col < 1) inner_col = 1;
    if (inner_row < 1) inner_row = 1;
    if (inner_col > d.inner_cols) inner_col = d.inner_cols;
    if (inner_row > d.inner_rows) inner_row = d.inner_rows;
    *outCol = inner_col;
    *outRow = inner_row;
    return 1;
}

// ---------------------------------------------------------------------------
// Word boundary detection
// ---------------------------------------------------------------------------

static int isWordChar(uint32_t ch) {
    if (ch == 0 || ch == ' ') return 0;
    if (ch == '_' || ch == '-') return 1;
    if (ch > 127) return 1;
    if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
        (ch >= '0' && ch <= '9')) return 1;
    return 0;
}

static void findWordBoundsLocal(int row, int col, int cols,
                                int *outStart, int *outEnd) {
    if (!g_cells || cols <= 0) { *outStart = col; *outEnd = col; return; }
    int base = row * cols;
    uint32_t ch = g_cells[base + col].character;
    int target = isWordChar(ch);
    int start = col;
    while (start > 0 && isWordChar(g_cells[base + start - 1].character) == target)
        start--;
    int end = col;
    while (end < cols - 1 && isWordChar(g_cells[base + end + 1].character) == target)
        end++;
    *outStart = start;
    *outEnd = end;
}

// ---------------------------------------------------------------------------
// Split separator hit-test
// ---------------------------------------------------------------------------

static void mouseXOffset(int px, float *outOffX, float *outCellW) {
    float cellW = g_cell_px_w / g_content_scale;
    RECT rc;
    GetClientRect(g_hwnd, &rc);
    float winW = (float)(rc.right - rc.left);
    float availW = winW - g_padding_left - g_padding_right;
    float cx = floorf((availW - g_cols * cellW) * 0.5f);
    if (cx < 0) cx = 0;
    *outOffX = g_padding_left + cx;
    *outCellW = cellW;
}

static int separatorHitTest(int col, int row, float mouseX,
                            float offX, float cellW) {
    int srow = row - g_grid_top_offset;
    int scols = g_cols;
    if (!g_cells || srow < 0 || srow >= g_rows) return 0;
    const float halfHit = 10.0f;
    for (int dc = -1; dc <= 1; dc++) {
        int c = col + dc;
        if (c < 0 || c >= scols) continue;
        uint32_t ch = g_cells[srow * scols + c].character;
        int type = 0;
        if (ch == 0x2502) { type = 1; }
        else if (ch == 0x2500) { type = 2; }
        else if (ch == 0x253C || ch == 0x251C || ch == 0x2524 ||
                 ch == 0x252C || ch == 0x2534 || ch == 0x250C ||
                 ch == 0x2510 || ch == 0x2514 || ch == 0x2518) {
            int hasVert = 0;
            if (srow > 0) {
                uint32_t nc = g_cells[(srow-1) * scols + c].character;
                hasVert = (nc == 0x2502 || nc == 0x253C || nc == 0x251C ||
                           nc == 0x2524 || nc == 0x252C || nc == 0x2534);
            }
            type = hasVert ? 1 : 2;
        }
        if (type == 0) continue;
        float sepCenterX = offX + (c + 0.5f) * cellW;
        if (fabsf(mouseX - sepCenterX) <= halfHit) return type;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Mouse state
// ---------------------------------------------------------------------------

static ULONGLONG g_last_click_time = 0;
static int g_last_click_col = -1, g_last_click_row = -1;
static int g_click_count = 0;
static int g_selecting = 0;
static int g_left_down = 0;
static int g_split_dragging = 0;
static int g_last_motion_col = -1, g_last_motion_row = -1;

// Shared from windows_input.c
extern void win_snapViewport(void);

// ---------------------------------------------------------------------------
// WM_LBUTTONDOWN
// ---------------------------------------------------------------------------

LRESULT win_handleLButtonDown(HWND hwnd, LPARAM lParam) {
    SetCapture(hwnd);
    int px = LOWORD(lParam), py = HIWORD(lParam);

    if (g_popup_active) {
        int col, row;
        mouseToCell(px, py, &col, &row);
        int pc, pr;
        if (popupHitTest(col, row, &pc, &pr) &&
            g_popup_mouse_tracking && g_popup_mouse_sgr) {
            sendSgrMousePopup(0 | mouseModifiers(), pc, pr, 1);
            g_left_down = 1;
            g_last_motion_col = pc;
            g_last_motion_row = pr;
        }
        return 0;
    }

    if (g_copy_mode) attyx_copy_mode_exit(0);

    // Split separator click
    if (g_split_active) {
        int sc, sr;
        mouseToCell(px, py, &sc, &sr);
        float ox, cw;
        mouseXOffset(px, &ox, &cw);
        if (separatorHitTest(sc, sr, (float)px, ox, cw)) {
            attyx_split_drag_start(sc, sr);
            g_split_dragging = 1;
            return 0;
        }
    }

    int col, row;
    mouseToCell(px, py, &col, &row);

    if (row == 0 && g_tab_bar_visible) {
        attyx_tab_bar_click(col, g_cols);
        return 0;
    }
    if (g_statusbar_visible) {
        int sb_row = (g_statusbar_position == 0) ? 0 : (g_rows - 1);
        if (row == sb_row) {
            attyx_statusbar_tab_click(col, g_cols);
            return 0;
        }
    }
    if (g_overlay_has_actions && attyx_overlay_click(col, row)) return 0;

    // Let pane switching win over app mouse tracking so OpenCode and other
    // mouse-aware apps do not trap clicks meant to focus another split.
    if (g_split_active && g_pane_rect_rows > 0) {
        int content_row = row - g_grid_top_offset;
        int pr = g_pane_rect_row, pc = g_pane_rect_col;
        int pe = pr + g_pane_rect_rows, pce = pc + g_pane_rect_cols;
        if (content_row >= 0 &&
            (content_row < pr || content_row >= pe || col < pc || col >= pce)) {
            attyx_split_click(col, row);
            return 0;
        }
    }

    if (g_mouse_tracking && g_mouse_sgr) {
        int track_col, track_row;
        mouseToCell1(px, py, &track_col, &track_row);
        sendSgrMouse(0 | mouseModifiers(), track_col, track_row, 1);
        g_left_down = 1;
        return 0;
    }

    if (g_split_active) {
        attyx_split_drag_start(col, row);
        g_split_dragging = 1;
        attyx_split_click(col, row);
    }

    row -= g_grid_top_offset;
    if (row < 0) row = 0;

    if (g_split_active && g_pane_rect_rows > 0) {
        int pr = g_pane_rect_row, pc = g_pane_rect_col;
        int pe = pr + g_pane_rect_rows, pce = pc + g_pane_rect_cols;
        if (row < pr) row = pr;
        if (row >= pe) row = pe - 1;
        if (col < pc) col = pc;
        if (col >= pce) col = pce - 1;
    }

    // Ctrl+click opens hyperlink
    if (GetKeyState(VK_CONTROL) & 0x8000) {
        int cols = g_cols, nrows = g_rows;
        if (g_cells && col >= 0 && col < cols && row >= 0 && row < nrows) {
            uint32_t lid = g_cells[row * cols + col].link_id;
            if (lid != 0) {
                char uri_buf[2048];
                int uri_len = attyx_get_link_uri(lid, uri_buf, sizeof(uri_buf));
                if (uri_len > 0) {
                    uri_buf[uri_len] = '\0';
                    ShellExecuteA(NULL, "open", uri_buf, NULL, NULL, SW_SHOW);
                }
                g_left_down = 1;
                return 0;
            }
            int dStart, dEnd;
            char dUrl[DETECTED_URL_MAX];
            int dLen = 0;
            if (detectUrlAtCell(row, col, cols, &dStart, &dEnd,
                                dUrl, DETECTED_URL_MAX, &dLen) && dLen > 0) {
                dUrl[dLen] = '\0';
                ShellExecuteA(NULL, "open", dUrl, NULL, NULL, SW_SHOW);
                g_left_down = 1;
                return 0;
            }
        }
    }

    // Shift-click extends selection
    if ((GetKeyState(VK_SHIFT) & 0x8000) && g_sel_active) {
        g_sel_end_row = row;
        g_sel_end_col = col;
        g_selecting = 1;
        g_left_down = 1;
        attyx_mark_all_dirty();
        return 0;
    }

    // Double/triple click detection
    ULONGLONG now = GetTickCount64();
    if (now - g_last_click_time < 350 &&
        col == g_last_click_col && row == g_last_click_row)
        g_click_count++;
    else
        g_click_count = 1;
    g_last_click_time = now;
    g_last_click_col = col;
    g_last_click_row = row;

    if (g_click_count >= 3) {
        g_sel_start_row = row; g_sel_start_col = 0;
        g_sel_end_row = row;   g_sel_end_col = g_cols - 1;
        g_sel_active = 1;
    } else if (g_click_count == 2) {
        int wS, wE;
        findWordBoundsLocal(row, col, g_cols, &wS, &wE);
        g_sel_start_row = row; g_sel_start_col = wS;
        g_sel_end_row = row;   g_sel_end_col = wE;
        g_sel_active = 1;
    } else {
        g_sel_start_row = row; g_sel_start_col = col;
        g_sel_end_row = row;   g_sel_end_col = col;
        g_sel_active = 0;
    }
    g_selecting = 1;
    g_left_down = 1;
    attyx_mark_all_dirty();
    return 0;
}

// ---------------------------------------------------------------------------
// WM_LBUTTONUP
// ---------------------------------------------------------------------------

LRESULT win_handleLButtonUp(HWND hwnd, LPARAM lParam) {
    (void)hwnd;
    ReleaseCapture();
    int px = LOWORD(lParam), py = HIWORD(lParam);

    if (g_popup_active) {
        g_left_down = 0;
        if (g_popup_mouse_tracking && g_popup_mouse_sgr) {
            int col, row;
            mouseToCell(px, py, &col, &row);
            int pc, pr;
            if (popupHitTest(col, row, &pc, &pr))
                sendSgrMousePopup(0 | mouseModifiers(), pc, pr, 0);
        }
        return 0;
    }
    g_left_down = 0;
    if (g_split_dragging) {
        if (g_split_drag_active) attyx_split_drag_end();
        g_split_dragging = 0;
    }
    if (g_mouse_tracking && g_mouse_sgr) {
        int col, row;
        mouseToCell1(px, py, &col, &row);
        sendSgrMouse(0 | mouseModifiers(), col, row, 0);
        return 0;
    }
    if (g_selecting) {
        g_selecting = 0;
        if (g_sel_start_row != g_sel_end_row || g_sel_start_col != g_sel_end_col)
            g_sel_active = 1;
        else if (g_click_count < 2)
            g_sel_active = 0;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// WM_MOUSEMOVE
// ---------------------------------------------------------------------------

LRESULT win_handleMouseMove(HWND hwnd, LPARAM lParam) {
    (void)hwnd;
    int px = LOWORD(lParam), py = HIWORD(lParam);

    if (g_popup_active) {
        if (g_popup_mouse_tracking && g_popup_mouse_sgr) {
            int col, row;
            mouseToCell(px, py, &col, &row);
            int pc, pr;
            if (popupHitTest(col, row, &pc, &pr)) {
                if (g_left_down && g_popup_mouse_tracking >= 2) {
                    if (pc != g_last_motion_col || pr != g_last_motion_row) {
                        sendSgrMousePopup(32, pc, pr, 1);
                        g_last_motion_col = pc;
                        g_last_motion_row = pr;
                    }
                } else if (!g_left_down && g_popup_mouse_tracking == 3) {
                    if (pc != g_last_motion_col || pr != g_last_motion_row) {
                        sendSgrMousePopup(35, pc, pr, 1);
                        g_last_motion_col = pc;
                        g_last_motion_row = pr;
                    }
                }
            }
        }
        return 0;
    }

    if (g_split_dragging && g_split_drag_active) {
        int col, row;
        mouseToCell(px, py, &col, &row);
        attyx_split_drag_update(col, row);
        return 0;
    }

    if (g_left_down && g_mouse_tracking && g_mouse_sgr) {
        if (g_mouse_tracking < 2) return 0;
        int col, row;
        mouseToCell1(px, py, &col, &row);
        if (col == g_last_motion_col && row == g_last_motion_row) return 0;
        sendSgrMouse(32, col, row, 1);
        g_last_motion_col = col;
        g_last_motion_row = row;
        return 0;
    }
    if (!g_left_down && g_mouse_tracking == 3 && g_mouse_sgr) {
        int col, row;
        mouseToCell1(px, py, &col, &row);
        if (col == g_last_motion_col && row == g_last_motion_row) return 0;
        sendSgrMouse(35, col, row, 1);
        g_last_motion_col = col;
        g_last_motion_row = row;
        return 0;
    }

    // Selection drag
    if (g_selecting && g_left_down) {
        int col, row;
        mouseToCell(px, py, &col, &row);
        row -= g_grid_top_offset;
        if (row < 0) row = 0;

        if (g_split_active && g_pane_rect_rows > 0) {
            int pr = g_pane_rect_row, pc = g_pane_rect_col;
            int pe = pr + g_pane_rect_rows, pce = pc + g_pane_rect_cols;
            if (row < pr) row = pr;
            if (row >= pe) row = pe - 1;
            if (col < pc) col = pc;
            if (col >= pce) col = pce - 1;
        }

        if (col == g_sel_end_col && row == g_sel_end_row) return 0;

        if (g_click_count >= 3) {
            g_sel_end_row = row;
            g_sel_end_col = (row >= g_sel_start_row) ? g_cols - 1 : 0;
            if (row < g_sel_start_row) g_sel_start_col = g_cols - 1;
            else g_sel_start_col = 0;
        } else if (g_click_count == 2) {
            int wS, wE;
            findWordBoundsLocal(row, col, g_cols, &wS, &wE);
            g_sel_end_row = row;
            if (row > g_sel_start_row ||
                (row == g_sel_start_row && col >= g_sel_start_col))
                g_sel_end_col = wE;
            else
                g_sel_end_col = wS;
        } else {
            g_sel_end_row = row;
            g_sel_end_col = col;
        }
        g_sel_active = 1;
        attyx_mark_all_dirty();
    }
    return 0;
}

// ---------------------------------------------------------------------------
// WM_RBUTTONDOWN / WM_RBUTTONUP
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Right-click context menu (native Win32)
// ---------------------------------------------------------------------------

#define CTX_ID_COPY           1
#define CTX_ID_PASTE          2
#define CTX_ID_SPLIT_VERT     3
#define CTX_ID_SPLIT_HORIZ    4
#define CTX_ID_ROTATE         5
#define CTX_ID_CLOSE_PANE     6
#define CTX_ID_OPEN_CONFIG    7

static void showContextMenu(HWND hwnd, int px, int py, int gridCol, int gridRow) {
    HMENU menu = CreatePopupMenu();
    if (!menu) return;

    AppendMenuW(menu, MF_STRING, CTX_ID_COPY,  L"Copy");
    AppendMenuW(menu, MF_STRING, CTX_ID_PASTE, L"Paste");
    AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
    AppendMenuW(menu, MF_STRING, CTX_ID_SPLIT_VERT,  L"Split Vertical");
    AppendMenuW(menu, MF_STRING, CTX_ID_SPLIT_HORIZ, L"Split Horizontal");
    AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
    AppendMenuW(menu, MF_STRING, CTX_ID_ROTATE,     L"Rotate Panes");
    AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
    AppendMenuW(menu, MF_STRING, CTX_ID_CLOSE_PANE, L"Close Pane");
    AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
    AppendMenuW(menu, MF_STRING, CTX_ID_OPEN_CONFIG, L"Open Config");

    // Convert client coords to screen coords for TrackPopupMenu
    POINT pt = { px, py };
    ClientToScreen(hwnd, &pt);

    int cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY,
                             pt.x, pt.y, 0, hwnd, NULL);
    DestroyMenu(menu);

    switch (cmd) {
        case CTX_ID_COPY:        attyx_platform_copy(); break;
        case CTX_ID_PASTE:       attyx_platform_paste(); break;
        case CTX_ID_SPLIT_VERT:  attyx_context_menu_action(53, gridCol, gridRow); break;
        case CTX_ID_SPLIT_HORIZ: attyx_context_menu_action(54, gridCol, gridRow); break;
        case CTX_ID_ROTATE:      attyx_dispatch_action(78); break;
        case CTX_ID_CLOSE_PANE:  attyx_context_menu_action(55, gridCol, gridRow); break;
        case CTX_ID_OPEN_CONFIG: attyx_dispatch_action(89); break;
        default: break;
    }
}

LRESULT win_handleRButtonDown(HWND hwnd, LPARAM lParam) {
    (void)hwnd;
    int px = LOWORD(lParam), py = HIWORD(lParam);

    if (g_popup_active) {
        if (g_popup_mouse_tracking && g_popup_mouse_sgr) {
            int col, row;
            mouseToCell(px, py, &col, &row);
            int pc, pr;
            if (popupHitTest(col, row, &pc, &pr))
                sendSgrMousePopup(2 | mouseModifiers(), pc, pr, 1);
        }
        return 0;
    }
    if (g_mouse_tracking && g_mouse_sgr) {
        int col, row;
        mouseToCell1(px, py, &col, &row);
        sendSgrMouse(2 | mouseModifiers(), col, row, 1);
    }
    return 0;
}

LRESULT win_handleRButtonUp(HWND hwnd, LPARAM lParam) {
    int px = LOWORD(lParam), py = HIWORD(lParam);

    if (g_popup_active) {
        if (g_popup_mouse_tracking && g_popup_mouse_sgr) {
            int col, row;
            mouseToCell(px, py, &col, &row);
            int pc, pr;
            if (popupHitTest(col, row, &pc, &pr))
                sendSgrMousePopup(2 | mouseModifiers(), pc, pr, 0);
        }
        return 0;
    }
    if (g_mouse_tracking && g_mouse_sgr) {
        int col, row;
        mouseToCell1(px, py, &col, &row);
        sendSgrMouse(2 | mouseModifiers(), col, row, 0);
        return 0;
    }

    // No mouse tracking — show context menu
    int col, row;
    mouseToCell(px, py, &col, &row);
    showContextMenu(hwnd, px, py, col, row);
    return 0;
}

// ---------------------------------------------------------------------------
// WM_MBUTTONDOWN / WM_MBUTTONUP
// ---------------------------------------------------------------------------

LRESULT win_handleMButtonDown(HWND hwnd, LPARAM lParam) {
    (void)hwnd;
    int px = LOWORD(lParam), py = HIWORD(lParam);

    if (g_popup_active) {
        if (g_popup_mouse_tracking && g_popup_mouse_sgr) {
            int col, row;
            mouseToCell(px, py, &col, &row);
            int pc, pr;
            if (popupHitTest(col, row, &pc, &pr))
                sendSgrMousePopup(1 | mouseModifiers(), pc, pr, 1);
        }
        return 0;
    }
    if (g_mouse_tracking && g_mouse_sgr) {
        int col, row;
        mouseToCell1(px, py, &col, &row);
        sendSgrMouse(1 | mouseModifiers(), col, row, 1);
    }
    return 0;
}

LRESULT win_handleMButtonUp(HWND hwnd, LPARAM lParam) {
    (void)hwnd;
    int px = LOWORD(lParam), py = HIWORD(lParam);

    if (g_popup_active) {
        if (g_popup_mouse_tracking && g_popup_mouse_sgr) {
            int col, row;
            mouseToCell(px, py, &col, &row);
            int pc, pr;
            if (popupHitTest(col, row, &pc, &pr))
                sendSgrMousePopup(1 | mouseModifiers(), pc, pr, 0);
        }
        return 0;
    }
    if (g_mouse_tracking && g_mouse_sgr) {
        int col, row;
        mouseToCell1(px, py, &col, &row);
        sendSgrMouse(1 | mouseModifiers(), col, row, 0);
    }
    return 0;
}

// ---------------------------------------------------------------------------
// WM_MOUSEWHEEL
// ---------------------------------------------------------------------------

LRESULT win_handleMouseWheel(HWND hwnd, WPARAM wParam, LPARAM lParam) {
    short delta = GET_WHEEL_DELTA_WPARAM(wParam);
    POINT pt = { LOWORD(lParam), HIWORD(lParam) };
    ScreenToClient(hwnd, &pt);
    int px = pt.x, py = pt.y;

    if (g_popup_active) {
        if (g_popup_mouse_tracking && g_popup_mouse_sgr && delta != 0) {
            int col, row;
            mouseToCell(px, py, &col, &row);
            int pc, pr;
            if (popupHitTest(col, row, &pc, &pr)) {
                int btn = (delta > 0 ? 64 : 65);
                sendSgrMousePopup(btn, pc, pr, 1);
            }
        }
        return 0;
    }
    if (g_mouse_tracking && g_mouse_sgr) {
        if (delta == 0) return 0;
        int col, row;
        mouseToCell1(px, py, &col, &row);
        int btn = (delta > 0 ? 64 : 65);
        sendSgrMouse(btn, col, row, 1);
        return 0;
    }
    if (g_alt_screen) return 0;
    int lines = delta / WHEEL_DELTA;
    if (lines == 0) lines = (delta > 0) ? 1 : -1;
    if (g_overlay_has_actions) {
        int col, row;
        mouseToCell(px, py, &col, &row);
        if (attyx_overlay_scroll(col, row, lines)) return 0;
    }
    attyx_scroll_viewport(lines);
    return 0;
}

#endif // _WIN32
