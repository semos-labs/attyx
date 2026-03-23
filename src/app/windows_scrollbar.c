// Attyx — Windows scrollbar (custom-rendered, Direct3D)
// Thin scroll indicator on the right edge, in the padding area.

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
    float thumbH = fmaxf((visibleRows / totalLines) * trackH, 16.0f);
    // vp=0 → bottom, vp=sb → top
    float thumbY = offY + (1.0f - (float)vp / (float)sb) * (trackH - thumbH);

    float barW = 3.0f * g_content_scale;
    float gridRight = offX + cols * gw;
    float barX = gridRight + 2.0f * g_content_scale;

    float fg = g_theme_bg_r < 128 ? 1.0f : 0.0f;

    // Thumb only, no track
    if (vi + 6 <= vertCap)
        vi = winEmitRect(verts, vi, barX, thumbY, barW, thumbH, fg, fg, fg, 0.3f);

    return vi;
}

#endif // _WIN32
