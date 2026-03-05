// Attyx — Metal frame drawing implementation

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CABase.h>
#include <string.h>
#include "macos_renderer_private.h"

static BOOL cellIsSelected(int row, int col) {
    if (!g_sel_active) return NO;
    // In copy mode with splits, clip selection to focused pane rect
    if (g_copy_mode && g_pane_rect_rows > 0) {
        int pr = g_pane_rect_row, pc = g_pane_rect_col;
        int pe = pr + g_pane_rect_rows, pce = pc + g_pane_rect_cols;
        if (row < pr || row >= pe || col < pc || col >= pce) return NO;
    }
    int sr = g_sel_start_row, sc = g_sel_start_col;
    int er = g_sel_end_row,   ec = g_sel_end_col;
    if (g_sel_block) {
        int minR = sr < er ? sr : er, maxR = sr > er ? sr : er;
        int minC = sc < ec ? sc : ec, maxC = sc > ec ? sc : ec;
        return row >= minR && row <= maxR && col >= minC && col <= maxC;
    }
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

static int emitRectV(Vertex* v, int i, float x, float y, float w, float h,
                     float r, float g, float b, float a) {
    float x1 = x + w, y1 = y + h;
    v[i+0] = (Vertex){ x,  y,  0,0, r,g,b,a };
    v[i+1] = (Vertex){ x1, y,  0,0, r,g,b,a };
    v[i+2] = (Vertex){ x,  y1, 0,0, r,g,b,a };
    v[i+3] = (Vertex){ x1, y,  0,0, r,g,b,a };
    v[i+4] = (Vertex){ x1, y1, 0,0, r,g,b,a };
    v[i+5] = (Vertex){ x,  y1, 0,0, r,g,b,a };
    return i + 6;
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
            free(_colorVerts);
            free(_cellSnapshot);

            int bgVertCap = (total * 2 + cols + cols + ATTYX_SEARCH_VIS_MAX) * 6;
            _bgVerts       = (Vertex*)calloc(bgVertCap, sizeof(Vertex));
            _textVerts     = (Vertex*)calloc(total * 6, sizeof(Vertex));
            _colorVerts    = (Vertex*)calloc(total * 6, sizeof(Vertex));
            _cellSnapshot  = (AttyxCell*)malloc(sizeof(AttyxCell) * total);
            _cellSnapshotCap = total;
            _totalTextVerts  = 0;
            _totalColorVerts = 0;
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

        BOOL imagesChanged = (g_image_gen != _lastImageGen) || (g_image_placement_count > 0);
        BOOL overlayChanged = (g_overlay_gen != _lastOverlayGen);
        BOOL popupChanged = (g_popup_gen != _lastPopupGen);
        // Title updates must be checked before the early-return so they aren't
        // skipped when the grid is idle (no dirty rows / cursor changes).
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

        // Native tab manager sync (process tab ops + update titles)
        if (g_native_tabs_enabled) {
            AttyxNativeTabManager* ntm = [(id)[NSApp delegate] valueForKey:@"nativeTabMgr"];
            if (ntm) [ntm sync];
        }

        if (!_fullRedrawNeeded && !dirtyAny(dirty) && !cursorChanged && !isBlinking && !g_search_active && !_trailActive && !g_popup_trail_active && !imagesChanged && !overlayChanged && !popupChanged) {
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
        if (gen1 != gen2) {
            // Torn read — restore dirty bits so the next frame re-reads.
            for (int i = 0; i < 4; i++)
                __sync_fetch_and_or((volatile uint64_t*)&g_dirty[i], dirty[i]);
            return;
        }

        AttyxCell* cells = _cellSnapshot;

        float gw = _glyphCache.glyph_w;
        float gh = _glyphCache.glyph_h;
        float sc = _glyphCache.scale;
        float padL = g_padding_left   * sc;
        float padR = g_padding_right  * sc;
        float padT = g_padding_top    * sc;
        float padB = g_padding_bottom * sc;
        CGSize ds = view.drawableSize;
        float dW = (float)ds.width;
        float dH = (float)ds.height;
        float availW = dW - padL - padR;
        float availH = dH - padT - padB;
        float cx = floorf((availW - cols * gw) * 0.5f);
        float cy = 0;
        if (cx < 0) cx = 0;
        if (cy < 0) cy = 0;
        float offX = padL + cx;
        float baseOffY = padT + cy;
        float offY = baseOffY + g_grid_top_offset * gh;
        float viewport[2] = { dW, dH };

        float atlasW = (float)_glyphCache.atlas_w;
        float glyphW = _glyphCache.glyph_w;
        float glyphH = _glyphCache.glyph_h;
        int atlasCols = _glyphCache.atlas_cols;
        int visibleRows = rows - g_grid_top_offset - g_grid_bottom_offset;
        if (visibleRows < 0) visibleRows = 0;
        int visibleTotal = visibleRows * cols;

        int dirtyRowCount = 0;
        for (int row = 0; row < visibleRows; row++) {
            if (!_fullRedrawNeeded && !dirtyBitTest(dirty, row)) continue;
            dirtyRowCount++;

            for (int col = 0; col < cols; col++) {
                int i = row * cols + col;
                float x0 = offX + col * gw;
                float y0 = offY + row * gh;
                float x1 = x0 + gw;
                float y1 = y0 + gh;
                const AttyxCell* cell = &cells[i];

                float br, bg, bb, ba;
                if (cellIsSelected(row, col)) {
                    if (g_theme_sel_bg_set) {
                        br = g_theme_sel_bg_r / 255.0f;
                        bg = g_theme_sel_bg_g / 255.0f;
                        bb = g_theme_sel_bg_b / 255.0f;
                    } else {
                        br = 0.20f; bg = 0.40f; bb = 0.70f;
                    }
                    ba = 1.0f;
                } else {
                    br = cell->bg_r / 255.0f;
                    bg = cell->bg_g / 255.0f;
                    bb = cell->bg_b / 255.0f;
                    ba = (cell->flags & 4) ? g_background_opacity : 1.0f;
                }

                int bi = i * 6;
                _bgVerts[bi+0] = (Vertex){ x0, y0, 0,0, br,bg,bb,ba };
                _bgVerts[bi+1] = (Vertex){ x1, y0, 0,0, br,bg,bb,ba };
                _bgVerts[bi+2] = (Vertex){ x0, y1, 0,0, br,bg,bb,ba };
                _bgVerts[bi+3] = (Vertex){ x1, y0, 0,0, br,bg,bb,ba };
                _bgVerts[bi+4] = (Vertex){ x1, y1, 0,0, br,bg,bb,ba };
                _bgVerts[bi+5] = (Vertex){ x0, y1, 0,0, br,bg,bb,ba };
            }
        }

        // Zero out stale BG vertices for hidden rows (below visibleRows)
        if (visibleTotal < total) {
            memset(&_bgVerts[visibleTotal * 6], 0, sizeof(Vertex) * 6 * (total - visibleTotal));
        }

        int cursorSlot = total * 6;
        memset(&_bgVerts[cursorSlot], 0, sizeof(Vertex) * 6);

        int bgVertCount = total * 6;
        BOOL drawCursor = curVisible && _blinkOn
                          && curRow >= g_grid_top_offset && curRow < (g_grid_top_offset + visibleRows) && curCol >= 0 && curCol < cols;
        if (drawCursor) {
            float cx0 = offX + curCol * gw;
            float cy0 = baseOffY + curRow * gh;
            float cr, cg_c, cb;
            if (g_theme_cursor_r >= 0) {
                cr = g_theme_cursor_r / 255.0f;
                cg_c = g_theme_cursor_g / 255.0f;
                cb = g_theme_cursor_b / 255.0f;
            } else {
                cr = 0.86f; cg_c = 0.86f; cb = 0.86f;
            }

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

        // Copy-mode search match highlighting (only within focused pane)
        if (g_copy_mode && g_copy_search_len > 0) {
            int qlen = g_copy_search_len;
            int pr = g_pane_rect_row, pc = g_pane_rect_col;
            int prows = g_pane_rect_rows, pcols = g_pane_rect_cols;
            if (prows <= 0) { prows = visibleRows; pr = 0; }
            if (pcols <= 0) { pcols = cols; pc = 0; }
            for (int row = 0; row < prows && (row + pr) < visibleRows; row++) {
                int absRow = row + pr;
                int base = absRow * cols + pc;
                for (int col = 0; col <= pcols - qlen; col++) {
                    if (bgVertCount + qlen * 6 > _metalBufCapBg) break;
                    int match = 1;
                    for (int k = 0; k < qlen; k++) {
                        uint32_t ch = cells[base + col + k].character;
                        uint32_t qch = g_copy_search_buf[k];
                        uint32_t cl = (ch >= 'A' && ch <= 'Z') ? ch + 32 : ch;
                        uint32_t ql = (qch >= 'A' && qch <= 'Z') ? qch + 32 : qch;
                        if (cl != ql) { match = 0; break; }
                    }
                    if (match) {
                        for (int k = 0; k < qlen; k++) {
                            if (bgVertCount + 6 > _metalBufCapBg) break;
                            float mx0 = offX + (pc + col + k) * gw;
                            float my0 = offY + absRow * gh;
                            bgVertCount = emitRectV(_bgVerts, bgVertCount, mx0, my0, gw, gh, 0.6f, 0.4f, 0.1f, 0.7f);
                        }
                    }
                }
            }
        }

        // Copy-mode cursor: solid block (same style as terminal cursor)
        if (g_copy_mode && bgVertCount + 6 <= _metalBufCapBg) {
            int cmRow = g_copy_cursor_row;
            int cmCol = g_copy_cursor_col;
            if (cmRow >= 0 && cmRow < visibleRows && cmCol >= 0 && cmCol < cols) {
                float cx0 = offX + cmCol * gw;
                float cy0 = offY + cmRow * gh;
                float cr, cg_c, cb;
                if (g_theme_cursor_r >= 0) {
                    cr = g_theme_cursor_r / 255.0f;
                    cg_c = g_theme_cursor_g / 255.0f;
                    cb = g_theme_cursor_b / 255.0f;
                } else {
                    cr = 0.86f; cg_c = 0.86f; cb = 0.86f;
                }
                bgVertCount = emitRectV(_bgVerts, bgVertCount, cx0, cy0, gw, gh, cr, cg_c, cb, 1);
            }
        }

        if (!g_sel_active) {
            uint32_t hoverLid = g_hover_link_id;
            float ulH = fmaxf(2.0f, 1.0f);

            for (int i = 0; i < visibleTotal; i++) {
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
                float lx0 = offX + lcol * gw;
                float lx1 = lx0 + gw;
                float ly1 = offY + (lrow + 1) * gh;
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
                    float lx0 = offX + c * gw;
                    float lx1 = lx0 + gw;
                    float ly1 = offY + (dRow + 1) * gh;
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
                if (m.row < 0 || m.row >= visibleRows) continue;
                BOOL isCurrent = (m.row == sCurRow && m.col_start == curCs && m.col_end == curCe);
                float hr, hg, hb, ha;
                if (isCurrent) {
                    hr = 1.0f; hg = 0.6f; hb = 0.0f; ha = 0.75f;
                } else {
                    hr = 1.0f; hg = 0.6f; hb = 0.0f; ha = 0.28f;
                }
                for (int cc = m.col_start; cc < m.col_end && cc < cols; cc++) {
                    if (bgVertCount + 6 > _metalBufCapBg) break;
                    float lx0 = offX + cc * gw, lx1 = lx0 + gw;
                    float ly0 = offY + m.row * gh, ly1 = ly0 + ulH;
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

        // Underline + strikethrough decorations
        {
            float decoH = fmaxf(2.0f, 1.0f);
            for (int i = 0; i < visibleTotal; i++) {
                const AttyxCell* cell = &cells[i];
                if (cell->character == 0x10EEEE) continue;  // Kitty Unicode placeholder
                uint8_t fl = cell->flags;
                int hasUnderline = (fl & 2);
                int hasStrike = (fl & 32);
                if (!hasUnderline && !hasStrike) continue;
                int drow = i / cols, dcol = i % cols;
                float dr = cell->fg_r / 255.0f;
                float dg = cell->fg_g / 255.0f;
                float db = cell->fg_b / 255.0f;
                float dx0 = offX + dcol * gw, dx1 = dx0 + gw;
                if (hasUnderline && bgVertCount + 6 <= _metalBufCapBg) {
                    float uy1 = offY + (drow + 1) * gh;
                    float uy0 = uy1 - decoH;
                    _bgVerts[bgVertCount+0] = (Vertex){ dx0,uy0, 0,0, dr,dg,db,1 };
                    _bgVerts[bgVertCount+1] = (Vertex){ dx1,uy0, 0,0, dr,dg,db,1 };
                    _bgVerts[bgVertCount+2] = (Vertex){ dx0,uy1, 0,0, dr,dg,db,1 };
                    _bgVerts[bgVertCount+3] = (Vertex){ dx1,uy0, 0,0, dr,dg,db,1 };
                    _bgVerts[bgVertCount+4] = (Vertex){ dx1,uy1, 0,0, dr,dg,db,1 };
                    _bgVerts[bgVertCount+5] = (Vertex){ dx0,uy1, 0,0, dr,dg,db,1 };
                    bgVertCount += 6;
                }
                if (hasStrike && bgVertCount + 6 <= _metalBufCapBg) {
                    float sy0 = offY + drow * gh + gh * 0.5f - decoH * 0.5f;
                    float sy1 = sy0 + decoH;
                    _bgVerts[bgVertCount+0] = (Vertex){ dx0,sy0, 0,0, dr,dg,db,1 };
                    _bgVerts[bgVertCount+1] = (Vertex){ dx1,sy0, 0,0, dr,dg,db,1 };
                    _bgVerts[bgVertCount+2] = (Vertex){ dx0,sy1, 0,0, dr,dg,db,1 };
                    _bgVerts[bgVertCount+3] = (Vertex){ dx1,sy0, 0,0, dr,dg,db,1 };
                    _bgVerts[bgVertCount+4] = (Vertex){ dx1,sy1, 0,0, dr,dg,db,1 };
                    _bgVerts[bgVertCount+5] = (Vertex){ dx0,sy1, 0,0, dr,dg,db,1 };
                    bgVertCount += 6;
                }
            }
        }

        int ti = 0;
        int ci = 0;
        if (_fullRedrawNeeded || dirtyAny(dirty)) {
            for (int i = 0; i < visibleTotal; i++) {
                const AttyxCell* cell = &cells[i];
                uint32_t ch = cell->character;
                if (ch <= 32) continue;
                if (ch == 0x10EEEE) continue;  // Kitty Unicode placeholder

                int row = i / cols;
                int col = i % cols;
                float x0 = offX + col * gw;
                float y0 = offY + row * gh;
                float x1 = x0 + gw;
                float y1 = y0 + gh;

                uint32_t key = ch;
                bool hasCombining = (cell->combining[0] != 0);
                if (hasCombining) key = combiningKey(ch, cell->combining[0], cell->combining[1]);

                int rawSlot = glyphCacheLookup(&_glyphCache, key);
                if (rawSlot < 0) {
                    rawSlot = hasCombining
                        ? glyphCacheRasterizeCombined(&_glyphCache, ch, cell->combining[0], cell->combining[1])
                        : glyphCacheRasterize(&_glyphCache, ch);
                    atlasW = (float)_glyphCache.atlas_w;
                }

                // Extract color flag (bit 29), wide flag (bit 30), and actual atlas slot index
                int isColor = (rawSlot & GLYPH_COLOR_BIT) ? 1 : 0;
                int wide    = (rawSlot & GLYPH_WIDE_BIT)  ? 1 : 0;
                int slot    = rawSlot & ~(GLYPH_WIDE_BIT | GLYPH_COLOR_BIT);

                int ac = slot % atlasCols;
                int ar = slot / atlasCols;
                float atlasH = (float)_glyphCache.atlas_h;

                float au0 = ac             * glyphW / atlasW;
                float av0 = ar             * glyphH / atlasH;
                float au1 = (ac + 1 + wide)* glyphW / atlasW; // 2 cols wide for wide glyphs
                float av1 = (ar + 1)       * glyphH / atlasH;

                // Wide glyphs extend the quad into the next cell (Ghostty/WezTerm style).
                // The next cell's content renders on top, covering overflow when non-empty.
                float x1w = wide ? x0 + 2.0f * gw : x1;

                if (isColor) {
                    // Color emoji: vertex color = white, alpha = window opacity
                    float wa = g_background_opacity < 1.0f ? g_background_opacity : 1.0f;
                    _colorVerts[ci+0] = (Vertex){ x0,  y0, au0,av0, 1,1,1,wa };
                    _colorVerts[ci+1] = (Vertex){ x1w, y0, au1,av0, 1,1,1,wa };
                    _colorVerts[ci+2] = (Vertex){ x0,  y1, au0,av1, 1,1,1,wa };
                    _colorVerts[ci+3] = (Vertex){ x1w, y0, au1,av0, 1,1,1,wa };
                    _colorVerts[ci+4] = (Vertex){ x1w, y1, au1,av1, 1,1,1,wa };
                    _colorVerts[ci+5] = (Vertex){ x0,  y1, au0,av1, 1,1,1,wa };
                    ci += 6;
                } else {
                    float fr, fg, fb;
                    if (g_theme_sel_fg_set && cellIsSelected(row, col)) {
                        fr = g_theme_sel_fg_r / 255.0f;
                        fg = g_theme_sel_fg_g / 255.0f;
                        fb = g_theme_sel_fg_b / 255.0f;
                    } else if (drawCursor && row == (curRow - g_grid_top_offset) && col == curCol
                               && (curShape == 0 || curShape == 1)) {
                        // Block cursor: use cell bg for contrast
                        fr = cell->bg_r / 255.0f;
                        fg = cell->bg_g / 255.0f;
                        fb = cell->bg_b / 255.0f;
                    } else {
                        fr = cell->fg_r / 255.0f;
                        fg = cell->fg_g / 255.0f;
                        fb = cell->fg_b / 255.0f;
                    }

                    _textVerts[ti+0] = (Vertex){ x0,  y0, au0,av0, fr,fg,fb,1 };
                    _textVerts[ti+1] = (Vertex){ x1w, y0, au1,av0, fr,fg,fb,1 };
                    _textVerts[ti+2] = (Vertex){ x0,  y1, au0,av1, fr,fg,fb,1 };
                    _textVerts[ti+3] = (Vertex){ x1w, y0, au1,av0, fr,fg,fb,1 };
                    _textVerts[ti+4] = (Vertex){ x1w, y1, au1,av1, fr,fg,fb,1 };
                    _textVerts[ti+5] = (Vertex){ x0,  y1, au0,av1, fr,fg,fb,1 };
                    ti += 6;
                }
            }
            _totalTextVerts  = ti;
            _totalColorVerts = ci;
        } else {
            ti = _totalTextVerts;
            ci = _totalColorVerts;
        }

        // Cursor trail effect (Neovide-style: stretched comet tail)
        if (g_cursor_trail && g_cursor_visible && cursorChanged && _prevCursorRow >= 0) {
            int cellDist = abs(curRow - _prevCursorRow) + abs(curCol - _prevCursorCol);
            if (cellDist > 1) {
                _trailX = offX + _prevCursorCol * gw;
                _trailY = baseOffY + _prevCursorRow * gh;
                _trailActive = YES;
                _trailLastTime = now;
            }
        }
        if (_trailActive && !g_cursor_visible) _trailActive = NO;
        if (_trailActive && g_cursor_trail && g_cursor_visible) {
            float targetX = offX + curCol * gw;
            float targetY = baseOffY + curRow * gh;
            float dt = (float)(now - _trailLastTime);
            _trailLastTime = now;
            float speed = 14.0f;
            float t = 1.0f - expf(-speed * dt);
            _trailX += (targetX - _trailX) * t;
            _trailY += (targetY - _trailY) * t;
            float dx = targetX - _trailX;
            float dy = targetY - _trailY;
            float dist = sqrtf(dx * dx + dy * dy);
            if (dist < 0.5f) {
                _trailActive = NO;
            } else {
                float cr_t, cg_t, cb_t;
                if (g_theme_cursor_r >= 0) {
                    cr_t = g_theme_cursor_r / 255.0f;
                    cg_t = g_theme_cursor_g / 255.0f;
                    cb_t = g_theme_cursor_b / 255.0f;
                } else {
                    cr_t = 0.86f; cg_t = 0.86f; cb_t = 0.86f;
                }

                float alpha = 1.0f;

                // Cursor shape dimensions for the trail cross-axis
                float cw = gw, ch = gh;   // block (cases 0,1)
                float cyOff = 0;          // y offset within cell
                float cxOff = 0;          // x offset within cell
                switch (curShape) {
                    case 2: case 3: { // underline
                        float th = fmaxf(2.0f, 1.0f);
                        cyOff = gh - th;
                        ch = th;
                        break;
                    }
                    case 4: case 5: { // bar
                        cw = fmaxf(2.0f, 1.0f);
                        break;
                    }
                    default: break;
                }

                // Convex hull of cursor rect at trail pos and cursor pos (hexagon)
                float tx0 = _trailX + cxOff, ty0 = _trailY + cyOff;
                float tx1 = tx0 + cw,        ty1 = ty0 + ch;
                float cx0 = targetX + cxOff,  cy0 = targetY + cyOff;
                float cx1 = cx0 + cw,         cy1 = cy0 + ch;

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

                if (bgVertCount + 12 <= _metalBufCapBg) {
                    for (int ti = 0; ti < 4; ti++) {
                        _bgVerts[bgVertCount++] = (Vertex){ hex[0][0],hex[0][1], 0,0, cr_t,cg_t,cb_t,alpha };
                        _bgVerts[bgVertCount++] = (Vertex){ hex[ti+1][0],hex[ti+1][1], 0,0, cr_t,cg_t,cb_t,alpha };
                        _bgVerts[bgVertCount++] = (Vertex){ hex[ti+2][0],hex[ti+2][1], 0,0, cr_t,cg_t,cb_t,alpha };
                    }
                }
                _fullRedrawNeeded = YES;
            }
        }

        _prevCursorRow     = curRow;
        _prevCursorCol     = curCol;
        _prevCursorShape   = curShape;
        _prevCursorVisible = curVisible;
        if (!_trailActive && !g_popup_trail_active) _fullRedrawNeeded = NO;

        memcpy(_bgMetalBuf.contents, _bgVerts, sizeof(Vertex) * bgVertCount);
        [_bgMetalBuf didModifyRange:NSMakeRange(0, sizeof(Vertex) * bgVertCount)];

        if (ti > 0) {
            memcpy(_textMetalBuf.contents, _textVerts, sizeof(Vertex) * ti);
            [_textMetalBuf didModifyRange:NSMakeRange(0, sizeof(Vertex) * ti)];
        }
        if (ci > 0) {
            NSUInteger colorBytes = sizeof(Vertex) * ci;
            if (!_colorMetalBuf || _metalBufCapColor < ci) {
                _colorMetalBuf = [self.device newBufferWithLength:colorBytes * 2
                                                          options:MTLResourceStorageModeShared];
                _metalBufCapColor = ci * 2;
            }
            memcpy(_colorMetalBuf.contents, _colorVerts, colorBytes);
            [_colorMetalBuf didModifyRange:NSMakeRange(0, colorBytes)];
        }

        id<MTLCommandBuffer> cmdBuf = [self.cmdQueue commandBuffer];
        MTLRenderPassDescriptor* rpd = view.currentRenderPassDescriptor;
        if (!rpd) return;

        // Gap quads fill all areas outside the centered grid, so clear to transparent.
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0.0f, 0.0f, 0.0f, 0.0f);

        id<MTLRenderCommandEncoder> enc =
            [cmdBuf renderCommandEncoderWithDescriptor:rpd];

        MTLViewport gridViewport = {
            .originX = 0, .originY = 0,
            .width = dW, .height = dH,
            .znear = 0, .zfar = 1
        };
        [enc setViewport:gridViewport];

        // Fill gap areas outside the centered grid with the terminal background color.
        {
            float defR = g_theme_bg_r / 255.0f;
            float defG = g_theme_bg_g / 255.0f;
            float defB = g_theme_bg_b / 255.0f;
            float ba   = g_background_opacity;
            float gridRight  = offX + cols * gw;
            float gridBottom = offY + visibleRows * gh;
            Vertex gapVerts[24];
            int gvc = 0;
            if (offY > 0.5f)
                gvc = emitRectV(gapVerts, gvc, 0, 0, dW, offY, defR, defG, defB, ba);
            if (gridBottom + 0.5f < dH)
                gvc = emitRectV(gapVerts, gvc, 0, gridBottom, dW, dH - gridBottom, defR, defG, defB, ba);
            if (offX > 0.5f)
                gvc = emitRectV(gapVerts, gvc, 0, offY, offX, (float)visibleRows * gh, defR, defG, defB, ba);
            if (gridRight + 0.5f < dW)
                gvc = emitRectV(gapVerts, gvc, gridRight, offY, dW - gridRight, (float)visibleRows * gh, defR, defG, defB, ba);
            if (gvc > 0) {
                [enc setRenderPipelineState:self.bgPipeline];
                [enc setVertexBytes:gapVerts length:sizeof(Vertex) * gvc atIndex:0];
                [enc setVertexBytes:viewport length:sizeof(viewport) atIndex:1];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:gvc];
            }
        }

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

        if (ci > 0 && _glyphCache.color_texture) {
            [enc setRenderPipelineState:self.colorPipeline];
            [enc setVertexBuffer:_colorMetalBuf offset:0 atIndex:0];
            [enc setVertexBytes:viewport length:sizeof(viewport) atIndex:1];
            [enc setFragmentTexture:_glyphCache.color_texture atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:ci];
        }

        // Kitty graphics: draw image placements over text.
        [self drawImagesWithEncoder:enc viewport:viewport
                             glyphW:gw glyphH:gh offX:offX offY:offY];

        // Overlay layers (debug card, etc.) — use baseOffY so overlays are NOT shifted
        [self drawOverlaysWithEncoder:enc viewport:viewport
                               glyphW:gw glyphH:gh offX:offX offY:baseOffY];
        _lastOverlayGen = g_overlay_gen;

        // Popup terminal (drawn after overlays, before IME)
        [self drawPopupWithEncoder:enc viewport:viewport
                            glyphW:gw glyphH:gh offX:offX offY:offY];
        _lastPopupGen = g_popup_gen;

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
                    float x0 = offX + (pCol + i) * gw;
                    float y0 = offY + pRow * gh;
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
                float ulY0 = offY + pRow * gh + gh - ulH;
                float ulY1 = offY + pRow * gh + gh;
                float ulX0 = offX + pCol * gw;
                float ulX1 = offX + (pCol + preCells) * gw;
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
                    float x0 = offX + (pCol + i) * gw;
                    float y0 = offY + pRow * gh;
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
