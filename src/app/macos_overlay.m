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

        // Backdrop: flush accumulated verts, then draw full-screen dim rect
        if (desc.backdrop_alpha > 0) {
            if (bi > 0) {
                id<MTLBuffer> bgBuf = [self.device newBufferWithBytes:bgVerts
                                                               length:sizeof(Vertex) * bi
                                                              options:MTLResourceStorageModeShared];
                [enc setRenderPipelineState:self.bgPipeline];
                [enc setVertexBuffer:bgBuf offset:0 atIndex:0];
                [enc setVertexBytes:viewport length:sizeof(float) * 2 atIndex:1];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:bi];
                bi = 0;
            }
            if (ti > 0) {
                id<MTLBuffer> textBuf = [self.device newBufferWithBytes:textVerts
                                                                length:sizeof(Vertex) * ti
                                                               options:MTLResourceStorageModeShared];
                [enc setRenderPipelineState:self.textPipeline];
                [enc setVertexBuffer:textBuf offset:0 atIndex:0];
                [enc setVertexBytes:viewport length:sizeof(float) * 2 atIndex:1];
                [enc setFragmentTexture:_glyphCache.texture atIndex:0];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:ti];
                ti = 0;
            }
            float ba = desc.backdrop_alpha / 255.0f;
            Vertex dimVerts[6];
            emitRect(dimVerts, 0, 0, 0, viewport[0], viewport[1], 0, 0, 0, ba);
            id<MTLBuffer> dimBuf = [self.device newBufferWithBytes:dimVerts
                                                            length:sizeof(Vertex) * 6
                                                           options:MTLResourceStorageModeShared];
            [enc setRenderPipelineState:self.bgPipeline];
            [enc setVertexBuffer:dimBuf offset:0 atIndex:0];
            [enc setVertexBytes:viewport length:sizeof(float) * 2 atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        }

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
            uint8_t flags = cell.flags;

            // Background quad
            if (bi + 6 <= OVERLAY_MAX_BG_VERTS) {
                bi = emitRect(bgVerts, bi, x, y, gw, gh,
                              cell.bg_r / 255.0f,
                              cell.bg_g / 255.0f,
                              cell.bg_b / 255.0f,
                              alpha);
            }

            // Resolve fg color with flags: bold brightens, dim darkens
            float fgR = cell.fg_r / 255.0f;
            float fgG = cell.fg_g / 255.0f;
            float fgB = cell.fg_b / 255.0f;
            if (flags & 0x01) { // bold
                fgR = fgR * 1.3f > 1.0f ? 1.0f : fgR * 1.3f;
                fgG = fgG * 1.3f > 1.0f ? 1.0f : fgG * 1.3f;
                fgB = fgB * 1.3f > 1.0f ? 1.0f : fgB * 1.3f;
            }
            if (flags & 0x08) { // dim
                fgR *= 0.6f; fgG *= 0.6f; fgB *= 0.6f;
            }

            // Text glyph (skip spaces and control chars)
            if (cell.character > 32 && ti + 6 <= OVERLAY_MAX_TEXT_VERTS) {
                uint32_t ch = cell.character;
                bool hasCombining = (cell.combining[0] != 0);
                uint32_t key = hasCombining ? combiningKey(ch, cell.combining[0], cell.combining[1]) : ch;

                int rawSlot = glyphCacheLookup(&_glyphCache, key);
                if (rawSlot < 0) {
                    rawSlot = hasCombining
                        ? glyphCacheRasterizeCombined(&_glyphCache, ch, cell.combining[0], cell.combining[1])
                        : glyphCacheRasterize(&_glyphCache, ch);
                }

                int wide = (rawSlot & GLYPH_WIDE_BIT) ? 1 : 0;
                int slot = rawSlot & ~(GLYPH_WIDE_BIT | GLYPH_COLOR_BIT);
                float glyphW = _glyphCache.glyph_w;
                float glyphH = _glyphCache.glyph_h;
                float atlasW = (float)_glyphCache.atlas_w;
                float atlasH = (float)_glyphCache.atlas_h;
                int atlasCols = _glyphCache.atlas_cols;
                int ac = slot % atlasCols;
                int ar = slot / atlasCols;
                float u0 = ac * glyphW / atlasW;
                float v0 = ar * glyphH / atlasH;
                float u1 = (ac + 1 + wide) * glyphW / atlasW;
                float v1 = (ar + 1) * glyphH / atlasH;
                float drawW = wide ? 2.0f * gw : gw;

                textVerts[ti+0] = (Vertex){ x,        y,    u0,v0, fgR,fgG,fgB,1 };
                textVerts[ti+1] = (Vertex){ x+drawW,  y,    u1,v0, fgR,fgG,fgB,1 };
                textVerts[ti+2] = (Vertex){ x,        y+gh, u0,v1, fgR,fgG,fgB,1 };
                textVerts[ti+3] = (Vertex){ x+drawW,  y,    u1,v0, fgR,fgG,fgB,1 };
                textVerts[ti+4] = (Vertex){ x+drawW,  y+gh, u1,v1, fgR,fgG,fgB,1 };
                textVerts[ti+5] = (Vertex){ x,        y+gh, u0,v1, fgR,fgG,fgB,1 };
                ti += 6;
            }

            // Underline decoration (1px line at bottom of cell)
            if ((flags & 0x02) && bi + 6 <= OVERLAY_MAX_BG_VERTS) {
                float lineH = gh > 8.0f ? 2.0f : 1.0f;
                bi = emitRect(bgVerts, bi, x, y + gh - lineH, gw, lineH,
                              fgR, fgG, fgB, 1.0f);
            }

            // Strikethrough decoration (1px line at middle of cell)
            if ((flags & 0x20) && bi + 6 <= OVERLAY_MAX_BG_VERTS) {
                float lineH = gh > 8.0f ? 2.0f : 1.0f;
                bi = emitRect(bgVerts, bi, x, y + gh * 0.5f - lineH * 0.5f,
                              gw, lineH, fgR, fgG, fgB, 1.0f);
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
