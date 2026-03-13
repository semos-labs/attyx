#ifndef ATTYX_WINDOWS_INTERNAL_H
#define ATTYX_WINDOWS_INTERNAL_H

#ifdef _WIN32

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef COBJMACROS
#define COBJMACROS
#endif
#ifndef INITGUID
#define INITGUID
#endif
#include <windows.h>
#include <imm.h>
#include <shellapi.h>

#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <stddef.h>
#include <stdbool.h>
#include <math.h>

#include "bridge.h"

// ---------------------------------------------------------------------------
// Shared state (written by Zig PTY thread, read by renderer on main thread)
// ---------------------------------------------------------------------------

extern AttyxCell* g_cells;
extern int g_cols;
extern int g_rows;
extern volatile uint64_t g_cell_gen;
extern volatile uint8_t g_row_wrapped[ATTYX_MAX_ROWS];
extern volatile int g_cursor_row;
extern volatile int g_cursor_col;
extern volatile int g_should_quit;

// Mode flags
extern volatile int g_bracketed_paste;
extern volatile int g_cursor_keys_app;

// Mouse mode flags
extern volatile int g_mouse_tracking;
extern volatile int g_mouse_sgr;

// Viewport / scrollback / alt screen
extern volatile int g_viewport_offset;
extern volatile int g_scrollback_count;
extern volatile int g_alt_screen;

// Selection
extern volatile int g_sel_start_row, g_sel_start_col;
extern volatile int g_sel_end_row, g_sel_end_col;
extern volatile int g_sel_active;

// Cursor appearance
extern volatile int g_cursor_shape;
extern volatile int g_cursor_visible;

// Window title
extern char         g_title_buf[ATTYX_TITLE_MAX];
extern volatile int g_title_len;
extern volatile int g_title_changed;

// IME
extern volatile int  g_ime_composing;
extern volatile int  g_ime_cursor_index;
extern volatile int  g_ime_anchor_row;
extern volatile int  g_ime_anchor_col;
extern char          g_ime_preedit[ATTYX_IME_MAX_BYTES];
extern volatile int  g_ime_preedit_len;

// Font config
extern char         g_font_family[ATTYX_FONT_FAMILY_MAX];
extern volatile int g_font_family_len;
extern volatile int g_font_size;
extern volatile int g_default_font_size;
extern volatile int g_cell_width;
extern volatile int g_cell_height;
extern char         g_font_fallback[ATTYX_FONT_FALLBACK_MAX][ATTYX_FONT_FAMILY_MAX];
extern volatile int g_font_fallback_count;

// Search state
extern char          g_search_query[ATTYX_SEARCH_QUERY_MAX];
extern volatile int  g_search_query_len;
extern volatile int  g_search_active;
extern volatile int  g_search_gen;
extern volatile int  g_search_nav_delta;
extern volatile int  g_search_total;
extern volatile int  g_search_current;
extern AttyxSearchVis g_search_vis[ATTYX_SEARCH_VIS_MAX];
extern volatile int  g_search_vis_count;
extern volatile int  g_search_cur_vis_row;
extern volatile int  g_search_cur_vis_cs;
extern volatile int  g_search_cur_vis_ce;

// Kitty keyboard protocol flags
extern volatile int g_kitty_kbd_flags;

// Hyperlink hover state
extern volatile uint32_t g_hover_link_id;
extern volatile int g_hover_row;

// Regex-detected URL hover state
#define DETECTED_URL_MAX 2048
extern char g_detected_url[DETECTED_URL_MAX];
extern volatile int g_detected_url_len;
extern volatile int g_detected_url_row;
extern volatile int g_detected_url_start_col;
extern volatile int g_detected_url_end_col;

// Row-level dirty bitset
extern volatile uint64_t g_dirty[4];

// Pending resize
extern volatile int g_pending_resize_rows;
extern volatile int g_pending_resize_cols;

// HWND handle (needed by input and render)
extern HWND g_hwnd;

// Cell pixel dimensions (set by renderer, used by input)
extern float g_cell_px_w;
extern float g_cell_px_h;
extern float g_content_scale;

// Renderer state used by input
extern int g_full_redraw;

// ---------------------------------------------------------------------------
// Dirty helpers
// ---------------------------------------------------------------------------

static inline int dirtyBitTest(const uint64_t dirty[4], int row) {
    if (row < 0 || row >= 256) return 0;
    return (dirty[row >> 6] >> (row & 63)) & 1;
}

static inline int dirtyAny(const uint64_t dirty[4]) {
    return (dirty[0] | dirty[1] | dirty[2] | dirty[3]) != 0;
}

// ---------------------------------------------------------------------------
// Input handling (windows_input.c)
// ---------------------------------------------------------------------------

LRESULT windows_handle_input(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);

// ---------------------------------------------------------------------------
// Clipboard (windows_clipboard.c)
// ---------------------------------------------------------------------------

void attyx_platform_copy(void);
void attyx_platform_paste(void);
void windows_clipboard_copy(const char* text, int len);
char* windows_clipboard_paste(void);

// ---------------------------------------------------------------------------
// URL detection helpers (shared)
// ---------------------------------------------------------------------------

int detectUrlAtCell(int row, int col, int cols,
                    int *outStart, int *outEnd,
                    char *outUrl, int urlBufSize, int *outUrlLen);

// ---------------------------------------------------------------------------
// Word boundary helpers (shared)
// ---------------------------------------------------------------------------

void findWordBounds(int row, int col, int cols, int* outStart, int* outEnd);

// ---------------------------------------------------------------------------
// Mouse helpers (windows_mouse.c)
// ---------------------------------------------------------------------------

void mouseToCell(int px, int py, int* outCol, int* outRow);
void mouseToCell1(int px, int py, int* outCol, int* outRow);

// Mouse event handlers (windows_mouse.c — called from windows_input.c dispatcher)
LRESULT win_handleLButtonDown(HWND hwnd, LPARAM lParam);
LRESULT win_handleLButtonUp(HWND hwnd, LPARAM lParam);
LRESULT win_handleRButtonDown(HWND hwnd, LPARAM lParam);
LRESULT win_handleRButtonUp(HWND hwnd, LPARAM lParam);
LRESULT win_handleMButtonDown(HWND hwnd, LPARAM lParam);
LRESULT win_handleMButtonUp(HWND hwnd, LPARAM lParam);
LRESULT win_handleMouseMove(HWND hwnd, LPARAM lParam);
LRESULT win_handleMouseWheel(HWND hwnd, WPARAM wParam, LPARAM lParam);

// ---------------------------------------------------------------------------
// Keyboard helpers (windows_input.c — shared with windows_mouse.c)
// ---------------------------------------------------------------------------

extern int g_suppress_char;
uint16_t win_mapVirtualKey(WPARAM vk, LPARAM lParam);
uint8_t  win_buildMods(void);
void     win_vkToKeyCombo(WPARAM vk, LPARAM lParam, uint16_t* outKey, uint32_t* outCp);
void     win_snapViewport(void);

#endif // _WIN32
#endif // ATTYX_WINDOWS_INTERNAL_H
