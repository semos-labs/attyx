// Attyx — Windows popup terminal draw pass (Direct3D 11)
// Draws popup overlay after regular overlays using shared D3D11 state.
// Uses winDrawSolidVerts/winDrawTextVerts from windows_render_util.c.

#ifdef _WIN32

#include "windows_internal.h"

#define POPUP_CHUNK 2048

void drawPopup(float offX, float offY, float gw, float gh,
               int vpW, int vpH) {
    if (!g_popup_desc.active) return;
    if (!g_d3d_device || !g_d3d_context) return;

    AttyxPopupDesc desc = g_popup_desc;
    int totalCells = desc.width * desc.height;
    if (totalCells <= 0 || totalCells > ATTYX_POPUP_MAX_CELLS) return;

    // 1. Dim overlay (full-screen translucent black rect)
    {
        WinVertex dimVerts[6];
        winEmitRect(dimVerts, 0, 0, 0, (float)vpW, (float)vpH,
                    0, 0, 0, 0.4f);
        winDrawSolidVerts(dimVerts, 6);
    }

    // 2. Draw popup cells in chunks
    for (int start = 0; start < totalCells; start += POPUP_CHUNK) {
        int end = (start + POPUP_CHUNK < totalCells)
                  ? start + POPUP_CHUNK : totalCells;

        WinVertex bgVerts[POPUP_CHUNK * 6];
        WinVertex textVerts[POPUP_CHUNK * 6];
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
                bi = winEmitRect(bgVerts, bi, x, y, gw, gh,
                                 cell.bg_r / 255.0f,
                                 cell.bg_g / 255.0f,
                                 cell.bg_b / 255.0f,
                                 alpha);
            }

            // Text glyph
            if (cell.character > 32 && ti + 6 <= POPUP_CHUNK * 6) {
                uint32_t ch = cell.character;
                bool hasCombining = (cell.combining[0] != 0);
                uint32_t key = hasCombining
                    ? combiningKey(ch, cell.combining[0], cell.combining[1])
                    : ch;

                int rawSlot = glyphCacheLookup(&g_gc, key);
                if (rawSlot < 0) {
                    rawSlot = hasCombining
                        ? glyphCacheRasterizeCombined(&g_gc, ch,
                              cell.combining[0], cell.combining[1])
                        : glyphCacheRasterize(&g_gc, ch);
                }

                int wide = (rawSlot & GLYPH_WIDE_BIT) ? 1 : 0;
                int slot = rawSlot & ~(GLYPH_WIDE_BIT | GLYPH_COLOR_BIT);
                float glyphW = g_gc.glyph_w;
                float glyphH = g_gc.glyph_h;
                float atlasW = (float)g_gc.atlas_w;
                float atlasH = (float)g_gc.atlas_h;
                int atlasCols = g_gc.atlas_cols;
                int ac = slot % atlasCols;
                int ar = slot / atlasCols;
                float u0 = ac * glyphW / atlasW;
                float v0 = ar * glyphH / atlasH;
                float u1 = (ac + 1 + wide) * glyphW / atlasW;
                float v1 = (ar + 1) * glyphH / atlasH;
                float drawW = wide ? 2.0f * gw : gw;

                ti = winEmitQuad(textVerts, ti,
                                 x, y, x + drawW, y + gh,
                                 u0, v0, u1, v1,
                                 cell.fg_r / 255.0f,
                                 cell.fg_g / 255.0f,
                                 cell.fg_b / 255.0f,
                                 1.0f);
            }
        }

        // Submit bg + text vertex buffers
        if (bi > 0) winDrawSolidVerts(bgVerts, bi);
        if (ti > 0) winDrawTextVerts(textVerts, ti, &g_gc);
    }

    // 3. Popup cursor
    if (desc.cursor_visible) {
        int curGridCol = desc.col + desc.cursor_col;
        int curGridRow = desc.row + desc.cursor_row;
        float cx = offX + curGridCol * gw;
        float cy = offY + curGridRow * gh;

        float cr, ccg, cb;
        winCursorColor(&cr, &ccg, &cb);

        float rx0 = cx, ry0 = cy, rx1 = cx + gw, ry1 = cy + gh;
        switch (desc.cursor_shape) {
            case 2: case 3: { // underline
                float th = 2.0f;
                ry0 = ry1 - th;
                break;
            }
            case 4: case 5: { // bar
                float th = 2.0f;
                rx1 = rx0 + th;
                break;
            }
            default: break; // block
        }

        WinVertex curVerts[6];
        winEmitRect(curVerts, 0, rx0, ry0, rx1 - rx0, ry1 - ry0,
                    cr, ccg, cb, 1.0f);
        winDrawSolidVerts(curVerts, 6);
    }
}

#endif // _WIN32
