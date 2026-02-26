// Attyx — Linux popup terminal draw pass (OpenGL 3.3)
// Draws popup overlay after regular overlays, using existing GL programs.

#ifdef __linux__

#include "linux_internal.h"

#define POPUP_CHUNK 2048

void drawPopup(float offX, float offY, float gw, float gh,
               float viewport[2]) {
    if (!g_popup_desc.active) return;

    AttyxPopupDesc desc = g_popup_desc;
    int totalCells = desc.width * desc.height;
    if (totalCells <= 0 || totalCells > ATTYX_POPUP_MAX_CELLS) return;

    // 1. Draw dim overlay (full-screen translucent black rect)
    {
        Vertex dimVerts[6];
        emitRect(dimVerts, 0, 0, 0, viewport[0], viewport[1],
                 0, 0, 0, 0.4f);
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glUseProgram(g_solid_prog);
        glUniform2f(g_vp_loc_solid, viewport[0], viewport[1]);
        glBindBuffer(GL_ARRAY_BUFFER, g_vbo);
        glBufferData(GL_ARRAY_BUFFER, sizeof(dimVerts),
                     dimVerts, GL_DYNAMIC_DRAW);
        setupVertexAttribs();
        glDrawArrays(GL_TRIANGLES, 0, 6);
        glDisable(GL_BLEND);
    }

    // 2. Draw popup cells in chunks
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

            if (bi + 6 <= POPUP_CHUNK * 6) {
                bi = emitRect(bgVerts, bi, x, y, gw, gh,
                              cell.bg_r / 255.0f,
                              cell.bg_g / 255.0f,
                              cell.bg_b / 255.0f,
                              alpha);
            }

            if (cell.character > 32 && ti + 6 <= POPUP_CHUNK * 6) {
                ti = emitGlyph(textVerts, ti, &g_gc, cell.character,
                               x, y, gw, gh,
                               cell.fg_r / 255.0f,
                               cell.fg_g / 255.0f,
                               cell.fg_b / 255.0f);
            }
        }

        // Draw bg chunk
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

        // Draw text chunk
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

    // 3. Draw popup cursor
    if (desc.cursor_visible) {
        int curGridCol = desc.col + 1 + desc.cursor_col;
        int curGridRow = desc.row + 1 + desc.cursor_row;
        float cx = offX + curGridCol * gw;
        float cy = offY + curGridRow * gh;

        Vertex curVerts[6];
        emitRect(curVerts, 0, cx, cy, gw, gh, 0.8f, 0.8f, 0.8f, 0.8f);

        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glUseProgram(g_solid_prog);
        glUniform2f(g_vp_loc_solid, viewport[0], viewport[1]);
        glBindBuffer(GL_ARRAY_BUFFER, g_vbo);
        glBufferData(GL_ARRAY_BUFFER, sizeof(curVerts),
                     curVerts, GL_DYNAMIC_DRAW);
        setupVertexAttribs();
        glDrawArrays(GL_TRIANGLES, 0, 6);
        glDisable(GL_BLEND);
    }
}

#endif // __linux__
