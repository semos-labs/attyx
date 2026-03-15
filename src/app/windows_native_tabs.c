// Attyx — Windows native tab bar renderer (D3D11)
//
// Renders a Windows Terminal-style tab bar in the custom titlebar area.
// Uses the existing D3D11 pipeline (solid rects + glyph text) to draw
// tabs, close buttons, a + button, and leaves space for caption buttons.

#ifdef _WIN32

#include "windows_internal.h"
#include <dwmapi.h>

// ---------------------------------------------------------------------------
// Layout constants (at 96 DPI — scaled by g_content_scale)
// ---------------------------------------------------------------------------

#define TAB_BAR_HEIGHT      36   // px at 96 DPI
#define CAPTION_BTN_WIDTH   46   // each: min, max, close
#define CAPTION_BTN_COUNT   3
#define CAPTION_TOTAL_W     (CAPTION_BTN_WIDTH * CAPTION_BTN_COUNT)
#define CLOSE_BTN_SIZE      14   // close X icon size
#define CLOSE_BTN_PAD       6    // padding inside close circle
#define PLUS_BTN_WIDTH      40   // + button width
#define TAB_PAD_H           10   // text padding inside tab
#define TAB_MIN_WIDTH       60   // minimum tab width
#define TAB_MAX_WIDTH       240  // maximum tab width

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

static int  s_hovered_tab   = -1;  // -1 = none, 0..N-1 = tab, N = plus btn
static int  s_hover_close   = 0;   // hovering over close X
static int  s_last_tab_count = 0;
static int  s_last_active    = -1;
static int  s_last_titles_gen = 0;

// Cached tab titles (UTF-16 for DirectWrite)
static wchar_t s_tab_titles[16][ATTYX_NATIVE_TAB_TITLE_MAX];
static int     s_title_lens[16];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static float ntab_scale(void) { return g_content_scale; }

float ntab_bar_height(void) {
    return TAB_BAR_HEIGHT * ntab_scale();
}

static float ntab_caption_width(void) {
    return CAPTION_TOTAL_W * ntab_scale();
}

static float ntab_tab_width(int tab_count, float bar_width) {
    float available = bar_width - ntab_caption_width() - PLUS_BTN_WIDTH * ntab_scale();
    float w = available / (float)(tab_count > 0 ? tab_count : 1);
    float sc = ntab_scale();
    if (w < TAB_MIN_WIDTH * sc) w = TAB_MIN_WIDTH * sc;
    if (w > TAB_MAX_WIDTH * sc) w = TAB_MAX_WIDTH * sc;
    return w;
}

static float ntab_tab_x(int idx, int tab_count, float bar_width) {
    return idx * ntab_tab_width(tab_count, bar_width);
}

// ---------------------------------------------------------------------------
// Title sync
// ---------------------------------------------------------------------------

static void ntab_sync_titles(void) {
    if (!g_native_tab_titles_changed) return;
    g_native_tab_titles_changed = 0;

    int cnt = g_native_tab_count;
    if (cnt < 1) cnt = 1;
    if (cnt > 16) cnt = 16;

    for (int i = 0; i < cnt; i++) {
        int len = MultiByteToWideChar(CP_UTF8, 0, g_native_tab_titles[i], -1,
                                       s_tab_titles[i], ATTYX_NATIVE_TAB_TITLE_MAX - 1);
        s_title_lens[i] = (len > 0) ? len - 1 : 0;  // exclude null
    }
}

// ---------------------------------------------------------------------------
// Draw — called from windows_renderer.c draw_frame
// ---------------------------------------------------------------------------

void ntab_draw(float vpW, float vpH) {
    if (!g_native_tabs_enabled) return;

    int tab_count = g_native_tab_count;
    int active = g_native_tab_active;
    if (tab_count < 1) tab_count = 1;
    if (tab_count > 16) tab_count = 16;
    if (active < 0) active = 0;
    if (active >= tab_count) active = tab_count - 1;

    // Show only when >1 tab or always-show is set
    if (tab_count <= 1 && !g_tab_always_show) return;

    ntab_sync_titles();

    float sc = ntab_scale();
    float barH = ntab_bar_height();
    float tabW = ntab_tab_width(tab_count, vpW);
    float captionW = ntab_caption_width();

    // Bar colors (dark theme, matching Windows Terminal)
    float barBgR = 0.12f, barBgG = 0.12f, barBgB = 0.12f;
    float activeBgR = 0.20f, activeBgG = 0.20f, activeBgB = 0.20f;
    float hoverBgR = 0.16f, hoverBgG = 0.16f, hoverBgB = 0.16f;
    float activeFgR = 1.0f, activeFgG = 1.0f, activeFgB = 1.0f;
    float inactiveFgR = 0.6f, inactiveFgG = 0.6f, inactiveFgB = 0.6f;
    float sepR = 1.0f, sepG = 1.0f, sepB = 1.0f, sepA = 0.08f;
    float closeHoverR = 1.0f, closeHoverG = 1.0f, closeHoverB = 1.0f, closeHoverA = 0.12f;

    // Use theme colors for bar background
    float tBgR = g_theme_bg_r / 255.0f;
    float tBgG = g_theme_bg_g / 255.0f;
    float tBgB = g_theme_bg_b / 255.0f;
    // Darken theme BG for bar
    barBgR = tBgR * 0.55f;
    barBgG = tBgG * 0.55f;
    barBgB = tBgB * 0.55f;
    // Active tab: slightly lighter
    activeBgR = tBgR * 0.85f;
    activeBgG = tBgG * 0.85f;
    activeBgB = tBgB * 0.85f;
    // Hover: between bar and active
    hoverBgR = tBgR * 0.70f;
    hoverBgG = tBgG * 0.70f;
    hoverBgB = tBgB * 0.70f;

    // Solid vertices buffer (generous: bar bg + tabs + separators + buttons)
    int maxVerts = (tab_count + 10) * 6;
    WinVertex* verts = (WinVertex*)_alloca(maxVerts * sizeof(WinVertex));
    int vi = 0;

    // 1. Bar background (full width, barH height)
    vi = winEmitRect(verts, vi, 0, 0, vpW, barH, barBgR, barBgG, barBgB, 1.0f);

    // 2. Per-tab backgrounds
    for (int i = 0; i < tab_count; i++) {
        float tx = ntab_tab_x(i, tab_count, vpW);
        int isActive = (i == active);
        int isHovered = (i == s_hovered_tab && !s_hover_close);

        if (isActive) {
            vi = winEmitRect(verts, vi, tx, 0, tabW, barH,
                             activeBgR, activeBgG, activeBgB, 1.0f);
        } else if (isHovered) {
            vi = winEmitRect(verts, vi, tx, 0, tabW, barH,
                             hoverBgR, hoverBgG, hoverBgB, 1.0f);
        }
    }

    // 3. Separators between tabs
    for (int i = 1; i < tab_count; i++) {
        // Skip separator adjacent to active or hovered tab
        if (i - 1 == active || i == active) continue;
        if (i - 1 == s_hovered_tab || i == s_hovered_tab) continue;
        float sx = ntab_tab_x(i, tab_count, vpW);
        float sepH = barH * 0.55f;
        float sepY = (barH - sepH) * 0.5f;
        vi = winEmitRect(verts, vi, sx - 0.5f, sepY, 1.0f, sepH, sepR, sepG, sepB, sepA);
    }

    // 4. Close button hover background (circle)
    if (s_hovered_tab >= 0 && s_hovered_tab < tab_count && s_hover_close && tab_count > 1) {
        float tx = ntab_tab_x(s_hovered_tab, tab_count, vpW);
        float closeSize = CLOSE_BTN_SIZE * sc;
        float cx = tx + tabW - closeSize - 8 * sc;
        float cy = (barH - closeSize) * 0.5f;
        vi = winEmitRect(verts, vi, cx, cy, closeSize, closeSize,
                         closeHoverR, closeHoverG, closeHoverB, closeHoverA);
    }

    // 5. Plus button hover
    {
        float plusX = tab_count * tabW;
        float plusW = PLUS_BTN_WIDTH * sc;
        if (s_hovered_tab == tab_count) {
            vi = winEmitRect(verts, vi, plusX, 0, plusW, barH,
                             hoverBgR, hoverBgG, hoverBgB, 1.0f);
        }
        // Separator before +
        float sepH = barH * 0.55f;
        float sepY = (barH - sepH) * 0.5f;
        vi = winEmitRect(verts, vi, plusX - 0.5f, sepY, 1.0f, sepH, sepR, sepG, sepB, sepA);
    }

    // Draw solid pass
    if (vi > 0) {
        ID3D11DeviceContext_PSSetShader(g_d3d_context, g_d3d_ps_solid, NULL, 0);
        winDrawVerts(verts, vi);
    }

    // 6. Close button X marks (drawn as two thin lines = 4 rects each)
    {
        WinVertex xv[64]; int xi = 0;
        for (int i = 0; i < tab_count; i++) {
            int isActive = (i == active);
            int isHovered = (i == s_hovered_tab);
            if (tab_count <= 1) continue;
            if (!isActive && !isHovered) continue;

            float tx = ntab_tab_x(i, tab_count, vpW);
            float closeSize = CLOSE_BTN_SIZE * sc;
            float cx = tx + tabW - closeSize - 8 * sc;
            float cy = (barH - closeSize) * 0.5f;
            float m = CLOSE_BTN_PAD * sc * 0.5f;
            float lw = 1.2f * sc;  // line width

            float xAlpha = (isHovered && s_hover_close) ? 0.9f : 0.4f;

            // Line 1: top-left to bottom-right
            float x0 = cx + m, y0 = cy + m;
            float x1 = cx + closeSize - m, y1 = cy + closeSize - m;
            // Approximate diagonal line with a rotated thin rect
            float dx = x1 - x0, dy = y1 - y0;
            float len = sqrtf(dx*dx + dy*dy);
            float nx = -dy / len * lw * 0.5f;
            float ny = dx / len * lw * 0.5f;
            if (xi + 6 <= 64) {
                xv[xi++] = (WinVertex){x0+nx, y0+ny, 0,0, 1,1,1,xAlpha};
                xv[xi++] = (WinVertex){x0-nx, y0-ny, 0,0, 1,1,1,xAlpha};
                xv[xi++] = (WinVertex){x1-nx, y1-ny, 0,0, 1,1,1,xAlpha};
                xv[xi++] = (WinVertex){x0+nx, y0+ny, 0,0, 1,1,1,xAlpha};
                xv[xi++] = (WinVertex){x1-nx, y1-ny, 0,0, 1,1,1,xAlpha};
                xv[xi++] = (WinVertex){x1+nx, y1+ny, 0,0, 1,1,1,xAlpha};
            }

            // Line 2: top-right to bottom-left
            x0 = cx + closeSize - m; y0 = cy + m;
            x1 = cx + m; y1 = cy + closeSize - m;
            dx = x1 - x0; dy = y1 - y0;
            len = sqrtf(dx*dx + dy*dy);
            nx = -dy / len * lw * 0.5f;
            ny = dx / len * lw * 0.5f;
            if (xi + 6 <= 64) {
                xv[xi++] = (WinVertex){x0+nx, y0+ny, 0,0, 1,1,1,xAlpha};
                xv[xi++] = (WinVertex){x0-nx, y0-ny, 0,0, 1,1,1,xAlpha};
                xv[xi++] = (WinVertex){x1-nx, y1-ny, 0,0, 1,1,1,xAlpha};
                xv[xi++] = (WinVertex){x0+nx, y0+ny, 0,0, 1,1,1,xAlpha};
                xv[xi++] = (WinVertex){x1-nx, y1-ny, 0,0, 1,1,1,xAlpha};
                xv[xi++] = (WinVertex){x1+nx, y1+ny, 0,0, 1,1,1,xAlpha};
            }
        }
        if (xi > 0) {
            ID3D11DeviceContext_PSSetShader(g_d3d_context, g_d3d_ps_solid, NULL, 0);
            winDrawVerts(xv, xi);
        }
    }

    // 7. Plus sign (two rects forming a +)
    {
        float plusX = tab_count * tabW;
        float plusW = PLUS_BTN_WIDTH * sc;
        float cx = plusX + plusW * 0.5f;
        float cy = barH * 0.5f;
        float armLen = 5.0f * sc;
        float armThick = 1.4f * sc;
        float pAlpha = 0.5f;

        WinVertex pv[12]; int pi = 0;
        // Horizontal arm
        pi = winEmitRect(pv, pi, cx - armLen, cy - armThick * 0.5f,
                         armLen * 2.0f, armThick, 1, 1, 1, pAlpha);
        // Vertical arm
        pi = winEmitRect(pv, pi, cx - armThick * 0.5f, cy - armLen,
                         armThick, armLen * 2.0f, 1, 1, 1, pAlpha);
        if (pi > 0) {
            ID3D11DeviceContext_PSSetShader(g_d3d_context, g_d3d_ps_solid, NULL, 0);
            winDrawVerts(pv, pi);
        }
    }

    // 8. Tab title text (using glyph cache)
    if (g_gc.texture_srv) {
        int maxTextVerts = tab_count * 64 * 6;  // rough max
        WinVertex* tv = (WinVertex*)_alloca(maxTextVerts * sizeof(WinVertex));
        int tvi = 0;

        for (int i = 0; i < tab_count; i++) {
            float tx = ntab_tab_x(i, tab_count, vpW);
            int isActive = (i == active);
            float fgR = isActive ? activeFgR : inactiveFgR;
            float fgG = isActive ? activeFgG : inactiveFgG;
            float fgB = isActive ? activeFgB : inactiveFgB;
            float fgA = 1.0f;

            // Text area: after left padding, before close button
            float textLeft = tx + TAB_PAD_H * sc;
            float closeSpace = (tab_count > 1) ? (CLOSE_BTN_SIZE + 12) * sc : TAB_PAD_H * sc;
            float textRight = tx + tabW - closeSpace;
            float maxTextW = textRight - textLeft;
            if (maxTextW < 10) continue;

            // Center text vertically
            float textY = (barH - g_gc.glyph_h) * 0.5f;

            // Render glyphs
            wchar_t* title = s_tab_titles[i];
            int titleLen = s_title_lens[i];
            if (titleLen <= 0) {
                // Fallback: "Tab"
                title = L"Tab";
                titleLen = 3;
            }

            float curX = textLeft;
            for (int ch = 0; ch < titleLen && curX + g_gc.glyph_w <= textRight; ch++) {
                uint32_t cp = (uint32_t)title[ch];
                if (cp == 0) break;

                int slot = glyphCacheLookup(&g_gc, cp);
                if (slot < 0) {
                    slot = glyphCacheRasterize(&g_gc, cp);
                    if (slot < 0) { curX += g_gc.glyph_w; continue; }
                }

                // Atlas UV
                int atlasCol = slot % g_gc.atlas_cols;
                int atlasRow = slot / g_gc.atlas_cols;
                float u0 = (float)(atlasCol * (int)g_gc.glyph_w) / (float)g_gc.atlas_w;
                float v0 = (float)(atlasRow * (int)g_gc.glyph_h) / (float)g_gc.atlas_h;
                float u1 = u0 + g_gc.glyph_w / (float)g_gc.atlas_w;
                float v1 = v0 + g_gc.glyph_h / (float)g_gc.atlas_h;

                if (tvi + 6 <= maxTextVerts) {
                    tvi = winEmitQuad(tv, tvi,
                                      curX, textY, curX + g_gc.glyph_w, textY + g_gc.glyph_h,
                                      u0, v0, u1, v1,
                                      fgR, fgG, fgB, fgA);
                }
                curX += g_gc.glyph_w;
            }
        }

        if (tvi > 0) {
            winDrawTextVerts(tv, tvi, &g_gc);
        }
    }
}

// ---------------------------------------------------------------------------
// Hit testing — called from WM_NCHITTEST in platform_windows.c
// ---------------------------------------------------------------------------

// Returns: HTCLIENT for tab area interaction, HTCLOSE/HTMAXBUTTON/HTMINBUTTON
// for caption buttons, or 0 if not in tab bar area.
int ntab_hit_test(int px, int py, int clientW) {
    if (!g_native_tabs_enabled) return 0;

    int tab_count = g_native_tab_count;
    if (tab_count < 1) tab_count = 1;
    if (tab_count <= 1 && !g_tab_always_show) return 0;

    float barH = ntab_bar_height();
    if (py < 0 || (float)py >= barH) return 0;

    float sc = ntab_scale();
    float captionW = ntab_caption_width();

    // Caption buttons are on the right
    float captionStart = (float)clientW - captionW;
    if ((float)px >= captionStart) {
        float btnW = CAPTION_BTN_WIDTH * sc;
        float rel = (float)px - captionStart;
        if (rel < btnW)     return HTMINBUTTON;
        if (rel < btnW * 2) return HTMAXBUTTON;
        return HTCLOSE;
    }

    return HTCLIENT;  // In tab bar but not caption buttons
}

// ---------------------------------------------------------------------------
// Mouse interaction — called from WndProc for mouse messages in tab bar
// ---------------------------------------------------------------------------

// Update hover state. Returns 1 if state changed (needs redraw).
int ntab_mouse_move(int px, int py, int clientW) {
    if (!g_native_tabs_enabled) return 0;

    int tab_count = g_native_tab_count;
    if (tab_count < 1) tab_count = 1;
    if (tab_count <= 1 && !g_tab_always_show) return 0;

    float barH = ntab_bar_height();
    int prev_hovered = s_hovered_tab;
    int prev_close = s_hover_close;

    if ((float)py >= barH || py < 0 || (float)px >= (float)clientW - ntab_caption_width()) {
        s_hovered_tab = -1;
        s_hover_close = 0;
    } else {
        float sc = ntab_scale();
        float tabW = ntab_tab_width(tab_count, (float)clientW);
        float tabsEnd = tab_count * tabW;
        float plusEnd = tabsEnd + PLUS_BTN_WIDTH * sc;

        if ((float)px < tabsEnd) {
            int idx = (int)((float)px / tabW);
            if (idx >= tab_count) idx = tab_count - 1;
            s_hovered_tab = idx;

            // Check close button
            if (tab_count > 1) {
                float tx = ntab_tab_x(idx, tab_count, (float)clientW);
                float closeSize = CLOSE_BTN_SIZE * sc;
                float cx = tx + tabW - closeSize - 8 * sc;
                float cy = (barH - closeSize) * 0.5f;
                s_hover_close = ((float)px >= cx && (float)px <= cx + closeSize &&
                                 (float)py >= cy && (float)py <= cy + closeSize);
            } else {
                s_hover_close = 0;
            }
        } else if ((float)px < plusEnd) {
            s_hovered_tab = tab_count;  // plus button
            s_hover_close = 0;
        } else {
            s_hovered_tab = -1;
            s_hover_close = 0;
        }
    }

    int changed = (s_hovered_tab != prev_hovered || s_hover_close != prev_close);
    if (changed) g_full_redraw = 1;
    return changed;
}

// Handle click. Returns 1 if consumed.
int ntab_mouse_down(int px, int py, int clientW) {
    if (!g_native_tabs_enabled) return 0;

    int tab_count = g_native_tab_count;
    if (tab_count < 1) tab_count = 1;
    if (tab_count <= 1 && !g_tab_always_show) return 0;

    float barH = ntab_bar_height();
    if ((float)py >= barH || py < 0) return 0;
    if ((float)px >= (float)clientW - ntab_caption_width()) return 0;  // caption buttons handled by DefWindowProc

    float sc = ntab_scale();
    float tabW = ntab_tab_width(tab_count, (float)clientW);
    float tabsEnd = tab_count * tabW;
    float plusEnd = tabsEnd + PLUS_BTN_WIDTH * sc;

    if ((float)px < tabsEnd) {
        int idx = (int)((float)px / tabW);
        if (idx >= tab_count) idx = tab_count - 1;

        // Check close button
        if (tab_count > 1 && s_hover_close) {
            // Close tab: switch to it first, then dispatch close action
            g_native_tab_click = idx;
            attyx_dispatch_action(50);  // tab_close
            g_full_redraw = 1;
            return 1;
        }

        // Tab click: switch to tab
        if (idx != g_native_tab_active) {
            g_native_tab_click = idx;
            g_full_redraw = 1;
        }
        return 1;
    } else if ((float)px < plusEnd) {
        // Plus button: new tab
        attyx_dispatch_action(49);  // tab_new
        g_full_redraw = 1;
        return 1;
    }

    return 0;
}

void ntab_mouse_leave(void) {
    if (s_hovered_tab != -1 || s_hover_close) {
        s_hovered_tab = -1;
        s_hover_close = 0;
        g_full_redraw = 1;
    }
}

#endif // _WIN32
