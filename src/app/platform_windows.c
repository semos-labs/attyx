// Attyx — Windows platform layer (Win32 + Direct3D 11)
// This file contains: globals, bridge functions, entry point.
// Renderer:  windows_renderer.c
// Input:     windows_input.c
// Clipboard: windows_clipboard.c

#ifdef _WIN32

#include "windows_internal.h"
#include <dwmapi.h>
// DirectComposition — dynamically loaded for per-pixel alpha transparency.
// We use DCompositionCreateDevice (not Device2/3) because IDCompositionDevice
// has CreateTargetForHwnd at vtable slot 6.  IDCompositionDevice2/3 move it to
// IDCompositionDesktopDevice (slot 10+), making our stub vtable wrong.
typedef HRESULT (WINAPI *PFN_DCompositionCreateDevice)(IDXGIDevice*, REFIID, void**);

// Minimal COM vtable stubs for IDCompositionDevice, IDCompositionTarget, IDCompositionVisual
typedef struct IDCompositionVisual IDCompositionVisual;
typedef struct IDCompositionTarget IDCompositionTarget;
typedef struct IDCompositionDevice IDCompositionDevice;

typedef struct IDCompositionVisualVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(IDCompositionVisual*, REFIID, void**);
    ULONG   (STDMETHODCALLTYPE *AddRef)(IDCompositionVisual*);
    ULONG   (STDMETHODCALLTYPE *Release)(IDCompositionVisual*);
    // IDCompositionVisual methods (offsets from IUnknown)
    HRESULT (STDMETHODCALLTYPE *SetOffsetX_float)(IDCompositionVisual*, float);
    HRESULT (STDMETHODCALLTYPE *SetOffsetX_anim)(IDCompositionVisual*, void*);
    HRESULT (STDMETHODCALLTYPE *SetOffsetY_float)(IDCompositionVisual*, float);
    HRESULT (STDMETHODCALLTYPE *SetOffsetY_anim)(IDCompositionVisual*, void*);
    HRESULT (STDMETHODCALLTYPE *SetTransform_mat)(IDCompositionVisual*, void*);
    HRESULT (STDMETHODCALLTYPE *SetTransform_anim)(IDCompositionVisual*, void*);
    HRESULT (STDMETHODCALLTYPE *SetTransformParent)(IDCompositionVisual*, IDCompositionVisual*);
    HRESULT (STDMETHODCALLTYPE *SetEffect)(IDCompositionVisual*, void*);
    HRESULT (STDMETHODCALLTYPE *SetBitmapInterpolationMode)(IDCompositionVisual*, int);
    HRESULT (STDMETHODCALLTYPE *SetBorderMode)(IDCompositionVisual*, int);
    HRESULT (STDMETHODCALLTYPE *SetClip_rect)(IDCompositionVisual*, void*);
    HRESULT (STDMETHODCALLTYPE *SetClip_anim)(IDCompositionVisual*, void*);
    HRESULT (STDMETHODCALLTYPE *SetContent)(IDCompositionVisual*, IUnknown*);
} IDCompositionVisualVtbl;
struct IDCompositionVisual { IDCompositionVisualVtbl *lpVtbl; };

typedef struct IDCompositionTargetVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(IDCompositionTarget*, REFIID, void**);
    ULONG   (STDMETHODCALLTYPE *AddRef)(IDCompositionTarget*);
    ULONG   (STDMETHODCALLTYPE *Release)(IDCompositionTarget*);
    HRESULT (STDMETHODCALLTYPE *SetRoot)(IDCompositionTarget*, IDCompositionVisual*);
} IDCompositionTargetVtbl;
struct IDCompositionTarget { IDCompositionTargetVtbl *lpVtbl; };

typedef struct IDCompositionDeviceVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(IDCompositionDevice*, REFIID, void**);
    ULONG   (STDMETHODCALLTYPE *AddRef)(IDCompositionDevice*);
    ULONG   (STDMETHODCALLTYPE *Release)(IDCompositionDevice*);
    HRESULT (STDMETHODCALLTYPE *Commit)(IDCompositionDevice*);
    HRESULT (STDMETHODCALLTYPE *WaitForCommitCompletion)(IDCompositionDevice*);
    HRESULT (STDMETHODCALLTYPE *GetFrameStatistics)(IDCompositionDevice*, void*);
    HRESULT (STDMETHODCALLTYPE *CreateTargetForHwnd)(IDCompositionDevice*, HWND, BOOL, IDCompositionTarget**);
    HRESULT (STDMETHODCALLTYPE *CreateVisual)(IDCompositionDevice*, IDCompositionVisual**);
} IDCompositionDeviceVtbl;
struct IDCompositionDevice { IDCompositionDeviceVtbl *lpVtbl; };

static IDCompositionDevice* s_dcomp_device = NULL;
static IDCompositionTarget*  s_dcomp_target = NULL;
static IDCompositionVisual*  s_dcomp_visual = NULL;

void win_init_composition(HWND hwnd, IDXGISwapChain* swap_chain) {
    HMODULE dcomp = LoadLibraryW(L"dcomp.dll");
    if (!dcomp) { ATTYX_LOG_INFO("platform", "dcomp.dll not found"); return; }
    PFN_DCompositionCreateDevice createDev =
        (PFN_DCompositionCreateDevice)GetProcAddress(dcomp, "DCompositionCreateDevice");
    if (!createDev) { ATTYX_LOG_INFO("platform", "DCompositionCreateDevice not found"); FreeLibrary(dcomp); return; }

    IDXGIDevice* dxgi_dev = NULL;
    ID3D11Device_QueryInterface(g_d3d_device, &IID_IDXGIDevice, (void**)&dxgi_dev);
    if (!dxgi_dev) { ATTYX_LOG_INFO("platform", "QueryInterface IDXGIDevice failed"); return; }

    // IDCompositionDevice IID: {C37EA93A-E7AA-450D-B16F-9746CB0407F3}
    static const IID IID_IDCompositionDevice =
        {0xC37EA93A, 0xE7AA, 0x450D, {0xB1,0x6F,0x97,0x46,0xCB,0x04,0x07,0xF3}};
    HRESULT hr = createDev(dxgi_dev, &IID_IDCompositionDevice, (void**)&s_dcomp_device);
    IDXGIDevice_Release(dxgi_dev);
    if (FAILED(hr) || !s_dcomp_device) { ATTYX_LOG_INFO("platform", "DCompositionCreateDevice failed: 0x%08lX", hr); return; }

    hr = s_dcomp_device->lpVtbl->CreateTargetForHwnd(s_dcomp_device, hwnd, TRUE, &s_dcomp_target);
    if (FAILED(hr)) { ATTYX_LOG_INFO("platform", "CreateTargetForHwnd failed: 0x%08lX", hr); return; }

    hr = s_dcomp_device->lpVtbl->CreateVisual(s_dcomp_device, &s_dcomp_visual);
    if (FAILED(hr)) { ATTYX_LOG_INFO("platform", "CreateVisual failed: 0x%08lX", hr); return; }

    s_dcomp_visual->lpVtbl->SetContent(s_dcomp_visual, (IUnknown*)swap_chain);
    s_dcomp_target->lpVtbl->SetRoot(s_dcomp_target, s_dcomp_visual);
    s_dcomp_device->lpVtbl->Commit(s_dcomp_device);
}

// ---------------------------------------------------------------------------
// Shared state definitions (C-owned globals — matches platform_linux.c)
// ---------------------------------------------------------------------------

AttyxCell* g_cells = NULL;
int g_cols = 0;
int g_rows = 0;

volatile uint64_t g_cell_gen = 0;
volatile int g_cursor_row = 0;
volatile int g_cursor_col = 0;
volatile int g_should_quit = 0;

volatile int g_bracketed_paste = 0;
volatile int g_cursor_keys_app = 0;

volatile int g_mouse_tracking = 0;
volatile int g_mouse_sgr = 0;

volatile int g_viewport_offset = 0;
volatile int g_scrollback_count = 0;
volatile int g_alt_screen = 0;

volatile int g_sel_start_row = -1, g_sel_start_col = -1;
volatile int g_sel_end_row = -1, g_sel_end_col = -1;
volatile int g_sel_active = 0;

volatile uint8_t g_row_wrapped[ATTYX_MAX_ROWS] = {0};

volatile int g_cursor_shape   = 0;
volatile int g_cursor_visible = 1;
volatile int g_cursor_trail   = 0;
volatile int g_font_ligatures = 1;

char         g_title_buf[ATTYX_TITLE_MAX];
volatile int g_title_len     = 0;
volatile int g_title_changed = 0;

volatile int  g_ime_composing    = 0;
volatile int  g_ime_cursor_index = -1;
volatile int  g_ime_anchor_row   = 0;
volatile int  g_ime_anchor_col   = 0;
char          g_ime_preedit[ATTYX_IME_MAX_BYTES];
volatile int  g_ime_preedit_len  = 0;

// Font config (written by Zig at startup)
char         g_font_family[ATTYX_FONT_FAMILY_MAX];
volatile int g_font_family_len = 0;
volatile int g_font_size       = 14;
volatile int g_default_font_size = 14;
volatile int g_cell_width      = 0;
volatile int g_cell_height     = 0;
char         g_font_fallback[ATTYX_FONT_FALLBACK_MAX][ATTYX_FONT_FAMILY_MAX];
volatile int g_font_fallback_count = 0;

// Search state globals
char          g_search_query[ATTYX_SEARCH_QUERY_MAX];
volatile int  g_search_query_len  = 0;
volatile int  g_search_active     = 0;
volatile int  g_search_gen        = 0;
volatile int  g_search_nav_delta  = 0;
volatile int  g_search_total      = 0;
volatile int  g_search_current    = 0;
AttyxSearchVis g_search_vis[ATTYX_SEARCH_VIS_MAX];
volatile int  g_search_vis_count  = 0;
volatile int  g_search_cur_vis_row = -1;
volatile int  g_search_cur_vis_cs  = 0;
volatile int  g_search_cur_vis_ce  = 0;

// Hyperlink hover state
volatile uint32_t g_hover_link_id = 0;
volatile int g_hover_row = -1;

// Regex-detected URL hover state
char g_detected_url[DETECTED_URL_MAX];
volatile int g_detected_url_len = 0;
volatile int g_detected_url_row = -1;
volatile int g_detected_url_start_col = 0;
volatile int g_detected_url_end_col = 0;

// Image placements
AttyxImagePlacement g_image_placements[ATTYX_MAX_IMAGE_PLACEMENTS];
volatile int      g_image_placement_count = 0;
volatile uint64_t g_image_gen = 0;

AttyxImagePlacement g_popup_image_placements[ATTYX_POPUP_MAX_IMAGE_PLACEMENTS];
volatile int        g_popup_image_placement_count = 0;

// Row dirty bits
volatile uint64_t g_dirty[4] = {0,0,0,0};

// Pending resize
volatile int g_pending_resize_rows = 0;
volatile int g_pending_resize_cols = 0;

// Context menu state
int   g_ctx_menu_open  = 0;
float g_ctx_menu_x     = 0;
float g_ctx_menu_y     = 0;
int   g_ctx_menu_hover = -1;
int   g_ctx_menu_col   = 0;
int   g_ctx_menu_row   = 0;

// Overlay system
AttyxOverlayDesc  g_overlay_descs[ATTYX_OVERLAY_MAX_LAYERS];
AttyxOverlayCell  g_overlay_cells[ATTYX_OVERLAY_MAX_LAYERS][ATTYX_OVERLAY_MAX_CELLS];
volatile int      g_overlay_count = 0;
volatile uint32_t g_overlay_gen   = 0;

// Popup terminal
AttyxPopupDesc    g_popup_desc;
AttyxOverlayCell  g_popup_cells[ATTYX_POPUP_MAX_CELLS];
volatile uint32_t g_popup_gen    = 0;

// HWND handle (shared with input and render)
HWND g_hwnd = NULL;

// Cell pixel dimensions (set by renderer)
float g_cell_px_w = 0;
float g_cell_px_h = 0;
float g_content_scale = 1.0f;
volatile float g_cell_w_pts = 0;
volatile float g_cell_h_pts = 0;
int g_full_redraw = 1;

// ---------------------------------------------------------------------------
// Bridge function implementations
// ---------------------------------------------------------------------------

void attyx_set_cursor(int row, int col) {
    g_cursor_row = row;
    g_cursor_col = col;
}

void attyx_request_quit(void) { g_should_quit = 1; }
int  attyx_should_quit(void)  { return g_should_quit; }

void attyx_set_mode_flags(int bracketed_paste, int cursor_keys_app) {
    g_bracketed_paste = bracketed_paste;
    g_cursor_keys_app = cursor_keys_app;
}

void attyx_set_mouse_mode(int tracking, int sgr) {
    g_mouse_tracking = tracking;
    g_mouse_sgr = sgr;
}

void attyx_mark_all_dirty(void) {
    for (int i = 0; i < 4; i++)
        InterlockedOr64((volatile LONG64*)&g_dirty[i], ~(uint64_t)0);
    if (g_hwnd) PostMessageW(g_hwnd, WM_USER + 1, 0, 0);
}

void attyx_scroll_viewport(int delta) {
    int cur = g_viewport_offset;
    int sb = g_scrollback_count;
    int nv = cur + delta;
    if (nv < 0) nv = 0;
    if (nv > sb) nv = sb;
    int actual = nv - cur;
    g_viewport_offset = nv;
    if (actual != 0 && g_sel_active) {
        g_sel_start_row += actual;
        g_sel_end_row += actual;
    }
}

void attyx_set_dirty(const uint64_t dirty[4]) {
    for (int i = 0; i < 4; i++)
        InterlockedOr64((volatile LONG64*)&g_dirty[i], dirty[i]);
    if (g_hwnd) PostMessageW(g_hwnd, WM_USER + 1, 0, 0);
}

void attyx_set_grid_size(int cols, int rows) {
    g_cols = cols;
    g_rows = rows;
}

void attyx_begin_cell_update(void) {
    InterlockedIncrement64((volatile LONG64*)&g_cell_gen);
}

void attyx_end_cell_update(void) {
    InterlockedIncrement64((volatile LONG64*)&g_cell_gen);
    if (g_hwnd) PostMessageW(g_hwnd, WM_USER + 1, 0, 0);
}

int attyx_check_resize(int* out_rows, int* out_cols) {
    int pr = g_pending_resize_rows;
    int pc = g_pending_resize_cols;
    if (pr <= 0 || pc <= 0) return 0;
    if (pr == g_rows && pc == g_cols) return 0;
    *out_rows = pr;
    *out_cols = pc;
    g_pending_resize_rows = 0;
    g_pending_resize_cols = 0;
    return 1;
}

// Forward declarations for helpers defined below WndProc
static float win_get_dpi_scale(HWND hwnd);
static void  win_apply_dark_mode(HWND hwnd);
static void  win_apply_transparency(HWND hwnd);

// ---------------------------------------------------------------------------
// Platform callbacks
// ---------------------------------------------------------------------------

void attyx_platform_close_window(void) {
    if (g_hwnd) PostMessageW(g_hwnd, WM_CLOSE, 0, 0);
}

void attyx_spawn_new_window(void) {
    wchar_t exe[MAX_PATH];
    DWORD len = GetModuleFileNameW(NULL, exe, MAX_PATH);
    if (len == 0 || len >= MAX_PATH) return;
    ShellExecuteW(NULL, L"open", exe, NULL, NULL, SW_SHOWNORMAL);
}

static DWORD WINAPI notifyThreadProc(LPVOID param) {
    // param points to a heap-allocated buffer: title\0body\0
    char* buf = (char*)param;
    char* title = buf;
    char* body  = buf + strlen(buf) + 1;

    // Convert to wide strings for MessageBoxW
    int tw = MultiByteToWideChar(CP_UTF8, 0, title, -1, NULL, 0);
    int bw = MultiByteToWideChar(CP_UTF8, 0, body,  -1, NULL, 0);
    wchar_t* wtitle = (wchar_t*)malloc(tw * sizeof(wchar_t));
    wchar_t* wbody  = (wchar_t*)malloc(bw * sizeof(wchar_t));
    if (wtitle && wbody) {
        MultiByteToWideChar(CP_UTF8, 0, title, -1, wtitle, tw);
        MultiByteToWideChar(CP_UTF8, 0, body,  -1, wbody,  bw);
        MessageBoxW(NULL, wbody, wtitle, MB_OK | MB_ICONINFORMATION);
    }
    free(wtitle);
    free(wbody);
    free(buf);
    return 0;
}

void attyx_platform_notify(const char* title, const char* body) {
    if (!title || !body) return;
    size_t tlen = strlen(title);
    size_t blen = strlen(body);
    char* buf = (char*)malloc(tlen + 1 + blen + 1);
    if (!buf) return;
    memcpy(buf, title, tlen + 1);
    memcpy(buf + tlen + 1, body, blen + 1);
    // Run on a separate thread to avoid blocking the render loop
    HANDLE h = CreateThread(NULL, 0, notifyThreadProc, buf, 0, NULL);
    if (h) CloseHandle(h);
    else free(buf);
}

void attyx_apply_window_update(void) {
    if (!g_hwnd) return;

    // Re-apply window decorations
    LONG style = GetWindowLongW(g_hwnd, GWL_STYLE);
    if (g_window_decorations)
        style |= (WS_CAPTION | WS_THICKFRAME);
    else
        style &= ~(WS_CAPTION | WS_THICKFRAME);
    SetWindowLongW(g_hwnd, GWL_STYLE, style);
    SetWindowPos(g_hwnd, NULL, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);

    // Re-apply transparency (handles opacity changes at runtime)
    win_apply_transparency(g_hwnd);

    // Recalculate grid size from current client area
    RECT rc;
    GetClientRect(g_hwnd, &rc);
    int fbW = rc.right - rc.left;
    int fbH = rc.bottom - rc.top;
    if (g_cell_px_w > 0 && g_cell_px_h > 0) {
        float padPxW = (float)(g_padding_left + g_padding_right) * g_content_scale;
        float padPxH = (float)(g_padding_top + g_padding_bottom) * g_content_scale;
        if (g_native_tabs_enabled) padPxH += ntab_bar_height();
        int new_cols = (int)((fbW - padPxW) / g_cell_px_w + 0.01f);
        int new_rows = (int)((fbH - padPxH) / g_cell_px_h + 0.01f);
        g_pending_resize_rows = new_rows;
        g_pending_resize_cols = new_cols;
    }
    g_full_redraw = 1;
    attyx_mark_all_dirty();
}

// ---------------------------------------------------------------------------
// Updater forward declarations (windows_updater.c)
// ---------------------------------------------------------------------------
void attyx_updater_init(const char *current_version);
int  attyx_updater_tick(UINT_PTR timer_id);
void attyx_updater_show(void);
void attyx_updater_check(void);

// ---------------------------------------------------------------------------
// Renderer forward declarations (windows_renderer.c)
// ---------------------------------------------------------------------------

int  windows_renderer_init(HWND hwnd);
void windows_renderer_resize(int width, int height);
int  windows_renderer_draw_frame(void);
void windows_renderer_present(void);
void windows_renderer_cleanup(void);

// ---------------------------------------------------------------------------
// DPI helpers
// ---------------------------------------------------------------------------

typedef UINT (WINAPI *PFN_GetDpiForWindow)(HWND);
static PFN_GetDpiForWindow s_GetDpiForWindow = NULL;

static float win_get_dpi_scale(HWND hwnd) {
    // Try per-monitor DPI (Win10 1607+)
    if (!s_GetDpiForWindow) {
        HMODULE user32 = GetModuleHandleW(L"user32.dll");
        if (user32)
            s_GetDpiForWindow = (PFN_GetDpiForWindow)GetProcAddress(user32, "GetDpiForWindow");
    }
    if (s_GetDpiForWindow && hwnd) {
        UINT dpi = s_GetDpiForWindow(hwnd);
        if (dpi > 0) return (float)dpi / 96.0f;
    }
    // Fallback: system DPI
    HDC hdc = GetDC(NULL);
    float scale = (float)GetDeviceCaps(hdc, LOGPIXELSX) / 96.0f;
    ReleaseDC(NULL, hdc);
    return scale;
}

// ---------------------------------------------------------------------------
// Transparency / dark mode helpers
// ---------------------------------------------------------------------------

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

static void win_apply_dark_mode(HWND hwnd) {
    BOOL dark = TRUE;
    DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof(dark));
}

// Undocumented Windows API for acrylic blur (Win10 1803+)
typedef enum { ACCENT_DISABLED = 0, ACCENT_ENABLE_BLURBEHIND = 3, ACCENT_ENABLE_ACRYLICBLURBEHIND = 4 } ACCENT_STATE;
typedef struct { ACCENT_STATE AccentState; DWORD AccentFlags; DWORD GradientColor; DWORD AnimationId; } ACCENT_POLICY;
typedef struct { DWORD Attribute; PVOID pData; ULONG cbData; } WINCOMPATTRDATA;
typedef BOOL (WINAPI *PFN_SetWindowCompositionAttribute)(HWND, WINCOMPATTRDATA*);

static void win_apply_transparency(HWND hwnd) {
    float opacity = g_background_opacity;
    if (opacity >= 1.0f && g_background_blur <= 0) return;

    // Extend DWM frame so our alpha channel composites with the desktop
    MARGINS margins = { -1, -1, -1, -1 };
    DwmExtendFrameIntoClientArea(hwnd, &margins);

    // Apply blur if requested
    if (g_background_blur > 0) {
        // Try Windows 11 Mica/Acrylic first (DWMWA_SYSTEMBACKDROP_TYPE = 38)
        int backdrop = 3;  // DWMSBT_TRANSIENTWINDOW = acrylic
        HRESULT hr = DwmSetWindowAttribute(hwnd, 38, &backdrop, sizeof(backdrop));
        if (FAILED(hr)) {
            // Fallback: undocumented SetWindowCompositionAttribute (Win10 1803+)
            HMODULE user32 = GetModuleHandleW(L"user32.dll");
            PFN_SetWindowCompositionAttribute pSetWCA =
                (PFN_SetWindowCompositionAttribute)GetProcAddress(user32, "SetWindowCompositionAttribute");
            if (pSetWCA) {
                ACCENT_POLICY accent = {0};
                accent.AccentState = ACCENT_ENABLE_ACRYLICBLURBEHIND;
                accent.GradientColor = 0x01000000;  // nearly transparent tint
                WINCOMPATTRDATA data = { 19, &accent, sizeof(accent) };  // WCA_ACCENT_POLICY = 19
                pSetWCA(hwnd, &data);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Window procedure
// ---------------------------------------------------------------------------

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    // Let DWM handle caption button rendering (snap layouts on Win11, etc.)
    if (g_native_tabs_enabled) {
        LRESULT dwmResult;
        if (DwmDefWindowProc(hwnd, msg, wParam, lParam, &dwmResult))
            return dwmResult;
    }

    switch (msg) {
    case WM_NCCALCSIZE:
        // Native tabs: extend client area into the title bar.
        // Borderless: expand client area to fill the entire window frame.
        if (g_native_tabs_enabled && wParam) {
            // Extend client area into the title bar so we can draw our tab bar.
            LRESULT r = DefWindowProcW(hwnd, msg, wParam, lParam);
            NCCALCSIZE_PARAMS* p = (NCCALCSIZE_PARAMS*)lParam;
            p->rgrc[0].top = p->rgrc[1].top;
            // When maximized, the window extends past the screen by the frame
            // thickness. Add the frame border back to avoid clipping.
            if (IsZoomed(hwnd)) {
                int frame = GetSystemMetrics(SM_CYFRAME)
                          + GetSystemMetrics(SM_CXPADDEDBORDER);
                p->rgrc[0].top += frame;
            }
            return r;
        }
        if (!g_window_decorations && wParam) return 0;
        break;

    // During window resize/move drag, DefWindowProc enters a modal message
    // loop that blocks our main loop. Use a timer to keep rendering at ~60fps.
    case WM_ENTERSIZEMOVE:
        SetTimer(hwnd, 1, 16, NULL);  // ~60fps timer
        return 0;
    case WM_EXITSIZEMOVE:
        KillTimer(hwnd, 1);
        return 0;
    case WM_TIMER:
        if (wParam == 1) {
            // Render a frame during modal resize/move
            if (windows_renderer_draw_frame()) {
                windows_renderer_present();
            }
        } else if (attyx_updater_tick(wParam)) {
            // Handled by updater
        }
        return 0;

    // Updater: background check completed, show update window on main thread.
    case WM_APP + 1:
        attyx_updater_show();
        return 0;

    case WM_SIZE:
        if (wParam != SIZE_MINIMIZED) {
            int w = LOWORD(lParam);
            int h = HIWORD(lParam);
            windows_renderer_resize(w, h);

            if (g_cell_px_w > 0 && g_cell_px_h > 0) {
                float padPxW = (float)(g_padding_left + g_padding_right) * g_content_scale;
                float padPxH = (float)(g_padding_top + g_padding_bottom) * g_content_scale;
                if (g_native_tabs_enabled) padPxH += ntab_bar_height();
                int new_cols = (int)((w - padPxW) / g_cell_px_w + 0.01f);
                int new_rows = (int)((h - padPxH) / g_cell_px_h + 0.01f);
                g_pending_resize_rows = new_rows;
                g_pending_resize_cols = new_cols;
            }
            g_full_redraw = 1;
            attyx_mark_all_dirty();
        }
        return 0;

    case WM_DPICHANGED: {
        float newScale = (float)HIWORD(wParam) / 96.0f;
        g_content_scale = newScale;

        // Recalculate cell pixel dimensions from point sizes
        g_cell_px_w = g_cell_w_pts * newScale;
        g_cell_px_h = g_cell_h_pts * newScale;

        // Trigger font rebuild at new DPI
        g_needs_font_rebuild = 1;

        // Windows provides the suggested new window rect in lParam
        RECT* suggested = (RECT*)lParam;
        SetWindowPos(hwnd, NULL,
                     suggested->left, suggested->top,
                     suggested->right - suggested->left,
                     suggested->bottom - suggested->top,
                     SWP_NOZORDER | SWP_NOACTIVATE);

        g_full_redraw = 1;
        attyx_mark_all_dirty();
        return 0;
    }

    case WM_COMMAND:
        if (windows_menu_handle_command(wParam))
            return 0;
        break;

    case WM_SYSCOMMAND:
        // Block Alt-key menu activation so Alt combos work as keybinds
        if ((wParam & 0xFFF0) == SC_KEYMENU)
            return 0;
        break;

    case WM_NCHITTEST: {
        POINT pt = { (short)LOWORD(lParam), (short)HIWORD(lParam) };
        ScreenToClient(hwnd, &pt);
        RECT rc;
        GetClientRect(hwnd, &rc);
        int cw = rc.right - rc.left;

        // Native tabs: handle tab bar area + caption buttons + edge resize
        if (g_native_tabs_enabled) {
            enum { EDGE = 6 };
            BOOL bottom = pt.y >= rc.bottom - EDGE;
            BOOL left   = pt.x < EDGE;
            BOOL right  = pt.x >= rc.right - EDGE;
            BOOL top    = pt.y < EDGE;
            if (top && left)     return HTTOPLEFT;
            if (top && right)    return HTTOPRIGHT;
            if (bottom && left)  return HTBOTTOMLEFT;
            if (bottom && right) return HTBOTTOMRIGHT;
            if (top)             return HTTOP;
            if (bottom)          return HTBOTTOM;
            if (left)            return HTLEFT;
            if (right)           return HTRIGHT;

            int ht = ntab_hit_test(pt.x, pt.y, cw);
            if (ht != 0) return ht;  // HTCLIENT, HTCAPTION, or caption buttons
            return HTCLIENT;
        }

        if (g_window_decorations) break;  // decorated windows use default hit-testing
        // Borderless: enable edge resize + top-area drag
        enum { EDGE = 6 };  // resize grip in pixels
        BOOL top    = pt.y < EDGE;
        BOOL bottom = pt.y >= rc.bottom - EDGE;
        BOOL left   = pt.x < EDGE;
        BOOL right  = pt.x >= rc.right - EDGE;
        if (top && left)     return HTTOPLEFT;
        if (top && right)    return HTTOPRIGHT;
        if (bottom && left)  return HTBOTTOMLEFT;
        if (bottom && right) return HTBOTTOMRIGHT;
        if (top)             return HTTOP;
        if (bottom)          return HTBOTTOM;
        if (left)            return HTLEFT;
        if (right)           return HTRIGHT;
        // Drag zone: statusbar area at top (if present), else first cell row
        int drag_h = g_grid_top_offset > 0
            ? (int)(g_grid_top_offset * g_cell_px_h)
            : (int)(g_cell_px_h);
        if (pt.y < drag_h) return HTCAPTION;
        return HTCLIENT;
    }

    case WM_CLOSE:
        g_should_quit = 1;
        DestroyWindow(hwnd);
        return 0;

    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;

    case WM_SETCURSOR:
        if (g_native_tabs_enabled && LOWORD(lParam) == HTCLIENT) {
            POINT cp; GetCursorPos(&cp);
            ScreenToClient(hwnd, &cp);
            if ((float)cp.y < ntab_bar_height()) {
                SetCursor(LoadCursor(NULL, IDC_ARROW));
                return TRUE;
            }
        }
        break;

    case WM_MOUSEMOVE:
        if (g_native_tabs_enabled) {
            POINT mp = { (short)LOWORD(lParam), (short)HIWORD(lParam) };
            RECT mrc; GetClientRect(hwnd, &mrc);
            int cw = mrc.right - mrc.left;
            if (ntab_mouse_drag(mp.x, mp.y, cw))
                return 0;
            ntab_mouse_move(mp.x, mp.y, cw);
            ntab_set_caption_hover(0);
        }
        break;

    case WM_MOUSELEAVE:
        if (g_native_tabs_enabled) ntab_mouse_leave();
        break;

    case WM_NCMOUSEMOVE:
        if (g_native_tabs_enabled) {
            int ht = (int)wParam;
            if (ht == HTCLOSE || ht == HTMAXBUTTON || ht == HTMINBUTTON)
                ntab_set_caption_hover(ht);
            else
                ntab_set_caption_hover(0);
            ntab_mouse_leave();
        }
        break;

    case WM_NCMOUSELEAVE:
        if (g_native_tabs_enabled) ntab_set_caption_hover(0);
        break;

    case WM_NCLBUTTONDOWN:
        if (g_native_tabs_enabled) {
            int ht = (int)wParam;
            if (ht == HTCLOSE) {
                PostMessageW(hwnd, WM_CLOSE, 0, 0);
                return 0;
            }
            if (ht == HTMINBUTTON) {
                ShowWindow(hwnd, SW_MINIMIZE);
                return 0;
            }
            if (ht == HTMAXBUTTON) {
                ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
                return 0;
            }
        }
        break;

    case WM_LBUTTONDOWN:
        if (g_native_tabs_enabled) {
            POINT lp = { (short)LOWORD(lParam), (short)HIWORD(lParam) };
            RECT lrc; GetClientRect(hwnd, &lrc);
            if (ntab_mouse_down(lp.x, lp.y, lrc.right - lrc.left))
                return 0;
        }
        break;

    case WM_LBUTTONUP:
        if (g_native_tabs_enabled) {
            POINT up = { (short)LOWORD(lParam), (short)HIWORD(lParam) };
            RECT urc; GetClientRect(hwnd, &urc);
            if (ntab_mouse_up(up.x, up.y, urc.right - urc.left))
                return 0;
        }
        break;

    default:
        break;
    }

    // Route input messages
    LRESULT result = windows_handle_input(hwnd, msg, wParam, lParam);
    if (result != -1) return result;

    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

// ---------------------------------------------------------------------------
// Entry point: attyx_run (called from Zig after PTY setup)
// ---------------------------------------------------------------------------

void attyx_run(AttyxCell* cells, int cols, int rows) {
    // Console already detached by main() before reaching here.
    g_cells = cells;
    g_cols  = cols;
    g_rows  = rows;

    // Declare per-monitor DPI awareness so Windows doesn't bitmap-scale us.
    // SetProcessDpiAwarenessContext (Win10 1703+), fall back to older API.
    {
        typedef BOOL (WINAPI *PFN_SetDpiCtx)(HANDLE);
        typedef HRESULT (WINAPI *PFN_SetDpiAwareness)(int);
        HMODULE user32 = GetModuleHandleW(L"user32.dll");
        if (user32) {
            PFN_SetDpiCtx fn = (PFN_SetDpiCtx)GetProcAddress(user32,
                "SetProcessDpiAwarenessContext");
            if (fn) {
                // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = (HANDLE)-4
                fn((HANDLE)(intptr_t)-4);
            } else {
                HMODULE shcore = LoadLibraryW(L"shcore.dll");
                if (shcore) {
                    PFN_SetDpiAwareness fn2 = (PFN_SetDpiAwareness)GetProcAddress(
                        shcore, "SetProcessDpiAwareness");
                    if (fn2) fn2(2); // PROCESS_PER_MONITOR_DPI_AWARE
                }
            }
        }
    }

    HINSTANCE hInstance = GetModuleHandleW(NULL);

    // Get DPI scaling (system-level; per-monitor updated in WM_DPICHANGED)
    g_content_scale = win_get_dpi_scale(NULL);

    // Placeholder cell dimensions for initial window sizing.
    // Real metrics are computed by windows_font_init() after D3D init.
    g_cell_px_w = 8.0f * g_content_scale;
    g_cell_px_h = 16.0f * g_content_scale;
    g_cell_w_pts = 8.0f;
    g_cell_h_pts = 16.0f;

    int winW = (int)(cols * g_cell_px_w / g_content_scale) + g_padding_left + g_padding_right;
    int winH = (int)(rows * g_cell_px_h / g_content_scale) + g_padding_top + g_padding_bottom;

    // Register window class
    WNDCLASSEXW wc = {0};
    wc.cbSize        = sizeof(wc);
    wc.style         = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc   = WndProc;
    wc.hInstance      = hInstance;
    wc.hCursor       = LoadCursorW(NULL, MAKEINTRESOURCEW(32513));
    wc.lpszClassName  = L"AttyxWindow";
    RegisterClassExW(&wc);

    // Build system menu bar (skip for borderless windows)
    HMENU hmenu = g_window_decorations ? windows_menu_create() : NULL;

    // Compute window rect from desired client area.
    // Borderless: keep WS_THICKFRAME for resize/snap but strip caption/menu
    // bits so DWM doesn't render ghost caption buttons.
    DWORD style = g_window_decorations
        ? WS_OVERLAPPEDWINDOW
        : (WS_POPUP | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX);
    BOOL has_menu = (hmenu != NULL) ? TRUE : FALSE;
    RECT rect = { 0, 0, winW, winH };
    AdjustWindowRect(&rect, style, has_menu);

    // DirectComposition requires WS_EX_NOREDIRECTIONBITMAP for per-pixel alpha
    DWORD exStyle = (g_background_opacity < 1.0f) ? 0x00200000L : 0;  // WS_EX_NOREDIRECTIONBITMAP
    g_hwnd = CreateWindowExW(
        exStyle,
        L"AttyxWindow",
        L"Attyx",
        style,
        CW_USEDEFAULT, CW_USEDEFAULT,
        rect.right - rect.left,
        rect.bottom - rect.top,
        NULL, hmenu, hInstance, NULL
    );

    if (!g_hwnd) return;

    // Apply dark mode title bar
    win_apply_dark_mode(g_hwnd);

    // Apply transparency if opacity < 1.0
    win_apply_transparency(g_hwnd);

    // Initialize D3D11 renderer
    if (!windows_renderer_init(g_hwnd)) {
        DestroyWindow(g_hwnd);
        return;
    }

    // Show window immediately after renderer init so the user sees something fast.
    // Font init may resize it shortly after, but a black window is better than nothing.
    ShowWindow(g_hwnd, SW_SHOW);
    UpdateWindow(g_hwnd);

    // Initialize DirectWrite font + glyph cache (needs D3D device from renderer)
    if (windows_font_init(&g_gc, g_d3d_device, g_content_scale)) {
        g_cell_px_w = g_gc.glyph_w;
        g_cell_px_h = g_gc.glyph_h;
        g_cell_w_pts = g_gc.glyph_w / g_content_scale;
        g_cell_h_pts = g_gc.glyph_h / g_content_scale;

        // Resize window to fit real cell metrics
        int newW = (int)(cols * g_cell_w_pts) + g_padding_left + g_padding_right;
        int newH = (int)(rows * g_cell_h_pts) + g_padding_top + g_padding_bottom;
        RECT newRect = { 0, 0, newW, newH };
        AdjustWindowRect(&newRect, style, TRUE);
        SetWindowPos(g_hwnd, NULL, 0, 0,
                     newRect.right - newRect.left,
                     newRect.bottom - newRect.top,
                     SWP_NOMOVE | SWP_NOZORDER);
    }

    // Apply window title if set
    if (g_title_len > 0) {
        wchar_t wtitle[ATTYX_TITLE_MAX];
        int wlen = MultiByteToWideChar(CP_UTF8, 0, g_title_buf, g_title_len, wtitle, ATTYX_TITLE_MAX - 1);
        wtitle[wlen] = 0;
        SetWindowTextW(g_hwnd, wtitle);
        g_title_changed = 0;
    }

    // Initialize auto-updater (schedules first check after 5s)
    extern const char *attyx_get_version(void);  // from windows_stubs.zig
    attyx_updater_init(attyx_get_version());

    // Message loop with 60fps frame pacing
    LARGE_INTEGER freq, last_frame;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&last_frame);
    double frame_interval = 1.0 / 60.0;

    while (!g_should_quit) {
        // Process all pending messages
        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) {
                g_should_quit = 1;
                break;
            }
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        if (g_should_quit) break;

        // Check font rebuild
        if (g_needs_font_rebuild) {
            g_needs_font_rebuild = 0;
            windows_font_cleanup(&g_gc);
            if (windows_font_init(&g_gc, g_d3d_device, g_content_scale)) {
                ligatureCacheClear();
                g_cell_px_w = g_gc.glyph_w;
                g_cell_px_h = g_gc.glyph_h;
                g_cell_w_pts = g_gc.glyph_w / g_content_scale;
                g_cell_h_pts = g_gc.glyph_h / g_content_scale;

                // Resize window to fit new cell metrics
                int newW = (int)(g_cols * g_cell_w_pts) + g_padding_left + g_padding_right;
                int newH = (int)(g_rows * g_cell_h_pts) + g_padding_top + g_padding_bottom;
                RECT fontRect = { 0, 0, newW, newH };
                DWORD ws = (DWORD)GetWindowLongW(g_hwnd, GWL_STYLE);
                AdjustWindowRect(&fontRect, ws, TRUE);
                SetWindowPos(g_hwnd, NULL, 0, 0,
                             fontRect.right - fontRect.left,
                             fontRect.bottom - fontRect.top,
                             SWP_NOMOVE | SWP_NOZORDER);

                g_full_redraw = 1;
                attyx_mark_all_dirty();
            }
        }

        // Check window property updates
        if (g_needs_window_update) {
            g_needs_window_update = 0;
            attyx_apply_window_update();
        }

        // Update window title
        if (g_title_changed) {
            g_title_changed = 0;
            wchar_t wtitle[ATTYX_TITLE_MAX];
            int wlen = MultiByteToWideChar(CP_UTF8, 0, g_title_buf, g_title_len, wtitle, ATTYX_TITLE_MAX - 1);
            wtitle[wlen] = 0;
            SetWindowTextW(g_hwnd, wtitle);
        }

        // Frame pacing
        LARGE_INTEGER now;
        QueryPerformanceCounter(&now);
        double elapsed = (double)(now.QuadPart - last_frame.QuadPart) / (double)freq.QuadPart;

        if (elapsed >= frame_interval) {
            if (windows_renderer_draw_frame()) {
                windows_renderer_present();
            }
            QueryPerformanceCounter(&last_frame);
        } else {
            // Sleep for ~1ms to avoid busy-waiting
            Sleep(1);
        }
    }

    // Cleanup
    windows_font_cleanup(&g_gc);
    windows_renderer_cleanup();
    DestroyWindow(g_hwnd);
    g_hwnd = NULL;
}

// URL detection and word bounds are in windows_text_util.c

#endif // _WIN32
