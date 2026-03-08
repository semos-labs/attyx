#ifndef ATTYX_MACOS_RENDERER_PRIVATE_H
#define ATTYX_MACOS_RENDERER_PRIVATE_H

#import <QuartzCore/CABase.h>
#include "macos_internal.h"

@interface AttyxRenderer () {
    GlyphCache _glyphCache;
    Vertex*     _bgVerts;
    Vertex*     _textVerts;
    int         _totalTextVerts;
    Vertex*     _colorVerts;
    int         _totalColorVerts;
    id<MTLBuffer> _bgMetalBuf;
    id<MTLBuffer> _textMetalBuf;
    id<MTLBuffer> _colorMetalBuf;
    int           _metalBufCapBg;
    int           _metalBufCapText;
    int           _metalBufCapColor;
    AttyxCell*  _cellSnapshot;
    int         _cellSnapshotCap;
    int         _prevCursorRow;
    int         _prevCursorCol;
    BOOL        _fullRedrawNeeded;
    int         _allocRows;
    int         _allocCols;
    BOOL        _blinkOn;
    BOOL        _prevBlinkOn;
    CFAbsoluteTime _blinkLastToggle;
    float       _trailX, _trailY;
    BOOL        _trailActive;
    CFAbsoluteTime _trailLastTime;
    int         _prevCursorShape;
    int         _prevCursorVisible;
    BOOL        _debugStats;
    uint64_t    _statsFrames;
    uint64_t    _statsSkipped;
    uint64_t    _statsDirtyRows;
    CFAbsoluteTime _statsLastPrint;
    uint64_t    _lastImageGen;
    uint32_t    _lastOverlayGen;
    uint32_t    _lastPopupGen;
}
@property (nonatomic, strong) id<MTLDevice>              device;
@property (nonatomic, strong) id<MTLCommandQueue>        cmdQueue;
@property (nonatomic, strong) id<MTLRenderPipelineState> bgPipeline;
@property (nonatomic, strong) id<MTLRenderPipelineState> textPipeline;
@property (nonatomic, strong) id<MTLRenderPipelineState> colorPipeline;
@property (nonatomic, strong) id<MTLRenderPipelineState> imagePipeline;
- (void)drawFrameImpl:(MTKView*)view;
- (void)rebuildFont:(MTKView*)view;
- (void)printStatsIfNeeded;
@end

// ---------------------------------------------------------------------------
// Image rendering (macos_renderer_images.m)
// ---------------------------------------------------------------------------

#define IMAGE_TEX_CACHE_CAP 64

typedef struct {
    uint32_t       image_id;
    uint32_t       width;
    uint32_t       height;
    id<MTLTexture> texture;
} ImageTexEntry;

// Texture cache helpers (defined in macos_renderer_images.m)
id<MTLTexture> findCachedTexture(uint32_t image_id, uint32_t width, uint32_t height);
void cacheTexture(uint32_t image_id, uint32_t width, uint32_t height, id<MTLTexture> tex);

@interface AttyxRenderer (Images)
- (void)drawImagesWithEncoder:(id<MTLRenderCommandEncoder>)enc
                     viewport:(float[2])viewport
                       glyphW:(float)gw
                       glyphH:(float)gh
                         offX:(float)offX
                         offY:(float)offY;
@end

// ---------------------------------------------------------------------------
// Popup rendering (macos_popup.m)
// ---------------------------------------------------------------------------

@interface AttyxRenderer (Popup)
- (void)drawPopupWithEncoder:(id<MTLRenderCommandEncoder>)enc
                    viewport:(float[2])viewport
                      glyphW:(float)gw
                      glyphH:(float)gh
                        offX:(float)offX
                        offY:(float)offY;
@end

#endif // ATTYX_MACOS_RENDERER_PRIVATE_H
