// Attyx — Linux platform layer (GLFW + OpenGL 3.3 + FreeType + Fontconfig)
// Renders a live terminal grid and handles keyboard/mouse input.

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
#include <stddef.h>
#include <math.h>

#include "bridge.h"

// ---------------------------------------------------------------------------
// Shared state (written by Zig PTY thread, read by renderer on main thread)
// ---------------------------------------------------------------------------

static AttyxCell* g_cells = NULL;
static int g_cols = 0;
static int g_rows = 0;
static volatile uint64_t g_cell_gen = 0;
static volatile int g_cursor_row = 0;
static volatile int g_cursor_col = 0;
static volatile int g_should_quit = 0;

static volatile int g_bracketed_paste = 0;
static volatile int g_cursor_keys_app = 0;

static volatile int g_mouse_tracking = 0;
static volatile int g_mouse_sgr = 0;

volatile int g_viewport_offset = 0;
volatile int g_scrollback_count = 0;
volatile int g_alt_screen = 0;

volatile int g_sel_start_row = -1, g_sel_start_col = -1;
volatile int g_sel_end_row = -1, g_sel_end_col = -1;
volatile int g_sel_active = 0;

volatile int g_cursor_shape   = 0;
volatile int g_cursor_visible = 1;

char         g_title_buf[ATTYX_TITLE_MAX];
volatile int g_title_len     = 0;
volatile int g_title_changed = 0;

volatile int  g_ime_composing    = 0;
volatile int  g_ime_cursor_index = -1;
volatile int  g_ime_anchor_row   = 0;
volatile int  g_ime_anchor_col   = 0;
char          g_ime_preedit[ATTYX_IME_MAX_BYTES];
volatile int  g_ime_preedit_len  = 0;

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

static volatile uint32_t g_hover_link_id = 0;
static volatile int g_hover_row = -1;

#define DETECTED_URL_MAX 2048
static char g_detected_url[DETECTED_URL_MAX];
static volatile int g_detected_url_len = 0;
static volatile int g_detected_url_row = -1;
static volatile int g_detected_url_start_col = 0;
static volatile int g_detected_url_end_col = 0;

static volatile uint64_t g_dirty[4] = {0,0,0,0};
static volatile int g_pending_resize_rows = 0;
static volatile int g_pending_resize_cols = 0;

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
        __sync_fetch_and_or((volatile uint64_t*)&g_dirty[i], ~(uint64_t)0);
}

void attyx_scroll_viewport(int delta) {
    int cur = g_viewport_offset;
    int sb = g_scrollback_count;
    int nv = cur + delta;
    if (nv < 0) nv = 0;
    if (nv > sb) nv = sb;
    g_viewport_offset = nv;
    attyx_mark_all_dirty();
}

void attyx_set_dirty(const uint64_t dirty[4]) {
    for (int i = 0; i < 4; i++)
        __sync_fetch_and_or((volatile uint64_t*)&g_dirty[i], dirty[i]);
}

void attyx_set_grid_size(int cols, int rows) {
    g_cols = cols;
    g_rows = rows;
}

void attyx_begin_cell_update(void) {
    __sync_fetch_and_add(&g_cell_gen, 1);
}

void attyx_end_cell_update(void) {
    __sync_fetch_and_add(&g_cell_gen, 1);
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

// ---------------------------------------------------------------------------
// GLSL shader sources (OpenGL 3.3 core — port of Metal shaders)
// ---------------------------------------------------------------------------

static const char* kVertSrc =
    "#version 330 core\n"
    "layout(location = 0) in vec2 aPos;\n"
    "layout(location = 1) in vec2 aTexCoord;\n"
    "layout(location = 2) in vec4 aColor;\n"
    "uniform vec2 viewport;\n"
    "out vec2 vTexCoord;\n"
    "out vec4 vColor;\n"
    "void main() {\n"
    "    vec2 pos = aPos / viewport * 2.0 - 1.0;\n"
    "    pos.y = -pos.y;\n"
    "    gl_Position = vec4(pos, 0.0, 1.0);\n"
    "    vTexCoord = aTexCoord;\n"
    "    vColor = aColor;\n"
    "}\n";

static const char* kFragSolidSrc =
    "#version 330 core\n"
    "in vec4 vColor;\n"
    "out vec4 fragColor;\n"
    "void main() {\n"
    "    fragColor = vColor;\n"
    "}\n";

static const char* kFragTextSrc =
    "#version 330 core\n"
    "in vec2 vTexCoord;\n"
    "in vec4 vColor;\n"
    "uniform sampler2D tex;\n"
    "out vec4 fragColor;\n"
    "void main() {\n"
    "    float a = texture(tex, vTexCoord).r;\n"
    "    fragColor = vec4(vColor.rgb, vColor.a * a);\n"
    "}\n";

// ---------------------------------------------------------------------------
// Vertex layout (matches Metal struct)
// ---------------------------------------------------------------------------

typedef struct __attribute__((packed)) {
    float px, py;
    float u, v;
    float r, g, b, a;
} Vertex;

// ---------------------------------------------------------------------------
// GL helpers
// ---------------------------------------------------------------------------

static GLuint compileShader(GLenum type, const char* src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[512];
        glGetShaderInfoLog(s, sizeof(log), NULL, log);
        fprintf(stderr, "[attyx] shader error: %s\n", log);
    }
    return s;
}

static GLuint createProgram(const char* vertSrc, const char* fragSrc) {
    GLuint vs = compileShader(GL_VERTEX_SHADER, vertSrc);
    GLuint fs = compileShader(GL_FRAGMENT_SHADER, fragSrc);
    GLuint prog = glCreateProgram();
    glAttachShader(prog, vs);
    glAttachShader(prog, fs);
    glLinkProgram(prog);
    GLint ok;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[512];
        glGetProgramInfoLog(prog, sizeof(log), NULL, log);
        fprintf(stderr, "[attyx] link error: %s\n", log);
    }
    glDeleteShader(vs);
    glDeleteShader(fs);
    return prog;
}

static void setupVertexAttribs(void) {
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, sizeof(Vertex),
                          (void*)offsetof(Vertex, px));
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, sizeof(Vertex),
                          (void*)offsetof(Vertex, u));
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(2, 4, GL_FLOAT, GL_FALSE, sizeof(Vertex),
                          (void*)offsetof(Vertex, r));
    glEnableVertexAttribArray(2);
}

// ---------------------------------------------------------------------------
// UTF-8 encode/decode helpers
// ---------------------------------------------------------------------------

static int utf8Encode(uint32_t cp, uint8_t* buf) {
    if (cp < 0x80)    { buf[0] = (uint8_t)cp; return 1; }
    if (cp < 0x800)   { buf[0] = 0xC0|(cp>>6); buf[1] = 0x80|(cp&0x3F); return 2; }
    if (cp < 0x10000) { buf[0] = 0xE0|(cp>>12); buf[1] = 0x80|((cp>>6)&0x3F); buf[2] = 0x80|(cp&0x3F); return 3; }
    if (cp < 0x110000){ buf[0] = 0xF0|(cp>>18); buf[1] = 0x80|((cp>>12)&0x3F); buf[2] = 0x80|((cp>>6)&0x3F); buf[3] = 0x80|(cp&0x3F); return 4; }
    return 0;
}

// ---------------------------------------------------------------------------
// Font discovery via Fontconfig
// ---------------------------------------------------------------------------

static char* findFontPath(const char* family) {
    FcConfig* config = FcInitLoadConfigAndFonts();
    FcPattern* pat = FcPatternCreate();
    FcPatternAddString(pat, FC_FAMILY, (const FcChar8*)family);
    FcPatternAddInteger(pat, FC_SPACING, FC_MONO);
    FcConfigSubstitute(config, pat, FcMatchPattern);
    FcDefaultSubstitute(pat);

    FcResult result;
    FcPattern* match = FcFontMatch(config, pat, &result);
    char* path = NULL;
    if (match) {
        FcChar8* file;
        if (FcPatternGetString(match, FC_FILE, 0, &file) == FcResultMatch)
            path = strdup((char*)file);
        FcPatternDestroy(match);
    }
    FcPatternDestroy(pat);
    return path;
}

// ---------------------------------------------------------------------------
// Dynamic glyph cache — rasterised with FreeType on demand
// ---------------------------------------------------------------------------

#define GLYPH_CACHE_CAP 4096

typedef struct {
    uint32_t codepoint;
    int slot;
} GlyphEntry;

typedef struct {
    GLuint     texture;
    FT_Library ft_lib;
    FT_Face    ft_face;
    float      glyph_w;
    float      glyph_h;
    float      scale;
    float      ascender;
    int        atlas_cols;
    int        atlas_w;
    int        atlas_h;
    int        next_slot;
    int        max_slots;
    GlyphEntry map[GLYPH_CACHE_CAP];
} GlyphCache;

static int glyphCacheLookup(GlyphCache* gc, uint32_t cp) {
    uint32_t idx = (cp * 2654435761u) % GLYPH_CACHE_CAP;
    for (int probe = 0; probe < GLYPH_CACHE_CAP; probe++) {
        uint32_t i = (idx + probe) % GLYPH_CACHE_CAP;
        if (gc->map[i].slot < 0) return -1;
        if (gc->map[i].codepoint == cp) return gc->map[i].slot;
    }
    return -1;
}

static void glyphCacheInsert(GlyphCache* gc, uint32_t cp, int slot) {
    uint32_t idx = (cp * 2654435761u) % GLYPH_CACHE_CAP;
    for (int probe = 0; probe < GLYPH_CACHE_CAP; probe++) {
        uint32_t i = (idx + probe) % GLYPH_CACHE_CAP;
        if (gc->map[i].slot < 0 || gc->map[i].codepoint == cp) {
            gc->map[i].codepoint = cp;
            gc->map[i].slot = slot;
            return;
        }
    }
}

static void glyphCacheGrow(GlyphCache* gc) {
    int oldH = gc->atlas_h;
    int newRows = (gc->max_slots / gc->atlas_cols) * 2;
    int newH = (int)(gc->glyph_h * newRows);
    int newMaxSlots = gc->atlas_cols * newRows;

    uint8_t* buf = (uint8_t*)calloc(gc->atlas_w * newH, 1);
    glBindTexture(GL_TEXTURE_2D, gc->texture);
    glGetTexImage(GL_TEXTURE_2D, 0, GL_RED, GL_UNSIGNED_BYTE, buf);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, gc->atlas_w, newH, 0,
                 GL_RED, GL_UNSIGNED_BYTE, buf);
    free(buf);

    gc->atlas_h = newH;
    gc->max_slots = newMaxSlots;
}

static int glyphCacheRasterize(GlyphCache* gc, uint32_t cp) {
    if (gc->next_slot >= gc->max_slots)
        glyphCacheGrow(gc);

    int slot = gc->next_slot++;
    int ac = slot % gc->atlas_cols;
    int ar = slot / gc->atlas_cols;
    int gw = (int)gc->glyph_w;
    int gh = (int)gc->glyph_h;

    FT_Face face = gc->ft_face;
    FT_UInt gi = FT_Get_Char_Index(face, cp);

    if (gi == 0) {
        // Font fallback via Fontconfig
        FcPattern* pat = FcPatternCreate();
        FcCharSet* cs = FcCharSetCreate();
        FcCharSetAddChar(cs, cp);
        FcPatternAddCharSet(pat, FC_CHARSET, cs);
        FcConfigSubstitute(NULL, pat, FcMatchPattern);
        FcDefaultSubstitute(pat);
        FcResult res;
        FcPattern* match = FcFontMatch(NULL, pat, &res);
        FT_Face fallback = NULL;
        if (match) {
            FcChar8* file; int index = 0;
            FcPatternGetString(match, FC_FILE, 0, &file);
            FcPatternGetInteger(match, FC_INDEX, 0, &index);
            if (FT_New_Face(gc->ft_lib, (char*)file, index, &fallback) == 0) {
                FT_Set_Pixel_Sizes(fallback, 0, (int)gc->glyph_h);
                gi = FT_Get_Char_Index(fallback, cp);
                if (gi != 0) face = fallback;
            }
            FcPatternDestroy(match);
        }
        FcCharSetDestroy(cs);
        FcPatternDestroy(pat);

        if (gi == 0) {
            if (fallback) FT_Done_Face(fallback);
            glyphCacheInsert(gc, cp, slot);
            return slot;
        }
        // face is set to fallback; we'll free it after rasterizing
    }

    FT_Load_Glyph(face, gi, FT_LOAD_DEFAULT);
    FT_Render_Glyph(face->glyph, FT_RENDER_MODE_NORMAL);
    FT_Bitmap* bmp = &face->glyph->bitmap;

    uint8_t* pixels = (uint8_t*)calloc(gw * gh, 1);
    int bl = face->glyph->bitmap_left;
    int bt = face->glyph->bitmap_top;
    int asc = (int)gc->ascender;

    for (unsigned row = 0; row < bmp->rows; row++) {
        int dy = asc - bt + (int)row;
        if (dy < 0 || dy >= gh) continue;
        for (unsigned col = 0; col < bmp->width; col++) {
            int dx = bl + (int)col;
            if (dx < 0 || dx >= gw) continue;
            pixels[dy * gw + dx] = bmp->buffer[row * bmp->pitch + col];
        }
    }

    if (face != gc->ft_face) FT_Done_Face(face);

    glBindTexture(GL_TEXTURE_2D, gc->texture);
    glTexSubImage2D(GL_TEXTURE_2D, 0, ac * gw, ar * gh, gw, gh,
                    GL_RED, GL_UNSIGNED_BYTE, pixels);
    free(pixels);

    glyphCacheInsert(gc, cp, slot);
    return slot;
}

static GlyphCache createGlyphCache(FT_Library ft_lib, float contentScale) {
    const char* fontEnv = getenv("ATTYX_FONT");
    char* fontPath = NULL;
    if (fontEnv && fontEnv[0])
        fontPath = findFontPath(fontEnv);
    if (!fontPath) fontPath = findFontPath("Monospace");
    if (!fontPath) fontPath = findFontPath("DejaVu Sans Mono");
    if (!fontPath) fontPath = findFontPath("Courier");
    if (!fontPath) {
        fprintf(stderr, "[attyx] no monospace font found\n");
        exit(1);
    }

    FT_Face face;
    if (FT_New_Face(ft_lib, fontPath, 0, &face) != 0) {
        fprintf(stderr, "[attyx] failed to load font: %s\n", fontPath);
        free(fontPath);
        exit(1);
    }
    free(fontPath);

    int fontSize = (int)(16.0f * contentScale);
    FT_Set_Pixel_Sizes(face, 0, fontSize);

    float ascender = (float)(face->size->metrics.ascender >> 6);
    float gh = (float)(face->size->metrics.height >> 6);
    float gw = (float)(face->size->metrics.max_advance >> 6);

    int cols = 32;
    int initRows = 32;
    int atlasW = (int)(gw * cols);
    int atlasH = (int)(gh * initRows);

    GLuint tex;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);

    uint8_t* zeroes = (uint8_t*)calloc(atlasW * atlasH, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, atlasW, atlasH, 0,
                 GL_RED, GL_UNSIGNED_BYTE, zeroes);
    free(zeroes);

    GlyphCache gc;
    memset(&gc, 0, sizeof(gc));
    gc.texture    = tex;
    gc.ft_lib     = ft_lib;
    gc.ft_face    = face;
    gc.glyph_w    = gw;
    gc.glyph_h    = gh;
    gc.scale      = contentScale;
    gc.ascender   = ascender;
    gc.atlas_cols = cols;
    gc.atlas_w    = atlasW;
    gc.atlas_h    = atlasH;
    gc.next_slot  = 0;
    gc.max_slots  = cols * initRows;

    for (int i = 0; i < GLYPH_CACHE_CAP; i++) gc.map[i].slot = -1;

    for (uint32_t ch = 32; ch < 127; ch++)
        glyphCacheRasterize(&gc, ch);

    return gc;
}

// ---------------------------------------------------------------------------
// Search overlay rendering helpers
// ---------------------------------------------------------------------------

static int emitRect(Vertex* v, int i, float x, float y, float w, float h,
                    float r, float g, float b, float a) {
    v[i+0] = (Vertex){ x,   y,   0,0, r,g,b,a };
    v[i+1] = (Vertex){ x+w, y,   0,0, r,g,b,a };
    v[i+2] = (Vertex){ x,   y+h, 0,0, r,g,b,a };
    v[i+3] = (Vertex){ x+w, y,   0,0, r,g,b,a };
    v[i+4] = (Vertex){ x+w, y+h, 0,0, r,g,b,a };
    v[i+5] = (Vertex){ x,   y+h, 0,0, r,g,b,a };
    return i + 6;
}

static int emitTri(Vertex* v, int i,
                   float x0, float y0, float x1, float y1, float x2, float y2,
                   float r, float g, float b, float a) {
    v[i+0] = (Vertex){ x0,y0, 0,0, r,g,b,a };
    v[i+1] = (Vertex){ x1,y1, 0,0, r,g,b,a };
    v[i+2] = (Vertex){ x2,y2, 0,0, r,g,b,a };
    return i + 3;
}

static int emitGlyph(Vertex* v, int i, GlyphCache* gc, uint32_t cp,
                     float x, float y, float gw, float gh,
                     float r, float g, float b) {
    int slot = glyphCacheLookup(gc, cp);
    if (slot < 0) slot = glyphCacheRasterize(gc, cp);
    float aW = (float)gc->atlas_w, aH = (float)gc->atlas_h;
    float gW = gc->glyph_w, gH = gc->glyph_h;
    int ac = slot % gc->atlas_cols, ar = slot / gc->atlas_cols;
    float u0 = ac * gW / aW, u1 = (ac+1) * gW / aW;
    float v0 = ar * gH / aH, v1 = (ar+1) * gH / aH;
    v[i+0] = (Vertex){ x,    y,    u0,v0, r,g,b,1 };
    v[i+1] = (Vertex){ x+gw, y,    u1,v0, r,g,b,1 };
    v[i+2] = (Vertex){ x,    y+gh, u0,v1, r,g,b,1 };
    v[i+3] = (Vertex){ x+gw, y,    u1,v0, r,g,b,1 };
    v[i+4] = (Vertex){ x+gw, y+gh, u1,v1, r,g,b,1 };
    v[i+5] = (Vertex){ x,    y+gh, u0,v1, r,g,b,1 };
    return i + 6;
}

static int emitString(Vertex* v, int i, GlyphCache* gc,
                      const char* str, int len, float x, float y,
                      float gw, float gh, float r, float g, float b) {
    for (int c = 0; c < len; c++) {
        uint32_t cp = (uint8_t)str[c];
        if (cp <= 32) continue;
        i = emitGlyph(v, i, gc, cp, x + c * gw, y, gw, gh, r, g, b);
    }
    return i;
}

// ---------------------------------------------------------------------------
// Dirty-bitset helpers
// ---------------------------------------------------------------------------

static inline int dirtyBitTest(const uint64_t dirty[4], int row) {
    if (row < 0 || row >= 256) return 0;
    return (dirty[row >> 6] >> (row & 63)) & 1;
}

static inline int dirtyAny(const uint64_t dirty[4]) {
    return (dirty[0] | dirty[1] | dirty[2] | dirty[3]) != 0;
}

// ---------------------------------------------------------------------------
// Selection helpers
// ---------------------------------------------------------------------------

static int cellIsSelected(int row, int col) {
    if (!g_sel_active) return 0;
    int sr = g_sel_start_row, sc = g_sel_start_col;
    int er = g_sel_end_row, ec = g_sel_end_col;
    if (sr > er || (sr == er && sc > ec)) {
        int tr = sr, tc = sc; sr = er; sc = ec; er = tr; ec = tc;
    }
    if (row < sr || row > er) return 0;
    if (row == sr && row == er) return col >= sc && col <= ec;
    if (row == sr) return col >= sc;
    if (row == er) return col <= ec;
    return 1;
}

// --- URL detection in cell row ---

static int isUrlChar(uint32_t ch) {
    if (ch <= 32 || ch == 127) return 0;
    if (ch == '<' || ch == '>' || ch == '"' || ch == '`') return 0;
    if (ch == '{' || ch == '}') return 0;
    return 1;
}

static int isTrailingPunct(uint32_t ch) {
    return (ch == '.' || ch == ',' || ch == ';' || ch == ':' ||
            ch == '!' || ch == '?' || ch == '\'' || ch == '"' ||
            ch == ')' || ch == ']' || ch == '>');
}

static int detectUrlAtCell(int row, int col, int cols,
                           int *outStart, int *outEnd,
                           char *outUrl, int urlBufSize, int *outUrlLen) {
    if (!g_cells || cols <= 0) return 0;
    int base = row * cols;

    char rowText[1024];
    int len = cols < 1023 ? cols : 1023;
    for (int i = 0; i < len; i++) {
        uint32_t ch = g_cells[base + i].character;
        rowText[i] = (ch >= 32 && ch < 127) ? (char)ch : ' ';
    }
    rowText[len] = '\0';

    const char *schemes[] = { "https://", "http://" };
    const int schemeLens[] = { 8, 7 };

    for (int s = 0; s < 2; s++) {
        const char *haystack = rowText;
        while (1) {
            const char *found = strstr(haystack, schemes[s]);
            if (!found) break;
            int startCol = (int)(found - rowText);
            int endCol = startCol + schemeLens[s];

            while (endCol < len && isUrlChar(g_cells[base + endCol].character))
                endCol++;
            endCol--;

            while (endCol > startCol + schemeLens[s] && isTrailingPunct(g_cells[base + endCol].character))
                endCol--;

            {
                int opens = 0, closes = 0;
                for (int i = startCol; i <= endCol; i++) {
                    uint32_t ch = g_cells[base + i].character;
                    if (ch == '(') opens++;
                    if (ch == ')') closes++;
                }
                while (opens > closes && endCol + 1 < len && g_cells[base + endCol + 1].character == ')') {
                    endCol++;
                    closes++;
                }
            }

            if (col >= startCol && col <= endCol) {
                *outStart = startCol;
                *outEnd = endCol;
                int urlLen = endCol - startCol + 1;
                if (urlLen >= urlBufSize) urlLen = urlBufSize - 1;
                for (int i = 0; i < urlLen; i++) {
                    uint32_t ch = g_cells[base + startCol + i].character;
                    outUrl[i] = (ch >= 32 && ch < 127) ? (char)ch : '?';
                }
                outUrl[urlLen] = '\0';
                *outUrlLen = urlLen;
                return 1;
            }
            haystack = found + 1;
        }
    }
    return 0;
}

// --- Word boundary helpers for double-click selection ---

static int isWordChar(uint32_t ch) {
    if (ch == 0 || ch == ' ') return 0;
    if (ch == '_' || ch == '-') return 1;
    if (ch > 127) return 1;
    if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
        (ch >= '0' && ch <= '9')) return 1;
    return 0;
}

static void findWordBounds(int row, int col, int cols, int* outStart, int* outEnd) {
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
// Renderer state
// ---------------------------------------------------------------------------

static GLFWwindow*  g_window = NULL;
static GlyphCache   g_gc;
static GLuint       g_solid_prog, g_text_prog;
static GLint        g_vp_loc_solid, g_vp_loc_text, g_tex_loc;
static GLuint       g_vao, g_vbo;

static Vertex*      g_bg_verts = NULL;
static Vertex*      g_text_verts = NULL;
static int          g_total_text_verts = 0;

static AttyxCell*   g_cell_snapshot = NULL;
static int          g_cell_snapshot_cap = 0;

static int          g_prev_cursor_row = -1;
static int          g_prev_cursor_col = -1;
static int          g_prev_cursor_shape = -1;
static int          g_prev_cursor_vis = -1;
static int          g_blink_on = 1;
static double       g_blink_last_toggle = 0.0;
static int          g_full_redraw = 1;
static int          g_alloc_rows = 0;
static int          g_alloc_cols = 0;
static int          g_bg_vert_cap = 0;

static float        g_cell_px_w = 0;
static float        g_cell_px_h = 0;
static float        g_content_scale = 1.0f;

// ---------------------------------------------------------------------------
// Draw frame
// ---------------------------------------------------------------------------

static void drawFrame(void) {
    if (!g_cells || g_cols <= 0 || g_rows <= 0) return;

    uint64_t gen1 = g_cell_gen;
    if (gen1 & 1) return;

    int rows = g_rows;
    int cols = g_cols;
    int total = cols * rows;

    uint64_t dirty[4];
    for (int i = 0; i < 4; i++)
        dirty[i] = __sync_lock_test_and_set((volatile uint64_t*)&g_dirty[i], 0);

    int curRow = g_cursor_row;
    int curCol = g_cursor_col;
    int curShape = g_cursor_shape;
    int curVis = g_cursor_visible;

    int cursorChanged = (curRow != g_prev_cursor_row || curCol != g_prev_cursor_col
                         || curShape != g_prev_cursor_shape || curVis != g_prev_cursor_vis);

    int isBlinking = curVis && (curShape == 0 || curShape == 2 || curShape == 4);
    double now = glfwGetTime();
    if (cursorChanged) {
        g_blink_on = 1;
        g_blink_last_toggle = now;
    } else if (isBlinking) {
        if (now - g_blink_last_toggle >= 0.5) {
            g_blink_on = !g_blink_on;
            g_blink_last_toggle = now;
        }
    } else {
        g_blink_on = 1;
    }

    // Reallocate persistent buffers if grid size changed
    if (rows != g_alloc_rows || cols != g_alloc_cols) {
        free(g_bg_verts);
        free(g_text_verts);
        free(g_cell_snapshot);

        g_bg_vert_cap = (total * 2 + cols + cols + ATTYX_SEARCH_VIS_MAX) * 6;
        g_bg_verts      = (Vertex*)calloc(g_bg_vert_cap, sizeof(Vertex));
        g_text_verts    = (Vertex*)calloc(total * 6, sizeof(Vertex));
        g_cell_snapshot = (AttyxCell*)malloc(sizeof(AttyxCell) * total);
        g_cell_snapshot_cap = total;
        g_total_text_verts = 0;
        g_alloc_rows = rows;
        g_alloc_cols = cols;
        g_full_redraw = 1;
    }

    if (!g_full_redraw && !dirtyAny(dirty) && !cursorChanged && !isBlinking && !g_search_active) return;

    if (g_cell_snapshot && g_cell_snapshot_cap >= total)
        memcpy(g_cell_snapshot, g_cells, sizeof(AttyxCell) * total);
    else
        return;

    uint64_t gen2 = g_cell_gen;
    if (gen1 != gen2) return;

    AttyxCell* cells = g_cell_snapshot;
    float gw = g_gc.glyph_w;
    float gh = g_gc.glyph_h;
    float viewport[2] = { cols * gw, rows * gh };
    float atlasW = (float)g_gc.atlas_w;
    float glyphW = g_gc.glyph_w;
    float glyphH = g_gc.glyph_h;
    int atlasCols = g_gc.atlas_cols;

    // Update bg vertices for dirty rows
    for (int row = 0; row < rows; row++) {
        if (!g_full_redraw && !dirtyBitTest(dirty, row)) continue;
        for (int col = 0; col < cols; col++) {
            int i = row * cols + col;
            float x0 = col * gw, y0 = row * gh;
            float x1 = x0 + gw, y1 = y0 + gh;
            const AttyxCell* cell = &cells[i];
            float br, bg, bb;
            if (cellIsSelected(row, col)) {
                br = 0.20f; bg = 0.40f; bb = 0.70f;
            } else {
                br = cell->bg_r / 255.0f;
                bg = cell->bg_g / 255.0f;
                bb = cell->bg_b / 255.0f;
            }
            int bi = i * 6;
            g_bg_verts[bi+0] = (Vertex){ x0,y0, 0,0, br,bg,bb,1 };
            g_bg_verts[bi+1] = (Vertex){ x1,y0, 0,0, br,bg,bb,1 };
            g_bg_verts[bi+2] = (Vertex){ x0,y1, 0,0, br,bg,bb,1 };
            g_bg_verts[bi+3] = (Vertex){ x1,y0, 0,0, br,bg,bb,1 };
            g_bg_verts[bi+4] = (Vertex){ x1,y1, 0,0, br,bg,bb,1 };
            g_bg_verts[bi+5] = (Vertex){ x0,y1, 0,0, br,bg,bb,1 };
        }
    }

    // Cursor quad (shape-aware)
    int cursorSlot = total * 6;
    memset(&g_bg_verts[cursorSlot], 0, sizeof(Vertex) * 6);
    int bgVertCount = total * 6;
    int drawCursor = curVis && g_blink_on
                     && curRow >= 0 && curRow < rows && curCol >= 0 && curCol < cols;
    if (drawCursor) {
        float cx0 = curCol * gw, cy0 = curRow * gh;
        float cr = 0.86f, cg_c = 0.86f, cb = 0.86f;
        float rx0 = cx0, ry0 = cy0, rx1 = cx0 + gw, ry1 = cy0 + gh;

        switch (curShape) {
            case 0: case 1: break; // block
            case 2: case 3: { // underline
                float th = fmaxf(2.0f, 1.0f);
                ry0 = ry1 - th;
                break;
            }
            case 4: case 5: { // bar
                float th = fmaxf(2.0f, 1.0f);
                rx1 = rx0 + th;
                break;
            }
            default: break;
        }

        g_bg_verts[cursorSlot+0] = (Vertex){ rx0,ry0, 0,0, cr,cg_c,cb,1 };
        g_bg_verts[cursorSlot+1] = (Vertex){ rx1,ry0, 0,0, cr,cg_c,cb,1 };
        g_bg_verts[cursorSlot+2] = (Vertex){ rx0,ry1, 0,0, cr,cg_c,cb,1 };
        g_bg_verts[cursorSlot+3] = (Vertex){ rx1,ry0, 0,0, cr,cg_c,cb,1 };
        g_bg_verts[cursorSlot+4] = (Vertex){ rx1,ry1, 0,0, cr,cg_c,cb,1 };
        g_bg_verts[cursorSlot+5] = (Vertex){ rx0,ry1, 0,0, cr,cg_c,cb,1 };
        bgVertCount += 6;
    }

    // Hyperlink underlines: OSC 8 (always visible) + detected URLs (on hover)
    if (!g_sel_active) {
        uint32_t hoverLid = g_hover_link_id;
        float ulH = fmaxf(2.0f, 1.0f);

        // OSC 8 links: always show underline
        for (int i = 0; i < total; i++) {
            uint32_t lid = cells[i].link_id;
            if (lid == 0) continue;
            if (bgVertCount + 6 > g_bg_vert_cap) break;
            float lr, lg, lb;
            if (lid == hoverLid) {
                lr = 0.4f; lg = 0.7f; lb = 1.0f;
            } else {
                lr = 0.25f; lg = 0.40f; lb = 0.65f;
            }
            int lrow = i / cols, lcol = i % cols;
            float lx0 = lcol * gw;
            float lx1 = lx0 + gw;
            float ly1 = (lrow + 1) * gh;
            float ly0 = ly1 - ulH;
            g_bg_verts[bgVertCount+0] = (Vertex){ lx0,ly0, 0,0, lr,lg,lb,1 };
            g_bg_verts[bgVertCount+1] = (Vertex){ lx1,ly0, 0,0, lr,lg,lb,1 };
            g_bg_verts[bgVertCount+2] = (Vertex){ lx0,ly1, 0,0, lr,lg,lb,1 };
            g_bg_verts[bgVertCount+3] = (Vertex){ lx1,ly0, 0,0, lr,lg,lb,1 };
            g_bg_verts[bgVertCount+4] = (Vertex){ lx1,ly1, 0,0, lr,lg,lb,1 };
            g_bg_verts[bgVertCount+5] = (Vertex){ lx0,ly1, 0,0, lr,lg,lb,1 };
            bgVertCount += 6;
        }

        // Detected URLs: show underline only when hovered
        int dRow = g_detected_url_row;
        int dStart = g_detected_url_start_col;
        int dEnd = g_detected_url_end_col;
        if (g_detected_url_len > 0 && dRow >= 0 && dRow < rows) {
            float lr = 0.4f, lg = 0.7f, lb = 1.0f;
            for (int c = dStart; c <= dEnd && c < cols; c++) {
                if (bgVertCount + 6 > g_bg_vert_cap) break;
                float lx0 = c * gw;
                float lx1 = lx0 + gw;
                float ly1 = (dRow + 1) * gh;
                float ly0 = ly1 - ulH;
                g_bg_verts[bgVertCount+0] = (Vertex){ lx0,ly0, 0,0, lr,lg,lb,1 };
                g_bg_verts[bgVertCount+1] = (Vertex){ lx1,ly0, 0,0, lr,lg,lb,1 };
                g_bg_verts[bgVertCount+2] = (Vertex){ lx0,ly1, 0,0, lr,lg,lb,1 };
                g_bg_verts[bgVertCount+3] = (Vertex){ lx1,ly0, 0,0, lr,lg,lb,1 };
                g_bg_verts[bgVertCount+4] = (Vertex){ lx1,ly1, 0,0, lr,lg,lb,1 };
                g_bg_verts[bgVertCount+5] = (Vertex){ lx0,ly1, 0,0, lr,lg,lb,1 };
                bgVertCount += 6;
            }
        }
    }

    // Search match highlights
    if (g_search_active) {
        int visCount = g_search_vis_count;
        int curRow = g_search_cur_vis_row;
        int curCs = g_search_cur_vis_cs;
        int curCe = g_search_cur_vis_ce;
        for (int vi = 0; vi < visCount && vi < ATTYX_SEARCH_VIS_MAX; vi++) {
            AttyxSearchVis m = g_search_vis[vi];
            if (m.row < 0 || m.row >= rows) continue;
            int isCurrent = (m.row == curRow && m.col_start == curCs && m.col_end == curCe);
            float hr, hg, hb, ha;
            if (isCurrent) {
                hr = 1.0f; hg = 0.6f; hb = 0.0f; ha = 0.75f;
            } else {
                hr = 1.0f; hg = 0.6f; hb = 0.0f; ha = 0.28f;
            }
            for (int cc = m.col_start; cc < m.col_end && cc < cols; cc++) {
                if (bgVertCount + 6 > g_bg_vert_cap) break;
                float lx0 = cc * gw, lx1 = lx0 + gw;
                float ly0 = m.row * gh, ly1 = ly0 + gh;
                g_bg_verts[bgVertCount+0] = (Vertex){ lx0,ly0, 0,0, hr,hg,hb,ha };
                g_bg_verts[bgVertCount+1] = (Vertex){ lx1,ly0, 0,0, hr,hg,hb,ha };
                g_bg_verts[bgVertCount+2] = (Vertex){ lx0,ly1, 0,0, hr,hg,hb,ha };
                g_bg_verts[bgVertCount+3] = (Vertex){ lx1,ly0, 0,0, hr,hg,hb,ha };
                g_bg_verts[bgVertCount+4] = (Vertex){ lx1,ly1, 0,0, hr,hg,hb,ha };
                g_bg_verts[bgVertCount+5] = (Vertex){ lx0,ly1, 0,0, hr,hg,hb,ha };
                bgVertCount += 6;
            }
        }
    }

    // Text vertices
    int ti = 0;
    if (g_full_redraw || dirtyAny(dirty)) {
        for (int i = 0; i < total; i++) {
            const AttyxCell* cell = &cells[i];
            uint32_t ch = cell->character;
            if (ch <= 32) continue;

            int row = i / cols, col = i % cols;
            float x0 = col * gw, y0 = row * gh;
            float x1 = x0 + gw, y1 = y0 + gh;

            int slot = glyphCacheLookup(&g_gc, ch);
            if (slot < 0) {
                slot = glyphCacheRasterize(&g_gc, ch);
                atlasW = (float)g_gc.atlas_w;
            }

            int ac = slot % atlasCols;
            int ar = slot / atlasCols;
            float atlasH = (float)g_gc.atlas_h;
            float au0 = ac       * glyphW / atlasW;
            float av0 = ar       * glyphH / atlasH;
            float au1 = (ac + 1) * glyphW / atlasW;
            float av1 = (ar + 1) * glyphH / atlasH;

            float fr = cell->fg_r / 255.0f;
            float fg = cell->fg_g / 255.0f;
            float fb = cell->fg_b / 255.0f;

            g_text_verts[ti+0] = (Vertex){ x0,y0, au0,av0, fr,fg,fb,1 };
            g_text_verts[ti+1] = (Vertex){ x1,y0, au1,av0, fr,fg,fb,1 };
            g_text_verts[ti+2] = (Vertex){ x0,y1, au0,av1, fr,fg,fb,1 };
            g_text_verts[ti+3] = (Vertex){ x1,y0, au1,av0, fr,fg,fb,1 };
            g_text_verts[ti+4] = (Vertex){ x1,y1, au1,av1, fr,fg,fb,1 };
            g_text_verts[ti+5] = (Vertex){ x0,y1, au0,av1, fr,fg,fb,1 };
            ti += 6;
        }
        g_total_text_verts = ti;
    } else {
        ti = g_total_text_verts;
    }

    g_prev_cursor_row   = curRow;
    g_prev_cursor_col   = curCol;
    g_prev_cursor_shape = curShape;
    g_prev_cursor_vis   = curVis;
    g_full_redraw = 0;

    // Window title update
    if (g_title_changed && g_window) {
        int tlen = g_title_len;
        if (tlen > 0 && tlen < ATTYX_TITLE_MAX) {
            char tbuf[ATTYX_TITLE_MAX];
            memcpy(tbuf, g_title_buf, tlen);
            tbuf[tlen] = 0;
            glfwSetWindowTitle(g_window, tbuf);
        }
        g_title_changed = 0;
    }

    // --- GL draw ---
    int fb_w, fb_h;
    glfwGetFramebufferSize(g_window, &fb_w, &fb_h);

    glClearColor(0.118f, 0.118f, 0.141f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    int grid_w = (int)viewport[0];
    int grid_h = (int)viewport[1];
    glViewport(0, fb_h - grid_h, grid_w, grid_h);

    glBindVertexArray(g_vao);

    // BG pass (blending on so search highlights respect alpha)
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glUseProgram(g_solid_prog);
    glUniform2f(g_vp_loc_solid, viewport[0], viewport[1]);
    glBindBuffer(GL_ARRAY_BUFFER, g_vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(Vertex) * bgVertCount,
                 g_bg_verts, GL_DYNAMIC_DRAW);
    setupVertexAttribs();
    glDrawArrays(GL_TRIANGLES, 0, bgVertCount);
    glDisable(GL_BLEND);

    // Text pass
    if (ti > 0) {
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glUseProgram(g_text_prog);
        glUniform2f(g_vp_loc_text, viewport[0], viewport[1]);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, g_gc.texture);
        glUniform1i(g_tex_loc, 0);
        glBufferData(GL_ARRAY_BUFFER, sizeof(Vertex) * ti,
                     g_text_verts, GL_DYNAMIC_DRAW);
        setupVertexAttribs();
        glDrawArrays(GL_TRIANGLES, 0, ti);
        glDisable(GL_BLEND);
    }

    // IME preedit overlay
    if (g_ime_composing && g_ime_preedit_len > 0) {
        int pRow = g_ime_anchor_row;
        int pCol = g_ime_anchor_col;
        if (pRow >= 0 && pRow < rows && pCol >= 0 && pCol < cols) {
            char preeditCopy[ATTYX_IME_MAX_BYTES];
            int pLen = g_ime_preedit_len;
            if (pLen > ATTYX_IME_MAX_BYTES - 1) pLen = ATTYX_IME_MAX_BYTES - 1;
            memcpy(preeditCopy, g_ime_preedit, pLen);
            preeditCopy[pLen] = '\0';

            int preCharCount = 0;
            uint32_t preCPs[128];
            const uint8_t* p = (const uint8_t*)preeditCopy;
            const uint8_t* end = p + pLen;
            while (p < end && preCharCount < 128) {
                uint32_t cp = 0;
                if ((*p & 0x80) == 0)         { cp = *p++; }
                else if ((*p & 0xE0) == 0xC0) { cp = (*p & 0x1F); p++; if (p < end) { cp = (cp << 6) | (*p & 0x3F); p++; } }
                else if ((*p & 0xF0) == 0xE0) { cp = (*p & 0x0F); p++; for (int j = 0; j < 2 && p < end; j++) { cp = (cp << 6) | (*p & 0x3F); p++; } }
                else if ((*p & 0xF8) == 0xF0) { cp = (*p & 0x07); p++; for (int j = 0; j < 3 && p < end; j++) { cp = (cp << 6) | (*p & 0x3F); p++; } }
                else { p++; continue; }
                preCPs[preCharCount++] = cp;
            }

            int preCells = preCharCount;
            if (pCol + preCells > cols) preCells = cols - pCol;

            Vertex imeVerts[128 * 6 + 6];
            int iv = 0;
            for (int i = 0; i < preCells; i++) {
                float x0 = (pCol + i) * gw, y0 = pRow * gh;
                float x1 = x0 + gw, y1 = y0 + gh;
                float br = 0.20f, bg = 0.20f, bb = 0.30f;
                imeVerts[iv++] = (Vertex){ x0,y0, 0,0, br,bg,bb,1 };
                imeVerts[iv++] = (Vertex){ x1,y0, 0,0, br,bg,bb,1 };
                imeVerts[iv++] = (Vertex){ x0,y1, 0,0, br,bg,bb,1 };
                imeVerts[iv++] = (Vertex){ x1,y0, 0,0, br,bg,bb,1 };
                imeVerts[iv++] = (Vertex){ x1,y1, 0,0, br,bg,bb,1 };
                imeVerts[iv++] = (Vertex){ x0,y1, 0,0, br,bg,bb,1 };
            }
            float ulH = 2.0f;
            float ulY0 = pRow * gh + gh - ulH, ulY1 = pRow * gh + gh;
            float ulX0 = pCol * gw, ulX1 = (pCol + preCells) * gw;
            imeVerts[iv++] = (Vertex){ ulX0,ulY0, 0,0, 0.9f,0.9f,0.3f,1 };
            imeVerts[iv++] = (Vertex){ ulX1,ulY0, 0,0, 0.9f,0.9f,0.3f,1 };
            imeVerts[iv++] = (Vertex){ ulX0,ulY1, 0,0, 0.9f,0.9f,0.3f,1 };
            imeVerts[iv++] = (Vertex){ ulX1,ulY0, 0,0, 0.9f,0.9f,0.3f,1 };
            imeVerts[iv++] = (Vertex){ ulX1,ulY1, 0,0, 0.9f,0.9f,0.3f,1 };
            imeVerts[iv++] = (Vertex){ ulX0,ulY1, 0,0, 0.9f,0.9f,0.3f,1 };

            glUseProgram(g_solid_prog);
            glUniform2f(g_vp_loc_solid, viewport[0], viewport[1]);
            glBufferData(GL_ARRAY_BUFFER, sizeof(Vertex) * iv,
                         imeVerts, GL_DYNAMIC_DRAW);
            setupVertexAttribs();
            glDrawArrays(GL_TRIANGLES, 0, iv);

            // Preedit text glyphs
            Vertex imeTextVerts[128 * 6];
            int ig = 0;
            for (int i = 0; i < preCells; i++) {
                uint32_t cp = preCPs[i];
                if (cp <= 32) continue;
                float x0 = (pCol + i) * gw, y0 = pRow * gh;
                float x1 = x0 + gw, y1 = y0 + gh;
                int slot = glyphCacheLookup(&g_gc, cp);
                if (slot < 0) slot = glyphCacheRasterize(&g_gc, cp);
                int ac2 = slot % g_gc.atlas_cols;
                int ar2 = slot / g_gc.atlas_cols;
                float aW = (float)g_gc.atlas_w, aH = (float)g_gc.atlas_h;
                float au0 = ac2 * glyphW / aW, av0 = ar2 * glyphH / aH;
                float au1 = (ac2+1) * glyphW / aW, av1 = (ar2+1) * glyphH / aH;
                float fr = 0.95f, fg = 0.95f, fb = 0.95f;
                imeTextVerts[ig++] = (Vertex){ x0,y0, au0,av0, fr,fg,fb,1 };
                imeTextVerts[ig++] = (Vertex){ x1,y0, au1,av0, fr,fg,fb,1 };
                imeTextVerts[ig++] = (Vertex){ x0,y1, au0,av1, fr,fg,fb,1 };
                imeTextVerts[ig++] = (Vertex){ x1,y0, au1,av0, fr,fg,fb,1 };
                imeTextVerts[ig++] = (Vertex){ x1,y1, au1,av1, fr,fg,fb,1 };
                imeTextVerts[ig++] = (Vertex){ x0,y1, au0,av1, fr,fg,fb,1 };
            }
            if (ig > 0) {
                glEnable(GL_BLEND);
                glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
                glUseProgram(g_text_prog);
                glUniform2f(g_vp_loc_text, viewport[0], viewport[1]);
                glBindTexture(GL_TEXTURE_2D, g_gc.texture);
                glUniform1i(g_tex_loc, 0);
                glBufferData(GL_ARRAY_BUFFER, sizeof(Vertex) * ig,
                             imeTextVerts, GL_DYNAMIC_DRAW);
                setupVertexAttribs();
                glDrawArrays(GL_TRIANGLES, 0, ig);
                glDisable(GL_BLEND);
            }
        }
    }

    // Search bar overlay
    if (g_search_active) {
        char queryCopy[ATTYX_SEARCH_QUERY_MAX + 1];
        int qLen = g_search_query_len;
        if (qLen > ATTYX_SEARCH_QUERY_MAX) qLen = ATTYX_SEARCH_QUERY_MAX;
        memcpy(queryCopy, g_search_query, qLen);
        queryCopy[qLen] = '\0';

        char countLabel[64];
        int sTotal = g_search_total;
        int sCurrent = g_search_current;
        int countLen = 0;
        if (sTotal > 0) {
            countLen = snprintf(countLabel, sizeof(countLabel), "%d of %d", sCurrent + 1, sTotal);
        } else if (qLen > 0) {
            countLen = snprintf(countLabel, sizeof(countLabel), "no results");
        }

        float barH = gh + 12.0f;
        float totalW = cols * gw;
        float padX = gw * 0.5f;
        float textY = (barH - gh) / 2.0f;

        float labelChars = 5;
        float inputX = padX + (labelChars + 1) * gw;
        float inputPad = gw * 0.4f;
        float inputInner = fmaxf(20 * gw, (qLen + 2) * gw);
        float inputW = inputPad * 2 + inputInner;
        if (inputX + inputW > totalW * 0.55f)
            inputW = totalW * 0.55f - inputX;
        float inputH = gh + 4.0f;
        float inputY = (barH - inputH) / 2.0f;

        float rx = totalW - padX;
        float closeX = rx - gw;
        float downCx = closeX - gw * 1.3f;
        float upCx = downCx - gw * 1.3f;
        float countX = upCx - gw * 0.5f - countLen * gw;

        // --- Solid pass: bar bg + input field bg + arrows ---
        Vertex sBg[6 + 6 + 3 + 3];
        int si = 0;

        si = emitRect(sBg, si, 0, 0, totalW, barH,
                      0.10f, 0.10f, 0.13f, 0.95f);
        si = emitRect(sBg, si, inputX, inputY, inputW, inputH,
                      0.18f, 0.18f, 0.22f, 1.0f);

        float aw2 = gw * 0.40f, ah2 = gh * 0.40f;
        float acy = barH / 2.0f;
        si = emitTri(sBg, si,
                     upCx,          acy - ah2/2,
                     upCx - aw2/2,  acy + ah2/2,
                     upCx + aw2/2,  acy + ah2/2,
                     0.50f, 0.55f, 0.65f, 1.0f);
        si = emitTri(sBg, si,
                     downCx,          acy + ah2/2,
                     downCx - aw2/2,  acy - ah2/2,
                     downCx + aw2/2,  acy - ah2/2,
                     0.50f, 0.55f, 0.65f, 1.0f);

        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glUseProgram(g_solid_prog);
        glUniform2f(g_vp_loc_solid, viewport[0], viewport[1]);
        glBufferData(GL_ARRAY_BUFFER, sizeof(Vertex) * si, sBg, GL_DYNAMIC_DRAW);
        setupVertexAttribs();
        glDrawArrays(GL_TRIANGLES, 0, si);
        glDisable(GL_BLEND);

        // --- Text pass: label + query + cursor + count + close ---
        Vertex stv[512 * 6];
        int sti = 0;

        sti = emitString(stv, sti, &g_gc, "Find:", 5,
                         padX, textY, gw, gh, 0.40f, 0.50f, 0.65f);

        float qx = inputX + inputPad;
        sti = emitString(stv, sti, &g_gc, queryCopy, qLen,
                         qx, textY, gw, gh, 0.92f, 0.92f, 0.92f);

        // Blinking cursor bar
        {
            double now = glfwGetTime();
            int phase = ((int)(now / 0.5)) % 2;
            if (phase == 0) {
                float cx = qx + qLen * gw;
                sti = emitRect(stv, sti, cx, textY, 2.0f, gh,
                               0.45f, 0.65f, 1.0f, 1.0f);
            }
        }

        if (countLen > 0) {
            float cr = (sTotal > 0) ? 0.50f : 0.60f;
            float cg = (sTotal > 0) ? 0.50f : 0.30f;
            float cb = (sTotal > 0) ? 0.55f : 0.30f;
            sti = emitString(stv, sti, &g_gc, countLabel, countLen,
                             countX, textY, gw, gh, cr, cg, cb);
        }

        sti = emitGlyph(stv, sti, &g_gc, 'x',
                        closeX, textY, gw, gh, 0.50f, 0.50f, 0.55f);

        if (sti > 0) {
            glEnable(GL_BLEND);
            glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
            glUseProgram(g_text_prog);
            glUniform2f(g_vp_loc_text, viewport[0], viewport[1]);
            glBindTexture(GL_TEXTURE_2D, g_gc.texture);
            glUniform1i(g_tex_loc, 0);
            glBufferData(GL_ARRAY_BUFFER, sizeof(Vertex) * sti,
                         stv, GL_DYNAMIC_DRAW);
            setupVertexAttribs();
            glDrawArrays(GL_TRIANGLES, 0, sti);
            glDisable(GL_BLEND);
        }
    }

    glBindVertexArray(0);
}

// ---------------------------------------------------------------------------
// Keyboard handling
// ---------------------------------------------------------------------------

static int g_suppress_char = 0;

static void snapViewport(void) {
    if (g_viewport_offset != 0) {
        g_viewport_offset = 0;
        attyx_mark_all_dirty();
    }
    if (g_sel_active) {
        g_sel_active = 0;
        attyx_mark_all_dirty();
    }
}

static void keyCallback(GLFWwindow* w, int key, int scancode, int action, int mods) {
    (void)w; (void)scancode;
    if (action == GLFW_RELEASE) return;
    g_suppress_char = 0;

    int ctrl  = (mods & GLFW_MOD_CONTROL) != 0;
    int alt   = (mods & GLFW_MOD_ALT) != 0;
    int shift = (mods & GLFW_MOD_SHIFT) != 0;

    // Ctrl+F toggles search
    if (ctrl && key == GLFW_KEY_F) {
        if (g_search_active) {
            g_search_active = 0;
            g_search_query_len = 0;
            g_search_gen++;
            attyx_mark_all_dirty();
        } else {
            g_search_active = 1;
            g_search_query_len = 0;
            g_search_gen++;
            attyx_mark_all_dirty();
        }
        g_suppress_char = 1;
        return;
    }

    // Ctrl+G / Shift+Ctrl+G — find next/prev (works whenever search is active)
    if (ctrl && key == GLFW_KEY_G && g_search_active) {
        if (shift) {
            __sync_fetch_and_add((volatile int*)&g_search_nav_delta, -1);
        } else {
            __sync_fetch_and_add((volatile int*)&g_search_nav_delta, 1);
        }
        attyx_mark_all_dirty();
        g_suppress_char = 1;
        return;
    }

    // When search bar is open, route keys to search input
    if (g_search_active) {
        if (key == GLFW_KEY_ESCAPE) {
            g_search_active = 0;
            g_search_query_len = 0;
            g_search_gen++;
            attyx_mark_all_dirty();
            g_suppress_char = 1;
            return;
        }
        if (key == GLFW_KEY_ENTER) {
            if (shift) {
                __sync_fetch_and_add((volatile int*)&g_search_nav_delta, -1);
            } else {
                __sync_fetch_and_add((volatile int*)&g_search_nav_delta, 1);
            }
            attyx_mark_all_dirty();
            g_suppress_char = 1;
            return;
        }
        if (key == GLFW_KEY_BACKSPACE) {
            if (g_search_query_len > 0) {
                g_search_query_len--;
                g_search_gen++;
                attyx_mark_all_dirty();
            }
            g_suppress_char = 1;
            return;
        }
        // Swallow other special keys in search mode
        g_suppress_char = 0; // let charCallback handle printable chars
        return;
    }

    // Ctrl+Shift+C/V for copy/paste
    if (ctrl && shift && key == GLFW_KEY_V) {
        const char* text = glfwGetClipboardString(g_window);
        if (text && *text) {
            int len = (int)strlen(text);
            if (g_bracketed_paste) {
                attyx_send_input((const uint8_t*)"\x1b[200~", 6);
                attyx_send_input((const uint8_t*)text, len);
                attyx_send_input((const uint8_t*)"\x1b[201~", 6);
            } else {
                attyx_send_input((const uint8_t*)text, len);
            }
        }
        g_suppress_char = 1;
        return;
    }
    if (ctrl && shift && key == GLFW_KEY_C) {
        // Copy — implemented below
        extern void doCopy(void);
        doCopy();
        g_suppress_char = 1;
        return;
    }

    snapViewport();

    // Shift+PageUp/Down/Home/End for scrollback
    if (shift && !g_mouse_tracking && !g_alt_screen) {
        if (key == GLFW_KEY_PAGE_UP)   { attyx_scroll_viewport(g_rows); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_PAGE_DOWN) { attyx_scroll_viewport(-g_rows); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_HOME)      { g_viewport_offset = g_scrollback_count; attyx_mark_all_dirty(); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_END)       { g_viewport_offset = 0; attyx_mark_all_dirty(); g_suppress_char = 1; return; }
    }

    // Arrow keys (DECCKM-aware)
    int appMode = (g_cursor_keys_app != 0);
    switch (key) {
        case GLFW_KEY_UP:    attyx_send_input((const uint8_t*)(appMode ? "\x1bOA" : "\x1b[A"), 3); g_suppress_char = 1; return;
        case GLFW_KEY_DOWN:  attyx_send_input((const uint8_t*)(appMode ? "\x1bOB" : "\x1b[B"), 3); g_suppress_char = 1; return;
        case GLFW_KEY_RIGHT: attyx_send_input((const uint8_t*)(appMode ? "\x1bOC" : "\x1b[C"), 3); g_suppress_char = 1; return;
        case GLFW_KEY_LEFT:  attyx_send_input((const uint8_t*)(appMode ? "\x1bOD" : "\x1b[D"), 3); g_suppress_char = 1; return;
        case GLFW_KEY_ENTER:     attyx_send_input((const uint8_t*)"\r", 1); g_suppress_char = 1; return;
        case GLFW_KEY_BACKSPACE: attyx_send_input((const uint8_t*)"\x7f", 1); g_suppress_char = 1; return;
        case GLFW_KEY_TAB:       attyx_send_input((const uint8_t*)"\t", 1); g_suppress_char = 1; return;
        case GLFW_KEY_ESCAPE:    attyx_send_input((const uint8_t*)"\x1b", 1); g_suppress_char = 1; return;
        case GLFW_KEY_HOME:      attyx_send_input((const uint8_t*)"\x1b[H", 3); g_suppress_char = 1; return;
        case GLFW_KEY_END:       attyx_send_input((const uint8_t*)"\x1b[F", 3); g_suppress_char = 1; return;
        case GLFW_KEY_PAGE_UP:   attyx_send_input((const uint8_t*)"\x1b[5~", 4); g_suppress_char = 1; return;
        case GLFW_KEY_PAGE_DOWN: attyx_send_input((const uint8_t*)"\x1b[6~", 4); g_suppress_char = 1; return;
        case GLFW_KEY_DELETE:    attyx_send_input((const uint8_t*)"\x1b[3~", 4); g_suppress_char = 1; return;
        case GLFW_KEY_INSERT:    attyx_send_input((const uint8_t*)"\x1b[2~", 4); g_suppress_char = 1; return;
        case GLFW_KEY_F1:  attyx_send_input((const uint8_t*)"\x1bOP",   3); g_suppress_char = 1; return;
        case GLFW_KEY_F2:  attyx_send_input((const uint8_t*)"\x1bOQ",   3); g_suppress_char = 1; return;
        case GLFW_KEY_F3:  attyx_send_input((const uint8_t*)"\x1bOR",   3); g_suppress_char = 1; return;
        case GLFW_KEY_F4:  attyx_send_input((const uint8_t*)"\x1bOS",   3); g_suppress_char = 1; return;
        case GLFW_KEY_F5:  attyx_send_input((const uint8_t*)"\x1b[15~", 5); g_suppress_char = 1; return;
        case GLFW_KEY_F6:  attyx_send_input((const uint8_t*)"\x1b[17~", 5); g_suppress_char = 1; return;
        case GLFW_KEY_F7:  attyx_send_input((const uint8_t*)"\x1b[18~", 5); g_suppress_char = 1; return;
        case GLFW_KEY_F8:  attyx_send_input((const uint8_t*)"\x1b[19~", 5); g_suppress_char = 1; return;
        case GLFW_KEY_F9:  attyx_send_input((const uint8_t*)"\x1b[20~", 5); g_suppress_char = 1; return;
        case GLFW_KEY_F10: attyx_send_input((const uint8_t*)"\x1b[21~", 5); g_suppress_char = 1; return;
        case GLFW_KEY_F11: attyx_send_input((const uint8_t*)"\x1b[23~", 5); g_suppress_char = 1; return;
        case GLFW_KEY_F12: attyx_send_input((const uint8_t*)"\x1b[24~", 5); g_suppress_char = 1; return;
        default: break;
    }

    // Ctrl+key → control codes
    if (ctrl && !alt && !shift) {
        if (key >= GLFW_KEY_A && key <= GLFW_KEY_Z) {
            uint8_t b = (uint8_t)(key - GLFW_KEY_A + 1);
            attyx_send_input(&b, 1);
            g_suppress_char = 1;
            return;
        }
        if (key == GLFW_KEY_LEFT_BRACKET)  { attyx_send_input((const uint8_t*)"\x1b", 1); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_RIGHT_BRACKET) { uint8_t b = 0x1d; attyx_send_input(&b, 1); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_BACKSLASH)     { uint8_t b = 0x1c; attyx_send_input(&b, 1); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_SPACE)         { uint8_t b = 0x00; attyx_send_input(&b, 1); g_suppress_char = 1; return; }
        g_suppress_char = 1;
        return;
    }

    // Alt+key → ESC prefix (handled via char callback — we just flag alt)
    if (alt && !ctrl) {
        // Let the char callback handle it; we'll detect alt there
        // For keys that don't produce a char event, send ESC + key name
        if (key >= GLFW_KEY_A && key <= GLFW_KEY_Z) {
            uint8_t esc = 0x1b;
            attyx_send_input(&esc, 1);
            uint8_t ch = (uint8_t)('a' + (key - GLFW_KEY_A));
            if (shift) ch = (uint8_t)(ch - 32);
            attyx_send_input(&ch, 1);
            g_suppress_char = 1;
            return;
        }
    }
}

static void charCallback(GLFWwindow* w, unsigned int codepoint) {
    (void)w;
    if (g_suppress_char) { g_suppress_char = 0; return; }

    // When search bar is open, route printable chars into search query
    if (g_search_active) {
        if (codepoint >= 32 && codepoint < 127) {
            if (g_search_query_len < ATTYX_SEARCH_QUERY_MAX - 1) {
                g_search_query[g_search_query_len++] = (char)codepoint;
                g_search_gen++;
                attyx_mark_all_dirty();
            }
        }
        return;
    }

    snapViewport();

    uint8_t buf[4];
    int len = utf8Encode(codepoint, buf);
    if (len > 0) attyx_send_input(buf, len);
}

// ---------------------------------------------------------------------------
// Mouse handling
// ---------------------------------------------------------------------------

static double g_last_click_time = 0;
static int g_last_click_col = -1, g_last_click_row = -1;
static int g_click_count = 0;
static int g_selecting = 0;
static int g_left_down = 0;

static inline int clampInt(int val, int lo, int hi) {
    if (val < lo) return lo;
    if (val > hi) return hi;
    return val;
}

static void mouseToCell(double mx, double my, int* outCol, int* outRow) {
    float cellW = g_cell_px_w / g_content_scale;
    float cellH = g_cell_px_h / g_content_scale;
    *outCol = clampInt((int)(mx / cellW), 0, g_cols - 1);
    *outRow = clampInt((int)(my / cellH), 0, g_rows - 1);
}

static void mouseToCell1(double mx, double my, int* outCol, int* outRow) {
    float cellW = g_cell_px_w / g_content_scale;
    float cellH = g_cell_px_h / g_content_scale;
    *outCol = clampInt((int)(mx / cellW) + 1, 1, g_cols);
    *outRow = clampInt((int)(my / cellH) + 1, 1, g_rows);
}

static void sendSgrMouse(int button, int col, int row, int press) {
    char buf[32];
    int len = snprintf(buf, sizeof(buf), "\x1b[<%d;%d;%d%c",
                       button, col, row, press ? 'M' : 'm');
    attyx_send_input((const uint8_t*)buf, len);
}

static int mouseModifiers(int mods) {
    int m = 0;
    if (mods & GLFW_MOD_SHIFT)   m |= 4;
    if (mods & GLFW_MOD_ALT)     m |= 8;
    if (mods & GLFW_MOD_CONTROL) m |= 16;
    return m;
}

static void mouseButtonCallback(GLFWwindow* w, int button, int action, int mods) {
    double mx, my;
    glfwGetCursorPos(w, &mx, &my);

    if (button == GLFW_MOUSE_BUTTON_LEFT) {
        if (action == GLFW_PRESS) {
            if (g_mouse_tracking && g_mouse_sgr) {
                int col, row;
                mouseToCell1(mx, my, &col, &row);
                sendSgrMouse(0 | mouseModifiers(mods), col, row, 1);
                g_left_down = 1;
                return;
            }
            int col, row;
            mouseToCell(mx, my, &col, &row);

            // Ctrl+click opens hyperlink
            if (mods & GLFW_MOD_CONTROL) {
                int cols = g_cols, nrows = g_rows;
                if (g_cells && col >= 0 && col < cols && row >= 0 && row < nrows) {
                    // OSC 8 link takes priority
                    uint32_t lid = g_cells[row * cols + col].link_id;
                    if (lid != 0) {
                        char uri_buf[2048];
                        int uri_len = attyx_get_link_uri(lid, uri_buf, sizeof(uri_buf));
                        if (uri_len > 0) {
                            char cmd[2200];
                            snprintf(cmd, sizeof(cmd), "xdg-open '%s' &", uri_buf);
                            (void)system(cmd);
                        }
                        g_left_down = 1;
                        return;
                    }

                    // Fallback: regex-detected URL
                    int dStart, dEnd;
                    char dUrl[DETECTED_URL_MAX];
                    int dLen = 0;
                    if (detectUrlAtCell(row, col, cols, &dStart, &dEnd, dUrl, DETECTED_URL_MAX, &dLen) && dLen > 0) {
                        char cmd[2200];
                        snprintf(cmd, sizeof(cmd), "xdg-open '%s' &", dUrl);
                        (void)system(cmd);
                        g_left_down = 1;
                        return;
                    }
                }
            }

            double now = glfwGetTime();
            if (now - g_last_click_time < 0.35 && col == g_last_click_col && row == g_last_click_row)
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
                findWordBounds(row, col, g_cols, &wS, &wE);
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
        } else {
            g_left_down = 0;
            if (g_mouse_tracking && g_mouse_sgr) {
                int col, row;
                mouseToCell1(mx, my, &col, &row);
                sendSgrMouse(0 | mouseModifiers(mods), col, row, 0);
                return;
            }
            if (g_selecting) {
                g_selecting = 0;
                if (g_sel_start_row != g_sel_end_row || g_sel_start_col != g_sel_end_col)
                    g_sel_active = 1;
                else if (g_click_count < 2)
                    g_sel_active = 0;
            }
        }
    } else if (button == GLFW_MOUSE_BUTTON_RIGHT) {
        if (!g_mouse_tracking || !g_mouse_sgr) return;
        int col, row;
        mouseToCell1(mx, my, &col, &row);
        sendSgrMouse((2 | mouseModifiers(mods)), col, row, action == GLFW_PRESS);
    } else if (button == GLFW_MOUSE_BUTTON_MIDDLE) {
        if (!g_mouse_tracking || !g_mouse_sgr) return;
        int col, row;
        mouseToCell1(mx, my, &col, &row);
        sendSgrMouse((1 | mouseModifiers(mods)), col, row, action == GLFW_PRESS);
    }
}

static int g_last_motion_col = -1, g_last_motion_row = -1;

static void cursorPosCallback(GLFWwindow* w, double mx, double my) {
    (void)w;
    if (g_left_down && g_mouse_tracking && g_mouse_sgr) {
        if (g_mouse_tracking < 2) return;
        int col, row;
        mouseToCell1(mx, my, &col, &row);
        if (col == g_last_motion_col && row == g_last_motion_row) return;
        sendSgrMouse(32, col, row, 1);
        g_last_motion_col = col;
        g_last_motion_row = row;
        return;
    }
    if (!g_left_down && g_mouse_tracking == 3 && g_mouse_sgr) {
        int col, row;
        mouseToCell1(mx, my, &col, &row);
        if (col == g_last_motion_col && row == g_last_motion_row) return;
        sendSgrMouse(35, col, row, 1);
        g_last_motion_col = col;
        g_last_motion_row = row;
        return;
    }
    if (g_selecting && g_left_down) {
        int col, row;
        mouseToCell(mx, my, &col, &row);
        if (col == g_sel_end_col && row == g_sel_end_row) return;

        if (g_click_count >= 3) {
            g_sel_end_row = row;
            g_sel_end_col = (row >= g_sel_start_row) ? g_cols - 1 : 0;
            if (row < g_sel_start_row) g_sel_start_col = g_cols - 1;
            else g_sel_start_col = 0;
        } else if (g_click_count == 2) {
            int wS, wE;
            findWordBounds(row, col, g_cols, &wS, &wE);
            g_sel_end_row = row;
            if (row > g_sel_start_row || (row == g_sel_start_row && col >= g_sel_start_col))
                g_sel_end_col = wE;
            else
                g_sel_end_col = wS;
        } else {
            g_sel_end_row = row;
            g_sel_end_col = col;
        }
        g_sel_active = 1;
        attyx_mark_all_dirty();
        return;
    }

    // Hyperlink hover detection (when mouse mode is off)
    if (!g_mouse_tracking && !g_left_down) {
        int col, row;
        mouseToCell(mx, my, &col, &row);
        int cols = g_cols, nrows = g_rows;

        // OSC 8 link check
        uint32_t lid = 0;
        if (g_cells && col >= 0 && col < cols && row >= 0 && row < nrows)
            lid = g_cells[row * cols + col].link_id;

        // Regex URL detection fallback
        int detStart = -1, detEnd = -1;
        char detUrlBuf[DETECTED_URL_MAX];
        int detUrlLen = 0;
        int hasDetected = 0;
        if (lid == 0 && g_cells && col >= 0 && col < cols && row >= 0 && row < nrows) {
            hasDetected = detectUrlAtCell(row, col, cols,
                                          &detStart, &detEnd,
                                          detUrlBuf, DETECTED_URL_MAX, &detUrlLen);
        }

        int isLink = (lid != 0 || hasDetected);
        int prevOscRow = g_hover_row;
        int prevDetRow = g_detected_url_row;
        uint32_t prevLid = g_hover_link_id;

        int oscChanged = (lid != prevLid);
        int detChanged = 0;
        if (hasDetected) {
            detChanged = (row != prevDetRow || detStart != g_detected_url_start_col || detEnd != g_detected_url_end_col);
        } else if (g_detected_url_len > 0) {
            detChanged = 1;
        }

        if (oscChanged || detChanged) {
            g_hover_link_id = lid;
            g_hover_row = (lid != 0) ? row : -1;

            if (hasDetected) {
                memcpy(g_detected_url, detUrlBuf, detUrlLen + 1);
                g_detected_url_len = detUrlLen;
                g_detected_url_row = row;
                g_detected_url_start_col = detStart;
                g_detected_url_end_col = detEnd;
            } else {
                g_detected_url_len = 0;
                g_detected_url_row = -1;
            }

            if (isLink)
                glfwSetCursor(w, glfwCreateStandardCursor(GLFW_HAND_CURSOR));
            else
                glfwSetCursor(w, glfwCreateStandardCursor(GLFW_IBEAM_CURSOR));

            if (prevOscRow >= 0 && prevOscRow < 256)
                __sync_fetch_and_or((volatile uint64_t*)&g_dirty[prevOscRow >> 6], (uint64_t)1 << (prevOscRow & 63));
            if (prevDetRow >= 0 && prevDetRow < 256)
                __sync_fetch_and_or((volatile uint64_t*)&g_dirty[prevDetRow >> 6], (uint64_t)1 << (prevDetRow & 63));
            if (row >= 0 && row < 256 && isLink)
                __sync_fetch_and_or((volatile uint64_t*)&g_dirty[row >> 6], (uint64_t)1 << (row & 63));
        }
    }
}

static void scrollCallback(GLFWwindow* w, double xoff, double yoff) {
    (void)xoff;
    if (g_mouse_tracking && g_mouse_sgr) {
        if (yoff == 0) return;
        double mx, my;
        glfwGetCursorPos(w, &mx, &my);
        int col, row;
        mouseToCell1(mx, my, &col, &row);
        int btn = (yoff > 0 ? 64 : 65);
        sendSgrMouse(btn, col, row, 1);
        return;
    }
    if (g_alt_screen) return;
    int lines = (int)yoff;
    if (lines == 0) lines = (yoff > 0) ? 1 : -1;
    attyx_scroll_viewport(lines);
    if (g_sel_active) { g_sel_active = 0; attyx_mark_all_dirty(); }
}

// ---------------------------------------------------------------------------
// Copy to clipboard
// ---------------------------------------------------------------------------

void doCopy(void) {
    if (!g_sel_active || !g_window) return;

    int sr = g_sel_start_row, sc = g_sel_start_col;
    int er = g_sel_end_row, ec = g_sel_end_col;
    if (sr > er || (sr == er && sc > ec)) {
        int tr = sr, tc = sc; sr = er; sc = ec; er = tr; ec = tc;
    }

    int cols = g_cols, rows = g_rows;
    if (cols <= 0 || rows <= 0) return;

    uint64_t gen;
    do { gen = g_cell_gen; } while (gen & 1);

    int maxlen = (er - sr + 1) * (cols * 4 + 1) + 1;
    char* buf = (char*)malloc(maxlen);
    if (!buf) return;
    int pos = 0;

    for (int row = sr; row <= er && row < rows; row++) {
        int cStart = (row == sr) ? sc : 0;
        int cEnd = (row == er) ? ec : cols - 1;
        if (cStart >= cols) cStart = cols - 1;
        if (cEnd >= cols) cEnd = cols - 1;

        int lastNonSpace = cStart - 1;
        for (int c = cEnd; c >= cStart; c--) {
            uint32_t ch = g_cells[row * cols + c].character;
            if (ch > 32) { lastNonSpace = c; break; }
        }

        for (int c = cStart; c <= lastNonSpace; c++) {
            uint32_t ch = g_cells[row * cols + c].character;
            if (ch == 0 || ch == ' ') {
                buf[pos++] = ' ';
            } else {
                uint8_t utf8[4];
                int n = utf8Encode(ch, utf8);
                memcpy(buf + pos, utf8, n);
                pos += n;
            }
        }
        if (row < er) buf[pos++] = '\n';
    }

    buf[pos] = '\0';
    if (pos > 0) glfwSetClipboardString(g_window, buf);
    free(buf);
}

// ---------------------------------------------------------------------------
// Framebuffer resize callback
// ---------------------------------------------------------------------------

static void framebufferSizeCallback(GLFWwindow* w, int width, int height) {
    (void)w;
    if (g_cell_px_w <= 0 || g_cell_px_h <= 0) return;
    int new_cols = (int)(width / g_cell_px_w + 0.01f);
    int new_rows = (int)(height / g_cell_px_h + 0.01f);
    if (new_cols < 1) new_cols = 1;
    if (new_rows < 1) new_rows = 1;
    if (new_cols > ATTYX_MAX_COLS) new_cols = ATTYX_MAX_COLS;
    if (new_rows > ATTYX_MAX_ROWS) new_rows = ATTYX_MAX_ROWS;
    g_pending_resize_rows = new_rows;
    g_pending_resize_cols = new_cols;
    g_full_redraw = 1;
}

// ---------------------------------------------------------------------------
// GLFW error callback
// ---------------------------------------------------------------------------

static void errorCallback(int error, const char* description) {
    fprintf(stderr, "[attyx] GLFW error %d: %s\n", error, description);
}

// ---------------------------------------------------------------------------
// C entry point called from Zig
// ---------------------------------------------------------------------------

void attyx_run(AttyxCell* cells, int cols, int rows) {
    g_cells = cells;
    g_cols  = cols;
    g_rows  = rows;

    glfwSetErrorCallback(errorCallback);
    if (!glfwInit()) {
        fprintf(stderr, "[attyx] failed to initialize GLFW\n");
        return;
    }

    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 3);
    glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);

    // Get content scale for HiDPI
    GLFWmonitor* primary = glfwGetPrimaryMonitor();
    float xscale = 1.0f, yscale = 1.0f;
    if (primary) glfwGetMonitorContentScale(primary, &xscale, &yscale);
    g_content_scale = xscale;

    // Initialize FreeType
    FT_Library ft_lib;
    if (FT_Init_FreeType(&ft_lib) != 0) {
        fprintf(stderr, "[attyx] FreeType init failed\n");
        glfwTerminate();
        return;
    }

    // Create temporary context to initialize GL (needed for glyph cache texture)
    GLFWwindow* tmpWin = glfwCreateWindow(1, 1, "", NULL, NULL);
    glfwMakeContextCurrent(tmpWin);

    // Create glyph cache (needs GL context for texture creation)
    g_gc = createGlyphCache(ft_lib, xscale);
    g_cell_px_w = g_gc.glyph_w;
    g_cell_px_h = g_gc.glyph_h;

    glfwDestroyWindow(tmpWin);

    // Create the real window
    int winW = (int)(cols * g_cell_px_w / xscale);
    int winH = (int)(rows * g_cell_px_h / yscale);

    g_window = glfwCreateWindow(winW, winH, "Attyx", NULL, NULL);
    if (!g_window) {
        fprintf(stderr, "[attyx] failed to create window\n");
        FT_Done_Face(g_gc.ft_face);
        FT_Done_FreeType(ft_lib);
        glfwTerminate();
        return;
    }

    glfwMakeContextCurrent(g_window);
    glfwSwapInterval(1);

    // Re-create glyph cache texture in the new context
    GLuint tex;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);

    // Read atlas from old texture (in old context — already destroyed!)
    // Instead, re-rasterize all cached glyphs in the new context.
    {
        int oldAtlasW = g_gc.atlas_w, oldAtlasH = g_gc.atlas_h;
        uint8_t* zeroes = (uint8_t*)calloc(oldAtlasW * oldAtlasH, 1);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, oldAtlasW, oldAtlasH, 0,
                     GL_RED, GL_UNSIGNED_BYTE, zeroes);
        free(zeroes);
        g_gc.texture = tex;
        g_gc.next_slot = 0;
        for (int i = 0; i < GLYPH_CACHE_CAP; i++) g_gc.map[i].slot = -1;
        for (uint32_t ch = 32; ch < 127; ch++)
            glyphCacheRasterize(&g_gc, ch);
    }

    // Create shader programs
    g_solid_prog = createProgram(kVertSrc, kFragSolidSrc);
    g_text_prog  = createProgram(kVertSrc, kFragTextSrc);
    g_vp_loc_solid = glGetUniformLocation(g_solid_prog, "viewport");
    g_vp_loc_text  = glGetUniformLocation(g_text_prog, "viewport");
    g_tex_loc      = glGetUniformLocation(g_text_prog, "tex");

    // Create VAO + VBO
    glGenVertexArrays(1, &g_vao);
    glGenBuffers(1, &g_vbo);

    // Set GLFW callbacks
    glfwSetFramebufferSizeCallback(g_window, framebufferSizeCallback);
    glfwSetKeyCallback(g_window, keyCallback);
    glfwSetCharCallback(g_window, charCallback);
    glfwSetMouseButtonCallback(g_window, mouseButtonCallback);
    glfwSetCursorPosCallback(g_window, cursorPosCallback);
    glfwSetScrollCallback(g_window, scrollCallback);

    // Main loop
    while (!glfwWindowShouldClose(g_window) && !g_should_quit) {
        glfwPollEvents();
        drawFrame();
        glfwSwapBuffers(g_window);
    }

    g_should_quit = 1;

    // Cleanup
    free(g_bg_verts);
    free(g_text_verts);
    free(g_cell_snapshot);
    glDeleteBuffers(1, &g_vbo);
    glDeleteVertexArrays(1, &g_vao);
    glDeleteProgram(g_solid_prog);
    glDeleteProgram(g_text_prog);
    glDeleteTextures(1, &g_gc.texture);
    FT_Done_Face(g_gc.ft_face);
    FT_Done_FreeType(ft_lib);
    glfwDestroyWindow(g_window);
    glfwTerminate();
}
