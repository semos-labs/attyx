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
static volatile int g_cursor_row = 0;
static volatile int g_cursor_col = 0;
static volatile int g_should_quit = 0;

// Mode flags (written by PTY thread, read by key handler on main thread)
static volatile int g_bracketed_paste = 0;
static volatile int g_cursor_keys_app = 0;

// Row-level dirty bitset (256 rows). PTY thread atomic-ORs in dirty bits;
// renderer atomically swaps each word to zero when snapshotting.
static volatile uint64_t g_dirty[4] = {0,0,0,0};

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

void attyx_set_dirty(const uint64_t dirty[4]) {
    for (int i = 0; i < 4; i++)
        __sync_fetch_and_or((volatile uint64_t*)&g_dirty[i], dirty[i]);
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
    memset(&gc, 0, sizeof(gc));
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
// Renderer (MTKViewDelegate)
// ---------------------------------------------------------------------------

@interface AttyxRenderer : NSObject <MTKViewDelegate> {
    GlyphCache _glyphCache;
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

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size {}

- (void)drawInMTKView:(MTKView*)view {
    if (!g_cells || g_cols <= 0 || g_rows <= 0) return;

    @autoreleasepool {
        int total = g_cols * g_rows;

        // Snapshot shared state so we work from a consistent copy.
        // The PTY thread can modify g_cells concurrently; without this
        // copy, the textCount measured in the first pass can disagree
        // with the characters seen in the second pass, causing a heap
        // buffer overflow in the vertex arrays.
        AttyxCell* cells = (AttyxCell*)malloc(sizeof(AttyxCell) * total);
        if (!cells) return;
        memcpy(cells, g_cells, sizeof(AttyxCell) * total);
        int curRow = g_cursor_row;
        int curCol = g_cursor_col;

        CGSize drawableSize = view.drawableSize;
        float scaleX = (float)drawableSize.width  / (g_cols * _glyphCache.glyph_w);
        float scaleY = (float)drawableSize.height / (g_rows * _glyphCache.glyph_h);
        float gw = _glyphCache.glyph_w * scaleX;
        float gh = _glyphCache.glyph_h * scaleY;
        float viewport[2] = { (float)drawableSize.width, (float)drawableSize.height };

        // Allocate max possible text vertices (every cell could have a glyph).
        size_t bgSize   = sizeof(Vertex) * (size_t)((total + 1) * 6);
        size_t textSize = sizeof(Vertex) * (size_t)(total * 6);

        Vertex* bgVerts   = (Vertex*)malloc(bgSize);
        Vertex* textVerts = (Vertex*)malloc(textSize);
        int ti = 0;

        float atlasW = (float)_glyphCache.atlas_w;
        float glyphW = _glyphCache.glyph_w;
        float glyphH = _glyphCache.glyph_h;
        int atlasCols = _glyphCache.atlas_cols;

        for (int i = 0; i < total; i++) {
            int row = i / g_cols;
            int col = i % g_cols;
            float x0 = col * gw;
            float y0 = row * gh;
            float x1 = x0 + gw;
            float y1 = y0 + gh;
            const AttyxCell* cell = &cells[i];

            float br = cell->bg_r / 255.0f;
            float bg = cell->bg_g / 255.0f;
            float bb = cell->bg_b / 255.0f;

            int bi = i * 6;
            bgVerts[bi+0] = (Vertex){ x0, y0, 0,0, br,bg,bb,1 };
            bgVerts[bi+1] = (Vertex){ x1, y0, 0,0, br,bg,bb,1 };
            bgVerts[bi+2] = (Vertex){ x0, y1, 0,0, br,bg,bb,1 };
            bgVerts[bi+3] = (Vertex){ x1, y0, 0,0, br,bg,bb,1 };
            bgVerts[bi+4] = (Vertex){ x1, y1, 0,0, br,bg,bb,1 };
            bgVerts[bi+5] = (Vertex){ x0, y1, 0,0, br,bg,bb,1 };

            uint32_t ch = cell->character;
            if (ch > 32) {
                int slot = glyphCacheLookup(&_glyphCache, ch);
                if (slot < 0) {
                    slot = glyphCacheRasterize(&_glyphCache, ch);
                    // Atlas may have grown — re-read dimensions.
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

                textVerts[ti+0] = (Vertex){ x0,y0, au0,av0, fr,fg,fb,1 };
                textVerts[ti+1] = (Vertex){ x1,y0, au1,av0, fr,fg,fb,1 };
                textVerts[ti+2] = (Vertex){ x0,y1, au0,av1, fr,fg,fb,1 };
                textVerts[ti+3] = (Vertex){ x1,y0, au1,av0, fr,fg,fb,1 };
                textVerts[ti+4] = (Vertex){ x1,y1, au1,av1, fr,fg,fb,1 };
                textVerts[ti+5] = (Vertex){ x0,y1, au0,av1, fr,fg,fb,1 };
                ti += 6;
            }
        }
        int textCount = ti / 6;

        int bgVertCount = total * 6;
        if (curRow >= 0 && curRow < g_rows && curCol >= 0 && curCol < g_cols) {
            float cx0 = curCol * gw;
            float cy0 = curRow * gh;
            float cx1 = cx0 + gw;
            float cy1 = cy0 + gh;
            float cr = 0.86f, cg = 0.86f, cb = 0.86f;

            int ci = total * 6;
            bgVerts[ci+0] = (Vertex){ cx0,cy0, 0,0, cr,cg,cb,1 };
            bgVerts[ci+1] = (Vertex){ cx1,cy0, 0,0, cr,cg,cb,1 };
            bgVerts[ci+2] = (Vertex){ cx0,cy1, 0,0, cr,cg,cb,1 };
            bgVerts[ci+3] = (Vertex){ cx1,cy0, 0,0, cr,cg,cb,1 };
            bgVerts[ci+4] = (Vertex){ cx1,cy1, 0,0, cr,cg,cb,1 };
            bgVerts[ci+5] = (Vertex){ cx0,cy1, 0,0, cr,cg,cb,1 };
            bgVertCount += 6;
        }

        id<MTLBuffer> bgBuf = [_device newBufferWithBytes:bgVerts
                                                   length:sizeof(Vertex) * bgVertCount
                                                  options:MTLResourceStorageModeShared];
        id<MTLBuffer> textBuf = nil;
        if (ti > 0) {
            textBuf = [_device newBufferWithBytes:textVerts
                                          length:sizeof(Vertex) * ti
                                         options:MTLResourceStorageModeShared];
        }
        free(bgVerts);
        free(textVerts);

        id<MTLCommandBuffer> cmdBuf = [_cmdQueue commandBuffer];
        MTLRenderPassDescriptor* rpd = view.currentRenderPassDescriptor;
        if (!rpd) { free(cells); return; }

        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0.118, 0.118, 0.141, 1.0);

        id<MTLRenderCommandEncoder> enc =
            [cmdBuf renderCommandEncoderWithDescriptor:rpd];

        [enc setRenderPipelineState:_bgPipeline];
        [enc setVertexBuffer:bgBuf  offset:0 atIndex:0];
        [enc setVertexBytes:viewport length:sizeof(viewport) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                vertexCount:bgVertCount];

        if (textBuf) {
            [enc setRenderPipelineState:_textPipeline];
            [enc setVertexBuffer:textBuf offset:0 atIndex:0];
            [enc setVertexBytes:viewport length:sizeof(viewport) atIndex:1];
            [enc setFragmentTexture:_glyphCache.texture atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                    vertexCount:ti];
        }

        [enc endEncoding];
        [cmdBuf presentDrawable:view.currentDrawable];
        [cmdBuf commit];
        free(cells);
    }
}

@end

// ---------------------------------------------------------------------------
// Terminal view — MTKView subclass that handles keyboard + paste
// ---------------------------------------------------------------------------

@interface AttyxView : MTKView
@end

@implementation AttyxView

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder  { return YES; }

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

@interface AttyxAppDelegate : NSObject <NSApplicationDelegate>
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

    // Window frame is in points; glyph dims are in pixels (points * scale).
    CGFloat winW = g_cols * gc.glyph_w / gc.scale;
    CGFloat winH = g_rows * gc.glyph_h / gc.scale;

    NSRect frame = NSMakeRect(200, 200, winW, winH);
    NSUInteger mask = NSWindowStyleMaskTitled
                    | NSWindowStyleMaskClosable
                    | NSWindowStyleMaskMiniaturizable;

    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:mask
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    [_window setTitle:@"Attyx"];

    AttyxView* termView = [[AttyxView alloc] initWithFrame:frame device:device];
    termView.layer.contentsScale = scaleFactor;
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
