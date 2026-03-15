// Attyx — Windows native tab bar (D3D11, Windows 11 style)
//
// File Explorer-style tab cards: rounded top corners on the active tab,
// DWM-integrated caption buttons (−, □, ×), theme-adaptive colors.

#ifdef _WIN32

#include "windows_internal.h"

// ---------------------------------------------------------------------------
// Layout constants (at 96 DPI, scaled by g_content_scale)
// ---------------------------------------------------------------------------

#define BAR_H           40
#define CORNER_R        8
#define CAP_BTN_W       46
#define CAP_COUNT       3
#define PLUS_W          40
#define TAB_PAD         12
#define TAB_MIN_W       80
#define TAB_MAX_W       240
#define CLOSE_SZ        16
#define CLOSE_ICON_PAD  5
#define CAP_ICON_SZ     10
#define PI_HALF         1.5707963f
#define ARC_SEGS        5

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

static int s_hovered_tab  = -1;
static int s_hover_close  = 0;
static int s_caption_hover = 0;  // 0, HTMINBUTTON, HTMAXBUTTON, HTCLOSE

static wchar_t s_titles[16][ATTYX_NATIVE_TAB_TITLE_MAX];
static int     s_title_lens[16];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static float sc(void) { return g_content_scale; }
float ntab_bar_height(void) { return BAR_H * sc(); }
static float cap_w(void) { return CAP_BTN_W * CAP_COUNT * sc(); }

static float tw(int n, float vpW) {
    float avail = vpW - cap_w() - PLUS_W * sc();
    float w = avail / (float)(n > 0 ? n : 1);
    float s = sc();
    if (w < TAB_MIN_W * s) w = TAB_MIN_W * s;
    if (w > TAB_MAX_W * s) w = TAB_MAX_W * s;
    return w;
}

static float tx(int i, int n, float vpW) { return i * tw(n, vpW); }

// Emit a thin diagonal line as two triangles.
static int emitLine(WinVertex* v, int vi,
                    float x0, float y0, float x1, float y1, float thick,
                    float r, float g, float b, float a) {
    float dx = x1 - x0, dy = y1 - y0;
    float len = sqrtf(dx * dx + dy * dy);
    if (len < 0.01f) return vi;
    float nx = -dy / len * thick * 0.5f, ny = dx / len * thick * 0.5f;
    v[vi++] = (WinVertex){x0+nx,y0+ny, 0,0, r,g,b,a};
    v[vi++] = (WinVertex){x0-nx,y0-ny, 0,0, r,g,b,a};
    v[vi++] = (WinVertex){x1-nx,y1-ny, 0,0, r,g,b,a};
    v[vi++] = (WinVertex){x0+nx,y0+ny, 0,0, r,g,b,a};
    v[vi++] = (WinVertex){x1-nx,y1-ny, 0,0, r,g,b,a};
    v[vi++] = (WinVertex){x1+nx,y1+ny, 0,0, r,g,b,a};
    return vi;
}

// Emit a rectangle with rounded top-left and top-right corners.
// Bottom edge is flat (connects to content area).
static int emitRoundTopRect(WinVertex* v, int vi,
                            float x, float y, float w, float h, float rad,
                            float r, float g, float b, float a) {
    if (rad < 1.0f) return winEmitRect(v, vi, x, y, w, h, r, g, b, a);

    float pts[4 + 2 * ARC_SEGS][2];
    int n = 0;

    // Bottom edge (flat)
    pts[n][0] = x;     pts[n][1] = y + h; n++;
    pts[n][0] = x + w; pts[n][1] = y + h; n++;
    // Right side up to arc
    pts[n][0] = x + w; pts[n][1] = y + rad; n++;
    // Top-right arc
    for (int i = 1; i <= ARC_SEGS; i++) {
        float t = (float)i / (float)ARC_SEGS * PI_HALF;
        pts[n][0] = (x + w - rad) + rad * cosf(t);
        pts[n][1] = (y + rad) - rad * sinf(t);
        n++;
    }
    // Top-left arc
    for (int i = 1; i <= ARC_SEGS; i++) {
        float t = PI_HALF + (float)i / (float)ARC_SEGS * PI_HALF;
        pts[n][0] = (x + rad) + rad * cosf(t);
        pts[n][1] = (y + rad) - rad * sinf(t);
        n++;
    }
    // Left side closes back to bottom-left (pts[0])

    // Fan triangulate from centroid
    float cx = x + w * 0.5f, cy = y + h * 0.5f;
    for (int i = 0; i < n; i++) {
        int j = (i + 1) % n;
        v[vi++] = (WinVertex){cx, cy, 0, 0, r, g, b, a};
        v[vi++] = (WinVertex){pts[i][0], pts[i][1], 0, 0, r, g, b, a};
        v[vi++] = (WinVertex){pts[j][0], pts[j][1], 0, 0, r, g, b, a};
    }
    return vi;
}

// ---------------------------------------------------------------------------
// Title sync
// ---------------------------------------------------------------------------

static void sync_titles(void) {
    if (!g_native_tab_titles_changed) return;
    g_native_tab_titles_changed = 0;
    int cnt = g_native_tab_count;
    if (cnt < 1) cnt = 1;
    if (cnt > 16) cnt = 16;
    for (int i = 0; i < cnt; i++) {
        int len = MultiByteToWideChar(CP_UTF8, 0, g_native_tab_titles[i], -1,
                                       s_titles[i], ATTYX_NATIVE_TAB_TITLE_MAX - 1);
        s_title_lens[i] = (len > 0) ? len - 1 : 0;
    }
}

// ---------------------------------------------------------------------------
// Draw
// ---------------------------------------------------------------------------

void ntab_draw(float vpW, float vpH) {
    if (!g_native_tabs_enabled) return;
    int count = g_native_tab_count;
    int active = g_native_tab_active;
    if (count < 1) count = 1;
    if (count > 16) count = 16;
    if (active < 0) active = 0;
    if (active >= count) active = count - 1;
    if (count <= 1 && !g_tab_always_show) return;

    sync_titles();

    float s = sc();
    float barH = ntab_bar_height();
    float tabW = tw(count, vpW);
    float rad = CORNER_R * s;

    // Theme colors
    float tR = g_theme_bg_r / 255.0f, tG = g_theme_bg_g / 255.0f, tB = g_theme_bg_b / 255.0f;
    float lum = (tR + tG + tB) / 3.0f;
    // Derive foreground: white on dark, dark on light
    float fR = lum < 0.5f ? 1.0f : 0.1f;
    float fG = fR, fB = fR;

    // Bar bg: darker than content. Active tab = content bg (seamless connection).
    float bR, bG, bB;
    if (lum < 0.5f) { bR = tR * 0.5f;  bG = tG * 0.5f;  bB = tB * 0.5f;  }
    else             { bR = tR * 0.92f; bG = tG * 0.92f; bB = tB * 0.92f; }
    float aR = tR, aG = tG, aB = tB;  // active tab = terminal bg
    float hR = (bR + aR) * 0.5f, hG = (bG + aG) * 0.5f, hB = (bB + aB) * 0.5f;

    // --- Solid pass: backgrounds ---
    // Max verts: bar(6) + active(~42) + hover(~42) + capHover(6) + seps(count*6)
    int maxV = 200 + count * 6;
    WinVertex* v = (WinVertex*)_alloca(maxV * sizeof(WinVertex));
    int vi = 0;

    // Bar background
    vi = winEmitRect(v, vi, 0, 0, vpW, barH, bR, bG, bB, 1.0f);

    // Active tab: rounded top corners, bottom flush with content
    vi = emitRoundTopRect(v, vi, tx(active, count, vpW), 0, tabW, barH,
                          rad, aR, aG, aB, 1.0f);

    // Hover tab (not active)
    if (s_hovered_tab >= 0 && s_hovered_tab < count && s_hovered_tab != active) {
        vi = emitRoundTopRect(v, vi, tx(s_hovered_tab, count, vpW), 2*s,
                              tabW, barH - 2*s, rad, hR, hG, hB, 0.5f);
    }

    // Plus button hover
    if (s_hovered_tab == count) {
        float px = count * tabW;
        vi = emitRoundTopRect(v, vi, px, 2*s, PLUS_W * s, barH - 2*s,
                              rad, hR, hG, hB, 0.5f);
    }

    // Separators
    for (int i = 1; i < count; i++) {
        if (i - 1 == active || i == active) continue;
        if (i - 1 == s_hovered_tab || i == s_hovered_tab) continue;
        float sx = tx(i, count, vpW);
        float sepH = barH * 0.5f, sepY = (barH - sepH) * 0.5f;
        vi = winEmitRect(v, vi, sx - 0.5f, sepY, 1.0f, sepH, fR, fG, fB, 0.1f);
    }

    // Caption button hover backgrounds
    {
        float capX = vpW - cap_w();
        float bw = CAP_BTN_W * s;
        if (s_caption_hover == HTMINBUTTON)
            vi = winEmitRect(v, vi, capX, 0, bw, barH, fR, fG, fB, 0.08f);
        else if (s_caption_hover == HTMAXBUTTON)
            vi = winEmitRect(v, vi, capX + bw, 0, bw, barH, fR, fG, fB, 0.08f);
        else if (s_caption_hover == HTCLOSE)
            vi = winEmitRect(v, vi, capX + bw*2, 0, bw, barH,
                             0.77f, 0.17f, 0.11f, 1.0f);  // #c42b1c
    }

    if (vi > 0) winDrawSolidVerts(v, vi);

    // --- Icon pass: close ×, plus +, caption buttons ---
    {
        WinVertex iv[256]; int ii = 0;
        float lw = 1.2f * s;

        // Tab close buttons
        for (int i = 0; i < count; i++) {
            int isA = (i == active), isH = (i == s_hovered_tab);
            if (count <= 1 || (!isA && !isH)) continue;
            float tabX = tx(i, count, vpW);
            float csz = CLOSE_SZ * s;
            float cx = tabX + tabW - csz - 8 * s, cy = (barH - csz) * 0.5f;
            float pad = CLOSE_ICON_PAD * s;
            float alpha = (isH && s_hover_close) ? 0.9f : 0.35f;
            if (isH && s_hover_close)
                ii = winEmitRect(iv, ii, cx, cy, csz, csz, fR, fG, fB, 0.1f);
            ii = emitLine(iv, ii, cx+pad, cy+pad, cx+csz-pad, cy+csz-pad,
                          lw, fR, fG, fB, alpha);
            ii = emitLine(iv, ii, cx+csz-pad, cy+pad, cx+pad, cy+csz-pad,
                          lw, fR, fG, fB, alpha);
        }

        // Plus +
        {
            float px = count * tabW + PLUS_W * s * 0.5f;
            float py = barH * 0.5f;
            float arm = 5.0f * s;
            ii = winEmitRect(iv, ii, px-arm, py-lw*0.5f, arm*2, lw, fR,fG,fB, 0.45f);
            ii = winEmitRect(iv, ii, px-lw*0.5f, py-arm, lw, arm*2, fR,fG,fB, 0.45f);
        }

        // Caption icons: minimize (−), maximize (□/⧉), close (×)
        {
            float capX = vpW - cap_w();
            float bw = CAP_BTN_W * s;
            float isz = CAP_ICON_SZ * s;
            float ci_lw = 1.0f * s;
            float ciR = fR, ciG = fG, ciB = fB, ciA = 0.65f;
            // Close hover → white on red
            float clR = ciR, clG = ciG, clB = ciB, clA = ciA;
            if (s_caption_hover == HTCLOSE) { clR=1; clG=1; clB=1; clA=1; }

            // Minimize: horizontal line
            float mx = capX + bw * 0.5f, my = barH * 0.5f;
            ii = winEmitRect(iv, ii, mx - isz*0.5f, my - ci_lw*0.5f,
                             isz, ci_lw, ciR, ciG, ciB, ciA);

            // Maximize/Restore
            float mmx = capX + bw * 1.5f, mmy = barH * 0.5f;
            float half = isz * 0.5f;
            if (IsZoomed(g_hwnd)) {
                // Restore: two overlapping squares
                float off = 2.0f * s, sz = isz - off;
                // Back square (up-right)
                float bx = mmx-half+off, by = mmy-half;
                ii = winEmitRect(iv, ii, bx, by, sz, ci_lw, ciR,ciG,ciB,ciA);
                ii = winEmitRect(iv, ii, bx, by+sz-ci_lw, sz, ci_lw, ciR,ciG,ciB,ciA);
                ii = winEmitRect(iv, ii, bx, by, ci_lw, sz, ciR,ciG,ciB,ciA);
                ii = winEmitRect(iv, ii, bx+sz-ci_lw, by, ci_lw, sz, ciR,ciG,ciB,ciA);
                // Front square (down-left)
                float fx = mmx-half, fy = mmy-half+off;
                ii = winEmitRect(iv, ii, fx, fy, sz, ci_lw, ciR,ciG,ciB,ciA);
                ii = winEmitRect(iv, ii, fx, fy+sz-ci_lw, sz, ci_lw, ciR,ciG,ciB,ciA);
                ii = winEmitRect(iv, ii, fx, fy, ci_lw, sz, ciR,ciG,ciB,ciA);
                ii = winEmitRect(iv, ii, fx+sz-ci_lw, fy, ci_lw, sz, ciR,ciG,ciB,ciA);
            } else {
                // Maximize: single square outline
                float sx = mmx-half, sy = mmy-half;
                ii = winEmitRect(iv, ii, sx, sy, isz, ci_lw, ciR,ciG,ciB,ciA);
                ii = winEmitRect(iv, ii, sx, sy+isz-ci_lw, isz, ci_lw, ciR,ciG,ciB,ciA);
                ii = winEmitRect(iv, ii, sx, sy, ci_lw, isz, ciR,ciG,ciB,ciA);
                ii = winEmitRect(iv, ii, sx+isz-ci_lw, sy, ci_lw, isz, ciR,ciG,ciB,ciA);
            }

            // Close: ×
            float clx = capX + bw * 2.5f, cly = barH * 0.5f;
            ii = emitLine(iv, ii, clx-half, cly-half, clx+half, cly+half,
                          ci_lw, clR, clG, clB, clA);
            ii = emitLine(iv, ii, clx+half, cly-half, clx-half, cly+half,
                          ci_lw, clR, clG, clB, clA);
        }

        if (ii > 0) winDrawSolidVerts(iv, ii);
    }

    // --- Text pass: tab titles ---
    if (g_gc.texture_srv) {
        int maxTV = count * 64 * 6;
        WinVertex* tv = (WinVertex*)_alloca(maxTV * sizeof(WinVertex));
        int tvi = 0;
        float inactA = (lum < 0.5f) ? 0.5f : 0.55f;

        for (int i = 0; i < count; i++) {
            float tabX = tx(i, count, vpW);
            int isA = (i == active);
            float tfR = fR, tfG = fG, tfB = fB;
            float tfA = isA ? 1.0f : inactA;

            float textL = tabX + TAB_PAD * s;
            float closeW = (count > 1) ? (CLOSE_SZ + 12) * s : TAB_PAD * s;
            float textR = tabX + tabW - closeW;
            if (textR - textL < 10) continue;

            float textY = (barH - g_gc.glyph_h) * 0.5f;
            wchar_t* title = s_titles[i];
            int tlen = s_title_lens[i];
            if (tlen <= 0) { title = L"Tab"; tlen = 3; }

            float cx = textL;
            for (int ch = 0; ch < tlen && cx + g_gc.glyph_w <= textR; ch++) {
                uint32_t cp = (uint32_t)title[ch];
                if (cp == 0) break;
                int slot = glyphCacheLookup(&g_gc, cp);
                if (slot < 0) slot = glyphCacheRasterize(&g_gc, cp);
                if (slot < 0) { cx += g_gc.glyph_w; continue; }

                int ac = slot % g_gc.atlas_cols, ar = slot / g_gc.atlas_cols;
                float u0 = (float)(ac * (int)g_gc.glyph_w) / (float)g_gc.atlas_w;
                float v0 = (float)(ar * (int)g_gc.glyph_h) / (float)g_gc.atlas_h;
                float u1 = u0 + g_gc.glyph_w / (float)g_gc.atlas_w;
                float v1 = v0 + g_gc.glyph_h / (float)g_gc.atlas_h;

                if (tvi + 6 <= maxTV)
                    tvi = winEmitQuad(tv, tvi, cx, textY, cx + g_gc.glyph_w,
                                     textY + g_gc.glyph_h, u0, v0, u1, v1,
                                     tfR, tfG, tfB, tfA);
                cx += g_gc.glyph_w;
            }
        }
        if (tvi > 0) winDrawTextVerts(tv, tvi, &g_gc);
    }
}

// ---------------------------------------------------------------------------
// Hit testing
// ---------------------------------------------------------------------------

int ntab_hit_test(int px, int py, int clientW) {
    if (!g_native_tabs_enabled) return 0;
    int count = g_native_tab_count;
    if (count < 1) count = 1;
    if (count <= 1 && !g_tab_always_show) return 0;

    float barH = ntab_bar_height();
    if (py < 0 || (float)py >= barH) return 0;

    float s = sc();
    float capStart = (float)clientW - cap_w();
    if ((float)px >= capStart) {
        float bw = CAP_BTN_W * s;
        float rel = (float)px - capStart;
        if (rel < bw)     return HTMINBUTTON;
        if (rel < bw * 2) return HTMAXBUTTON;
        return HTCLOSE;
    }

    float tabW = tw(count, (float)clientW);
    float tabsEnd = count * tabW;
    float plusEnd = tabsEnd + PLUS_W * s;

    if ((float)px < tabsEnd) return HTCLIENT;
    if ((float)px < plusEnd)  return HTCLIENT;
    return HTCAPTION;
}

// ---------------------------------------------------------------------------
// Mouse interaction
// ---------------------------------------------------------------------------

int ntab_mouse_move(int px, int py, int clientW) {
    if (!g_native_tabs_enabled) return 0;
    int count = g_native_tab_count;
    if (count < 1) count = 1;
    if (count <= 1 && !g_tab_always_show) return 0;

    float barH = ntab_bar_height();
    int prev_tab = s_hovered_tab, prev_cl = s_hover_close;

    if ((float)py >= barH || py < 0 || (float)px >= (float)clientW - cap_w()) {
        s_hovered_tab = -1; s_hover_close = 0;
    } else {
        float s = sc();
        float tabW = tw(count, (float)clientW);
        float tabsEnd = count * tabW;
        float plusEnd = tabsEnd + PLUS_W * s;

        if ((float)px < tabsEnd) {
            int idx = (int)((float)px / tabW);
            if (idx >= count) idx = count - 1;
            s_hovered_tab = idx;
            if (count > 1) {
                float tabX = tx(idx, count, (float)clientW);
                float csz = CLOSE_SZ * s;
                float cx = tabX + tabW - csz - 8*s, cy = (barH - csz) * 0.5f;
                s_hover_close = ((float)px >= cx && (float)px <= cx+csz &&
                                 (float)py >= cy && (float)py <= cy+csz);
            } else s_hover_close = 0;
        } else if ((float)px < plusEnd) {
            s_hovered_tab = count; s_hover_close = 0;
        } else {
            s_hovered_tab = -1; s_hover_close = 0;
        }
    }

    int changed = (s_hovered_tab != prev_tab || s_hover_close != prev_cl);
    if (changed) g_full_redraw = 1;
    return changed;
}

int ntab_mouse_down(int px, int py, int clientW) {
    if (!g_native_tabs_enabled) return 0;
    int count = g_native_tab_count;
    if (count < 1) count = 1;
    if (count <= 1 && !g_tab_always_show) return 0;

    float barH = ntab_bar_height();
    if ((float)py >= barH || py < 0) return 0;
    if ((float)px >= (float)clientW - cap_w()) return 0;

    float s = sc();
    float tabW = tw(count, (float)clientW);
    float tabsEnd = count * tabW;

    if ((float)px < tabsEnd) {
        int idx = (int)((float)px / tabW);
        if (idx >= count) idx = count - 1;
        if (count > 1 && s_hover_close) {
            g_native_tab_click = idx;
            attyx_dispatch_action(50);
            g_full_redraw = 1;
            return 1;
        }
        if (idx != g_native_tab_active) {
            g_native_tab_click = idx;
            g_full_redraw = 1;
        }
        return 1;
    } else if ((float)px < tabsEnd + PLUS_W * s) {
        attyx_dispatch_action(49);
        g_full_redraw = 1;
        return 1;
    }
    return 0;
}

void ntab_mouse_leave(void) {
    if (s_hovered_tab != -1 || s_hover_close) {
        s_hovered_tab = -1; s_hover_close = 0;
        g_full_redraw = 1;
    }
}

void ntab_set_caption_hover(int ht) {
    if (s_caption_hover != ht) {
        s_caption_hover = ht;
        g_full_redraw = 1;
    }
}

#endif // _WIN32
