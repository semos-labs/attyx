// Attyx — macOS popup terminal draw pass (Metal)
// Category on AttyxRenderer that draws popup overlay after regular overlays.

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#include <string.h>
#include "macos_internal.h"
#include "macos_renderer_private.h"

// Process popup cells in chunks to avoid stack overflow with large popups.
// Chunk size kept moderate — vertex data sent via Metal buffers (not setVertexBytes)
// because popups can exceed the 4KB setVertexBytes limit.
#define POPUP_CHUNK 2048

@implementation AttyxRenderer (Popup)

- (void)drawPopupWithEncoder:(id<MTLRenderCommandEncoder>)enc
                    viewport:(float[2])viewport
                      glyphW:(float)gw glyphH:(float)gh
                        offX:(float)offX offY:(float)offY {
    if (!g_popup_desc.active) return;

    AttyxPopupDesc desc = g_popup_desc;
    int totalCells = desc.width * desc.height;
    if (totalCells <= 0 || totalCells > ATTYX_POPUP_MAX_CELLS) return;

    // 1. Draw dim overlay (full-screen translucent black rect)
    // 6 vertices * 32 bytes = 192 bytes — fits setVertexBytes 4KB limit
    {
        Vertex dimVerts[6];
        emitRect(dimVerts, 0, 0, 0, viewport[0], viewport[1],
                 0, 0, 0, 0.4f);
        [enc setRenderPipelineState:self.bgPipeline];
        [enc setVertexBytes:dimVerts length:sizeof(dimVerts) atIndex:0];
        [enc setVertexBytes:viewport length:sizeof(float) * 2 atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    }

    // 2. Draw popup cells in chunks using Metal buffers
    for (int start = 0; start < totalCells; start += POPUP_CHUNK) {
        int end = (start + POPUP_CHUNK < totalCells)
                  ? start + POPUP_CHUNK : totalCells;

        Vertex bgVerts[POPUP_CHUNK * 6];
        Vertex textVerts[POPUP_CHUNK * 6];
        int bi = 0, ti = 0;

        for (int ci = start; ci < end; ci++) {
            int cellRow = ci / desc.width;
            int cellCol = ci % desc.width;
            int gridCol = desc.col + cellCol;
            int gridRow = desc.row + cellRow;

            float x = offX + gridCol * gw;
            float y = offY + gridRow * gh;

            AttyxOverlayCell cell = g_popup_cells[ci];
            float alpha = cell.bg_alpha / 255.0f;

            // Background quad
            if (bi + 6 <= POPUP_CHUNK * 6) {
                bi = emitRect(bgVerts, bi, x, y, gw, gh,
                              cell.bg_r / 255.0f,
                              cell.bg_g / 255.0f,
                              cell.bg_b / 255.0f,
                              alpha);
            }

            // Text glyph (skip spaces and control chars)
            if (cell.character > 32 && ti + 6 <= POPUP_CHUNK * 6) {
                ti = emitGlyph(textVerts, ti, &_glyphCache, cell.character,
                               x, y, gw, gh,
                               cell.fg_r / 255.0f,
                               cell.fg_g / 255.0f,
                               cell.fg_b / 255.0f);
            }
        }

        // Draw bg chunk via Metal buffer
        if (bi > 0) {
            id<MTLBuffer> bgBuf = [self.device newBufferWithBytes:bgVerts
                                                          length:sizeof(Vertex) * bi
                                                         options:MTLResourceStorageModeShared];
            [enc setRenderPipelineState:self.bgPipeline];
            [enc setVertexBuffer:bgBuf offset:0 atIndex:0];
            [enc setVertexBytes:viewport length:sizeof(float) * 2 atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:bi];
        }

        // Draw text chunk via Metal buffer
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

    // 3. Draw popup cursor
    // 6 vertices * 32 bytes = 192 bytes — fits setVertexBytes 4KB limit
    if (desc.cursor_visible) {
        int curGridCol = desc.col + 1 + desc.cursor_col;  // +1 for border
        int curGridRow = desc.row + 1 + desc.cursor_row;
        float cx = offX + curGridCol * gw;
        float cy = offY + curGridRow * gh;

        Vertex curVerts[6];
        // Block cursor: solid white rect
        emitRect(curVerts, 0, cx, cy, gw, gh, 0.8f, 0.8f, 0.8f, 0.8f);

        [enc setRenderPipelineState:self.bgPipeline];
        [enc setVertexBytes:curVerts length:sizeof(curVerts) atIndex:0];
        [enc setVertexBytes:viewport length:sizeof(float) * 2 atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    }
}

@end
