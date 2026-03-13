// Attyx — Linux overlay draw pass (OpenGL 3.3)
// Draws overlay layers after terminal content, using existing GL programs.

#ifdef __linux__

#include "linux_internal.h"

#define OVERLAY_MAX_BG_VERTS    (2048 * 6)
#define OVERLAY_MAX_TEXT_VERTS  (2048 * 6)

void drawOverlays(float offX, float offY, float gw, float gh,
                  float viewport[2]) {
    int count = g_overlay_count;
    if (count <= 0) return;
    if (count > ATTYX_OVERLAY_MAX_LAYERS) count = ATTYX_OVERLAY_MAX_LAYERS;

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
                glEnable(GL_BLEND);
                glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
                glUseProgram(g_solid_prog);
                glUniform2f(g_vp_loc_solid, viewport[0], viewport[1]);
                glBindBuffer(GL_ARRAY_BUFFER, g_vbo);
                glBufferData(GL_ARRAY_BUFFER, sizeof(Vertex) * bi,
                             bgVerts, GL_DYNAMIC_DRAW);
                setupVertexAttribs();
                glDrawArrays(GL_TRIANGLES, 0, bi);
                glDisable(GL_BLEND);
                bi = 0;
            }
            if (ti > 0) {
                glEnable(GL_BLEND);
                glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
                glUseProgram(g_text_prog);
                glUniform2f(g_vp_loc_text, viewport[0], viewport[1]);
                glActiveTexture(GL_TEXTURE0);
                glBindTexture(GL_TEXTURE_2D, g_gc.texture);
                glUniform1i(g_tex_loc, 0);
                glBufferData(GL_ARRAY_BUFFER, sizeof(Vertex) * ti,
                             textVerts, GL_DYNAMIC_DRAW);
                setupVertexAttribs();
                glDrawArrays(GL_TRIANGLES, 0, ti);
                glDisable(GL_BLEND);
                ti = 0;
            }
            // Draw full-screen dim rect
            float ba = desc.backdrop_alpha / 255.0f;
            Vertex dimVerts[6];
            emitRect(dimVerts, 0, 0, 0, viewport[0], viewport[1], 0, 0, 0, ba);
            glEnable(GL_BLEND);
            glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
            glUseProgram(g_solid_prog);
            glUniform2f(g_vp_loc_solid, viewport[0], viewport[1]);
            glBindBuffer(GL_ARRAY_BUFFER, g_vbo);
            glBufferData(GL_ARRAY_BUFFER, sizeof(Vertex) * 6,
                         dimVerts, GL_DYNAMIC_DRAW);
            setupVertexAttribs();
            glDrawArrays(GL_TRIANGLES, 0, 6);
            glDisable(GL_BLEND);
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
                bool hasCombining = (cell.combining[0] != 0
                                     && cell.combining[0] != 0xFE0F);
                uint32_t key = hasCombining ? combiningKey(ch, cell.combining[0], cell.combining[1]) : ch;

                int rawSlot = glyphCacheLookup(&g_gc, key);
                if (rawSlot < 0) {
                    rawSlot = hasCombining
                        ? glyphCacheRasterizeCombined(&g_gc, ch, cell.combining[0], cell.combining[1])
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

    // Draw background quads
    if (bi > 0) {
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glUseProgram(g_solid_prog);
        glUniform2f(g_vp_loc_solid, viewport[0], viewport[1]);
        glBindBuffer(GL_ARRAY_BUFFER, g_vbo);
        glBufferData(GL_ARRAY_BUFFER, sizeof(Vertex) * bi,
                     bgVerts, GL_DYNAMIC_DRAW);
        setupVertexAttribs();
        glDrawArrays(GL_TRIANGLES, 0, bi);
        glDisable(GL_BLEND);
    }

    // Draw text glyphs
    if (ti > 0) {
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glUseProgram(g_text_prog);
        glUniform2f(g_vp_loc_text, viewport[0], viewport[1]);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, g_gc.texture);
        glUniform1i(g_tex_loc, 0);
        glBufferData(GL_ARRAY_BUFFER, sizeof(Vertex) * ti,
                     textVerts, GL_DYNAMIC_DRAW);
        setupVertexAttribs();
        glDrawArrays(GL_TRIANGLES, 0, ti);
        glDisable(GL_BLEND);
    }
}

#endif // __linux__
