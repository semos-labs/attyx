// Attyx — Windows renderer draw logic (Direct3D 11)
// Cell background, cursor, selection, decoration, search highlight vertex generation.
// Split from windows_renderer.c to keep files under 600 lines.

#ifdef _WIN32

#include "windows_internal.h"

// ---------------------------------------------------------------------------
// Draw state (shared with windows_renderer.c via extern declarations)
// ---------------------------------------------------------------------------

WinVertex*   g_win_bg_verts        = NULL;
WinVertex*   g_win_text_verts      = NULL;
int          g_win_total_text_verts = 0;
AttyxCell*   g_win_cell_snapshot   = NULL;
int          g_win_cell_snapshot_cap = 0;
int          g_win_alloc_rows      = 0;
int          g_win_alloc_cols      = 0;
int          g_win_bg_vert_cap     = 0;

int          g_win_prev_cursor_row   = -1;
int          g_win_prev_cursor_col   = -1;
int          g_win_prev_cursor_shape = -1;
int          g_win_prev_cursor_vis   = -1;
int          g_win_blink_on          = 1;

// ---------------------------------------------------------------------------
// Build cell background vertices for dirty rows
// ---------------------------------------------------------------------------

static int build_bg_verts(WinVertex* verts, AttyxCell* cells,
                           int visibleRows, int cols, int total,
                           float offX, float offY, float gw, float gh,
                           const uint64_t dirty[4]) {
    for (int row = 0; row < visibleRows; row++) {
        if (!g_full_redraw && !dirtyBitTest(dirty, row)) continue;
        for (int col = 0; col < cols; col++) {
            int i = row * cols + col;
            float x0 = offX + col * gw, y0 = offY + row * gh;
            const AttyxCell* cell = &cells[i];
            float br, bg, bb, ba;
            winCellBgColor(cell, row, col, &br, &bg, &bb, &ba);
            int bi = i * 6;
            verts[bi+0] = (WinVertex){ x0,     y0,     0,0, br,bg,bb,ba };
            verts[bi+1] = (WinVertex){ x0+gw,  y0,     0,0, br,bg,bb,ba };
            verts[bi+2] = (WinVertex){ x0,     y0+gh,  0,0, br,bg,bb,ba };
            verts[bi+3] = (WinVertex){ x0+gw,  y0,     0,0, br,bg,bb,ba };
            verts[bi+4] = (WinVertex){ x0+gw,  y0+gh,  0,0, br,bg,bb,ba };
            verts[bi+5] = (WinVertex){ x0,     y0+gh,  0,0, br,bg,bb,ba };
        }
    }
    int visibleTotal = visibleRows * cols;
    if (visibleTotal < total)
        memset(&verts[visibleTotal * 6], 0, sizeof(WinVertex) * 6 * (total - visibleTotal));
    return total * 6;
}

// ---------------------------------------------------------------------------
// Append cursor quad
// ---------------------------------------------------------------------------

static int build_cursor(WinVertex* verts, int bgVertCount,
                         int curRow, int curCol, int curShape, int curVis,
                         int visibleRows, int cols, int total,
                         float offX, float baseOffY, float gw, float gh) {
    int cursorSlot = total * 6;
    memset(&verts[cursorSlot], 0, sizeof(WinVertex) * 6);

    int drawCursor = curVis && g_win_blink_on
                     && curRow >= g_grid_top_offset
                     && curRow < (g_grid_top_offset + visibleRows)
                     && curCol >= 0 && curCol < cols;
    if (!drawCursor) return bgVertCount;

    float cx0 = offX + curCol * gw;
    float cy0 = baseOffY + curRow * gh;
    float cr, cg_c, cb;
    winCursorColor(&cr, &cg_c, &cb);
    float rx0 = cx0, ry0 = cy0, rx1 = cx0 + gw, ry1 = cy0 + gh;

    switch (curShape) {
        case 0: case 1: break;
        case 2: case 3: { float th = fmaxf(2.0f, 1.0f); ry0 = ry1 - th; break; }
        case 4: case 5: { float th = fmaxf(2.0f, 1.0f); rx1 = rx0 + th; break; }
        default: break;
    }

    verts[cursorSlot+0] = (WinVertex){ rx0,ry0, 0,0, cr,cg_c,cb,1 };
    verts[cursorSlot+1] = (WinVertex){ rx1,ry0, 0,0, cr,cg_c,cb,1 };
    verts[cursorSlot+2] = (WinVertex){ rx0,ry1, 0,0, cr,cg_c,cb,1 };
    verts[cursorSlot+3] = (WinVertex){ rx1,ry0, 0,0, cr,cg_c,cb,1 };
    verts[cursorSlot+4] = (WinVertex){ rx1,ry1, 0,0, cr,cg_c,cb,1 };
    verts[cursorSlot+5] = (WinVertex){ rx0,ry1, 0,0, cr,cg_c,cb,1 };
    return bgVertCount + 6;
}

// ---------------------------------------------------------------------------
// Copy-mode cursor
// ---------------------------------------------------------------------------

static int build_copy_cursor(WinVertex* verts, int bgVertCount,
                              int visibleRows, int cols,
                              float offX, float offY, float gw, float gh) {
    if (!g_copy_mode) return bgVertCount;
    int cmRow = g_copy_cursor_row;
    int cmCol = g_copy_cursor_col;
    if (cmRow < 0 || cmRow >= visibleRows || cmCol < 0 || cmCol >= cols) return bgVertCount;
    float cr, cg_c, cb;
    winCursorColor(&cr, &cg_c, &cb);
    return winEmitRect(verts, bgVertCount,
                        offX + cmCol * gw, offY + cmRow * gh,
                        gw, gh, cr, cg_c, cb, 1);
}

// ---------------------------------------------------------------------------
// Hyperlink underlines
// ---------------------------------------------------------------------------

static int build_link_underlines(WinVertex* verts, int bgVertCount, int vertCap,
                                  AttyxCell* cells, int visibleTotal, int cols,
                                  float offX, float offY, float gw, float gh) {
    if (g_sel_active) return bgVertCount;
    uint32_t hoverLid = g_hover_link_id;
    float ulH = fmaxf(2.0f, 1.0f);
    for (int i = 0; i < visibleTotal; i++) {
        uint32_t lid = cells[i].link_id;
        if (lid == 0) continue;
        if (bgVertCount + 6 > vertCap) break;
        float lr, lg, lb;
        if (lid == hoverLid) { lr = 0.4f; lg = 0.7f; lb = 1.0f; }
        else                 { lr = 0.25f; lg = 0.40f; lb = 0.65f; }
        int lrow = i / cols, lcol = i % cols;
        float lx0 = offX + lcol * gw;
        float ly1 = offY + (lrow + 1) * gh;
        float ly0 = ly1 - ulH;
        bgVertCount = winEmitRect(verts, bgVertCount,
                                   lx0, ly0, gw, ulH, lr, lg, lb, 1);
    }
    return bgVertCount;
}

// ---------------------------------------------------------------------------
// Search highlights
// ---------------------------------------------------------------------------

static int build_search_highlights(WinVertex* verts, int bgVertCount, int vertCap,
                                    int visibleRows, int cols,
                                    float offX, float offY, float gw, float gh) {
    if (!g_search_active) return bgVertCount;
    int visCount = g_search_vis_count;
    int srchRow = g_search_cur_vis_row;
    int srchCs  = g_search_cur_vis_cs;
    int srchCe  = g_search_cur_vis_ce;
    int spr = g_pane_rect_row, spc = g_pane_rect_col;
    for (int vi = 0; vi < visCount && vi < ATTYX_SEARCH_VIS_MAX; vi++) {
        AttyxSearchVis m = g_search_vis[vi];
        int drawRow = m.row + spr;
        if (m.row < 0 || drawRow >= visibleRows) continue;
        int isCur = (m.row == srchRow && m.col_start == srchCs && m.col_end == srchCe);
        float hr = 1.0f, hg = 0.6f, hb = 0.0f;
        float ha = isCur ? 0.75f : 0.28f;
        for (int cc = m.col_start; cc < m.col_end && cc < cols; cc++) {
            if (bgVertCount + 6 > vertCap) break;
            bgVertCount = winEmitRect(verts, bgVertCount,
                                       offX + (spc + cc) * gw, offY + drawRow * gh,
                                       gw, gh, hr, hg, hb, ha);
        }
    }
    return bgVertCount;
}

// ---------------------------------------------------------------------------
// Underline + strikethrough decorations
// ---------------------------------------------------------------------------

static int build_decorations(WinVertex* verts, int bgVertCount, int vertCap,
                              AttyxCell* cells, int visibleTotal, int cols,
                              float offX, float offY, float gw, float gh) {
    float decoH = fmaxf(2.0f, 1.0f);
    for (int i = 0; i < visibleTotal; i++) {
        const AttyxCell* cell = &cells[i];
        if (cell->character == 0x10EEEE) continue;
        uint8_t fl = cell->flags;
        int hasUnderline = (fl & 2);
        int hasStrike    = (fl & 32);
        if (!hasUnderline && !hasStrike) continue;
        int drow = i / cols, dcol = i % cols;
        float dr = cell->fg_r / 255.0f;
        float dg = cell->fg_g / 255.0f;
        float db = cell->fg_b / 255.0f;
        float dx0 = offX + dcol * gw;
        if (hasUnderline && bgVertCount + 6 <= vertCap) {
            float uy1 = offY + (drow + 1) * gh;
            bgVertCount = winEmitRect(verts, bgVertCount,
                                       dx0, uy1 - decoH, gw, decoH, dr, dg, db, 1);
        }
        if (hasStrike && bgVertCount + 6 <= vertCap) {
            float sy0 = offY + drow * gh + gh * 0.5f - decoH * 0.5f;
            bgVertCount = winEmitRect(verts, bgVertCount,
                                       dx0, sy0, gw, decoH, dr, dg, db, 1);
        }
    }
    return bgVertCount;
}

// ---------------------------------------------------------------------------
// Build text vertices (glyph atlas quads)
// ---------------------------------------------------------------------------

static int build_text_verts(WinVertex* verts, AttyxCell* cells,
                             int visibleRows, int cols,
                             float offX, float offY, float gw, float gh,
                             int curRow, int curCol, int curShape, int curVis) {
    if (!g_gc.texture || !g_gc.texture_srv) return 0;

    int visibleTotal = visibleRows * cols;
    int atlasCols = g_gc.atlas_cols;
    float glyphW = g_gc.glyph_w;
    float glyphH = g_gc.glyph_h;
    float atlasW = (float)g_gc.atlas_w;

    int drawCursor = curVis && g_win_blink_on
                     && curRow >= g_grid_top_offset
                     && curRow < (g_grid_top_offset + visibleRows)
                     && curCol >= 0 && curCol < cols;

    int ti = 0;
    for (int i = 0; i < visibleTotal; ) {
        const AttyxCell* cell = &cells[i];
        uint32_t ch = cell->character;
        if (ch <= 32 || ch == 0x10EEEE) { i++; continue; }

        int row = i / cols, col = i % cols;

        // --- Ligature detection ---
        if (g_font_ligatures && isLigaTrigger(ch) && !cell->combining[0]) {
            int maxRun = cols - col;
            if (maxRun > MAX_LIGA_LEN) maxRun = MAX_LIGA_LEN;
            int runLen = 1;
            while (runLen < maxRun) {
                const AttyxCell* next = &cells[i + runLen];
                if (!isLigaTrigger(next->character)) break;
                if (next->combining[0]) break;
                if (next->fg_r != cell->fg_r || next->fg_g != cell->fg_g
                    || next->fg_b != cell->fg_b) break;
                if ((next->flags & 0x11) != (cell->flags & 0x11)) break;
                runLen++;
            }
            if (runLen >= 2) {
                uint32_t cps[MAX_LIGA_LEN];
                for (int k = 0; k < runLen; k++) cps[k] = cells[i+k].character;
                int ligaStyle = ((cell->flags & 0x01) ? 1 : 0)
                              | ((cell->flags & 0x10) ? 2 : 0);
                const LigaResult* lr = shapeLigatureRun(&g_gc, cps, runLen, ligaStyle);
                atlasW = (float)g_gc.atlas_w;
                if (lr && lr->hasAlternates) {
                    for (int k = 0; k < runLen; k++) {
                        int sSlot = lr->slots[k];
                        if (sSlot < 0) continue;
                        int sac = sSlot % atlasCols;
                        int sar = sSlot / atlasCols;
                        float atlasH = (float)g_gc.atlas_h;
                        float su0 = sac       * glyphW / atlasW;
                        float sv0 = sar       * glyphH / atlasH;
                        float su1 = (sac + 1) * glyphW / atlasW;
                        float sv1 = (sar + 1) * glyphH / atlasH;
                        float lx0 = offX + (col + k) * gw;
                        float ly0 = offY + row * gh;
                        float lx1 = lx0 + gw;
                        float ly1 = ly0 + gh;
                        float fr, fg, fb;
                        winCellFgColor(cell, row, col + k, drawCursor,
                                       curRow - g_grid_top_offset, curCol, curShape,
                                       &fr, &fg, &fb);
                        ti = winEmitQuad(verts, ti, lx0, ly0, lx1, ly1,
                                         su0, sv0, su1, sv1, fr, fg, fb, 1);
                    }
                    i += runLen;
                    continue;
                }
            }
        }

        // --- Normal per-cell rendering ---
        float x0 = offX + col * gw, y0 = offY + row * gh;
        float x1 = x0 + gw, y1 = y0 + gh;

        uint32_t key = ch;
        uint8_t fl = cell->flags;
        if (fl & 0x01) key |= GLYPH_BOLD_BIT;
        if (fl & 0x10) key |= GLYPH_ITALIC_BIT;
        bool hasCombining = (cell->combining[0] != 0);
        if (hasCombining) key = combiningKey(ch, cell->combining[0], cell->combining[1]);

        int rawSlot = glyphCacheLookup(&g_gc, key);
        if (rawSlot < 0) {
            rawSlot = hasCombining
                ? glyphCacheRasterizeCombined(&g_gc, ch, cell->combining[0], cell->combining[1])
                : glyphCacheRasterize(&g_gc, key);
            atlasW = (float)g_gc.atlas_w;
        }

        int wide = (rawSlot & GLYPH_WIDE_BIT) ? 1 : 0;
        int slot = rawSlot & ~(GLYPH_WIDE_BIT | GLYPH_COLOR_BIT);

        int ac = slot % atlasCols;
        int ar = slot / atlasCols;
        float atlasH = (float)g_gc.atlas_h;
        float au0 = ac              * glyphW / atlasW;
        float av0 = ar              * glyphH / atlasH;
        float au1 = (ac + 1 + wide) * glyphW / atlasW;
        float av1 = (ar + 1)        * glyphH / atlasH;

        float x1w = wide ? x0 + 2.0f * gw : x1;

        float fr, fg, fb;
        winCellFgColor(cell, row, col, drawCursor,
                       curRow - g_grid_top_offset, curCol, curShape,
                       &fr, &fg, &fb);

        ti = winEmitQuad(verts, ti, x0, y0, x1w, y1,
                         au0, av0, au1, av1, fr, fg, fb, 1);
        i++;
    }
    return ti;
}

// ---------------------------------------------------------------------------
// Public: build all vertices for the frame
// ---------------------------------------------------------------------------

int winBuildFrameVerts(AttyxCell* cells, const uint64_t dirty[4],
                       int rows, int cols, int total,
                       int curRow, int curCol, int curShape, int curVis,
                       float offX, float baseOffY, float offY,
                       float gw, float gh,
                       int visibleRows, int visibleTotal) {
    int bgVertCount = build_bg_verts(g_win_bg_verts, cells, visibleRows, cols,
                                      total, offX, offY, gw, gh, dirty);

    bgVertCount = build_cursor(g_win_bg_verts, bgVertCount,
                                curRow, curCol, curShape, curVis,
                                visibleRows, cols, total,
                                offX, baseOffY, gw, gh);

    bgVertCount = build_copy_cursor(g_win_bg_verts, bgVertCount,
                                     visibleRows, cols, offX, offY, gw, gh);

    bgVertCount = build_link_underlines(g_win_bg_verts, bgVertCount, g_win_bg_vert_cap,
                                         cells, visibleTotal, cols, offX, offY, gw, gh);

    bgVertCount = build_search_highlights(g_win_bg_verts, bgVertCount, g_win_bg_vert_cap,
                                           visibleRows, cols, offX, offY, gw, gh);

    bgVertCount = build_decorations(g_win_bg_verts, bgVertCount, g_win_bg_vert_cap,
                                     cells, visibleTotal, cols, offX, offY, gw, gh);

    bgVertCount = winBuildScrollbar(g_win_bg_verts, bgVertCount, g_win_bg_vert_cap,
                                     offX, offY, gw, gh, cols, visibleRows);

    // Build text vertices
    g_win_total_text_verts = build_text_verts(g_win_text_verts, cells,
                                              visibleRows, cols,
                                              offX, offY, gw, gh,
                                              curRow, curCol, curShape, curVis);

    return bgVertCount;
}

#endif // _WIN32
