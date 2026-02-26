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

    // 3. Draw popup cursor (shape-aware + themed color + trail)
    {
        static float _popupTrailX, _popupTrailY;
        static double _popupTrailLastTime;
        static int   _popupPrevRow = -1, _popupPrevCol = -1;

        int curCol = desc.cursor_col;
        int curRow = desc.cursor_row;
        int curShape = desc.cursor_shape;
        int curGridCol = desc.col + curCol;
        int curGridRow = desc.row + curRow;
        float cx = offX + curGridCol * gw;
        float cy = offY + curGridRow * gh;

        int cursorChanged = (curRow != _popupPrevRow || curCol != _popupPrevCol);

        // Cursor color from theme
        float cr, cg_c, cb;
        if (g_theme_cursor_r >= 0) {
            cr = g_theme_cursor_r / 255.0f;
            cg_c = g_theme_cursor_g / 255.0f;
            cb = g_theme_cursor_b / 255.0f;
        } else {
            cr = 0.86f; cg_c = 0.86f; cb = 0.86f;
        }

        if (desc.cursor_visible) {
            // Shape-aware cursor rect
            float rx0 = cx, ry0 = cy, rx1 = cx + gw, ry1 = cy + gh;
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

            Vertex curVerts[6];
            curVerts[0] = (Vertex){ rx0,ry0, 0,0, cr,cg_c,cb,1 };
            curVerts[1] = (Vertex){ rx1,ry0, 0,0, cr,cg_c,cb,1 };
            curVerts[2] = (Vertex){ rx0,ry1, 0,0, cr,cg_c,cb,1 };
            curVerts[3] = (Vertex){ rx1,ry0, 0,0, cr,cg_c,cb,1 };
            curVerts[4] = (Vertex){ rx1,ry1, 0,0, cr,cg_c,cb,1 };
            curVerts[5] = (Vertex){ rx0,ry1, 0,0, cr,cg_c,cb,1 };

            [enc setRenderPipelineState:self.bgPipeline];
            [enc setVertexBytes:curVerts length:sizeof(curVerts) atIndex:0];
            [enc setVertexBytes:viewport length:sizeof(float) * 2 atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        }

        // Cursor trail (Neovide-style exponential-decay comet)
        CFAbsoluteTime now = CACurrentMediaTime();
        if (g_cursor_trail && desc.cursor_visible && cursorChanged && _popupPrevRow >= 0) {
            int cellDist = abs(curRow - _popupPrevRow) + abs(curCol - _popupPrevCol);
            if (cellDist > 1) {
                _popupTrailX = offX + (desc.col + _popupPrevCol) * gw;
                _popupTrailY = offY + (desc.row + _popupPrevRow) * gh;
                g_popup_trail_active = 1;
                _popupTrailLastTime = now;
            }
        }
        if (g_popup_trail_active && !desc.cursor_visible) g_popup_trail_active = 0;
        if (g_popup_trail_active && g_cursor_trail && desc.cursor_visible) {
            float targetX = cx;
            float targetY = cy;
            float dt = (float)(now - _popupTrailLastTime);
            _popupTrailLastTime = now;
            float speed = 14.0f;
            float t = 1.0f - expf(-speed * dt);
            _popupTrailX += (targetX - _popupTrailX) * t;
            _popupTrailY += (targetY - _popupTrailY) * t;
            float dx = targetX - _popupTrailX;
            float dy = targetY - _popupTrailY;
            float dist = sqrtf(dx * dx + dy * dy);
            if (dist < 0.5f) {
                g_popup_trail_active = 0;
            } else {
                float cw = gw, ch = gh;
                float cyOff = 0, cxOff = 0;
                switch (curShape) {
                    case 2: case 3: { float th = fmaxf(2.0f, 1.0f); cyOff = gh - th; ch = th; break; }
                    case 4: case 5: { cw = fmaxf(2.0f, 1.0f); break; }
                    default: break;
                }

                float tx0 = _popupTrailX + cxOff, ty0 = _popupTrailY + cyOff;
                float tx1 = tx0 + cw,              ty1 = ty0 + ch;
                float cx0 = targetX + cxOff,        cy0 = targetY + cyOff;
                float cx1 = cx0 + cw,               cy1 = cy0 + ch;

                float hex[6][2];
                if (dx >= 0 && dy >= 0) {
                    hex[0][0]=tx0; hex[0][1]=ty0; hex[1][0]=tx1; hex[1][1]=ty0;
                    hex[2][0]=cx1; hex[2][1]=cy0; hex[3][0]=cx1; hex[3][1]=cy1;
                    hex[4][0]=cx0; hex[4][1]=cy1; hex[5][0]=tx0; hex[5][1]=ty1;
                } else if (dx >= 0) {
                    hex[0][0]=tx0; hex[0][1]=ty1; hex[1][0]=tx1; hex[1][1]=ty1;
                    hex[2][0]=cx1; hex[2][1]=cy1; hex[3][0]=cx1; hex[3][1]=cy0;
                    hex[4][0]=cx0; hex[4][1]=cy0; hex[5][0]=tx0; hex[5][1]=ty0;
                } else if (dy >= 0) {
                    hex[0][0]=tx1; hex[0][1]=ty0; hex[1][0]=tx0; hex[1][1]=ty0;
                    hex[2][0]=cx0; hex[2][1]=cy0; hex[3][0]=cx0; hex[3][1]=cy1;
                    hex[4][0]=cx1; hex[4][1]=cy1; hex[5][0]=tx1; hex[5][1]=ty1;
                } else {
                    hex[0][0]=tx1; hex[0][1]=ty1; hex[1][0]=tx0; hex[1][1]=ty1;
                    hex[2][0]=cx0; hex[2][1]=cy1; hex[3][0]=cx0; hex[3][1]=cy0;
                    hex[4][0]=cx1; hex[4][1]=cy0; hex[5][0]=tx1; hex[5][1]=ty0;
                }

                // 4 triangles = 12 verts for hexagon fan
                Vertex trailVerts[12];
                for (int ti = 0; ti < 4; ti++) {
                    trailVerts[ti*3+0] = (Vertex){ hex[0][0],hex[0][1], 0,0, cr,cg_c,cb,1 };
                    trailVerts[ti*3+1] = (Vertex){ hex[ti+1][0],hex[ti+1][1], 0,0, cr,cg_c,cb,1 };
                    trailVerts[ti*3+2] = (Vertex){ hex[ti+2][0],hex[ti+2][1], 0,0, cr,cg_c,cb,1 };
                }

                [enc setRenderPipelineState:self.bgPipeline];
                [enc setVertexBytes:trailVerts length:sizeof(trailVerts) atIndex:0];
                [enc setVertexBytes:viewport length:sizeof(float) * 2 atIndex:1];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:12];
            }
        }

        _popupPrevRow = curRow;
        _popupPrevCol = curCol;
    }
}

@end
