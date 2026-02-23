// Attyx — macOS platform layer (Cocoa + Metal + Core Text)
// Renders a live terminal grid and handles keyboard input.

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <CoreText/CoreText.h>
#import <Carbon/Carbon.h>  // kVK_* virtual key codes
#import <QuartzCore/CABase.h>

#include "bridge.h"

// ---------------------------------------------------------------------------
// Shared state (written by Zig PTY thread, read by renderer on main thread)
// ---------------------------------------------------------------------------

static AttyxCell* g_cells = NULL;
static int g_cols = 0;
static int g_rows = 0;
// Seqlock generation: odd = PTY thread is mid-update, even = safe to read.
static volatile uint64_t g_cell_gen = 0;
static volatile int g_cursor_row = 0;
static volatile int g_cursor_col = 0;
static volatile int g_should_quit = 0;

// Mode flags (written by PTY thread, read by key handler on main thread)
static volatile int g_bracketed_paste = 0;
static volatile int g_cursor_keys_app = 0;

// Mouse mode flags (written by PTY thread, read by mouse handlers on main thread)
// tracking: 0=off, 1=x10, 2=button_event, 3=any_event
static volatile int g_mouse_tracking = 0;
static volatile int g_mouse_sgr = 0;

// Viewport / scrollback (read + written by both threads via volatile)
volatile int g_viewport_offset = 0;
volatile int g_scrollback_count = 0;
volatile int g_alt_screen = 0;

// Selection (viewport-relative, 0-indexed; -1 = no selection)
volatile int g_sel_start_row = -1, g_sel_start_col = -1;
volatile int g_sel_end_row = -1, g_sel_end_col = -1;
volatile int g_sel_active = 0;

// Cursor shape and visibility
volatile int g_cursor_shape   = 0;
volatile int g_cursor_visible = 1;

// Window title
char         g_title_buf[ATTYX_TITLE_MAX];
volatile int g_title_len     = 0;
volatile int g_title_changed = 0;

// IME composition state
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
volatile int g_cell_width      = -100;
volatile int g_cell_height     = -100;

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

// Hyperlink hover state (written by mouse-move handler, read by renderer).
static volatile uint32_t g_hover_link_id = 0;
static volatile int g_hover_row = -1;

// Regex-detected URL hover state (for plain-text URLs without OSC 8).
#define DETECTED_URL_MAX 2048
static char g_detected_url[DETECTED_URL_MAX];
static volatile int g_detected_url_len = 0;
static volatile int g_detected_url_row = -1;
static volatile int g_detected_url_start_col = 0;
static volatile int g_detected_url_end_col = 0;

// Row-level dirty bitset (256 rows). PTY thread atomic-ORs in dirty bits;
// renderer atomically swaps each word to zero when snapshotting.
static volatile uint64_t g_dirty[4] = {0,0,0,0};

// Pending resize: set by renderer on drawableSizeWillChange, consumed by PTY thread.
static volatile int g_pending_resize_rows = 0;
static volatile int g_pending_resize_cols = 0;

// Cell dimensions in points (set once at glyph cache creation, used for window snapping).
static CGFloat g_cell_pt_w = 0;
static CGFloat g_cell_pt_h = 0;

void attyx_set_cursor(int row, int col) {
    g_cursor_row = row;
    g_cursor_col = col;
}

void attyx_request_quit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp terminate:nil];
    });
}

int attyx_should_quit(void) {
    return g_should_quit;
}

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
    __sync_fetch_and_add(&g_cell_gen, 1); // gen becomes odd → "updating"
}

void attyx_end_cell_update(void) {
    __sync_fetch_and_add(&g_cell_gen, 1); // gen becomes even → "ready"
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
// Metal shader source (compiled at runtime for build simplicity)
// ---------------------------------------------------------------------------

static NSString* const kShaderSource =
@"#include <metal_stdlib>\n"
 "using namespace metal;\n"
 "\n"
 "struct Vertex {\n"
 "    packed_float2 position;\n"
 "    packed_float2 texcoord;\n"
 "    packed_float4 color;\n"
 "};\n"
 "\n"
 "struct VertexOut {\n"
 "    float4 position [[position]];\n"
 "    float2 texcoord;\n"
 "    float4 color;\n"
 "};\n"
 "\n"
 "vertex VertexOut vert_main(\n"
 "    const device Vertex* vertices [[buffer(0)]],\n"
 "    constant float2& viewport [[buffer(1)]],\n"
 "    uint vid [[vertex_id]])\n"
 "{\n"
 "    VertexOut out;\n"
 "    float2 pos = vertices[vid].position / viewport * 2.0 - 1.0;\n"
 "    pos.y = -pos.y;\n"
 "    out.position = float4(pos, 0.0, 1.0);\n"
 "    out.texcoord = vertices[vid].texcoord;\n"
 "    out.color = vertices[vid].color;\n"
 "    return out;\n"
 "}\n"
 "\n"
 "fragment float4 frag_solid(VertexOut in [[stage_in]]) {\n"
 "    return in.color;\n"
 "}\n"
 "\n"
 "fragment float4 frag_text(\n"
 "    VertexOut in [[stage_in]],\n"
 "    texture2d<float> tex [[texture(0)]])\n"
 "{\n"
 "    constexpr sampler s(filter::linear);\n"
 "    float a = tex.sample(s, in.texcoord).r;\n"
 "    return float4(in.color.rgb, in.color.a * a);\n"
 "}\n";

// ---------------------------------------------------------------------------
// Vertex layout (matches shader struct)
// ---------------------------------------------------------------------------

typedef struct __attribute__((packed)) {
    float px, py;
    float u, v;
    float r, g, b, a;
} Vertex;

// ---------------------------------------------------------------------------
// Dynamic glyph cache — rasterised with Core Text on demand
// ---------------------------------------------------------------------------

#define GLYPH_CACHE_CAP 4096

typedef struct {
    uint32_t codepoint;
    int slot;  // atlas slot index, or -1 if empty
} GlyphEntry;

typedef struct {
    id<MTLTexture> texture;
    CTFontRef      font;       // primary font (retained)
    float          glyph_w;    // glyph cell width in atlas pixels (= points * scale)
    float          glyph_h;    // glyph cell height in atlas pixels
    float          scale;      // backing scale factor
    CGFloat        descent;    // font descent (for glyph positioning)
    int            atlas_cols; // slots per row in the atlas
    int            atlas_w;    // texture width in pixels
    int            atlas_h;    // texture height in pixels
    int            next_slot;  // next free slot index
    int            max_slots;  // current capacity (atlas_cols * atlas_rows)
    id<MTLDevice>  device;     // for atlas growth

    GlyphEntry     map[GLYPH_CACHE_CAP];
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

    MTLTextureDescriptor* desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                           width:gc->atlas_w
                                                          height:newH
                                                       mipmapped:NO];
    id<MTLTexture> newTex = [gc->device newTextureWithDescriptor:desc];

    // Copy old texture content via a CPU-side readback.
    uint8_t* buf = (uint8_t*)calloc(gc->atlas_w * newH, 1);
    [gc->texture getBytes:buf
              bytesPerRow:gc->atlas_w
               fromRegion:MTLRegionMake2D(0, 0, gc->atlas_w, oldH)
              mipmapLevel:0];
    [newTex replaceRegion:MTLRegionMake2D(0, 0, gc->atlas_w, newH)
              mipmapLevel:0
                withBytes:buf
              bytesPerRow:gc->atlas_w];
    free(buf);

    gc->texture = newTex;
    gc->atlas_h = newH;
    gc->max_slots = newMaxSlots;
}

static int glyphCacheRasterize(GlyphCache* gc, uint32_t cp) {
    if (gc->next_slot >= gc->max_slots) {
        glyphCacheGrow(gc);
    }

    int slot = gc->next_slot++;
    int ac = slot % gc->atlas_cols;
    int ar = slot / gc->atlas_cols;
    int gw = (int)gc->glyph_w;
    int gh = (int)gc->glyph_h;

    // Convert codepoint to UTF-16 for Core Text.
    UniChar utf16[2];
    int utf16Len;
    if (cp <= 0xFFFF) {
        utf16[0] = (UniChar)cp;
        utf16Len = 1;
    } else {
        uint32_t u = cp - 0x10000;
        utf16[0] = (UniChar)(0xD800 + (u >> 10));
        utf16[1] = (UniChar)(0xDC00 + (u & 0x3FF));
        utf16Len = 2;
    }

    // Font fallback: try the primary font, fall back via Core Text if needed.
    CTFontRef drawFont = gc->font;
    CGGlyph glyph;
    if (!CTFontGetGlyphsForCharacters(gc->font, utf16, &glyph, utf16Len)) {
        NSString* str = [[NSString alloc] initWithCharacters:utf16 length:utf16Len];
        CTFontRef fallback = CTFontCreateForString(gc->font, (__bridge CFStringRef)str,
                                                    CFRangeMake(0, str.length));
        if (fallback) {
            if (CTFontGetGlyphsForCharacters(fallback, utf16, &glyph, utf16Len)) {
                drawFont = fallback;
            } else {
                CFRelease(fallback);
                glyphCacheInsert(gc, cp, slot);
                return slot;  // empty slot — renders as blank
            }
        } else {
            glyphCacheInsert(gc, cp, slot);
            return slot;
        }
    }

    // Rasterize the single glyph into a temporary bitmap.
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    uint8_t* pixels = (uint8_t*)calloc(gw * gh, 1);
    CGContextRef ctx = CGBitmapContextCreate(pixels, gw, gh, 8, gw, cs, kCGImageAlphaNone);
    CGColorSpaceRelease(cs);

    CGContextSetGrayFillColor(ctx, 1.0, 1.0);
    CGPoint pos = CGPointMake(0, gh - gc->glyph_h + gc->descent);
    CTFontDrawGlyphs(drawFont, &glyph, &pos, 1, ctx);
    CGContextRelease(ctx);

    if (drawFont != gc->font) CFRelease(drawFont);

    // Upload into the atlas texture at the slot's position.
    [gc->texture replaceRegion:MTLRegionMake2D(ac * gw, ar * gh, gw, gh)
                   mipmapLevel:0
                     withBytes:pixels
                   bytesPerRow:gw];
    free(pixels);

    glyphCacheInsert(gc, cp, slot);
    return slot;
}

static GlyphCache createGlyphCache(id<MTLDevice> device, CGFloat scale) {
    // Try user-specified font, then common defaults.
    const char* fontEnv = getenv("ATTYX_FONT");
    CGFloat fontSize = 16.0 * scale;
    CTFontRef font = NULL;

    if (fontEnv && fontEnv[0]) {
        CFStringRef name = CFStringCreateWithCString(NULL, fontEnv, kCFStringEncodingUTF8);
        font = CTFontCreateWithName(name, fontSize, NULL);
        CFRelease(name);
    }
    if (!font) font = CTFontCreateWithName(CFSTR("Menlo-Regular"), fontSize, NULL);
    if (!font) font = CTFontCreateWithName(CFSTR("Monaco"), fontSize, NULL);
    if (!font) font = CTFontCreateWithName(CFSTR("Courier"), fontSize, NULL);

    CGFloat ascent  = CTFontGetAscent(font);
    CGFloat descent = CTFontGetDescent(font);
    CGFloat leading = CTFontGetLeading(font);
    float gh = (float)ceil(ascent + descent + leading);

    UniChar mChar = 'M';
    CGGlyph mGlyph;
    CTFontGetGlyphsForCharacters(font, &mChar, &mGlyph, 1);
    CGSize advance;
    CTFontGetAdvancesForGlyphs(font, kCTFontOrientationDefault, &mGlyph, &advance, 1);
    float gw = (float)ceil(advance.width);

    // Start with a 32x32 slot atlas (1024 slots).
    int cols = 32;
    int initRows = 32;
    int atlasW = (int)(gw * cols);
    int atlasH = (int)(gh * initRows);

    MTLTextureDescriptor* desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                           width:atlasW
                                                          height:atlasH
                                                       mipmapped:NO];
    id<MTLTexture> tex = [device newTextureWithDescriptor:desc];

    // Clear the texture to zero.
    uint8_t* zeroes = (uint8_t*)calloc(atlasW * atlasH, 1);
    [tex replaceRegion:MTLRegionMake2D(0, 0, atlasW, atlasH)
           mipmapLevel:0
             withBytes:zeroes
           bytesPerRow:atlasW];
    free(zeroes);

    GlyphCache gc;
    memset((void*)&gc, 0, sizeof(gc));
    gc.texture   = tex;
    gc.font      = (CTFontRef)CFRetain(font);
    gc.glyph_w   = gw;
    gc.glyph_h   = gh;
    gc.scale     = (float)scale;
    gc.descent   = descent;
    gc.atlas_cols = cols;
    gc.atlas_w   = atlasW;
    gc.atlas_h   = atlasH;
    gc.next_slot = 0;
    gc.max_slots = cols * initRows;
    gc.device    = device;

    // Mark all hash map entries as empty.
    for (int i = 0; i < GLYPH_CACHE_CAP; i++) gc.map[i].slot = -1;

    // Pre-seed ASCII 32-126 so the common path has zero overhead.
    for (uint32_t ch = 32; ch < 127; ch++) {
        glyphCacheRasterize(&gc, ch);
    }

    CFRelease(font);
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
// Dirty-bitset helpers (mirrors DirtyRows from Zig)
// ---------------------------------------------------------------------------

static inline int dirtyBitTest(const uint64_t dirty[4], int row) {
    if (row < 0 || row >= 256) return 0;
    return (dirty[row >> 6] >> (row & 63)) & 1;
}

static inline int dirtyAny(const uint64_t dirty[4]) {
    return (dirty[0] | dirty[1] | dirty[2] | dirty[3]) != 0;
}

// Forward-declare; the search bar is created after the renderer.
@class AttyxSearchBar;
static AttyxSearchBar* g_nativeSearchBar = nil;
static void syncSearchBarCount(void); // defined after AttyxSearchBar @implementation

// ---------------------------------------------------------------------------
// Renderer (MTKViewDelegate) — damage-aware with persistent buffers
// ---------------------------------------------------------------------------

@interface AttyxRenderer : NSObject <MTKViewDelegate> {
    GlyphCache _glyphCache;

    // Persistent CPU-side vertex arrays (survive across frames).
    Vertex*     _bgVerts;
    Vertex*     _textVerts;
    int         _totalTextVerts;

    // Persistent Metal buffers (reused each frame, recreated on resize).
    id<MTLBuffer> _bgMetalBuf;
    id<MTLBuffer> _textMetalBuf;
    int           _metalBufCapBg;
    int           _metalBufCapText;

    // Persistent cell snapshot (avoids per-frame malloc).
    AttyxCell*  _cellSnapshot;
    int         _cellSnapshotCap;

    // Previous frame state for change detection.
    int         _prevCursorRow;
    int         _prevCursorCol;
    BOOL        _fullRedrawNeeded;
    int         _allocRows;
    int         _allocCols;

    // Cursor blink state
    BOOL        _blinkOn;
    CFAbsoluteTime _blinkLastToggle;
    int         _prevCursorShape;
    int         _prevCursorVisible;

    // Debug stats
    BOOL        _debugStats;
    uint64_t    _statsFrames;
    uint64_t    _statsSkipped;
    uint64_t    _statsDirtyRows;
    CFAbsoluteTime _statsLastPrint;
}
@property (nonatomic, strong) id<MTLDevice>              device;
@property (nonatomic, strong) id<MTLCommandQueue>        cmdQueue;
@property (nonatomic, strong) id<MTLRenderPipelineState> bgPipeline;
@property (nonatomic, strong) id<MTLRenderPipelineState> textPipeline;
@end

/// Check if a cell at (row, col) is within the current selection.
/// Selection is stored as start/end which may be in any order.
static BOOL cellIsSelected(int row, int col) {
    if (!g_sel_active) return NO;
    int sr = g_sel_start_row, sc = g_sel_start_col;
    int er = g_sel_end_row,   ec = g_sel_end_col;
    // Normalize so (sr,sc) <= (er,ec)
    if (sr > er || (sr == er && sc > ec)) {
        int tr = sr, tc = sc;
        sr = er; sc = ec;
        er = tr; ec = tc;
    }
    if (row < sr || row > er) return NO;
    if (row == sr && row == er) return col >= sc && col <= ec;
    if (row == sr) return col >= sc;
    if (row == er) return col <= ec;
    return YES;
}

@implementation AttyxRenderer

- (instancetype)initWithDevice:(id<MTLDevice>)device
                          view:(MTKView*)view
                    glyphCache:(GlyphCache)glyphCache
{
    self = [super init];
    if (!self) return nil;

    _device     = device;
    _cmdQueue   = [device newCommandQueue];
    _glyphCache = glyphCache;

    _bgVerts          = NULL;
    _textVerts        = NULL;
    _totalTextVerts   = 0;
    _bgMetalBuf       = nil;
    _textMetalBuf     = nil;
    _metalBufCapBg    = 0;
    _metalBufCapText  = 0;
    _cellSnapshot     = NULL;
    _cellSnapshotCap  = 0;
    _prevCursorRow      = -1;
    _prevCursorCol      = -1;
    _prevCursorShape    = -1;
    _prevCursorVisible  = -1;
    _blinkOn            = YES;
    _blinkLastToggle    = CACurrentMediaTime();
    _fullRedrawNeeded   = YES;
    _allocRows          = 0;
    _allocCols        = 0;

    _debugStats       = (getenv("ATTYX_DEBUG_STATS") != NULL);
    _statsFrames      = 0;
    _statsSkipped     = 0;
    _statsDirtyRows   = 0;
    _statsLastPrint   = CFAbsoluteTimeGetCurrent();

    NSError* err = nil;
    id<MTLLibrary> lib = [device newLibraryWithSource:kShaderSource
                                              options:nil
                                                error:&err];
    if (!lib) { NSLog(@"Shader error: %@", err); return nil; }

    id<MTLFunction> vertFn     = [lib newFunctionWithName:@"vert_main"];
    id<MTLFunction> fragSolid  = [lib newFunctionWithName:@"frag_solid"];
    id<MTLFunction> fragText   = [lib newFunctionWithName:@"frag_text"];

    {
        MTLRenderPipelineDescriptor* d = [[MTLRenderPipelineDescriptor alloc] init];
        d.vertexFunction   = vertFn;
        d.fragmentFunction = fragSolid;
        d.colorAttachments[0].pixelFormat     = view.colorPixelFormat;
        d.colorAttachments[0].blendingEnabled = YES;
        d.colorAttachments[0].sourceRGBBlendFactor        = MTLBlendFactorSourceAlpha;
        d.colorAttachments[0].destinationRGBBlendFactor   = MTLBlendFactorOneMinusSourceAlpha;
        d.colorAttachments[0].sourceAlphaBlendFactor      = MTLBlendFactorOne;
        d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        _bgPipeline = [device newRenderPipelineStateWithDescriptor:d error:&err];
        if (!_bgPipeline) { NSLog(@"BG pipeline: %@", err); return nil; }
    }

    {
        MTLRenderPipelineDescriptor* d = [[MTLRenderPipelineDescriptor alloc] init];
        d.vertexFunction   = vertFn;
        d.fragmentFunction = fragText;
        d.colorAttachments[0].pixelFormat     = view.colorPixelFormat;
        d.colorAttachments[0].blendingEnabled = YES;
        d.colorAttachments[0].sourceRGBBlendFactor        = MTLBlendFactorSourceAlpha;
        d.colorAttachments[0].destinationRGBBlendFactor   = MTLBlendFactorOneMinusSourceAlpha;
        d.colorAttachments[0].sourceAlphaBlendFactor      = MTLBlendFactorSourceAlpha;
        d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        _textPipeline = [device newRenderPipelineStateWithDescriptor:d error:&err];
        if (!_textPipeline) { NSLog(@"Text pipeline: %@", err); return nil; }
    }

    return self;
}

- (void)dealloc {
    free(_bgVerts);
    free(_textVerts);
    free(_cellSnapshot);
}

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size {
    // Small epsilon avoids float truncation giving 79 instead of 80 on startup.
    int new_cols = (int)(size.width  / _glyphCache.glyph_w + 0.01f);
    int new_rows = (int)(size.height / _glyphCache.glyph_h + 0.01f);
    if (new_cols < 1) new_cols = 1;
    if (new_rows < 1) new_rows = 1;
    if (new_cols > ATTYX_MAX_COLS) new_cols = ATTYX_MAX_COLS;
    if (new_rows > ATTYX_MAX_ROWS) new_rows = ATTYX_MAX_ROWS;
    g_pending_resize_rows = new_rows;
    g_pending_resize_cols = new_cols;
    _fullRedrawNeeded = YES;
}

- (void)drawInMTKView:(MTKView*)view {
    if (!g_cells || g_cols <= 0 || g_rows <= 0) return;

    // Seqlock read: skip frame if PTY thread is mid-update.
    uint64_t gen1 = g_cell_gen;
    if (gen1 & 1) return;

    @autoreleasepool {
        int rows = g_rows;
        int cols = g_cols;
        int total = cols * rows;

        // --- Snapshot dirty bits (atomic exchange to zero) ---
        uint64_t dirty[4];
        for (int i = 0; i < 4; i++)
            dirty[i] = __sync_lock_test_and_set((volatile uint64_t*)&g_dirty[i], 0);

        int curRow = g_cursor_row;
        int curCol = g_cursor_col;
        int curShape = g_cursor_shape;
        int curVisible = g_cursor_visible;

        BOOL cursorChanged = (curRow != _prevCursorRow || curCol != _prevCursorCol
                              || curShape != _prevCursorShape || curVisible != _prevCursorVisible);

        // Blink logic: toggle every 500ms for blinking shapes (0, 2, 4).
        BOOL isBlinking = curVisible && (curShape == 0 || curShape == 2 || curShape == 4);
        CFAbsoluteTime now = CACurrentMediaTime();
        if (cursorChanged) {
            _blinkOn = YES;
            _blinkLastToggle = now;
        } else if (isBlinking) {
            if (now - _blinkLastToggle >= 0.5) {
                _blinkOn = !_blinkOn;
                _blinkLastToggle = now;
            }
        } else {
            _blinkOn = YES;
        }

        // --- Reallocate persistent buffers if grid size changed ---
        if (rows != _allocRows || cols != _allocCols) {
            free(_bgVerts);
            free(_textVerts);
            free(_cellSnapshot);

            int bgVertCap = (total * 2 + cols + cols + ATTYX_SEARCH_VIS_MAX) * 6;
            _bgVerts       = (Vertex*)calloc(bgVertCap, sizeof(Vertex));
            _textVerts     = (Vertex*)calloc(total * 6, sizeof(Vertex));
            _cellSnapshot  = (AttyxCell*)malloc(sizeof(AttyxCell) * total);
            _cellSnapshotCap = total;
            _totalTextVerts = 0;
            _allocRows = rows;
            _allocCols = cols;
            _fullRedrawNeeded = YES;

            // Recreate Metal buffers at new capacity.
            _metalBufCapBg   = bgVertCap;
            _metalBufCapText = total * 6;
            _bgMetalBuf   = [_device newBufferWithLength:sizeof(Vertex) * _metalBufCapBg
                                                 options:MTLResourceStorageModeShared];
            _textMetalBuf = [_device newBufferWithLength:sizeof(Vertex) * _metalBufCapText
                                                 options:MTLResourceStorageModeShared];
        }

        // --- Frame skip: nothing dirty, cursor didn't move, no blink toggle ---
        if (!_fullRedrawNeeded && !dirtyAny(dirty) && !cursorChanged && !isBlinking && !g_search_active) {
            if (_debugStats) _statsSkipped++;
            if (_debugStats) _statsFrames++;
            [self printStatsIfNeeded];
            return;
        }

        // --- Snapshot cells into persistent buffer (no malloc per frame) ---
        if (_cellSnapshot && _cellSnapshotCap >= total) {
            memcpy(_cellSnapshot, g_cells, sizeof(AttyxCell) * total);
        } else {
            return;
        }

        // Seqlock validation: if generation changed during our read,
        // the snapshot is torn (mix of old + new data). Skip this frame.
        uint64_t gen2 = g_cell_gen;
        if (gen1 != gen2) return;

        AttyxCell* cells = _cellSnapshot;

        // --- Layout math (fixed glyph size — viewport locked to grid) ---
        float gw = _glyphCache.glyph_w;
        float gh = _glyphCache.glyph_h;
        float viewport[2] = { cols * gw, rows * gh };

        float atlasW = (float)_glyphCache.atlas_w;
        float glyphW = _glyphCache.glyph_w;
        float glyphH = _glyphCache.glyph_h;
        int atlasCols = _glyphCache.atlas_cols;

        // --- Update bg vertices for dirty rows ---
        int dirtyRowCount = 0;
        for (int row = 0; row < rows; row++) {
            if (!_fullRedrawNeeded && !dirtyBitTest(dirty, row)) continue;
            dirtyRowCount++;

            for (int col = 0; col < cols; col++) {
                int i = row * cols + col;
                float x0 = col * gw;
                float y0 = row * gh;
                float x1 = x0 + gw;
                float y1 = y0 + gh;
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
                _bgVerts[bi+0] = (Vertex){ x0, y0, 0,0, br,bg,bb,1 };
                _bgVerts[bi+1] = (Vertex){ x1, y0, 0,0, br,bg,bb,1 };
                _bgVerts[bi+2] = (Vertex){ x0, y1, 0,0, br,bg,bb,1 };
                _bgVerts[bi+3] = (Vertex){ x1, y0, 0,0, br,bg,bb,1 };
                _bgVerts[bi+4] = (Vertex){ x1, y1, 0,0, br,bg,bb,1 };
                _bgVerts[bi+5] = (Vertex){ x0, y1, 0,0, br,bg,bb,1 };
            }
        }

        // --- Update cursor quad in bg vertices (shape-aware) ---
        int cursorSlot = total * 6;
        memset(&_bgVerts[cursorSlot], 0, sizeof(Vertex) * 6);

        int bgVertCount = total * 6;
        BOOL drawCursor = curVisible && _blinkOn
                          && curRow >= 0 && curRow < rows && curCol >= 0 && curCol < cols;
        if (drawCursor) {
            float cx0 = curCol * gw;
            float cy0 = curRow * gh;
            float cr = 0.86f, cg_c = 0.86f, cb = 0.86f;

            float rx0 = cx0, ry0 = cy0, rx1 = cx0 + gw, ry1 = cy0 + gh;
            switch (curShape) {
                case 0: case 1: // block (blinking/steady)
                    break;
                case 2: case 3: { // underline (blinking/steady): 2px at bottom
                    float thickness = fmaxf(2.0f, 1.0f);
                    ry0 = ry1 - thickness;
                    break;
                }
                case 4: case 5: { // bar (blinking/steady): 2px at left
                    float thickness = fmaxf(2.0f, 1.0f);
                    rx1 = rx0 + thickness;
                    break;
                }
                default: break;
            }

            _bgVerts[cursorSlot+0] = (Vertex){ rx0,ry0, 0,0, cr,cg_c,cb,1 };
            _bgVerts[cursorSlot+1] = (Vertex){ rx1,ry0, 0,0, cr,cg_c,cb,1 };
            _bgVerts[cursorSlot+2] = (Vertex){ rx0,ry1, 0,0, cr,cg_c,cb,1 };
            _bgVerts[cursorSlot+3] = (Vertex){ rx1,ry0, 0,0, cr,cg_c,cb,1 };
            _bgVerts[cursorSlot+4] = (Vertex){ rx1,ry1, 0,0, cr,cg_c,cb,1 };
            _bgVerts[cursorSlot+5] = (Vertex){ rx0,ry1, 0,0, cr,cg_c,cb,1 };
            bgVertCount += 6;
        }

        // --- Hyperlink underlines: OSC 8 (always visible) + detected URLs (on hover) ---
        if (!g_sel_active) {
            uint32_t hoverLid = g_hover_link_id;
            float ulH = fmaxf(2.0f, 1.0f);

            // OSC 8 links: always show underline (brighter on hover)
            for (int i = 0; i < total; i++) {
                uint32_t lid = cells[i].link_id;
                if (lid == 0) continue;
                if (bgVertCount + 6 > _metalBufCapBg) break;
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
                _bgVerts[bgVertCount+0] = (Vertex){ lx0,ly0, 0,0, lr,lg,lb,1 };
                _bgVerts[bgVertCount+1] = (Vertex){ lx1,ly0, 0,0, lr,lg,lb,1 };
                _bgVerts[bgVertCount+2] = (Vertex){ lx0,ly1, 0,0, lr,lg,lb,1 };
                _bgVerts[bgVertCount+3] = (Vertex){ lx1,ly0, 0,0, lr,lg,lb,1 };
                _bgVerts[bgVertCount+4] = (Vertex){ lx1,ly1, 0,0, lr,lg,lb,1 };
                _bgVerts[bgVertCount+5] = (Vertex){ lx0,ly1, 0,0, lr,lg,lb,1 };
                bgVertCount += 6;
            }

            // Detected URLs: show underline only when hovered
            int dRow = g_detected_url_row;
            int dStart = g_detected_url_start_col;
            int dEnd = g_detected_url_end_col;
            if (g_detected_url_len > 0 && dRow >= 0 && dRow < rows) {
                float lr = 0.4f, lg = 0.7f, lb = 1.0f;
                for (int c = dStart; c <= dEnd && c < cols; c++) {
                    if (bgVertCount + 6 > _metalBufCapBg) break;
                    float lx0 = c * gw;
                    float lx1 = lx0 + gw;
                    float ly1 = (dRow + 1) * gh;
                    float ly0 = ly1 - ulH;
                    _bgVerts[bgVertCount+0] = (Vertex){ lx0,ly0, 0,0, lr,lg,lb,1 };
                    _bgVerts[bgVertCount+1] = (Vertex){ lx1,ly0, 0,0, lr,lg,lb,1 };
                    _bgVerts[bgVertCount+2] = (Vertex){ lx0,ly1, 0,0, lr,lg,lb,1 };
                    _bgVerts[bgVertCount+3] = (Vertex){ lx1,ly0, 0,0, lr,lg,lb,1 };
                    _bgVerts[bgVertCount+4] = (Vertex){ lx1,ly1, 0,0, lr,lg,lb,1 };
                    _bgVerts[bgVertCount+5] = (Vertex){ lx0,ly1, 0,0, lr,lg,lb,1 };
                    bgVertCount += 6;
                }
            }
        }

        // --- Search match highlights ---
        if (g_search_active) {
            int visCount = g_search_vis_count;
            int curRow = g_search_cur_vis_row;
            int curCs = g_search_cur_vis_cs;
            int curCe = g_search_cur_vis_ce;
            float ulH = gh; // full cell height for highlight
            for (int vi = 0; vi < visCount && vi < ATTYX_SEARCH_VIS_MAX; vi++) {
                AttyxSearchVis m = g_search_vis[vi];
                if (m.row < 0 || m.row >= rows) continue;
                BOOL isCurrent = (m.row == curRow && m.col_start == curCs && m.col_end == curCe);
                float hr, hg, hb, ha;
                if (isCurrent) {
                    hr = 1.0f; hg = 0.6f; hb = 0.0f; ha = 0.75f;
                } else {
                    hr = 1.0f; hg = 0.6f; hb = 0.0f; ha = 0.28f;
                }
                for (int cc = m.col_start; cc < m.col_end && cc < cols; cc++) {
                    if (bgVertCount + 6 > _metalBufCapBg) break;
                    float lx0 = cc * gw, lx1 = lx0 + gw;
                    float ly0 = m.row * gh, ly1 = ly0 + ulH;
                    _bgVerts[bgVertCount+0] = (Vertex){ lx0,ly0, 0,0, hr,hg,hb,ha };
                    _bgVerts[bgVertCount+1] = (Vertex){ lx1,ly0, 0,0, hr,hg,hb,ha };
                    _bgVerts[bgVertCount+2] = (Vertex){ lx0,ly1, 0,0, hr,hg,hb,ha };
                    _bgVerts[bgVertCount+3] = (Vertex){ lx1,ly0, 0,0, hr,hg,hb,ha };
                    _bgVerts[bgVertCount+4] = (Vertex){ lx1,ly1, 0,0, hr,hg,hb,ha };
                    _bgVerts[bgVertCount+5] = (Vertex){ lx0,ly1, 0,0, hr,hg,hb,ha };
                    bgVertCount += 6;
                }
            }
        }

        // --- Rebuild text vertices on any dirty frame ---
        int ti = 0;
        if (_fullRedrawNeeded || dirtyAny(dirty)) {
            for (int i = 0; i < total; i++) {
                const AttyxCell* cell = &cells[i];
                uint32_t ch = cell->character;
                if (ch <= 32) continue;

                int row = i / cols;
                int col = i % cols;
                float x0 = col * gw;
                float y0 = row * gh;
                float x1 = x0 + gw;
                float y1 = y0 + gh;

                int slot = glyphCacheLookup(&_glyphCache, ch);
                if (slot < 0) {
                    slot = glyphCacheRasterize(&_glyphCache, ch);
                    atlasW = (float)_glyphCache.atlas_w;
                }

                int ac = slot % atlasCols;
                int ar = slot / atlasCols;
                float atlasH = (float)_glyphCache.atlas_h;

                float au0 = ac       * glyphW / atlasW;
                float av0 = ar       * glyphH / atlasH;
                float au1 = (ac + 1) * glyphW / atlasW;
                float av1 = (ar + 1) * glyphH / atlasH;

                float fr = cell->fg_r / 255.0f;
                float fg = cell->fg_g / 255.0f;
                float fb = cell->fg_b / 255.0f;

                _textVerts[ti+0] = (Vertex){ x0,y0, au0,av0, fr,fg,fb,1 };
                _textVerts[ti+1] = (Vertex){ x1,y0, au1,av0, fr,fg,fb,1 };
                _textVerts[ti+2] = (Vertex){ x0,y1, au0,av1, fr,fg,fb,1 };
                _textVerts[ti+3] = (Vertex){ x1,y0, au1,av0, fr,fg,fb,1 };
                _textVerts[ti+4] = (Vertex){ x1,y1, au1,av1, fr,fg,fb,1 };
                _textVerts[ti+5] = (Vertex){ x0,y1, au0,av1, fr,fg,fb,1 };
                ti += 6;
            }
            _totalTextVerts = ti;
        } else {
            ti = _totalTextVerts;
        }

        _prevCursorRow     = curRow;
        _prevCursorCol     = curCol;
        _prevCursorShape   = curShape;
        _prevCursorVisible = curVisible;
        _fullRedrawNeeded  = NO;

        // --- Window title update ---
        if (g_title_changed) {
            int tlen = g_title_len;
            if (tlen > 0 && tlen < ATTYX_TITLE_MAX) {
                NSString* title = [[NSString alloc] initWithBytes:g_title_buf
                                                           length:tlen
                                                         encoding:NSUTF8StringEncoding];
                if (title) {
                    NSWindow* win = [(MTKView*)view window];
                    if (win) [win setTitle:title];
                }
            }
            g_title_changed = 0;
        }

        // --- Copy vertices into persistent Metal buffers (no alloc per frame) ---
        memcpy(_bgMetalBuf.contents, _bgVerts, sizeof(Vertex) * bgVertCount);
        [_bgMetalBuf didModifyRange:NSMakeRange(0, sizeof(Vertex) * bgVertCount)];

        if (ti > 0) {
            memcpy(_textMetalBuf.contents, _textVerts, sizeof(Vertex) * ti);
            [_textMetalBuf didModifyRange:NSMakeRange(0, sizeof(Vertex) * ti)];
        }

        // --- Draw ---
        id<MTLCommandBuffer> cmdBuf = [_cmdQueue commandBuffer];
        MTLRenderPassDescriptor* rpd = view.currentRenderPassDescriptor;
        if (!rpd) return;

        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0.118, 0.118, 0.141, 1.0);

        id<MTLRenderCommandEncoder> enc =
            [cmdBuf renderCommandEncoderWithDescriptor:rpd];

        MTLViewport gridViewport = {
            .originX = 0, .originY = 0,
            .width = cols * gw, .height = rows * gh,
            .znear = 0, .zfar = 1
        };
        [enc setViewport:gridViewport];

        [enc setRenderPipelineState:_bgPipeline];
        [enc setVertexBuffer:_bgMetalBuf offset:0 atIndex:0];
        [enc setVertexBytes:viewport length:sizeof(viewport) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                vertexCount:bgVertCount];

        if (ti > 0) {
            [enc setRenderPipelineState:_textPipeline];
            [enc setVertexBuffer:_textMetalBuf offset:0 atIndex:0];
            [enc setVertexBytes:viewport length:sizeof(viewport) atIndex:1];
            [enc setFragmentTexture:_glyphCache.texture atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                    vertexCount:ti];
        }

        // --- IME preedit overlay ---
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
                    if ((*p & 0x80) == 0)          { cp = *p++; }
                    else if ((*p & 0xE0) == 0xC0)  { cp = (*p & 0x1F); p++; if (p < end) { cp = (cp << 6) | (*p & 0x3F); p++; } }
                    else if ((*p & 0xF0) == 0xE0)  { cp = (*p & 0x0F); p++; for (int j = 0; j < 2 && p < end; j++) { cp = (cp << 6) | (*p & 0x3F); p++; } }
                    else if ((*p & 0xF8) == 0xF0)  { cp = (*p & 0x07); p++; for (int j = 0; j < 3 && p < end; j++) { cp = (cp << 6) | (*p & 0x3F); p++; } }
                    else { p++; continue; }
                    preCPs[preCharCount++] = cp;
                }

                int preCells = preCharCount;
                if (pCol + preCells > cols) preCells = cols - pCol;

                Vertex imeVerts[128 * 6 + 6];
                int iv = 0;

                for (int i = 0; i < preCells; i++) {
                    float x0 = (pCol + i) * gw;
                    float y0 = pRow * gh;
                    float x1 = x0 + gw;
                    float y1 = y0 + gh;
                    float br = 0.20f, bg = 0.20f, bb = 0.30f;
                    imeVerts[iv++] = (Vertex){ x0,y0, 0,0, br,bg,bb,1 };
                    imeVerts[iv++] = (Vertex){ x1,y0, 0,0, br,bg,bb,1 };
                    imeVerts[iv++] = (Vertex){ x0,y1, 0,0, br,bg,bb,1 };
                    imeVerts[iv++] = (Vertex){ x1,y0, 0,0, br,bg,bb,1 };
                    imeVerts[iv++] = (Vertex){ x1,y1, 0,0, br,bg,bb,1 };
                    imeVerts[iv++] = (Vertex){ x0,y1, 0,0, br,bg,bb,1 };
                }

                // Underline bar at bottom of preedit cells
                float ulH = 2.0f;
                float ulY0 = pRow * gh + gh - ulH;
                float ulY1 = pRow * gh + gh;
                float ulX0 = pCol * gw;
                float ulX1 = (pCol + preCells) * gw;
                imeVerts[iv++] = (Vertex){ ulX0,ulY0, 0,0, 0.9f,0.9f,0.3f,1 };
                imeVerts[iv++] = (Vertex){ ulX1,ulY0, 0,0, 0.9f,0.9f,0.3f,1 };
                imeVerts[iv++] = (Vertex){ ulX0,ulY1, 0,0, 0.9f,0.9f,0.3f,1 };
                imeVerts[iv++] = (Vertex){ ulX1,ulY0, 0,0, 0.9f,0.9f,0.3f,1 };
                imeVerts[iv++] = (Vertex){ ulX1,ulY1, 0,0, 0.9f,0.9f,0.3f,1 };
                imeVerts[iv++] = (Vertex){ ulX0,ulY1, 0,0, 0.9f,0.9f,0.3f,1 };

                [enc setRenderPipelineState:_bgPipeline];
                [enc setVertexBytes:imeVerts length:sizeof(Vertex) * iv atIndex:0];
                [enc setVertexBytes:viewport length:sizeof(viewport) atIndex:1];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                        vertexCount:iv];

                // Preedit text glyphs
                int imeGlyphs = 0;
                Vertex imeTextVerts[128 * 6];
                for (int i = 0; i < preCells; i++) {
                    uint32_t cp = preCPs[i];
                    if (cp <= 32) continue;
                    float x0 = (pCol + i) * gw;
                    float y0 = pRow * gh;
                    float x1 = x0 + gw;
                    float y1 = y0 + gh;

                    int slot = glyphCacheLookup(&_glyphCache, cp);
                    if (slot < 0) slot = glyphCacheRasterize(&_glyphCache, cp);

                    int ac = slot % _glyphCache.atlas_cols;
                    int ar = slot / _glyphCache.atlas_cols;
                    float aW = (float)_glyphCache.atlas_w;
                    float aH = (float)_glyphCache.atlas_h;
                    float au0 = ac       * glyphW / aW;
                    float av0 = ar       * glyphH / aH;
                    float au1 = (ac + 1) * glyphW / aW;
                    float av1 = (ar + 1) * glyphH / aH;

                    float fr = 0.95f, fg = 0.95f, fb = 0.95f;
                    imeTextVerts[imeGlyphs++] = (Vertex){ x0,y0, au0,av0, fr,fg,fb,1 };
                    imeTextVerts[imeGlyphs++] = (Vertex){ x1,y0, au1,av0, fr,fg,fb,1 };
                    imeTextVerts[imeGlyphs++] = (Vertex){ x0,y1, au0,av1, fr,fg,fb,1 };
                    imeTextVerts[imeGlyphs++] = (Vertex){ x1,y0, au1,av0, fr,fg,fb,1 };
                    imeTextVerts[imeGlyphs++] = (Vertex){ x1,y1, au1,av1, fr,fg,fb,1 };
                    imeTextVerts[imeGlyphs++] = (Vertex){ x0,y1, au0,av1, fr,fg,fb,1 };
                }

                if (imeGlyphs > 0) {
                    [enc setRenderPipelineState:_textPipeline];
                    [enc setVertexBytes:imeTextVerts length:sizeof(Vertex) * imeGlyphs atIndex:0];
                    [enc setVertexBytes:viewport length:sizeof(viewport) atIndex:1];
                    [enc setFragmentTexture:_glyphCache.texture atIndex:0];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                            vertexCount:imeGlyphs];
                }
            }
        }

        // Sync the native search bar's count label from bridge globals
        syncSearchBarCount();

        [enc endEncoding];
        [cmdBuf commit];
        [cmdBuf waitUntilCompleted];
        [view.currentDrawable present];

        if (_debugStats) {
            _statsFrames++;
            _statsDirtyRows += dirtyRowCount;
            [self printStatsIfNeeded];
        }
    }
}

- (void)printStatsIfNeeded {
    if (!_debugStats) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _statsLastPrint >= 2.0) {
        double elapsed = now - _statsLastPrint;
        double fps = _statsFrames / elapsed;
        double skipPct = _statsFrames > 0 ? 100.0 * _statsSkipped / _statsFrames : 0;
        double avgDirty = (_statsFrames - _statsSkipped) > 0
            ? (double)_statsDirtyRows / (_statsFrames - _statsSkipped) : 0;
        fprintf(stderr, "[attyx] fps=%.0f skip=%.0f%% avg_dirty=%.1f rows\n",
                fps, skipPct, avgDirty);
        _statsFrames = 0;
        _statsSkipped = 0;
        _statsDirtyRows = 0;
        _statsLastPrint = now;
    }
}

@end

// ---------------------------------------------------------------------------
// Native search bar (Cocoa)
// ---------------------------------------------------------------------------

@interface AttyxSearchBar : NSVisualEffectView <NSTextFieldDelegate>
@property (strong) NSView     *inputBox;
@property (strong) NSTextField *inputField;
@property (strong) NSTextField *countLabel;
@property (strong) NSButton *prevButton;
@property (strong) NSButton *nextButton;
@property (strong) NSButton *closeButton;
@property (weak)   NSView   *termView;
@end

@implementation AttyxSearchBar

- (instancetype)initForTermView:(NSView*)parent {
    self = [super initWithFrame:NSZeroRect];
    if (!self) return nil;

    _termView = parent;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.material = NSVisualEffectMaterialMenu;
    self.state = NSVisualEffectStateActive;
    self.wantsLayer = YES;
    self.layer.cornerRadius = 0;

    // --- Input container (dark rounded box with real padding) ---
    _inputBox = [[NSView alloc] initWithFrame:NSZeroRect];
    _inputBox.translatesAutoresizingMaskIntoConstraints = NO;
    _inputBox.wantsLayer = YES;
    _inputBox.layer.cornerRadius = 6;
    _inputBox.layer.backgroundColor = [[NSColor colorWithWhite:0.12 alpha:1.0] CGColor];
    [self addSubview:_inputBox];

    // --- Input field (plain, no background — container handles it) ---
    _inputField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _inputField.translatesAutoresizingMaskIntoConstraints = NO;
    _inputField.placeholderString = @"Find";
    _inputField.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
    _inputField.bordered = NO;
    _inputField.focusRingType = NSFocusRingTypeNone;
    _inputField.drawsBackground = NO;
    _inputField.textColor = [NSColor whiteColor];
    _inputField.cell.scrollable = YES;
    _inputField.cell.wraps = NO;
    _inputField.delegate = self;
    [_inputBox addSubview:_inputField];

    // Pin input field inside container with padding
    [NSLayoutConstraint activateConstraints:@[
        [_inputField.leadingAnchor constraintEqualToAnchor:_inputBox.leadingAnchor constant:8],
        [_inputField.trailingAnchor constraintEqualToAnchor:_inputBox.trailingAnchor constant:-8],
        [_inputField.centerYAnchor constraintEqualToAnchor:_inputBox.centerYAnchor],
    ]];

    // --- Count label ---
    _countLabel = [NSTextField labelWithString:@""];
    _countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _countLabel.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    _countLabel.textColor = [NSColor secondaryLabelColor];
    _countLabel.alignment = NSTextAlignmentRight;
    [_countLabel setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self addSubview:_countLabel];

    // --- Prev / Next / Close buttons (SF Symbols) ---
    NSImageSymbolConfiguration* symCfg = [NSImageSymbolConfiguration
        configurationWithPointSize:12 weight:NSFontWeightMedium];
    NSImage* upImg   = [[NSImage imageWithSystemSymbolName:@"chevron.up"
                          accessibilityDescription:@"Previous"]
                         imageWithSymbolConfiguration:symCfg];
    NSImage* downImg = [[NSImage imageWithSystemSymbolName:@"chevron.down"
                          accessibilityDescription:@"Next"]
                         imageWithSymbolConfiguration:symCfg];
    NSImage* xImg    = [[NSImage imageWithSystemSymbolName:@"xmark"
                          accessibilityDescription:@"Close"]
                         imageWithSymbolConfiguration:symCfg];

    _prevButton  = [NSButton buttonWithImage:upImg   target:self action:@selector(goPrev:)];
    _nextButton  = [NSButton buttonWithImage:downImg target:self action:@selector(goNext:)];
    _closeButton = [NSButton buttonWithImage:xImg    target:self action:@selector(dismiss)];
    for (NSButton* b in @[_prevButton, _nextButton, _closeButton]) {
        b.translatesAutoresizingMaskIntoConstraints = NO;
        b.bordered = NO;
        b.bezelStyle = NSBezelStyleInline;
        b.contentTintColor = [NSColor secondaryLabelColor];
        [b setContentHuggingPriority:NSLayoutPriorityRequired
                      forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self addSubview:b];
    }
    _prevButton.toolTip  = @"Previous Match (\u21e7\u2318G)";
    _nextButton.toolTip  = @"Next Match (\u2318G)";
    _closeButton.toolTip = @"Close (Esc)";

    // --- Outer layout ---
    NSDictionary *views = NSDictionaryOfVariableBindings(_inputBox, _countLabel, _prevButton, _nextButton, _closeButton);
    [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:
        @"H:|-8-[_inputBox]-6-[_countLabel(>=44)]-4-[_prevButton(26)]-1-[_nextButton(26)]-6-[_closeButton(26)]-6-|"
        options:0 metrics:nil views:views]];

    // Vertically center every element in the bar
    for (NSView* sub in @[_inputBox, _countLabel, _prevButton, _nextButton, _closeButton]) {
        [NSLayoutConstraint activateConstraints:@[
            [sub.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
    }

    // Input box height
    [_inputBox.heightAnchor constraintEqualToConstant:26].active = YES;

    return self;
}

- (void)show {
    if (self.superview) {
        [self.window makeFirstResponder:_inputField];
        return;
    }
    NSView* parent = _termView;
    if (!parent) return;

    [parent addSubview:self];
    [NSLayoutConstraint activateConstraints:@[
        [self.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor],
        [self.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor],
        [self.topAnchor constraintEqualToAnchor:parent.topAnchor],
        [self.heightAnchor constraintEqualToConstant:36],
    ]];

    g_search_active = 1;
    g_search_query_len = 0;
    g_search_gen++;
    [_inputField setStringValue:@""];
    _countLabel.stringValue = @"";
    [self.window makeFirstResponder:_inputField];
    attyx_mark_all_dirty();
}

- (void)dismiss {
    if (!self.superview) return;
    g_search_active = 0;
    g_search_query_len = 0;
    g_search_gen++;
    attyx_mark_all_dirty();

    NSView* parent = _termView;
    [self removeFromSuperview];
    if (parent) [parent.window makeFirstResponder:parent];
}

- (void)toggle {
    if (self.superview) [self dismiss];
    else [self show];
}

- (void)goNext:(id)sender {
    __sync_fetch_and_add((volatile int*)&g_search_nav_delta, 1);
    attyx_mark_all_dirty();
}

- (void)goPrev:(id)sender {
    __sync_fetch_and_add((volatile int*)&g_search_nav_delta, -1);
    attyx_mark_all_dirty();
}

- (void)syncCountLabel {
    if (!self.superview) return;
    int total = g_search_total;
    int cur   = g_search_current;
    if (total > 0) {
        _countLabel.stringValue = [NSString stringWithFormat:@"%d/%d", cur + 1, total];
        _countLabel.textColor = [NSColor secondaryLabelColor];
    } else if (g_search_query_len > 0) {
        _countLabel.stringValue = @"-/0";
        _countLabel.textColor = [NSColor systemRedColor];
    } else {
        _countLabel.stringValue = @"";
    }
}

// NSTextFieldDelegate
- (void)controlTextDidChange:(NSNotification *)n {
    const char* utf8 = [_inputField.stringValue UTF8String];
    int len = (int)strlen(utf8);
    if (len > ATTYX_SEARCH_QUERY_MAX - 1) len = ATTYX_SEARCH_QUERY_MAX - 1;
    memcpy(g_search_query, utf8, len);
    g_search_query_len = len;
    g_search_gen++;
    attyx_mark_all_dirty();
}

- (BOOL)control:(NSControl*)ctl textView:(NSTextView*)tv doCommandBySelector:(SEL)sel {
    if (sel == @selector(insertNewline:))    { [self goNext:nil]; return YES; }
    if (sel == @selector(cancelOperation:))  { [self dismiss]; return YES; }
    return NO;
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags f = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    unsigned short kc = event.keyCode;
    BOOL cmd   = (f & NSEventModifierFlagCommand) != 0;
    BOOL shift = (f & NSEventModifierFlagShift) != 0;

    if (cmd && kc == 3 /* F */) { [self dismiss]; return YES; }
    if (cmd && kc == 5 /* G */) {
        if (shift) [self goPrev:nil]; else [self goNext:nil];
        return YES;
    }
    return [super performKeyEquivalent:event];
}

@end

static void syncSearchBarCount(void) {
    if (g_nativeSearchBar) [g_nativeSearchBar syncCountLabel];
}

// ---------------------------------------------------------------------------
// Terminal view — MTKView subclass that handles keyboard + paste
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Mouse helpers
// ---------------------------------------------------------------------------

static inline int clampInt(int val, int lo, int hi) {
    if (val < lo) return lo;
    if (val > hi) return hi;
    return val;
}

static void mouseCell(NSEvent *event, NSView *view, int *outCol, int *outRow) {
    NSPoint loc = [view convertPoint:event.locationInWindow fromView:nil];
    loc.y = view.bounds.size.height - loc.y;
    int col = (int)(loc.x / g_cell_pt_w) + 1;
    int row = (int)(loc.y / g_cell_pt_h) + 1;
    *outCol = clampInt(col, 1, g_cols);
    *outRow = clampInt(row, 1, g_rows);
}

static void mouseCell0(NSEvent *event, NSView *view, int *outCol, int *outRow) {
    NSPoint loc = [view convertPoint:event.locationInWindow fromView:nil];
    loc.y = view.bounds.size.height - loc.y;
    int col = (int)(loc.x / g_cell_pt_w);
    int row = (int)(loc.y / g_cell_pt_h);
    *outCol = clampInt(col, 0, g_cols - 1);
    *outRow = clampInt(row, 0, g_rows - 1);
}

static int mouseModifiers(NSEventModifierFlags flags) {
    int m = 0;
    if (flags & NSEventModifierFlagShift)   m |= 4;
    if (flags & NSEventModifierFlagOption)  m |= 8;
    if (flags & NSEventModifierFlagControl) m |= 16;
    return m;
}

static void sendSgrMouse(int button, int col, int row, BOOL press) {
    char buf[32];
    int len = snprintf(buf, sizeof(buf), "\x1b[<%d;%d;%d%c",
                       button, col, row, press ? 'M' : 'm');
    attyx_send_input((const uint8_t *)buf, len);
}

// ---------------------------------------------------------------------------
// AttyxView — keyboard + mouse input
// ---------------------------------------------------------------------------

@interface AttyxView : MTKView <NSTextInputClient> {
    int _lastMouseCol;
    int _lastMouseRow;
    BOOL _leftDown;
    BOOL _rightDown;
    BOOL _middleDown;
    CGFloat _scrollAccum;
    BOOL _selecting;
    int _clickCount;
    NSMutableString* _markedText;
    NSRange _markedRange;
    NSRange _selectedRange;
}
@end

@implementation AttyxView

- (instancetype)initWithFrame:(NSRect)frameRect device:(id<MTLDevice>)device {
    self = [super initWithFrame:frameRect device:device];
    if (self) {
        _markedText = [[NSMutableString alloc] init];
        _markedRange = NSMakeRange(NSNotFound, 0);
        _selectedRange = NSMakeRange(0, 0);
    }
    return self;
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder  { return YES; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas)
        [self removeTrackingArea:area];
    NSTrackingArea *ta = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:(NSTrackingMouseMoved |
                      NSTrackingMouseEnteredAndExited |
                      NSTrackingActiveInKeyWindow |
                      NSTrackingInVisibleRect)
               owner:self
            userInfo:nil];
    [self addTrackingArea:ta];
}

// --- URL detection in cell row ---

static BOOL isUrlChar(uint32_t ch) {
    if (ch <= 32 || ch == 127) return NO;
    if (ch == '<' || ch == '>' || ch == '"' || ch == '`') return NO;
    if (ch == '{' || ch == '}') return NO;
    return YES;
}

static BOOL isTrailingPunct(uint32_t ch) {
    return (ch == '.' || ch == ',' || ch == ';' || ch == ':' ||
            ch == '!' || ch == '?' || ch == '\'' || ch == '"' ||
            ch == ')' || ch == ']' || ch == '>');
}

/// Scan a row for a URL that contains column `col`.
/// Returns YES if found, filling outStart/outEnd (inclusive column range)
/// and outUrl/outUrlLen with the URL string.
static BOOL detectUrlAtCell(int row, int col, int cols,
                            int *outStart, int *outEnd,
                            char *outUrl, int urlBufSize, int *outUrlLen) {
    if (!g_cells || cols <= 0) return NO;
    int base = row * cols;

    // Extract row text into a local buffer (ASCII portion is enough for URL detection).
    char rowText[1024];
    int len = cols < 1023 ? cols : 1023;
    for (int i = 0; i < len; i++) {
        uint32_t ch = g_cells[base + i].character;
        rowText[i] = (ch >= 32 && ch < 127) ? (char)ch : ' ';
    }
    rowText[len] = '\0';

    // Find all http:// or https:// occurrences in the row.
    const char *schemes[] = { "https://", "http://" };
    const int schemeLens[] = { 8, 7 };

    for (int s = 0; s < 2; s++) {
        const char *haystack = rowText;
        while (1) {
            const char *found = strstr(haystack, schemes[s]);
            if (!found) break;
            int startCol = (int)(found - rowText);
            int endCol = startCol + schemeLens[s];

            // Extend forward while URL-valid characters.
            while (endCol < len && isUrlChar(g_cells[base + endCol].character))
                endCol++;
            endCol--; // endCol is now the last valid column (inclusive).

            // Strip trailing punctuation that's unlikely part of the URL.
            while (endCol > startCol + schemeLens[s] && isTrailingPunct(g_cells[base + endCol].character))
                endCol--;

            // Handle matched parentheses: if URL ends before a ')' we already stripped,
            // but if there's a '(' inside the URL, allow the trailing ')'.
            // (Simple heuristic: count parens)
            {
                int opens = 0, closes = 0;
                for (int i = startCol; i <= endCol; i++) {
                    uint32_t ch = g_cells[base + i].character;
                    if (ch == '(') opens++;
                    if (ch == ')') closes++;
                }
                // If unbalanced closes, check if the next char is ')' and we can include it.
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
                return YES;
            }

            haystack = found + 1;
        }
    }
    return NO;
}

// --- Word boundary helpers for double-click selection ---

static BOOL isWordChar(uint32_t ch) {
    if (ch == 0 || ch == ' ') return NO;
    if (ch == '_' || ch == '-') return YES;
    if (ch > 127) return YES;
    if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')) return YES;
    return NO;
}

static void findWordBounds(int row, int col, int cols, int *outStart, int *outEnd) {
    if (!g_cells || cols <= 0) { *outStart = col; *outEnd = col; return; }
    int base = row * cols;
    uint32_t ch = g_cells[base + col].character;
    BOOL target = isWordChar(ch);

    int start = col;
    while (start > 0 && isWordChar(g_cells[base + start - 1].character) == target)
        start--;

    int end = col;
    while (end < cols - 1 && isWordChar(g_cells[base + end + 1].character) == target)
        end++;

    *outStart = start;
    *outEnd = end;
}

// --- Mouse: clicks ---

- (void)mouseDown:(NSEvent *)event {
    if (g_mouse_tracking && g_mouse_sgr) {
        int col, row;
        mouseCell(event, self, &col, &row);
        int btn = 0 | mouseModifiers(event.modifierFlags);
        sendSgrMouse(btn, col, row, YES);
        _leftDown = YES;
        _lastMouseCol = col;
        _lastMouseRow = row;
        return;
    }
    int col, row;
    mouseCell0(event, self, &col, &row);

    // Cmd+click opens hyperlink
    if (event.modifierFlags & NSEventModifierFlagCommand) {
        int cols = g_cols, rows_n = g_rows;
        if (g_cells && col >= 0 && col < cols && row >= 0 && row < rows_n) {
            // OSC 8 link takes priority
            uint32_t lid = g_cells[row * cols + col].link_id;
            if (lid != 0) {
                char uri_buf[2048];
                int uri_len = attyx_get_link_uri(lid, uri_buf, sizeof(uri_buf));
                if (uri_len > 0) {
                    NSString* urlStr = [[NSString alloc] initWithBytes:uri_buf
                                                               length:uri_len
                                                             encoding:NSUTF8StringEncoding];
                    if (urlStr) {
                        NSURL* url = [NSURL URLWithString:urlStr];
                        if (url) [[NSWorkspace sharedWorkspace] openURL:url];
                    }
                }
                return;
            }

            // Fallback: regex-detected URL
            int dStart, dEnd;
            char dUrl[DETECTED_URL_MAX];
            int dLen = 0;
            if (detectUrlAtCell(row, col, cols, &dStart, &dEnd, dUrl, DETECTED_URL_MAX, &dLen) && dLen > 0) {
                NSString* urlStr = [[NSString alloc] initWithBytes:dUrl
                                                           length:dLen
                                                         encoding:NSUTF8StringEncoding];
                if (urlStr) {
                    NSURL* url = [NSURL URLWithString:urlStr];
                    if (url) [[NSWorkspace sharedWorkspace] openURL:url];
                }
                return;
            }
        }
    }
    _clickCount = (int)event.clickCount;

    if (_clickCount >= 3) {
        // Triple-click: select entire row
        g_sel_start_row = row; g_sel_start_col = 0;
        g_sel_end_row = row;   g_sel_end_col = g_cols - 1;
        g_sel_active = 1;
        _selecting = YES;
    } else if (_clickCount == 2) {
        // Double-click: select word
        int wStart, wEnd;
        findWordBounds(row, col, g_cols, &wStart, &wEnd);
        g_sel_start_row = row; g_sel_start_col = wStart;
        g_sel_end_row = row;   g_sel_end_col = wEnd;
        g_sel_active = 1;
        _selecting = YES;
    } else {
        // Single click: start new selection
        g_sel_start_row = row; g_sel_start_col = col;
        g_sel_end_row = row;   g_sel_end_col = col;
        g_sel_active = 0;
        _selecting = YES;
    }
    attyx_mark_all_dirty();
}

- (void)mouseUp:(NSEvent *)event {
    _leftDown = NO;
    if (g_mouse_tracking && g_mouse_sgr) {
        int col, row;
        mouseCell(event, self, &col, &row);
        int btn = 0 | mouseModifiers(event.modifierFlags);
        sendSgrMouse(btn, col, row, NO);
        return;
    }
    if (_selecting) {
        _selecting = NO;
        if (g_sel_start_row != g_sel_end_row || g_sel_start_col != g_sel_end_col)
            g_sel_active = 1;
        else
            g_sel_active = 0;
    }
}

- (void)rightMouseDown:(NSEvent *)event {
    if (!g_mouse_tracking || !g_mouse_sgr) return;
    int col, row;
    mouseCell(event, self, &col, &row);
    int btn = 2 | mouseModifiers(event.modifierFlags);
    sendSgrMouse(btn, col, row, YES);
    _rightDown = YES;
    _lastMouseCol = col;
    _lastMouseRow = row;
}

- (void)rightMouseUp:(NSEvent *)event {
    _rightDown = NO;
    if (!g_mouse_tracking || !g_mouse_sgr) return;
    int col, row;
    mouseCell(event, self, &col, &row);
    int btn = 2 | mouseModifiers(event.modifierFlags);
    sendSgrMouse(btn, col, row, NO);
}

- (void)otherMouseDown:(NSEvent *)event {
    if (!g_mouse_tracking || !g_mouse_sgr) return;
    int col, row;
    mouseCell(event, self, &col, &row);
    int btn = 1 | mouseModifiers(event.modifierFlags);
    sendSgrMouse(btn, col, row, YES);
    _middleDown = YES;
    _lastMouseCol = col;
    _lastMouseRow = row;
}

- (void)otherMouseUp:(NSEvent *)event {
    _middleDown = NO;
    if (!g_mouse_tracking || !g_mouse_sgr) return;
    int col, row;
    mouseCell(event, self, &col, &row);
    int btn = 1 | mouseModifiers(event.modifierFlags);
    sendSgrMouse(btn, col, row, NO);
}

// --- Mouse: drag / motion ---

- (void)mouseDragged:(NSEvent *)event {
    if (g_mouse_tracking && g_mouse_sgr) {
        int tracking = g_mouse_tracking;
        if (tracking < 2) return;
        int col, row;
        mouseCell(event, self, &col, &row);
        if (col == _lastMouseCol && row == _lastMouseRow) return;
        int btn = 32 | mouseModifiers(event.modifierFlags);
        sendSgrMouse(btn, col, row, YES);
        _lastMouseCol = col;
        _lastMouseRow = row;
        return;
    }
    if (_selecting) {
        int col, row;
        mouseCell0(event, self, &col, &row);
        if (col == g_sel_end_col && row == g_sel_end_row) return;

        if (_clickCount >= 3) {
            // Triple-click drag: extend by whole rows
            g_sel_end_row = row;
            g_sel_end_col = (row >= g_sel_start_row) ? g_cols - 1 : 0;
            if (row < g_sel_start_row) g_sel_start_col = g_cols - 1;
            else g_sel_start_col = 0;
        } else if (_clickCount == 2) {
            // Double-click drag: extend by whole words
            int wStart, wEnd;
            findWordBounds(row, col, g_cols, &wStart, &wEnd);
            if (row > g_sel_start_row || (row == g_sel_start_row && col >= g_sel_start_col)) {
                g_sel_end_row = row;
                g_sel_end_col = wEnd;
            } else {
                g_sel_end_row = row;
                g_sel_end_col = wStart;
            }
        } else {
            g_sel_end_row = row;
            g_sel_end_col = col;
        }
        g_sel_active = 1;
        attyx_mark_all_dirty();
    }
}

- (void)rightMouseDragged:(NSEvent *)event {
    int tracking = g_mouse_tracking;
    if (!tracking || !g_mouse_sgr) return;
    if (tracking < 2) return;
    int col, row;
    mouseCell(event, self, &col, &row);
    if (col == _lastMouseCol && row == _lastMouseRow) return;
    int btn = (32 | 2) | mouseModifiers(event.modifierFlags);
    sendSgrMouse(btn, col, row, YES);
    _lastMouseCol = col;
    _lastMouseRow = row;
}

- (void)otherMouseDragged:(NSEvent *)event {
    int tracking = g_mouse_tracking;
    if (!tracking || !g_mouse_sgr) return;
    if (tracking < 2) return;
    int col, row;
    mouseCell(event, self, &col, &row);
    if (col == _lastMouseCol && row == _lastMouseRow) return;
    int btn = (32 | 1) | mouseModifiers(event.modifierFlags);
    sendSgrMouse(btn, col, row, YES);
    _lastMouseCol = col;
    _lastMouseRow = row;
}

- (void)mouseMoved:(NSEvent *)event {
    int tracking = g_mouse_tracking;
    if (tracking == 3 && g_mouse_sgr) {
        int col, row;
        mouseCell(event, self, &col, &row);
        if (col == _lastMouseCol && row == _lastMouseRow) return;
        int btn = 35 | mouseModifiers(event.modifierFlags);
        sendSgrMouse(btn, col, row, YES);
        _lastMouseCol = col;
        _lastMouseRow = row;
        return;
    }

    // Hyperlink hover detection (when mouse mode is off)
    if (!tracking) {
        int col, row;
        mouseCell0(event, self, &col, &row);
        int cols = g_cols, rows_n = g_rows;

        // 1) Check OSC 8 explicit link_id first
        uint32_t lid = 0;
        if (g_cells && col >= 0 && col < cols && row >= 0 && row < rows_n) {
            lid = g_cells[row * cols + col].link_id;
        }

        // 2) If no OSC 8 link, try regex URL detection
        int detStart = -1, detEnd = -1;
        char detUrlBuf[DETECTED_URL_MAX];
        int detUrlLen = 0;
        BOOL hasDetected = NO;
        if (lid == 0 && g_cells && col >= 0 && col < cols && row >= 0 && row < rows_n) {
            hasDetected = detectUrlAtCell(row, col, cols,
                                          &detStart, &detEnd,
                                          detUrlBuf, DETECTED_URL_MAX, &detUrlLen);
        }

        // Determine what changed
        BOOL isLink = (lid != 0 || hasDetected);
        int prevOscRow = g_hover_row;
        int prevDetRow = g_detected_url_row;
        int prevDetStart = g_detected_url_start_col;
        int prevDetEnd = g_detected_url_end_col;
        uint32_t prevLid = g_hover_link_id;

        BOOL oscChanged = (lid != prevLid);
        BOOL detChanged = NO;
        if (hasDetected) {
            detChanged = (row != prevDetRow || detStart != prevDetStart || detEnd != prevDetEnd);
        } else if (g_detected_url_len > 0) {
            detChanged = YES; // was detected, now isn't
        }

        if (oscChanged || detChanged) {
            // Update OSC 8 state
            g_hover_link_id = lid;
            g_hover_row = (lid != 0) ? row : -1;

            // Update detected URL state
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

            if (isLink) {
                [[NSCursor pointingHandCursor] set];
            } else {
                [[NSCursor IBeamCursor] set];
            }

            // Mark affected rows dirty for underline repaint
            if (prevOscRow >= 0 && prevOscRow < 256)
                __sync_fetch_and_or((volatile uint64_t*)&g_dirty[prevOscRow >> 6], (uint64_t)1 << (prevOscRow & 63));
            if (prevDetRow >= 0 && prevDetRow < 256)
                __sync_fetch_and_or((volatile uint64_t*)&g_dirty[prevDetRow >> 6], (uint64_t)1 << (prevDetRow & 63));
            if (row >= 0 && row < 256 && isLink)
                __sync_fetch_and_or((volatile uint64_t*)&g_dirty[row >> 6], (uint64_t)1 << (row & 63));
        }
    }
}

// --- Mouse: scroll wheel ---

- (void)scrollWheel:(NSEvent *)event {
    if (g_mouse_tracking && g_mouse_sgr) {
        CGFloat dy = event.scrollingDeltaY;
        if (event.hasPreciseScrollingDeltas) dy /= 3.0;
        if (dy == 0) return;
        int col, row;
        mouseCell(event, self, &col, &row);
        int btn = (dy > 0 ? 64 : 65) | mouseModifiers(event.modifierFlags);
        sendSgrMouse(btn, col, row, YES);
        return;
    }

    if (g_alt_screen) return;

    CGFloat dy = event.scrollingDeltaY;
    if (event.hasPreciseScrollingDeltas) {
        _scrollAccum += dy;
        CGFloat threshold = g_cell_pt_h > 0 ? g_cell_pt_h : 16.0;
        int lines = (int)(_scrollAccum / threshold);
        if (lines == 0) return;
        _scrollAccum -= lines * threshold;
        attyx_scroll_viewport(lines);
    } else {
        int lines = (int)dy;
        if (lines == 0) lines = (dy > 0) ? 1 : -1;
        attyx_scroll_viewport(lines);
    }
    if (g_sel_active) {
        g_sel_active = 0;
        attyx_mark_all_dirty();
    }
}

// Suppress system beep for unhandled keys
- (void)keyUp:(NSEvent *)event {}

/// Helper: snap viewport to bottom + clear selection on typing.
- (void)snapViewportAndClearSelection {
    if (g_viewport_offset != 0) {
        g_viewport_offset = 0;
        attyx_mark_all_dirty();
    }
    if (g_sel_active) {
        g_sel_active = 0;
        attyx_mark_all_dirty();
    }
}

/// Helper: send special/control keys directly to the PTY.
/// Returns YES if the key was handled (caller should return).
- (BOOL)handleSpecialKey:(NSEvent *)event {
    NSEventModifierFlags flags = event.modifierFlags;
    BOOL ctrl  = (flags & NSEventModifierFlagControl) != 0;
    BOOL alt   = (flags & NSEventModifierFlagOption) != 0;
    BOOL cmd   = (flags & NSEventModifierFlagCommand) != 0;
    BOOL shift = (flags & NSEventModifierFlagShift) != 0;

    if (cmd) {
        [super keyDown:event];
        return YES;
    }

    if (shift && !g_mouse_tracking && !g_alt_screen) {
        unsigned short kc = event.keyCode;
        if (kc == kVK_PageUp)   { attyx_scroll_viewport(g_rows); return YES; }
        if (kc == kVK_PageDown) { attyx_scroll_viewport(-g_rows); return YES; }
        if (kc == kVK_Home)     { g_viewport_offset = g_scrollback_count; attyx_mark_all_dirty(); return YES; }
        if (kc == kVK_End)      { g_viewport_offset = 0; attyx_mark_all_dirty(); return YES; }
    }

    unsigned short kc = event.keyCode;

    BOOL appMode = (g_cursor_keys_app != 0);
    const char* appUp    = "\x1bOA";
    const char* appDown  = "\x1bOB";
    const char* appRight = "\x1bOC";
    const char* appLeft  = "\x1bOD";
    const char* csiUp    = "\x1b[A";
    const char* csiDown  = "\x1b[B";
    const char* csiRight = "\x1b[C";
    const char* csiLeft  = "\x1b[D";

    switch (kc) {
        case kVK_UpArrow:    { const char* s = appMode ? appUp : csiUp;       attyx_send_input((const uint8_t*)s, 3); return YES; }
        case kVK_DownArrow:  { const char* s = appMode ? appDown : csiDown;   attyx_send_input((const uint8_t*)s, 3); return YES; }
        case kVK_RightArrow: { const char* s = appMode ? appRight : csiRight; attyx_send_input((const uint8_t*)s, 3); return YES; }
        case kVK_LeftArrow:  { const char* s = appMode ? appLeft : csiLeft;   attyx_send_input((const uint8_t*)s, 3); return YES; }
        case kVK_Return:        attyx_send_input((const uint8_t*)"\r", 1); return YES;
        case kVK_Delete:        attyx_send_input((const uint8_t*)"\x7f", 1); return YES;
        case kVK_Tab:           attyx_send_input((const uint8_t*)"\t", 1); return YES;
        case kVK_Escape:        attyx_send_input((const uint8_t*)"\x1b", 1); return YES;
        case kVK_Home:          attyx_send_input((const uint8_t*)"\x1b[H", 3); return YES;
        case kVK_End:           attyx_send_input((const uint8_t*)"\x1b[F", 3); return YES;
        case kVK_PageUp:        attyx_send_input((const uint8_t*)"\x1b[5~", 4); return YES;
        case kVK_PageDown:      attyx_send_input((const uint8_t*)"\x1b[6~", 4); return YES;
        case kVK_ForwardDelete: attyx_send_input((const uint8_t*)"\x1b[3~", 4); return YES;
        case kVK_Help:          attyx_send_input((const uint8_t*)"\x1b[2~", 4); return YES;
        case kVK_F1:  attyx_send_input((const uint8_t*)"\x1bOP",   3); return YES;
        case kVK_F2:  attyx_send_input((const uint8_t*)"\x1bOQ",   3); return YES;
        case kVK_F3:  attyx_send_input((const uint8_t*)"\x1bOR",   3); return YES;
        case kVK_F4:  attyx_send_input((const uint8_t*)"\x1bOS",   3); return YES;
        case kVK_F5:  attyx_send_input((const uint8_t*)"\x1b[15~", 5); return YES;
        case kVK_F6:  attyx_send_input((const uint8_t*)"\x1b[17~", 5); return YES;
        case kVK_F7:  attyx_send_input((const uint8_t*)"\x1b[18~", 5); return YES;
        case kVK_F8:  attyx_send_input((const uint8_t*)"\x1b[19~", 5); return YES;
        case kVK_F9:  attyx_send_input((const uint8_t*)"\x1b[20~", 5); return YES;
        case kVK_F10: attyx_send_input((const uint8_t*)"\x1b[21~", 5); return YES;
        case kVK_F11: attyx_send_input((const uint8_t*)"\x1b[23~", 5); return YES;
        case kVK_F12: attyx_send_input((const uint8_t*)"\x1b[24~", 5); return YES;
        default: break;
    }

    if (ctrl) {
        NSString* chars = event.charactersIgnoringModifiers;
        if (chars.length == 1) {
            unichar ch = [chars characterAtIndex:0];
            if (ch >= 'a' && ch <= 'z') { uint8_t b = (uint8_t)(ch - 'a' + 1); attyx_send_input(&b, 1); return YES; }
            if (ch >= 'A' && ch <= 'Z') { uint8_t b = (uint8_t)(ch - 'A' + 1); attyx_send_input(&b, 1); return YES; }
            if (ch == '[')  { attyx_send_input((const uint8_t*)"\x1b", 1); return YES; }
            if (ch == ']')  { uint8_t b = 0x1d; attyx_send_input(&b, 1); return YES; }
            if (ch == '\\') { uint8_t b = 0x1c; attyx_send_input(&b, 1); return YES; }
            if (ch == '^' || ch == '6') { uint8_t b = 0x1e; attyx_send_input(&b, 1); return YES; }
            if (ch == '_' || ch == '-') { uint8_t b = 0x1f; attyx_send_input(&b, 1); return YES; }
            if (ch == '@' || ch == ' ' || ch == '2') { uint8_t b = 0x00; attyx_send_input(&b, 1); return YES; }
        }
        return YES;
    }

    if (alt) {
        NSString* chars = event.charactersIgnoringModifiers;
        if (chars.length > 0) {
            const char* utf8 = [chars UTF8String];
            if (utf8) {
                uint8_t esc = 0x1b;
                attyx_send_input(&esc, 1);
                attyx_send_input((const uint8_t*)utf8, (int)strlen(utf8));
                return YES;
            }
        }
    }

    return NO;
}

- (void)keyDown:(NSEvent *)event {
    NSEventModifierFlags flags = event.modifierFlags;
    BOOL cmd   = (flags & NSEventModifierFlagCommand) != 0;
    BOOL shift = (flags & NSEventModifierFlagShift) != 0;
    unsigned short kc = event.keyCode;

    // Cmd+F toggles native search bar
    if (cmd && kc == 3 /* kVK_F */) {
        if (g_nativeSearchBar) [g_nativeSearchBar toggle];
        return;
    }

    // Cmd+G / Shift+Cmd+G — find next/prev (terminal has focus but search is active)
    if (cmd && kc == 5 /* kVK_G */ && g_search_active) {
        if (shift) {
            __sync_fetch_and_add((volatile int*)&g_search_nav_delta, -1);
        } else {
            __sync_fetch_and_add((volatile int*)&g_search_nav_delta, 1);
        }
        attyx_mark_all_dirty();
        return;
    }

    [self snapViewportAndClearSelection];

    // While composing, let the IME handle everything except Cmd shortcuts.
    if ([self hasMarkedText]) {
        if (cmd) {
            [super keyDown:event];
            return;
        }
        [self interpretKeyEvents:@[event]];
        return;
    }

    if ([self handleSpecialKey:event]) return;

    [self interpretKeyEvents:@[event]];
}

// ---------------------------------------------------------------------------
// NSTextInputClient — routes through macOS IME
// ---------------------------------------------------------------------------

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    NSString* text = ([string isKindOfClass:[NSAttributedString class]])
        ? [(NSAttributedString*)string string]
        : (NSString*)string;

    g_ime_composing = 0;
    g_ime_preedit_len = 0;
    _markedText.string = @"";
    _markedRange = NSMakeRange(NSNotFound, 0);
    _selectedRange = NSMakeRange(0, 0);
    attyx_mark_all_dirty();

    const char* utf8 = [text UTF8String];
    if (utf8 && strlen(utf8) > 0) {
        attyx_send_input((const uint8_t*)utf8, (int)strlen(utf8));
    }
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
    NSString* text = ([string isKindOfClass:[NSAttributedString class]])
        ? [(NSAttributedString*)string string]
        : (NSString*)string;

    if (text.length == 0) {
        [self unmarkText];
        return;
    }

    _markedText.string = text;
    _markedRange = NSMakeRange(0, text.length);
    _selectedRange = selectedRange;

    const char* utf8 = [text UTF8String];
    int len = utf8 ? (int)strlen(utf8) : 0;
    if (len > ATTYX_IME_MAX_BYTES - 1) len = ATTYX_IME_MAX_BYTES - 1;

    if (!g_ime_composing) {
        g_ime_anchor_row = g_cursor_row;
        g_ime_anchor_col = g_cursor_col;
    }

    memcpy(g_ime_preedit, utf8, len);
    g_ime_preedit[len] = '\0';
    g_ime_preedit_len = len;
    g_ime_cursor_index = (selectedRange.location != NSNotFound) ? (int)selectedRange.location : -1;
    g_ime_composing = 1;
    attyx_mark_all_dirty();
}

- (void)unmarkText {
    _markedText.string = @"";
    _markedRange = NSMakeRange(NSNotFound, 0);
    _selectedRange = NSMakeRange(0, 0);
    g_ime_composing = 0;
    g_ime_preedit_len = 0;
    attyx_mark_all_dirty();
}

- (BOOL)hasMarkedText {
    return (_markedRange.location != NSNotFound && _markedRange.length > 0);
}

- (NSRange)markedRange {
    return _markedRange;
}

- (NSRange)selectedRange {
    return _selectedRange;
}

- (NSAttributedString*)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    return nil;
}

- (NSArray<NSAttributedStringKey>*)validAttributesForMarkedText {
    return @[];
}

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    int row = g_ime_composing ? g_ime_anchor_row : g_cursor_row;
    int col = g_ime_composing ? g_ime_anchor_col : g_cursor_col;

    NSRect cellRect = NSMakeRect(col * g_cell_pt_w, (row + 1) * g_cell_pt_h, g_cell_pt_w, g_cell_pt_h);
    NSRect screenRect = [self.window convertRectToScreen:[self convertRect:cellRect toView:nil]];
    return screenRect;
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
    return NSNotFound;
}

- (void)doCommandBySelector:(SEL)selector {
    if (selector == @selector(insertNewline:)) {
        attyx_send_input((const uint8_t*)"\r", 1);
    } else if (selector == @selector(insertTab:)) {
        attyx_send_input((const uint8_t*)"\t", 1);
    } else if (selector == @selector(cancelOperation:)) {
        attyx_send_input((const uint8_t*)"\x1b", 1);
    } else if (selector == @selector(deleteBackward:)) {
        attyx_send_input((const uint8_t*)"\x7f", 1);
    } else {
        [super doCommandBySelector:selector];
    }
}

// --- Paste (Cmd+V) ---
- (void)paste:(id)sender {
    NSPasteboard* pb = [NSPasteboard generalPasteboard];
    NSString* text = [pb stringForType:NSPasteboardTypeString];
    if (!text || text.length == 0) return;

    const char* utf8 = [text UTF8String];
    if (!utf8) return;
    int len = (int)strlen(utf8);

    if (g_bracketed_paste) {
        attyx_send_input((const uint8_t*)"\x1b[200~", 6);
        attyx_send_input((const uint8_t*)utf8, len);
        attyx_send_input((const uint8_t*)"\x1b[201~", 6);
    } else {
        attyx_send_input((const uint8_t*)utf8, len);
    }
}

// --- Copy (Cmd+C) ---
- (void)copy:(id)sender {
    if (!g_sel_active) return;

    int sr = g_sel_start_row, sc = g_sel_start_col;
    int er = g_sel_end_row,   ec = g_sel_end_col;
    if (sr > er || (sr == er && sc > ec)) {
        int tr = sr, tc = sc;
        sr = er; sc = ec;
        er = tr; ec = tc;
    }

    int cols = g_cols;
    int rows = g_rows;
    if (cols <= 0 || rows <= 0) return;

    NSMutableString* result = [NSMutableString string];

    // Read from the cell snapshot that the renderer also uses.
    // Take a stable copy of the generation counter to avoid torn reads.
    uint64_t gen;
    do { gen = g_cell_gen; } while (gen & 1);

    for (int row = sr; row <= er && row < rows; row++) {
        int cStart = (row == sr) ? sc : 0;
        int cEnd   = (row == er) ? ec : cols - 1;
        if (cStart >= cols) cStart = cols - 1;
        if (cEnd >= cols) cEnd = cols - 1;

        // Find last non-space to trim trailing whitespace
        int lastNonSpace = cStart - 1;
        for (int c = cEnd; c >= cStart; c--) {
            int idx = row * cols + c;
            uint32_t ch = g_cells[idx].character;
            if (ch > 32) { lastNonSpace = c; break; }
        }

        for (int c = cStart; c <= lastNonSpace; c++) {
            int idx = row * cols + c;
            uint32_t ch = g_cells[idx].character;
            if (ch == 0 || ch == ' ') {
                [result appendString:@" "];
            } else {
                unichar u = (unichar)ch;
                if (ch > 0xFFFF) {
                    // Encode as surrogate pair
                    uint32_t cp = ch - 0x10000;
                    unichar hi = (unichar)(0xD800 + (cp >> 10));
                    unichar lo = (unichar)(0xDC00 + (cp & 0x3FF));
                    unichar pair[2] = {hi, lo};
                    [result appendString:[NSString stringWithCharacters:pair length:2]];
                } else {
                    [result appendString:[NSString stringWithCharacters:&u length:1]];
                }
            }
        }

        if (row < er) [result appendString:@"\n"];
    }

    if (result.length > 0) {
        NSPasteboard* pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setString:result forType:NSPasteboardTypeString];
    }
}

@end

// ---------------------------------------------------------------------------
// App Delegate
// ---------------------------------------------------------------------------

@interface AttyxAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (nonatomic, strong) NSWindow* window;
@property (nonatomic, strong) AttyxRenderer* renderer;
@end

@implementation AttyxAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        NSLog(@"Metal is not supported on this machine");
        [NSApp terminate:nil];
        return;
    }

    CGFloat scaleFactor = [NSScreen mainScreen].backingScaleFactor;
    GlyphCache gc = createGlyphCache(device, scaleFactor);

    // Cell size in points (used for window snapping).
    g_cell_pt_w = gc.glyph_w / gc.scale;
    g_cell_pt_h = gc.glyph_h / gc.scale;

    CGFloat winW = g_cols * g_cell_pt_w;
    CGFloat winH = g_rows * g_cell_pt_h;

    NSRect frame = NSMakeRect(200, 200, winW, winH);
    NSUInteger mask = NSWindowStyleMaskTitled
                    | NSWindowStyleMaskClosable
                    | NSWindowStyleMaskMiniaturizable
                    | NSWindowStyleMaskResizable;

    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:mask
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    [_window setTitle:@"Attyx"];
    [_window setDelegate:self];
    [_window setAcceptsMouseMovedEvents:YES];

    AttyxView* termView = [[AttyxView alloc] initWithFrame:frame device:device];
    termView.layer.contentsScale = scaleFactor;
    termView.layerContentsPlacement = NSViewLayerContentsPlacementTopLeft;
    ((CAMetalLayer*)termView.layer).presentsWithTransaction = YES;
    termView.clearColor = MTLClearColorMake(0.118, 0.118, 0.141, 1.0);
    termView.preferredFramesPerSecond = 60;

    _renderer = [[AttyxRenderer alloc] initWithDevice:device
                                                 view:termView
                                           glyphCache:gc];
    termView.delegate = _renderer;

    [_window setContentView:termView];
    [_window makeKeyAndOrderFront:nil];
    [_window makeFirstResponder:termView];
    [NSApp activateIgnoringOtherApps:YES];

    g_nativeSearchBar = [[AttyxSearchBar alloc] initForTermView:termView];
}

- (NSSize)windowWillResize:(NSWindow*)sender toSize:(NSSize)frameSize {
    if (g_cell_pt_w <= 0 || g_cell_pt_h <= 0) return frameSize;

    NSRect frameRect = NSMakeRect(0, 0, frameSize.width, frameSize.height);
    NSRect contentRect = [sender contentRectForFrameRect:frameRect];

    int snappedCols = (int)(contentRect.size.width  / g_cell_pt_w);
    int snappedRows = (int)(contentRect.size.height / g_cell_pt_h);
    if (snappedCols < 1) snappedCols = 1;
    if (snappedRows < 1) snappedRows = 1;
    if (snappedCols > ATTYX_MAX_COLS) snappedCols = ATTYX_MAX_COLS;
    if (snappedRows > ATTYX_MAX_ROWS) snappedRows = ATTYX_MAX_ROWS;

    contentRect.size.width  = snappedCols * g_cell_pt_w;
    contentRect.size.height = snappedRows * g_cell_pt_h;

    NSRect snappedFrame = [sender frameRectForContentRect:contentRect];
    return snappedFrame.size;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    return YES;
}

- (void)applicationWillTerminate:(NSNotification*)notification {
    g_should_quit = 1;
}

@end

// ---------------------------------------------------------------------------
// C entry point called from Zig
// ---------------------------------------------------------------------------

void attyx_run(AttyxCell* cells, int cols, int rows) {
    g_cells = cells;
    g_cols  = cols;
    g_rows  = rows;

    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        NSMenu* menuBar = [[NSMenu alloc] init];
        NSMenuItem* appMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:appMenuItem];
        NSMenu* appMenu = [[NSMenu alloc] init];
        [appMenu addItemWithTitle:@"Quit Attyx"
                           action:@selector(terminate:)
                    keyEquivalent:@"q"];
        [appMenuItem setSubmenu:appMenu];

        // Edit menu for Cmd+V paste support
        NSMenuItem* editMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:editMenuItem];
        NSMenu* editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
        [editMenu addItemWithTitle:@"Copy"
                            action:@selector(copy:)
                     keyEquivalent:@"c"];
        [editMenu addItemWithTitle:@"Paste"
                            action:@selector(paste:)
                     keyEquivalent:@"v"];
        [editMenuItem setSubmenu:editMenu];

        [app setMainMenu:menuBar];

        AttyxAppDelegate* delegate = [[AttyxAppDelegate alloc] init];
        [app setDelegate:delegate];
        [app run];
    }
}
