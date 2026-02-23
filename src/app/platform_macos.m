// Attyx — macOS platform layer (Cocoa + Metal + Core Text)
// Renders a live terminal grid and handles keyboard input.

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <CoreText/CoreText.h>
#import <Carbon/Carbon.h>  // kVK_* virtual key codes

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
// Dirty-bitset helpers (mirrors DirtyRows from Zig)
// ---------------------------------------------------------------------------

static inline int dirtyBitTest(const uint64_t dirty[4], int row) {
    if (row < 0 || row >= 256) return 0;
    return (dirty[row >> 6] >> (row & 63)) & 1;
}

static inline int dirtyAny(const uint64_t dirty[4]) {
    return (dirty[0] | dirty[1] | dirty[2] | dirty[3]) != 0;
}

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
    _prevCursorRow    = -1;
    _prevCursorCol    = -1;
    _fullRedrawNeeded = YES;
    _allocRows        = 0;
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
        d.colorAttachments[0].pixelFormat = view.colorPixelFormat;
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
        BOOL cursorMoved = (curRow != _prevCursorRow || curCol != _prevCursorCol);

        // --- Reallocate persistent buffers if grid size changed ---
        if (rows != _allocRows || cols != _allocCols) {
            free(_bgVerts);
            free(_textVerts);
            free(_cellSnapshot);

            int bgVertCap = (total + cols) * 6; // +cols for cursor row
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

        // --- Frame skip: nothing dirty, cursor didn't move ---
        if (!_fullRedrawNeeded && !dirtyAny(dirty) && !cursorMoved) {
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

                float br = cell->bg_r / 255.0f;
                float bg = cell->bg_g / 255.0f;
                float bb = cell->bg_b / 255.0f;

                int bi = i * 6;
                _bgVerts[bi+0] = (Vertex){ x0, y0, 0,0, br,bg,bb,1 };
                _bgVerts[bi+1] = (Vertex){ x1, y0, 0,0, br,bg,bb,1 };
                _bgVerts[bi+2] = (Vertex){ x0, y1, 0,0, br,bg,bb,1 };
                _bgVerts[bi+3] = (Vertex){ x1, y0, 0,0, br,bg,bb,1 };
                _bgVerts[bi+4] = (Vertex){ x1, y1, 0,0, br,bg,bb,1 };
                _bgVerts[bi+5] = (Vertex){ x0, y1, 0,0, br,bg,bb,1 };
            }
        }

        // --- Update cursor quad in bg vertices ---
        int cursorSlot = total * 6;
        memset(&_bgVerts[cursorSlot], 0, sizeof(Vertex) * 6);

        int bgVertCount = total * 6;
        if (curRow >= 0 && curRow < rows && curCol >= 0 && curCol < cols) {
            float cx0 = curCol * gw;
            float cy0 = curRow * gh;
            float cx1 = cx0 + gw;
            float cy1 = cy0 + gh;
            float cr = 0.86f, cg = 0.86f, cb = 0.86f;

            _bgVerts[cursorSlot+0] = (Vertex){ cx0,cy0, 0,0, cr,cg,cb,1 };
            _bgVerts[cursorSlot+1] = (Vertex){ cx1,cy0, 0,0, cr,cg,cb,1 };
            _bgVerts[cursorSlot+2] = (Vertex){ cx0,cy1, 0,0, cr,cg,cb,1 };
            _bgVerts[cursorSlot+3] = (Vertex){ cx1,cy0, 0,0, cr,cg,cb,1 };
            _bgVerts[cursorSlot+4] = (Vertex){ cx1,cy1, 0,0, cr,cg,cb,1 };
            _bgVerts[cursorSlot+5] = (Vertex){ cx0,cy1, 0,0, cr,cg,cb,1 };
            bgVertCount += 6;
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

        _prevCursorRow = curRow;
        _prevCursorCol = curCol;
        _fullRedrawNeeded = NO;

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

@interface AttyxView : MTKView {
    int _lastMouseCol;
    int _lastMouseRow;
    BOOL _leftDown;
    BOOL _rightDown;
    BOOL _middleDown;
}
@end

@implementation AttyxView

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

// --- Mouse: clicks ---

- (void)mouseDown:(NSEvent *)event {
    if (!g_mouse_tracking || !g_mouse_sgr) return;
    int col, row;
    mouseCell(event, self, &col, &row);
    int btn = 0 | mouseModifiers(event.modifierFlags);
    sendSgrMouse(btn, col, row, YES);
    _leftDown = YES;
    _lastMouseCol = col;
    _lastMouseRow = row;
}

- (void)mouseUp:(NSEvent *)event {
    _leftDown = NO;
    if (!g_mouse_tracking || !g_mouse_sgr) return;
    int col, row;
    mouseCell(event, self, &col, &row);
    int btn = 0 | mouseModifiers(event.modifierFlags);
    sendSgrMouse(btn, col, row, NO);
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
    int tracking = g_mouse_tracking;
    if (!tracking || !g_mouse_sgr) return;
    if (tracking < 2) return; // x10 has no motion
    int col, row;
    mouseCell(event, self, &col, &row);
    if (col == _lastMouseCol && row == _lastMouseRow) return;
    int btn = 32 | mouseModifiers(event.modifierFlags);
    sendSgrMouse(btn, col, row, YES);
    _lastMouseCol = col;
    _lastMouseRow = row;
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
    if (tracking != 3 || !g_mouse_sgr) return; // any_event only
    int col, row;
    mouseCell(event, self, &col, &row);
    if (col == _lastMouseCol && row == _lastMouseRow) return;
    int btn = 35 | mouseModifiers(event.modifierFlags); // 32 + 3 (no button)
    sendSgrMouse(btn, col, row, YES);
    _lastMouseCol = col;
    _lastMouseRow = row;
}

// --- Mouse: scroll wheel ---

- (void)scrollWheel:(NSEvent *)event {
    if (!g_mouse_tracking || !g_mouse_sgr) return;
    CGFloat dy = event.scrollingDeltaY;
    if (event.hasPreciseScrollingDeltas) dy /= 3.0;
    if (dy == 0) return;
    int col, row;
    mouseCell(event, self, &col, &row);
    int btn = (dy > 0 ? 64 : 65) | mouseModifiers(event.modifierFlags);
    sendSgrMouse(btn, col, row, YES);
}

// Suppress system beep for unhandled keys
- (void)keyUp:(NSEvent *)event {}

- (void)keyDown:(NSEvent *)event {
    NSEventModifierFlags flags = event.modifierFlags;
    BOOL ctrl = (flags & NSEventModifierFlagControl) != 0;
    BOOL alt  = (flags & NSEventModifierFlagOption) != 0;
    BOOL cmd  = (flags & NSEventModifierFlagCommand) != 0;

    if (cmd) {
        // Cmd+V → paste (handled by the responder chain via paste:)
        // Cmd+Q → quit (handled by the menu)
        [super keyDown:event];
        return;
    }

    unsigned short kc = event.keyCode;

    // --- Special keys (by virtual keycode) ---

    // Arrow keys: DECCKM switches between CSI and SS3
    const char* appUp    = "\x1bOA";
    const char* appDown  = "\x1bOB";
    const char* appRight = "\x1bOC";
    const char* appLeft  = "\x1bOD";
    const char* csiUp    = "\x1b[A";
    const char* csiDown  = "\x1b[B";
    const char* csiRight = "\x1b[C";
    const char* csiLeft  = "\x1b[D";
    BOOL appMode = (g_cursor_keys_app != 0);

    switch (kc) {
        case kVK_UpArrow: {
            const char* s = appMode ? appUp : csiUp;
            attyx_send_input((const uint8_t*)s, 3);
            return;
        }
        case kVK_DownArrow: {
            const char* s = appMode ? appDown : csiDown;
            attyx_send_input((const uint8_t*)s, 3);
            return;
        }
        case kVK_RightArrow: {
            const char* s = appMode ? appRight : csiRight;
            attyx_send_input((const uint8_t*)s, 3);
            return;
        }
        case kVK_LeftArrow: {
            const char* s = appMode ? appLeft : csiLeft;
            attyx_send_input((const uint8_t*)s, 3);
            return;
        }
        case kVK_Return:
            attyx_send_input((const uint8_t*)"\r", 1);
            return;
        case kVK_Delete:  // Backspace
            attyx_send_input((const uint8_t*)"\x7f", 1);
            return;
        case kVK_Tab:
            attyx_send_input((const uint8_t*)"\t", 1);
            return;
        case kVK_Escape:
            attyx_send_input((const uint8_t*)"\x1b", 1);
            return;
        case kVK_Home:
            attyx_send_input((const uint8_t*)"\x1b[H", 3);
            return;
        case kVK_End:
            attyx_send_input((const uint8_t*)"\x1b[F", 3);
            return;
        case kVK_PageUp:
            attyx_send_input((const uint8_t*)"\x1b[5~", 4);
            return;
        case kVK_PageDown:
            attyx_send_input((const uint8_t*)"\x1b[6~", 4);
            return;
        case kVK_ForwardDelete:
            attyx_send_input((const uint8_t*)"\x1b[3~", 4);
            return;
        case kVK_Help:  // Insert on extended keyboards
            attyx_send_input((const uint8_t*)"\x1b[2~", 4);
            return;
        case kVK_F1:  attyx_send_input((const uint8_t*)"\x1bOP",   3); return;
        case kVK_F2:  attyx_send_input((const uint8_t*)"\x1bOQ",   3); return;
        case kVK_F3:  attyx_send_input((const uint8_t*)"\x1bOR",   3); return;
        case kVK_F4:  attyx_send_input((const uint8_t*)"\x1bOS",   3); return;
        case kVK_F5:  attyx_send_input((const uint8_t*)"\x1b[15~", 5); return;
        case kVK_F6:  attyx_send_input((const uint8_t*)"\x1b[17~", 5); return;
        case kVK_F7:  attyx_send_input((const uint8_t*)"\x1b[18~", 5); return;
        case kVK_F8:  attyx_send_input((const uint8_t*)"\x1b[19~", 5); return;
        case kVK_F9:  attyx_send_input((const uint8_t*)"\x1b[20~", 5); return;
        case kVK_F10: attyx_send_input((const uint8_t*)"\x1b[21~", 5); return;
        case kVK_F11: attyx_send_input((const uint8_t*)"\x1b[23~", 5); return;
        case kVK_F12: attyx_send_input((const uint8_t*)"\x1b[24~", 5); return;
        default:
            break;
    }

    // --- Ctrl+key → control codes 0x01..0x1A ---
    if (ctrl) {
        NSString* chars = event.charactersIgnoringModifiers;
        if (chars.length == 1) {
            unichar ch = [chars characterAtIndex:0];
            if (ch >= 'a' && ch <= 'z') {
                uint8_t b = (uint8_t)(ch - 'a' + 1);
                attyx_send_input(&b, 1);
                return;
            }
            if (ch >= 'A' && ch <= 'Z') {
                uint8_t b = (uint8_t)(ch - 'A' + 1);
                attyx_send_input(&b, 1);
                return;
            }
            // Ctrl+[ = ESC, Ctrl+] = GS, Ctrl+\ = FS, Ctrl+^ = RS, Ctrl+_ = US
            if (ch == '[') { attyx_send_input((const uint8_t*)"\x1b", 1); return; }
            if (ch == ']') { uint8_t b = 0x1d; attyx_send_input(&b, 1); return; }
            if (ch == '\\') { uint8_t b = 0x1c; attyx_send_input(&b, 1); return; }
            if (ch == '^' || ch == '6') { uint8_t b = 0x1e; attyx_send_input(&b, 1); return; }
            if (ch == '_' || ch == '-') { uint8_t b = 0x1f; attyx_send_input(&b, 1); return; }
            if (ch == '@' || ch == ' ' || ch == '2') { uint8_t b = 0x00; attyx_send_input(&b, 1); return; }
        }
    }

    // --- Alt/Option+key → ESC prefix ---
    if (alt) {
        NSString* chars = event.charactersIgnoringModifiers;
        if (chars.length > 0) {
            const char* utf8 = [chars UTF8String];
            if (utf8) {
                uint8_t esc = 0x1b;
                attyx_send_input(&esc, 1);
                attyx_send_input((const uint8_t*)utf8, (int)strlen(utf8));
                return;
            }
        }
    }

    // --- Regular text input ---
    NSString* chars = event.characters;
    if (chars.length > 0) {
        const char* utf8 = [chars UTF8String];
        if (utf8 && strlen(utf8) > 0) {
            attyx_send_input((const uint8_t*)utf8, (int)strlen(utf8));
        }
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
