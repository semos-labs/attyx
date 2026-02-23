#ifndef ATTYX_MACOS_RENDERER_PRIVATE_H
#define ATTYX_MACOS_RENDERER_PRIVATE_H

#import <QuartzCore/CABase.h>
#include "macos_internal.h"

@interface AttyxRenderer () {
    GlyphCache _glyphCache;
    Vertex*     _bgVerts;
    Vertex*     _textVerts;
    int         _totalTextVerts;
    id<MTLBuffer> _bgMetalBuf;
    id<MTLBuffer> _textMetalBuf;
    int           _metalBufCapBg;
    int           _metalBufCapText;
    AttyxCell*  _cellSnapshot;
    int         _cellSnapshotCap;
    int         _prevCursorRow;
    int         _prevCursorCol;
    BOOL        _fullRedrawNeeded;
    int         _allocRows;
    int         _allocCols;
    BOOL        _blinkOn;
    CFAbsoluteTime _blinkLastToggle;
    int         _prevCursorShape;
    int         _prevCursorVisible;
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
- (void)drawFrameImpl:(MTKView*)view;
- (void)rebuildFont:(MTKView*)view;
- (void)printStatsIfNeeded;
@end

#endif // ATTYX_MACOS_RENDERER_PRIVATE_H
