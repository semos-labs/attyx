#ifndef ATTYX_LINUX_INTERNAL_H
#define ATTYX_LINUX_INTERNAL_H

#ifdef __linux__

#define GL_GLEXT_PROTOTYPES
#include <GL/gl.h>
#include <GL/glext.h>
#define GLFW_INCLUDE_NONE
#include <GLFW/glfw3.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include <fontconfig/fontconfig.h>

#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
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

// Context menu state (main thread only; right-click when mouse tracking is off)
extern int   g_ctx_menu_open;   // 1 = menu is visible
extern float g_ctx_menu_x;     // pixel X of menu top-left (grid coords)
extern float g_ctx_menu_y;     // pixel Y of menu top-left (grid coords)
extern int   g_ctx_menu_hover;  // hovered item index (-1 = none, 0 = "Reload Config")

// Pending resize
extern volatile int g_pending_resize_rows;
extern volatile int g_pending_resize_cols;

// GLFW window handle (needed by input and render)
extern GLFWwindow* g_window;

// ---------------------------------------------------------------------------
// Vertex layout
// ---------------------------------------------------------------------------

typedef struct __attribute__((packed)) {
    float px, py;
    float u, v;
    float r, g, b, a;
} Vertex;

// ---------------------------------------------------------------------------
// GlyphCache
// ---------------------------------------------------------------------------

#define GLYPH_CACHE_CAP  4096
#define GLYPH_WIDE_BIT   (1 << 30)
// Bit 29 flags a color emoji glyph stored in color_texture (GL_RGBA8), not texture (GL_R8).
#define GLYPH_COLOR_BIT  (1 << 29)

typedef struct {
    uint32_t codepoint;
    int slot;
} GlyphEntry;

typedef struct {
    GLuint     texture;         // GL_R8 — grayscale glyphs
    GLuint     color_texture;   // GL_RGBA8 — color emoji (premultiplied BGRA→RGBA)
    FT_Library ft_lib;
    FT_Face    ft_face;
    float      glyph_w;
    float      glyph_h;
    float      scale;
    float      ascender;
    float      baseline_y_offset;
    float      x_offset;
    int        atlas_cols;
    int        atlas_w;
    int        atlas_h;
    int        next_slot;
    int        max_slots;
    GlyphEntry map[GLYPH_CACHE_CAP];
} GlyphCache;

// Glyph cache (defined in linux_render.c — renderer owns it)
extern GlyphCache g_gc;

// Cell pixel dimensions (set in attyx_run, used by input and render)
extern float g_cell_px_w;
extern float g_cell_px_h;
extern float g_content_scale;

// Renderer state used by input (full_redraw flag)
extern int g_full_redraw;

// ---------------------------------------------------------------------------
// GLSL shader source strings (linux_render_util.c)
// ---------------------------------------------------------------------------

extern const char* kVertSrc;
extern const char* kFragSolidSrc;
extern const char* kFragTextSrc;
extern const char* kFragColorTextSrc;

// ---------------------------------------------------------------------------
// GlyphCache functions (linux_glyph.c)
// ---------------------------------------------------------------------------

char* findFontPath(const char* family);
int   glyphCacheLookup(GlyphCache* gc, uint32_t cp);
int   glyphCacheRasterize(GlyphCache* gc, uint32_t cp);
GlyphCache createGlyphCache(FT_Library ft_lib, float contentScale);

// ---------------------------------------------------------------------------
// Emit helpers (linux_render.c — used by renderer)
// ---------------------------------------------------------------------------

int emitRect(Vertex* v, int i, float x, float y, float w, float h,
             float r, float g, float b, float a);
int emitTri(Vertex* v, int i,
            float x0, float y0, float x1, float y1, float x2, float y2,
            float r, float g, float b, float a);
int emitGlyph(Vertex* v, int i, GlyphCache* gc, uint32_t cp,
              float x, float y, float gw, float gh,
              float r, float g, float b);
int emitString(Vertex* v, int i, GlyphCache* gc,
               const char* str, int len, float x, float y,
               float gw, float gh, float r, float g, float b);

// ---------------------------------------------------------------------------
// Dirty helpers (linux_render.c)
// ---------------------------------------------------------------------------

static inline int dirtyBitTest(const uint64_t dirty[4], int row) {
    if (row < 0 || row >= 256) return 0;
    return (dirty[row >> 6] >> (row & 63)) & 1;
}

static inline int dirtyAny(const uint64_t dirty[4]) {
    return (dirty[0] | dirty[1] | dirty[2] | dirty[3]) != 0;
}

// ---------------------------------------------------------------------------
// GL helpers (linux_render.c)
// ---------------------------------------------------------------------------

GLuint compileShader(GLenum type, const char* src);
GLuint createProgram(const char* vertSrc, const char* fragSrc);
void   setupVertexAttribs(void);

// ---------------------------------------------------------------------------
// Overlay rendering (linux_overlay.c)
// ---------------------------------------------------------------------------

void drawOverlays(float offX, float offY, float gw, float gh,
                  float viewport[2]);

// ---------------------------------------------------------------------------
// Popup rendering (linux_popup.c)
// ---------------------------------------------------------------------------

void drawPopup(float offX, float offY, float gw, float gh,
               float viewport[2]);

// ---------------------------------------------------------------------------
// UTF-8 helper (linux_input.c — also used in linux_render.c via doCopy)
// ---------------------------------------------------------------------------

int utf8Encode(uint32_t cp, uint8_t* buf);

// ---------------------------------------------------------------------------
// Clipboard
// ---------------------------------------------------------------------------

void doCopy(void);

// ---------------------------------------------------------------------------
// Selection helpers (linux_render.c — also needed by input)
// ---------------------------------------------------------------------------

int cellIsSelected(int row, int col);

// ---------------------------------------------------------------------------
// URL detection helpers (linux_render.c — also needed by input)
// ---------------------------------------------------------------------------

int detectUrlAtCell(int row, int col, int cols,
                    int *outStart, int *outEnd,
                    char *outUrl, int urlBufSize, int *outUrlLen);

// ---------------------------------------------------------------------------
// Word boundary helpers (linux_render.c — also needed by input)
// ---------------------------------------------------------------------------

void findWordBounds(int row, int col, int cols, int* outStart, int* outEnd);

// ---------------------------------------------------------------------------
// Mouse helpers (linux_input.c)
// ---------------------------------------------------------------------------

void mouseToCell(double mx, double my, int* outCol, int* outRow);
void mouseToCell1(double mx, double my, int* outCol, int* outRow);

// ---------------------------------------------------------------------------
// Callback registration (linux_input.c)
// ---------------------------------------------------------------------------

void linux_set_error_callback(void);
void linux_register_callbacks(GLFWwindow* win);

// ---------------------------------------------------------------------------
// Font rebuild (linux_render.c — called from main loop when g_needs_font_rebuild is set)
// ---------------------------------------------------------------------------

void linux_rebuild_font(void);

// ---------------------------------------------------------------------------
// Draw frame (linux_render.c)
// ---------------------------------------------------------------------------

int drawFrame(void);

// ---------------------------------------------------------------------------
// Renderer init / cleanup (linux_render.c)
// ---------------------------------------------------------------------------

void linux_renderer_init(void);
void linux_renderer_cleanup(void);

#endif // __linux__
#endif // ATTYX_LINUX_INTERNAL_H
