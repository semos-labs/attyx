// Attyx — Windows scrollbar (custom-rendered, Direct3D)
// Draws a thin semi-transparent scrollbar on the right edge of the grid.

#ifdef _WIN32

#include "windows_internal.h"
#include <math.h>

int winBuildScrollbar(WinVertex* verts, int vi, int vertCap,
                      float offX, float offY, float gw, float gh,
                      int cols, int visibleRows) {
    int sb = g_scrollback_count;
    int vp = g_viewport_offset;
    if (sb <= 0 || g_alt_screen) return vi;

    float trackH = visibleRows * gh;
    if (trackH <= 0) return vi;

    float totalLines = (float)(sb + visibleRows);
    float thumbH = fmaxf((visibleRows / totalLines) * trackH, 12.0f);
    float scrollPos = (float)(sb - vp) / totalLines;
    float thumbY = offY + scrollPos * (trackH - thumbH);

    float barW = 6.0f * g_content_scale;
    float barX = offX + cols * gw - barW;

    float fg = g_theme_bg_r < 128 ? 1.0f : 0.0f;

    // Track
    if (vi + 6 <= vertCap)
        vi = winEmitRect(verts, vi, barX, offY, barW, trackH, fg, fg, fg, 0.06f);

    // Thumb
    if (vi + 6 <= vertCap)
        vi = winEmitRect(verts, vi, barX, thumbY, barW, thumbH, fg, fg, fg, 0.35f);

    return vi;
}

#endif // _WIN32
