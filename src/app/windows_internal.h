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

#include <d3d11.h>
#include <dxgi.h>
#include <dwrite.h>
#include <d2d1.h>
#include <wincodec.h>

// DXGI 1.2 types for swap chain creation (avoid dxgi1_2.h dependency)
#ifndef __dxgi1_2_h__
typedef enum DXGI_ALPHA_MODE {
    DXGI_ALPHA_MODE_UNSPECIFIED    = 0,
    DXGI_ALPHA_MODE_PREMULTIPLIED  = 1,
    DXGI_ALPHA_MODE_STRAIGHT       = 2,
    DXGI_ALPHA_MODE_IGNORE         = 3,
} DXGI_ALPHA_MODE;

typedef enum DXGI_SCALING {
    DXGI_SCALING_STRETCH              = 0,
    DXGI_SCALING_NONE                 = 1,
    DXGI_SCALING_ASPECT_RATIO_STRETCH = 2,
} DXGI_SCALING;

typedef struct DXGI_SWAP_CHAIN_DESC1 {
    UINT Width, Height;
    DXGI_FORMAT Format;
    BOOL Stereo;
    DXGI_SAMPLE_DESC SampleDesc;
    DXGI_USAGE BufferUsage;
    UINT BufferCount;
    DXGI_SCALING Scaling;
    DXGI_SWAP_EFFECT SwapEffect;
    DXGI_ALPHA_MODE AlphaMode;
    UINT Flags;
} DXGI_SWAP_CHAIN_DESC1;

// Minimal IDXGISwapChain1 — inherits IDXGISwapChain, no extra methods needed
typedef IDXGISwapChain IDXGISwapChain1;

// IDXGIFactory2 vtable (only the methods we use)
typedef struct IDXGIFactory2 IDXGIFactory2;
typedef struct IDXGIFactory2Vtbl {
    // IUnknown
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(IDXGIFactory2*, REFIID, void**);
    ULONG   (STDMETHODCALLTYPE *AddRef)(IDXGIFactory2*);
    ULONG   (STDMETHODCALLTYPE *Release)(IDXGIFactory2*);
    // IDXGIObject (4 methods)
    HRESULT (STDMETHODCALLTYPE *SetPrivateData)(IDXGIFactory2*, REFGUID, UINT, const void*);
    HRESULT (STDMETHODCALLTYPE *SetPrivateDataInterface)(IDXGIFactory2*, REFGUID, const IUnknown*);
    HRESULT (STDMETHODCALLTYPE *GetPrivateData)(IDXGIFactory2*, REFGUID, UINT*, void*);
    HRESULT (STDMETHODCALLTYPE *GetParent)(IDXGIFactory2*, REFIID, void**);
    // IDXGIFactory (4 methods)
    HRESULT (STDMETHODCALLTYPE *EnumAdapters)(IDXGIFactory2*, UINT, IDXGIAdapter**);
    HRESULT (STDMETHODCALLTYPE *MakeWindowAssociation)(IDXGIFactory2*, HWND, UINT);
    HRESULT (STDMETHODCALLTYPE *GetWindowAssociation)(IDXGIFactory2*, HWND*);
    HRESULT (STDMETHODCALLTYPE *CreateSwapChain)(IDXGIFactory2*, IUnknown*, DXGI_SWAP_CHAIN_DESC*, IDXGISwapChain**);
    HRESULT (STDMETHODCALLTYPE *CreateSoftwareAdapter)(IDXGIFactory2*, HMODULE, IDXGIAdapter**);
    // IDXGIFactory1 (2 methods)
    HRESULT (STDMETHODCALLTYPE *EnumAdapters1)(IDXGIFactory2*, UINT, void**);
    BOOL    (STDMETHODCALLTYPE *IsCurrent)(IDXGIFactory2*);
    // IDXGIFactory2
    BOOL    (STDMETHODCALLTYPE *IsWindowedStereoEnabled)(IDXGIFactory2*);
    HRESULT (STDMETHODCALLTYPE *CreateSwapChainForHwnd)(IDXGIFactory2*, IUnknown*, HWND,
                const DXGI_SWAP_CHAIN_DESC1*, const void*, IDXGIOutput*, IDXGISwapChain1**);
    HRESULT (STDMETHODCALLTYPE *CreateSwapChainForCoreWindow)(IDXGIFactory2*, IUnknown*, IUnknown*,
                const DXGI_SWAP_CHAIN_DESC1*, IDXGIOutput*, IDXGISwapChain1**);
    HRESULT (STDMETHODCALLTYPE *GetSharedResourceAdapterLuid)(IDXGIFactory2*, HANDLE, LUID*);
    HRESULT (STDMETHODCALLTYPE *RegisterStereoStatusWindow)(IDXGIFactory2*, HWND, UINT, DWORD*);
    HRESULT (STDMETHODCALLTYPE *RegisterStereoStatusEvent)(IDXGIFactory2*, HANDLE, DWORD*);
    HRESULT (STDMETHODCALLTYPE *UnregisterStereoStatus)(IDXGIFactory2*, DWORD);
    HRESULT (STDMETHODCALLTYPE *RegisterOcclusionStatusWindow)(IDXGIFactory2*, HWND, UINT, DWORD*);
    HRESULT (STDMETHODCALLTYPE *RegisterOcclusionStatusEvent)(IDXGIFactory2*, HANDLE, DWORD*);
    HRESULT (STDMETHODCALLTYPE *UnregisterOcclusionStatus)(IDXGIFactory2*, DWORD);
    HRESULT (STDMETHODCALLTYPE *CreateSwapChainForComposition)(IDXGIFactory2*, IUnknown*,
                const DXGI_SWAP_CHAIN_DESC1*, IDXGIOutput*, IDXGISwapChain1**);
} IDXGIFactory2Vtbl;
struct IDXGIFactory2 { IDXGIFactory2Vtbl *lpVtbl; };

static const GUID IID_IDXGIFactory2 =
    {0x50c83a1c,0xe072,0x4c48,{0x87,0xb0,0x36,0x30,0xfa,0x36,0xa6,0xd0}};
#endif // __dxgi1_2_h__

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
// Vertex layout (matches HLSL shader input)
// ---------------------------------------------------------------------------

typedef struct {
    float px, py;       // position in pixels
    float u, v;         // texture coordinates
    float r, g, b, a;   // vertex color
} WinVertex;

// ---------------------------------------------------------------------------
// GlyphCache (DirectWrite + D3D11 atlas)
// ---------------------------------------------------------------------------

#define GLYPH_CACHE_CAP  4096
#define GLYPH_WIDE_BIT   (1 << 30)
#define GLYPH_COLOR_BIT  (1 << 29)
#define GLYPH_BOLD_BIT   (1 << 21)
#define GLYPH_ITALIC_BIT (1 << 22)

typedef struct {
    uint32_t codepoint;
    int slot;
} GlyphEntry;

typedef struct GlyphCache {
    ID3D11Texture2D*          texture;        // R8 — grayscale glyphs
    ID3D11ShaderResourceView* texture_srv;
    ID3D11Texture2D*          color_texture;  // BGRA8 — color emoji (lazy)
    ID3D11ShaderResourceView* color_srv;

    IDWriteFactory*           dw_factory;
    IDWriteTextFormat*        dw_format;       // regular
    IDWriteTextFormat*        dw_format_bold;
    IDWriteTextFormat*        dw_format_italic;
    IDWriteTextFormat*        dw_format_bold_italic;
    IDWriteFontFace*          dw_face;         // regular face (for glyph index)
    IDWriteFontFace*          dw_face_bold;
    IDWriteFontFace*          dw_face_italic;
    IDWriteFontFace*          dw_face_bold_italic;

    ID2D1Factory*             d2d_factory;
    ID2D1RenderTarget*        d2d_rt;          // WIC bitmap render target
    ID2D1SolidColorBrush*     d2d_brush;
    IWICBitmap*               wic_bitmap;      // off-screen rasterization target
    IWICImagingFactory*       wic_factory;

    float      glyph_w;
    float      glyph_h;
    int        font_size;      // em-size in pixels
    float      scale;          // DPI scale
    float      ascender;
    float      baseline_y_offset;
    float      x_offset;
    int        atlas_cols;
    int        atlas_w;
    int        atlas_h;
    int        next_slot;
    int        max_slots;

    ID3D11Device*        d3d_device;

    GlyphEntry map[GLYPH_CACHE_CAP];
} GlyphCache;

// Glyph cache (owned by windows_renderer.c)
extern GlyphCache g_gc;

// ---------------------------------------------------------------------------
// Font functions (windows_font.c)
// ---------------------------------------------------------------------------

int  windows_font_init(GlyphCache* gc, ID3D11Device* device, float scale);
int  windows_font_init_ui(GlyphCache* gc, ID3D11Device* device, float scale, float ptSize);
void windows_font_cleanup(GlyphCache* gc);

// Font discovery helpers (used by windows_glyph.c for fallback chain)
IDWriteFontFace*   find_font_face(IDWriteFactory* factory, const wchar_t* family,
                                   DWRITE_FONT_WEIGHT weight, DWRITE_FONT_STYLE style);
IDWriteTextFormat*  create_format(IDWriteFactory* factory, const wchar_t* family,
                                   float fontSize, DWRITE_FONT_WEIGHT weight,
                                   DWRITE_FONT_STYLE style);

// ---------------------------------------------------------------------------
// Glyph rasterization (windows_glyph.c)
// ---------------------------------------------------------------------------

int  glyphCacheLookup(GlyphCache* gc, uint32_t cp);
void glyphCacheInsert(GlyphCache* gc, uint32_t cp, int slot);
void glyphCacheGrow(GlyphCache* gc);
int  glyphCacheRasterize(GlyphCache* gc, uint32_t cp);
uint32_t combiningKey(uint32_t base, uint32_t c1, uint32_t c2);
int  glyphCacheRasterizeCombined(GlyphCache* gc, uint32_t base, uint32_t c1, uint32_t c2);

// ---------------------------------------------------------------------------
// Box-drawing (windows_boxdraw.c)
// ---------------------------------------------------------------------------

int renderBoxDraw(uint8_t* pixels, int stride, uint32_t cp,
                  int gw, int gh, float scale);

// ---------------------------------------------------------------------------
// Render utility functions (windows_render_util.c)
// ---------------------------------------------------------------------------

// HLSL shader sources
extern const char* kHlslVertSrc;
extern const char* kHlslPixelSolidSrc;
extern const char* kHlslPixelTextSrc;

// Vertex emit helpers
int winEmitRect(WinVertex* v, int i, float x, float y, float w, float h,
                float r, float g, float b, float a);
int winEmitQuad(WinVertex* v, int i,
                float x0, float y0, float x1, float y1,
                float u0, float v0, float u1, float v1,
                float r, float g, float b, float a);
int winEmitLine(WinVertex* v, int vi,
                float x0, float y0, float x1, float y1, float thick,
                float r, float g, float b, float a);
int winEmitRoundTopRect(WinVertex* v, int vi,
                        float x, float y, float w, float h, float rad,
                        float r, float g, float b, float a);

// Selection helpers
int winCellIsSelected(int row, int col);

// Grid-to-screen coordinate helpers
float winGridToScreenX(float offX, float gw, int col);
float winGridToScreenY(float offY, float gh, int row);

// Color conversion
void winCellBgColor(const AttyxCell* cell, int row, int col,
                    float* r, float* g, float* b, float* a);
void winCellFgColor(const AttyxCell* cell, int row, int col,
                    int drawCursor, int curRow, int curCol, int curShape,
                    float* r, float* g, float* b);
void winCursorColor(float* r, float* g, float* b);

// Shared D3D11 vertex draw (creates temp buffer, uploads, draws, releases)
void winDrawVerts(WinVertex* verts, int count);
void winDrawSolidVerts(WinVertex* verts, int count);
void winDrawTextVerts(WinVertex* verts, int count, GlyphCache* gc);

// ---------------------------------------------------------------------------
// Renderer draw state (windows_renderer_draw.c)
// ---------------------------------------------------------------------------

extern WinVertex*   g_win_bg_verts;
extern WinVertex*   g_win_text_verts;
extern int          g_win_total_text_verts;
extern AttyxCell*   g_win_cell_snapshot;
extern int          g_win_cell_snapshot_cap;
extern int          g_win_alloc_rows;
extern int          g_win_alloc_cols;
extern int          g_win_bg_vert_cap;
extern int          g_win_prev_cursor_row;
extern int          g_win_prev_cursor_col;
extern int          g_win_prev_cursor_shape;
extern int          g_win_prev_cursor_vis;
extern int          g_win_blink_on;

// Build all BG/cursor/decoration vertices for a frame. Returns vertex count.
int winBuildFrameVerts(AttyxCell* cells, const uint64_t dirty[4],
                       int rows, int cols, int total,
                       int curRow, int curCol, int curShape, int curVis,
                       float offX, float baseOffY, float offY,
                       float gw, float gh,
                       int visibleRows, int visibleTotal);

// ---------------------------------------------------------------------------
// Renderer D3D11 state (shared with overlay/popup renderers)
// ---------------------------------------------------------------------------

// D3D11 device/context — owned by windows_renderer.c, used by overlay/popup
extern ID3D11Device*           g_d3d_device;
extern ID3D11DeviceContext*    g_d3d_context;
extern ID3D11InputLayout*      g_d3d_input_layout;
extern ID3D11VertexShader*     g_d3d_vs;
extern ID3D11PixelShader*      g_d3d_ps_solid;
extern ID3D11PixelShader*      g_d3d_ps_text;
extern ID3D11BlendState*       g_d3d_blend_alpha;
extern ID3D11SamplerState*     g_d3d_sampler;
extern ID3D11Buffer*           g_d3d_cbuffer;

// ---------------------------------------------------------------------------
// Ligature support (windows_ligature.c)
// ---------------------------------------------------------------------------

#define MAX_LIGA_LEN       16
#define LIGA_RESULT_CAP    512

typedef struct {
    uint32_t key;              // ligatureKey hash (0 = empty slot)
    int8_t   count;            // number of codepoints in the sequence
    bool     hasAlternates;    // true if shaping produced different glyphs
    int      slots[MAX_LIGA_LEN]; // atlas slots (-1 = not yet rasterized)
} LigaResult;

uint32_t          ligatureKey(const uint32_t* cps, int count);
bool              isLigaTrigger(uint32_t ch);
const LigaResult* shapeLigatureRun(GlyphCache* gc, const uint32_t* cps, int count, int style);
void              ligatureCacheClear(void);

// ---------------------------------------------------------------------------
// Input handling (windows_input.c)
// ---------------------------------------------------------------------------

LRESULT windows_handle_input(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);

// ---------------------------------------------------------------------------
// Menu bar (windows_menu.c)
// ---------------------------------------------------------------------------

HMENU windows_menu_create(void);
int   windows_menu_handle_command(WPARAM wParam);

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
// Native tab bar (windows_native_tabs.c)
// ---------------------------------------------------------------------------

float ntab_bar_height(void);
void  ntab_draw(float vpW, float vpH);
int   ntab_hit_test(int px, int py, int clientW);
int   ntab_mouse_move(int px, int py, int clientW);
int   ntab_mouse_down(int px, int py, int clientW);
int   ntab_mouse_drag(int px, int py, int clientW);
int   ntab_mouse_up(int px, int py, int clientW);
void  ntab_mouse_leave(void);
void  ntab_set_caption_hover(int ht);

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
