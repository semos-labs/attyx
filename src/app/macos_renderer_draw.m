// Attyx — Metal frame drawing implementation

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CABase.h>
#include <string.h>
#include "macos_renderer_private.h"

static BOOL cellIsSelected(int row, int col) {
    if (!g_sel_active) return NO;
    int sr = g_sel_start_row, sc = g_sel_start_col;
    int er = g_sel_end_row,   ec = g_sel_end_col;
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

@implementation AttyxRenderer (DrawFrame)

- (void)drawFrameImpl:(MTKView*)view {
    if (!g_cells || g_cols <= 0 || g_rows <= 0) return;

    uint64_t gen1 = g_cell_gen;
    if (gen1 & 1) return;

    @autoreleasepool {
        int rows = g_rows;
        int cols = g_cols;
        int total = cols * rows;

        uint64_t dirty[4];
        for (int i = 0; i < 4; i++)
            dirty[i] = __sync_lock_test_and_set((volatile uint64_t*)&g_dirty[i], 0);

        int curRow = g_cursor_row;
        int curCol = g_cursor_col;
        int curShape = g_cursor_shape;
        int curVisible = g_cursor_visible;

        BOOL cursorChanged = (curRow != _prevCursorRow || curCol != _prevCursorCol
                              || curShape != _prevCursorShape || curVisible != _prevCursorVisible);

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

            _metalBufCapBg   = bgVertCap;
            _metalBufCapText = total * 6;
            _bgMetalBuf   = [self.device newBufferWithLength:sizeof(Vertex) * _metalBufCapBg
                                                     options:MTLResourceStorageModeShared];
            _textMetalBuf = [self.device newBufferWithLength:sizeof(Vertex) * _metalBufCapText
                                                     options:MTLResourceStorageModeShared];
        }

        if (!_fullRedrawNeeded && !dirtyAny(dirty) && !cursorChanged && !isBlinking && !g_search_active) {
            if (_debugStats) _statsSkipped++;
            if (_debugStats) _statsFrames++;
            [self printStatsIfNeeded];
            return;
        }

        if (_cellSnapshot && _cellSnapshotCap >= total) {
            memcpy(_cellSnapshot, g_cells, sizeof(AttyxCell) * total);
        } else {
            return;
        }

        uint64_t gen2 = g_cell_gen;
        if (gen1 != gen2) return;

        AttyxCell* cells = _cellSnapshot;

        float gw = _glyphCache.glyph_w;
        float gh = _glyphCache.glyph_h;
        float viewport[2] = { cols * gw, rows * gh };

        float atlasW = (float)_glyphCache.atlas_w;
        float glyphW = _glyphCache.glyph_w;
        float glyphH = _glyphCache.glyph_h;
        int atlasCols = _glyphCache.atlas_cols;

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
                case 0: case 1: break;
                case 2: case 3: {
                    float thickness = fmaxf(2.0f, 1.0f);
                    ry0 = ry1 - thickness;
                    break;
                }
                case 4: case 5: {
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

        if (!g_sel_active) {
            uint32_t hoverLid = g_hover_link_id;
            float ulH = fmaxf(2.0f, 1.0f);

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

        if (g_search_active) {
            int visCount = g_search_vis_count;
            int sCurRow = g_search_cur_vis_row;
            int curCs = g_search_cur_vis_cs;
            int curCe = g_search_cur_vis_ce;
            float ulH = gh;
            for (int vi = 0; vi < visCount && vi < ATTYX_SEARCH_VIS_MAX; vi++) {
                AttyxSearchVis m = g_search_vis[vi];
                if (m.row < 0 || m.row >= rows) continue;
                BOOL isCurrent = (m.row == sCurRow && m.col_start == curCs && m.col_end == curCe);
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

        memcpy(_bgMetalBuf.contents, _bgVerts, sizeof(Vertex) * bgVertCount);
        [_bgMetalBuf didModifyRange:NSMakeRange(0, sizeof(Vertex) * bgVertCount)];

        if (ti > 0) {
            memcpy(_textMetalBuf.contents, _textVerts, sizeof(Vertex) * ti);
            [_textMetalBuf didModifyRange:NSMakeRange(0, sizeof(Vertex) * ti)];
        }

        id<MTLCommandBuffer> cmdBuf = [self.cmdQueue commandBuffer];
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

        [enc setRenderPipelineState:self.bgPipeline];
        [enc setVertexBuffer:_bgMetalBuf offset:0 atIndex:0];
        [enc setVertexBytes:viewport length:sizeof(viewport) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                vertexCount:bgVertCount];

        if (ti > 0) {
            [enc setRenderPipelineState:self.textPipeline];
            [enc setVertexBuffer:_textMetalBuf offset:0 atIndex:0];
            [enc setVertexBytes:viewport length:sizeof(viewport) atIndex:1];
            [enc setFragmentTexture:_glyphCache.texture atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                    vertexCount:ti];
        }

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

                [enc setRenderPipelineState:self.bgPipeline];
                [enc setVertexBytes:imeVerts length:sizeof(Vertex) * iv atIndex:0];
                [enc setVertexBytes:viewport length:sizeof(viewport) atIndex:1];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                        vertexCount:iv];

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
                    [enc setRenderPipelineState:self.textPipeline];
                    [enc setVertexBytes:imeTextVerts length:sizeof(Vertex) * imeGlyphs atIndex:0];
                    [enc setVertexBytes:viewport length:sizeof(viewport) atIndex:1];
                    [enc setFragmentTexture:_glyphCache.texture atIndex:0];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                            vertexCount:imeGlyphs];
                }
            }
        }

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

@end
