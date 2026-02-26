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

    // 3. Draw popup cursor (shape-aware + themed color + trail)
    {
        static float s_popupTrailX, s_popupTrailY;
        static double s_popupTrailLastTime;
        static int   s_popupPrevRow = -1, s_popupPrevCol = -1;

        int curCol = desc.cursor_col;
        int curRow = desc.cursor_row;
        int curShape = desc.cursor_shape;
        int curGridCol = desc.col + curCol;
        int curGridRow = desc.row + curRow;
        float cx = offX + curGridCol * gw;
        float cy = offY + curGridRow * gh;

        int cursorChanged = (curRow != s_popupPrevRow || curCol != s_popupPrevCol);

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

        // Cursor trail (Neovide-style exponential-decay comet)
        double now = glfwGetTime();
        if (g_cursor_trail && desc.cursor_visible && cursorChanged && s_popupPrevRow >= 0) {
            int cellDist = abs(curRow - s_popupPrevRow) + abs(curCol - s_popupPrevCol);
            if (cellDist > 1) {
                s_popupTrailX = offX + (desc.col + s_popupPrevCol) * gw;
                s_popupTrailY = offY + (desc.row + s_popupPrevRow) * gh;
                g_popup_trail_active = 1;
                s_popupTrailLastTime = now;
            }
        }
        if (g_popup_trail_active && !desc.cursor_visible) g_popup_trail_active = 0;
        if (g_popup_trail_active && g_cursor_trail && desc.cursor_visible) {
            float targetX = cx;
            float targetY = cy;
            float dt = (float)(now - s_popupTrailLastTime);
            s_popupTrailLastTime = now;
            float speed = 14.0f;
            float t = 1.0f - expf(-speed * dt);
            s_popupTrailX += (targetX - s_popupTrailX) * t;
            s_popupTrailY += (targetY - s_popupTrailY) * t;
            float dx = targetX - s_popupTrailX;
            float dy = targetY - s_popupTrailY;
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

                float tx0 = s_popupTrailX + cxOff, ty0 = s_popupTrailY + cyOff;
                float tx1 = tx0 + cw,               ty1 = ty0 + ch;
                float cx0 = targetX + cxOff,         cy0 = targetY + cyOff;
                float cx1 = cx0 + cw,                cy1 = cy0 + ch;

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

                glEnable(GL_BLEND);
                glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
                glUseProgram(g_solid_prog);
                glUniform2f(g_vp_loc_solid, viewport[0], viewport[1]);
                glBindBuffer(GL_ARRAY_BUFFER, g_vbo);
                glBufferData(GL_ARRAY_BUFFER, sizeof(trailVerts),
                             trailVerts, GL_DYNAMIC_DRAW);
                setupVertexAttribs();
                glDrawArrays(GL_TRIANGLES, 0, 12);
                glDisable(GL_BLEND);
            }
        }

        s_popupPrevRow = curRow;
        s_popupPrevCol = curCol;
    }
}

#endif // __linux__
