// Attyx — macOS Metal renderer (MTKViewDelegate)

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CABase.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include "macos_internal.h"
#include "macos_renderer_private.h"

// ---------------------------------------------------------------------------
// Emit helpers (shared with search bar)
// ---------------------------------------------------------------------------

int emitRect(Vertex* v, int i, float x, float y, float w, float h,
             float r, float g, float b, float a) {
    v[i+0] = (Vertex){ x,   y,   0,0, r,g,b,a };
    v[i+1] = (Vertex){ x+w, y,   0,0, r,g,b,a };
    v[i+2] = (Vertex){ x,   y+h, 0,0, r,g,b,a };
    v[i+3] = (Vertex){ x+w, y,   0,0, r,g,b,a };
    v[i+4] = (Vertex){ x+w, y+h, 0,0, r,g,b,a };
    v[i+5] = (Vertex){ x,   y+h, 0,0, r,g,b,a };
    return i + 6;
}

int emitGlyph(Vertex* v, int i, GlyphCache* gc, uint32_t cp,
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

int emitString(Vertex* v, int i, GlyphCache* gc,
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
// AttyxRenderer
// ---------------------------------------------------------------------------

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
    _colorVerts       = NULL;
    _totalColorVerts  = 0;
    _bgMetalBuf       = nil;
    _textMetalBuf     = nil;
    _colorMetalBuf    = nil;
    _metalBufCapBg    = 0;
    _metalBufCapText  = 0;
    _metalBufCapColor = 0;
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
    _allocCols          = 0;

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

    id<MTLFunction> vertFn    = [lib newFunctionWithName:@"vert_main"];
    id<MTLFunction> fragSolid = [lib newFunctionWithName:@"frag_solid"];
    id<MTLFunction> fragText  = [lib newFunctionWithName:@"frag_text"];

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

    id<MTLFunction> fragColorText = [lib newFunctionWithName:@"frag_color_text"];
    {
        MTLRenderPipelineDescriptor* d = [[MTLRenderPipelineDescriptor alloc] init];
        d.vertexFunction   = vertFn;
        d.fragmentFunction = fragColorText;
        d.colorAttachments[0].pixelFormat              = view.colorPixelFormat;
        d.colorAttachments[0].blendingEnabled           = YES;
        d.colorAttachments[0].sourceRGBBlendFactor      = MTLBlendFactorOne;
        d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        d.colorAttachments[0].sourceAlphaBlendFactor    = MTLBlendFactorOne;
        d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        _colorPipeline = [device newRenderPipelineStateWithDescriptor:d error:&err];
        if (!_colorPipeline) { NSLog(@"Color pipeline: %@", err); return nil; }
    }

    id<MTLFunction> fragImage = [lib newFunctionWithName:@"frag_image"];
    {
        MTLRenderPipelineDescriptor* d = [[MTLRenderPipelineDescriptor alloc] init];
        d.vertexFunction   = vertFn;
        d.fragmentFunction = fragImage;
        d.colorAttachments[0].pixelFormat              = view.colorPixelFormat;
        d.colorAttachments[0].blendingEnabled           = YES;
        d.colorAttachments[0].sourceRGBBlendFactor      = MTLBlendFactorSourceAlpha;
        d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        d.colorAttachments[0].sourceAlphaBlendFactor    = MTLBlendFactorOne;
        d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        _imagePipeline = [device newRenderPipelineStateWithDescriptor:d error:&err];
        if (!_imagePipeline) { NSLog(@"Image pipeline: %@", err); return nil; }
    }

    _lastImageGen = 0;

    return self;
}

- (void)dealloc {
    free(_bgVerts);
    free(_textVerts);
    free(_colorVerts);
    free(_cellSnapshot);
}

- (void)drawInMTKView:(MTKView*)view {
    if (g_needs_font_rebuild) {
        g_needs_font_rebuild = 0;
        [self rebuildFont:view];
    }
    if (g_needs_window_update) {
        g_needs_window_update = 0;
        attyx_apply_window_update();
    }
    [self drawFrameImpl:view];
}

- (void)rebuildFont:(MTKView*)view {
    // Release old Core Text font. Metal textures are ARC-managed (released
    // automatically when _glyphCache struct fields are overwritten below).
    if (_glyphCache.font) CFRelease(_glyphCache.font);

    CGFloat scale = [NSScreen mainScreen].backingScaleFactor;
    _glyphCache = createGlyphCache(_device, scale);
    ligatureCacheClear();

    g_cell_pt_w = _glyphCache.glyph_w / _glyphCache.scale;
    g_cell_pt_h = _glyphCache.glyph_h / _glyphCache.scale;
    g_cell_w_pts = (float)g_cell_pt_w;
    g_cell_h_pts = (float)g_cell_pt_h;

    NSWindow* window = view.window;
    if (window) {
        [window setContentSize:NSMakeSize(g_cols * g_cell_pt_w + g_padding_left + g_padding_right,
                                          g_rows * g_cell_pt_h + g_padding_top  + g_padding_bottom)];
    }

    _fullRedrawNeeded = YES;
}

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size {
    float padLpx = g_padding_left  * _glyphCache.scale;
    float padRpx = g_padding_right * _glyphCache.scale;
    float padTpx = g_padding_top   * _glyphCache.scale;
    float padBpx = g_padding_bottom * _glyphCache.scale;
    int new_cols = (int)((size.width  - padLpx - padRpx) / _glyphCache.glyph_w + 0.01f);
    int new_rows = (int)((size.height - padTpx - padBpx) / _glyphCache.glyph_h + 0.01f);
    if (new_cols < 1) new_cols = 1;
    if (new_rows < 1) new_rows = 1;
    if (new_cols > ATTYX_MAX_COLS) new_cols = ATTYX_MAX_COLS;
    if (new_rows > ATTYX_MAX_ROWS) new_rows = ATTYX_MAX_ROWS;
    g_pending_resize_rows = new_rows;
    g_pending_resize_cols = new_cols;
    _fullRedrawNeeded = YES;
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
        ATTYX_LOG_DEBUG("renderer", "fps=%.0f skip=%.0f%% avg_dirty=%.1f rows",
                fps, skipPct, avgDirty);
        _statsFrames = 0;
        _statsSkipped = 0;
        _statsDirtyRows = 0;
        _statsLastPrint = now;
    }
}

@end
