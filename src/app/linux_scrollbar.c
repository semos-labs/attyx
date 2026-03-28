// Attyx — Linux scrollbar (custom-rendered, OpenGL)
// Thin scroll indicator on the right edge, in the padding area.

#include "linux_internal.h"

void drawScrollbar(float offX, float offY, float gw, float gh,
                   int cols, int visibleRows, float viewport[2]) {
    if (!g_window_scrollbar) return;

    int sb = g_scrollback_count;
    int vp = g_viewport_offset;
    if (sb <= 0 || g_alt_screen) return;

    float trackH = visibleRows * gh;
    if (trackH <= 0) return;

    float totalLines = (float)(sb + visibleRows);
    float thumbH = fmaxf((visibleRows / totalLines) * trackH, 16.0f);
    // vp=0 → bottom, vp=sb → top
    float thumbY = offY + (1.0f - (float)vp / (float)sb) * (trackH - thumbH);

    float barW = 3.0f * g_content_scale;
    float gridRight = offX + cols * gw;
    float barX = gridRight + 2.0f * g_content_scale; // in the padding, not overlapping content

    float fg = g_theme_bg_r < 128 ? 1.0f : 0.0f;

    Vertex sv[6];
    int vi = emitRect(sv, 0, barX, thumbY, barW, thumbH, fg, fg, fg, 0.3f);

    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glUseProgram(g_solid_prog);
    glUniform2f(g_vp_loc_solid, viewport[0], viewport[1]);
    glBindVertexArray(g_vao);
    glBindBuffer(GL_ARRAY_BUFFER, g_vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(Vertex) * vi, sv, GL_DYNAMIC_DRAW);
    setupVertexAttribs();
    glDrawArrays(GL_TRIANGLES, 0, vi);
    glDisable(GL_BLEND);
}
