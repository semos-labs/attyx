// Attyx — Windows overlay draw pass (Direct3D 11)
// Draws overlay layers after terminal content using shared D3D11 state.
// Uses winDrawSolidVerts/winDrawTextVerts from windows_render_util.c for
// D3D11 buffer submission.

#ifdef _WIN32

#include "windows_internal.h"

#define OVERLAY_MAX_BG_VERTS    (2048 * 6)
#define OVERLAY_MAX_TEXT_VERTS  (2048 * 6)

void drawOverlays(float offX, float offY, float gw, float gh,
                  int vpW, int vpH) {
    int count = g_overlay_count;
    static int logged = 0;
    if (!logged && count > 0) {
        logged = 1;
        fprintf(stderr, "[attyx] drawOverlays: count=%d desc0: vis=%d col=%d row=%d w=%d h=%d cells=%d\n",
                count, g_overlay_descs[0].visible, g_overlay_descs[0].col, g_overlay_descs[0].row,
                g_overlay_descs[0].width, g_overlay_descs[0].height, g_overlay_descs[0].cell_count);
        fflush(stderr);
    }
    if (count <= 0) return;
    if (count > ATTYX_OVERLAY_MAX_LAYERS) count = ATTYX_OVERLAY_MAX_LAYERS;
    if (!g_d3d_device || !g_d3d_context) return;

    WinVertex bgVerts[OVERLAY_MAX_BG_VERTS];
    WinVertex textVerts[OVERLAY_MAX_TEXT_VERTS];
    int bi = 0, ti = 0;

    for (int layer = 0; layer < count; layer++) {
        AttyxOverlayDesc desc = g_overlay_descs[layer];
        if (!desc.visible) continue;
        if (desc.cell_count <= 0) continue;

        // Backdrop: full-screen dim rect — flush accumulated verts first
        if (desc.backdrop_alpha > 0) {
            if (bi > 0) {
                winDrawSolidVerts(bgVerts, bi);
                bi = 0;
            }
            if (ti > 0) {
                winDrawTextVerts(textVerts, ti, &g_gc);
                ti = 0;
            }
            // Draw full-screen dim rect
            float ba = desc.backdrop_alpha / 255.0f;
            WinVertex dimVerts[6];
            winEmitRect(dimVerts, 0, 0, 0, (float)vpW, (float)vpH,
                        0, 0, 0, ba);
            winDrawSolidVerts(dimVerts, 6);
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
                bi = winEmitRect(bgVerts, bi, x, y, gw, gh,
                                 cell.bg_r / 255.0f,
                                 cell.bg_g / 255.0f,
                                 cell.bg_b / 255.0f,
                                 alpha);
            }

            // Resolve fg color
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

            // Text glyph
            if (cell.character > 32 && ti + 6 <= OVERLAY_MAX_TEXT_VERTS) {
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
                                 fgR, fgG, fgB, 1.0f);
            }

            // Underline
            if ((flags & 0x02) && bi + 6 <= OVERLAY_MAX_BG_VERTS) {
                float lineH = gh > 8.0f ? 2.0f : 1.0f;
                bi = winEmitRect(bgVerts, bi, x, y + gh - lineH, gw, lineH,
                                 fgR, fgG, fgB, 1.0f);
            }

            // Strikethrough
            if ((flags & 0x20) && bi + 6 <= OVERLAY_MAX_BG_VERTS) {
                float lineH = gh > 8.0f ? 2.0f : 1.0f;
                bi = winEmitRect(bgVerts, bi, x, y + gh * 0.5f - lineH * 0.5f,
                                 gw, lineH, fgR, fgG, fgB, 1.0f);
            }
        }
    }

    // Flush remaining bg quads
    if (bi > 0) {
        winDrawSolidVerts(bgVerts, bi);
    }

    // Flush remaining text glyphs
    if (ti > 0) {
        winDrawTextVerts(textVerts, ti, &g_gc);
    }
}

#endif // _WIN32
