// Attyx — Linux scrollbar (custom-rendered, OpenGL)
// Draws a thin semi-transparent scrollbar on the right edge of the grid.

#include "linux_internal.h"

void drawScrollbar(float offX, float offY, float gw, float gh,
                   int cols, int visibleRows, float viewport[2]) {
    int sb = g_scrollback_count;
    int vp = g_viewport_offset;
    if (sb <= 0 || g_alt_screen) return;

    float trackH = visibleRows * gh;
    if (trackH <= 0) return;

    float totalLines = (float)(sb + visibleRows);
    float thumbH = fmaxf((visibleRows / totalLines) * trackH, 12.0f);
    float scrollPos = (float)(sb - vp) / totalLines;
    float thumbY = offY + scrollPos * (trackH - thumbH);

    float barW = 6.0f * g_content_scale;
    float barX = offX + cols * gw - barW;

    // Theme-aware: use foreground color at low alpha
    float fg = g_theme_bg_r < 128 ? 1.0f : 0.0f; // light thumb on dark bg, dark on light

    Vertex sv[12];
    int vi = 0;

    // Track
    vi = emitRect(sv, vi, barX, offY, barW, trackH, fg, fg, fg, 0.06f);

    // Thumb
    vi = emitRect(sv, vi, barX, thumbY, barW, thumbH, fg, fg, fg, 0.35f);

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
