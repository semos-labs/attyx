// Attyx — macOS overlay draw pass (Metal)
// Category on AttyxRenderer that draws overlay layers after terminal content.

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#include <string.h>
#include "macos_internal.h"
#include "macos_renderer_private.h"

// Max vertices for overlay: each cell needs 6 bg verts + 6 text verts.
// With ATTYX_OVERLAY_MAX_CELLS=2048 per layer and 4 layers, allocate for
// the common case (one small card, ~300 cells).
#define OVERLAY_MAX_BG_VERTS    (2048 * 6)
#define OVERLAY_MAX_TEXT_VERTS  (2048 * 6)

@implementation AttyxRenderer (Overlay)

- (void)drawOverlaysWithEncoder:(id<MTLRenderCommandEncoder>)enc
                       viewport:(float[2])viewport
                         glyphW:(float)gw
                         glyphH:(float)gh
                           offX:(float)offX
                           offY:(float)offY {
    int count = g_overlay_count;
    if (count <= 0) return;
    if (count > ATTYX_OVERLAY_MAX_LAYERS) count = ATTYX_OVERLAY_MAX_LAYERS;

    // Stack-allocate vertex buffers, then upload via MTLBuffer (not setVertexBytes
    // which has a hard 4KB limit — overlays can easily exceed that).
    Vertex bgVerts[OVERLAY_MAX_BG_VERTS];
    Vertex textVerts[OVERLAY_MAX_TEXT_VERTS];
    int bi = 0, ti = 0;

    for (int layer = 0; layer < count; layer++) {
        AttyxOverlayDesc desc = g_overlay_descs[layer];
        if (!desc.visible) continue;
        if (desc.cell_count <= 0) continue;

        int w = desc.width;
        int h = desc.height;
        int cellCount = desc.cell_count;
        if (cellCount > w * h) cellCount = w * h;
        if (cellCount > ATTYX_OVERLAY_MAX_CELLS) cellCount = ATTYX_OVERLAY_MAX_CELLS;

        for (int ci = 0; ci < cellCount; ci++) {
            int cellRow = ci / w;
            int cellCol = ci % w;
            int gridCol = desc.col + cellCol;
            int gridRow = desc.row + cellRow;

            float x = offX + gridCol * gw;
            float y = offY + gridRow * gh;

            AttyxOverlayCell cell = g_overlay_cells[layer][ci];
            float alpha = cell.bg_alpha / 255.0f;

            // Background quad
            if (bi + 6 <= OVERLAY_MAX_BG_VERTS) {
                bi = emitRect(bgVerts, bi, x, y, gw, gh,
                              cell.bg_r / 255.0f,
                              cell.bg_g / 255.0f,
                              cell.bg_b / 255.0f,
                              alpha);
            }

            // Text glyph (skip spaces and control chars)
            if (cell.character > 32 && ti + 6 <= OVERLAY_MAX_TEXT_VERTS) {
                ti = emitGlyph(textVerts, ti, &_glyphCache, cell.character,
                               x, y, gw, gh,
                               cell.fg_r / 255.0f,
                               cell.fg_g / 255.0f,
                               cell.fg_b / 255.0f);
            }
        }
    }

    // Draw background quads (use MTLBuffer — setVertexBytes has a 4KB limit)
    if (bi > 0) {
        id<MTLBuffer> bgBuf = [self.device newBufferWithBytes:bgVerts
                                                       length:sizeof(Vertex) * bi
                                                      options:MTLResourceStorageModeShared];
        [enc setRenderPipelineState:self.bgPipeline];
        [enc setVertexBuffer:bgBuf offset:0 atIndex:0];
        [enc setVertexBytes:viewport length:sizeof(float) * 2 atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:bi];
    }

    // Draw text glyphs (use MTLBuffer — setVertexBytes has a 4KB limit)
    if (ti > 0) {
        id<MTLBuffer> textBuf = [self.device newBufferWithBytes:textVerts
                                                        length:sizeof(Vertex) * ti
                                                       options:MTLResourceStorageModeShared];
        [enc setRenderPipelineState:self.textPipeline];
        [enc setVertexBuffer:textBuf offset:0 atIndex:0];
        [enc setVertexBytes:viewport length:sizeof(float) * 2 atIndex:1];
        [enc setFragmentTexture:_glyphCache.texture atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:ti];
    }
}

@end
