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
#define SESS_W          36  // session dropdown button width

// Padding: tabs float inside the bar with margins
#define BAR_PAD_TOP     6
#define BAR_PAD_LEFT    8
#define TAB_FONT_PT     11

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

static int s_hovered_tab  = -1;
static int s_hover_close  = 0;
static int s_caption_hover = 0;  // 0, HTMINBUTTON, HTMAXBUTTON, HTCLOSE

static wchar_t s_titles[16][ATTYX_NATIVE_TAB_TITLE_MAX];
static int     s_title_lens[16];

// Drag state
#define DRAG_THRESH  4.0f
#define TEAR_DIST   40.0f
static int   s_drag_on    = 0;  // mouse is down on a tab
static int   s_drag_go    = 0;  // past threshold, actively dragging
static int   s_drag_tear  = 0;  // dragged far enough to tear off
static int   s_drag_idx   = -1; // which tab is being dragged
static int   s_drag_slot  = -1; // where it would drop
static float s_drag_start_x, s_drag_start_y;
static float s_drag_off_x;      // click offset within tab
static float s_drag_x;          // current drag position

// Dedicated glyph cache for tab titles (Segoe UI, fixed 12px)
static GlyphCache s_tab_gc;
static int        s_tab_gc_ready = 0;

static void tab_gc_init(void) {
    if (s_tab_gc_ready) return;
    if (windows_font_init_ui(&s_tab_gc, g_d3d_device, g_content_scale, TAB_FONT_PT))
        s_tab_gc_ready = 1;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static float sc(void) { return g_content_scale; }
float ntab_bar_height(void) { return BAR_H * sc(); }
static float cap_w(void) { return CAP_BTN_W * CAP_COUNT * sc(); }

static float padL(void) { return BAR_PAD_LEFT * sc(); }
static float padT(void) { return BAR_PAD_TOP * sc(); }
static float trail_w(void) {
    float s = sc();
    return PLUS_W * s + (g_sessions_active ? SESS_W * s : 0);
}

static float tw(int n, float vpW) {
    float avail = vpW - cap_w() - trail_w() - padL();
    float w = avail / (float)(n > 0 ? n : 1);
    float s = sc();
    if (w < TAB_MIN_W * s) w = TAB_MIN_W * s;
    if (w > TAB_MAX_W * s) w = TAB_MAX_W * s;
    return w;
}

static float tx(int i, int n, float vpW) { return padL() + i * tw(n, vpW); }


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

    sync_titles();
    tab_gc_init();

    float s = sc();
    float barH = ntab_bar_height();
    float tabW = tw(count, vpW);
    float rad = CORNER_R * s;
    float pT = padT();  // vertical offset: tabs start below top padding

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
    int maxV = 200 + count * 6;
    WinVertex* v = (WinVertex*)_alloca(maxV * sizeof(WinVertex));
    int vi = 0;

    // Bar background
    vi = winEmitRect(v, vi, 0, 0, vpW, barH, bR, bG, bB, 1.0f);

    float tabH = barH - pT;

    if (s_drag_on && s_drag_go && !s_drag_tear) {
        // --- Drag mode: draw non-dragged tabs shifted, floating dragged tab ---
        int slot = 0;
        for (int i = 0; i < count; i++) {
            if (i == s_drag_idx) continue;
            if (slot == s_drag_slot) slot++;
            float sx = padL() + slot * tabW;
            int isA = (i == active);
            if (isA)
                vi = winEmitRoundTopRect(v, vi, sx, pT, tabW, tabH, rad, aR, aG, aB, 1.0f);
            slot++;
        }
        // Floating dragged tab
        float fx = s_drag_x - s_drag_off_x;
        if (fx < padL()) fx = padL();
        float maxFx = vpW - cap_w() - PLUS_W * s - tabW;
        if (fx > maxFx) fx = maxFx;
        vi = winEmitRoundTopRect(v, vi, fx, pT, tabW, tabH, rad, aR, aG, aB, 1.0f);
    } else {
        // --- Normal mode ---
        vi = winEmitRoundTopRect(v, vi, tx(active, count, vpW), pT, tabW, tabH,
                              rad, aR, aG, aB, 1.0f);

        // Hover tab (not active)
        if (s_hovered_tab >= 0 && s_hovered_tab < count && s_hovered_tab != active) {
            vi = winEmitRoundTopRect(v, vi, tx(s_hovered_tab, count, vpW), pT + 2*s,
                                  tabW, tabH - 2*s, rad, hR, hG, hB, 0.5f);
        }

        // Plus button hover
        if (s_hovered_tab == count) {
            float px = tx(count, count, vpW);
            vi = winEmitRoundTopRect(v, vi, px, pT + 2*s, PLUS_W * s, tabH - 2*s,
                                  rad, hR, hG, hB, 0.5f);
        }
        // Session button hover
        if (g_sessions_active && s_hovered_tab == count + 1) {
            float sx = tx(count, count, vpW) + PLUS_W * s;
            vi = winEmitRoundTopRect(v, vi, sx, pT + 2*s, SESS_W * s, tabH - 2*s,
                                  rad, hR, hG, hB, 0.5f);
        }

        // Separators
        for (int i = 1; i < count; i++) {
            if (i - 1 == active || i == active) continue;
            if (i - 1 == s_hovered_tab || i == s_hovered_tab) continue;
            float sx = tx(i, count, vpW);
            float sepH = tabH * 0.5f, sepY = pT + (tabH - sepH) * 0.5f;
            vi = winEmitRect(v, vi, sx - 0.5f, sepY, 1.0f, sepH, fR, fG, fB, 0.1f);
        }
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
            float cx = tabX + tabW - csz - 8 * s;
            float cy = pT + (tabH - csz) * 0.5f;
            float pad = CLOSE_ICON_PAD * s;
            float alpha = (isH && s_hover_close) ? 0.9f : 0.35f;
            if (isH && s_hover_close)
                ii = winEmitRect(iv, ii, cx, cy, csz, csz, fR, fG, fB, 0.1f);
            ii = winEmitLine(iv, ii, cx+pad, cy+pad, cx+csz-pad, cy+csz-pad,
                          lw, fR, fG, fB, alpha);
            ii = winEmitLine(iv, ii, cx+csz-pad, cy+pad, cx+pad, cy+csz-pad,
                          lw, fR, fG, fB, alpha);
        }

        // Plus +
        {
            float px = tx(count, count, vpW) + PLUS_W * s * 0.5f;
            float py = pT + tabH * 0.5f;
            float arm = 5.0f * s;
            ii = winEmitRect(iv, ii, px-arm, py-lw*0.5f, arm*2, lw, fR,fG,fB, 0.45f);
            ii = winEmitRect(iv, ii, px-lw*0.5f, py-arm, lw, arm*2, fR,fG,fB, 0.45f);
        }
        // Session icon: stacked rectangles (rectangle.stack style)
        if (g_sessions_active) {
            float sx = tx(count, count, vpW) + PLUS_W * s + SESS_W * s * 0.5f;
            float sy = pT + tabH * 0.5f;
            float rw = 8.0f * s, rh = 5.0f * s, off = 3.0f * s;
            float ilw = 1.0f * s, ia = 0.45f;
            // Back rect (offset up)
            float bx = sx - rw*0.5f + off*0.3f, by = sy - rh*0.5f - off*0.5f;
            ii = winEmitRect(iv, ii, bx, by, rw, ilw, fR,fG,fB, ia*0.5f);
            ii = winEmitRect(iv, ii, bx, by+rh-ilw, rw, ilw, fR,fG,fB, ia*0.5f);
            ii = winEmitRect(iv, ii, bx, by, ilw, rh, fR,fG,fB, ia*0.5f);
            ii = winEmitRect(iv, ii, bx+rw-ilw, by, ilw, rh, fR,fG,fB, ia*0.5f);
            // Front rect (offset down)
            float fx = sx - rw*0.5f - off*0.3f, fy = sy - rh*0.5f + off*0.5f;
            ii = winEmitRect(iv, ii, fx, fy, rw, ilw, fR,fG,fB, ia);
            ii = winEmitRect(iv, ii, fx, fy+rh-ilw, rw, ilw, fR,fG,fB, ia);
            ii = winEmitRect(iv, ii, fx, fy, ilw, rh, fR,fG,fB, ia);
            ii = winEmitRect(iv, ii, fx+rw-ilw, fy, ilw, rh, fR,fG,fB, ia);
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
            ii = winEmitLine(iv, ii, clx-half, cly-half, clx+half, cly+half,
                          ci_lw, clR, clG, clB, clA);
            ii = winEmitLine(iv, ii, clx+half, cly-half, clx-half, cly+half,
                          ci_lw, clR, clG, clB, clA);
        }

        if (ii > 0) winDrawSolidVerts(iv, ii);
    }

    // --- Text pass: tab titles (Segoe UI via s_tab_gc) ---
    if (s_tab_gc_ready && s_tab_gc.texture_srv) {
        GlyphCache* tgc = &s_tab_gc;
        int maxTV = count * 64 * 6;
        WinVertex* tv = (WinVertex*)_alloca(maxTV * sizeof(WinVertex));
        int tvi = 0;
        float inactA = (lum < 0.5f) ? 0.5f : 0.55f;

        // Build position array (handles both normal and drag modes)
        float tabXs[16];
        if (s_drag_on && s_drag_go && !s_drag_tear) {
            int slot = 0;
            for (int i = 0; i < count; i++) {
                if (i == s_drag_idx) {
                    float fx = s_drag_x - s_drag_off_x;
                    if (fx < padL()) fx = padL();
                    float maxFx = vpW - cap_w() - PLUS_W * s - tabW;
                    if (fx > maxFx) fx = maxFx;
                    tabXs[i] = fx;
                    continue;
                }
                if (slot == s_drag_slot) slot++;
                tabXs[i] = padL() + slot * tabW;
                slot++;
            }
        } else {
            for (int i = 0; i < count; i++) tabXs[i] = tx(i, count, vpW);
        }

        for (int i = 0; i < count; i++) {
            if (s_drag_tear && i == s_drag_idx) continue;
            float tabX = tabXs[i];
            int isA = (i == active);
            float tfR = fR, tfG = fG, tfB = fB;
            float tfA = isA ? 1.0f : inactA;

            float textL = floorf(tabX + TAB_PAD * s);
            float closeW = (count > 1) ? (CLOSE_SZ + 12) * s : TAB_PAD * s;
            float textR = tabX + tabW - closeW;
            if (textR - textL < 10) continue;

            float textY = floorf(pT + (tabH - tgc->glyph_h) * 0.5f);
            wchar_t* title = s_titles[i];
            int tlen = s_title_lens[i];
            if (tlen <= 0) { title = L"Tab"; tlen = 3; }

            float gx = textL;
            for (int ch = 0; ch < tlen && gx + tgc->glyph_w <= textR; ch++) {
                uint32_t cp = (uint32_t)title[ch];
                if (cp == 0) break;
                int slot = glyphCacheLookup(tgc, cp);
                if (slot < 0) slot = glyphCacheRasterize(tgc, cp);
                if (slot < 0) { gx += tgc->glyph_w; continue; }

                int ac = slot % tgc->atlas_cols, ar = slot / tgc->atlas_cols;
                float u0 = (float)(ac * (int)tgc->glyph_w) / (float)tgc->atlas_w;
                float v0 = (float)(ar * (int)tgc->glyph_h) / (float)tgc->atlas_h;
                float u1 = u0 + tgc->glyph_w / (float)tgc->atlas_w;
                float v1 = v0 + tgc->glyph_h / (float)tgc->atlas_h;

                float sx = floorf(gx);  // snap each glyph to pixel grid
                if (tvi + 6 <= maxTV)
                    tvi = winEmitQuad(tv, tvi, sx, textY, sx + tgc->glyph_w,
                                     textY + tgc->glyph_h, u0, v0, u1, v1,
                                     tfR, tfG, tfB, tfA);
                gx += tgc->glyph_w;
            }
        }
        if (tvi > 0) winDrawTextVerts(tv, tvi, tgc);
    }
}

// ---------------------------------------------------------------------------
// Hit testing
// ---------------------------------------------------------------------------

int ntab_hit_test(int px, int py, int clientW) {
    if (!g_native_tabs_enabled) return 0;
    int count = g_native_tab_count;
    if (count < 1) count = 1;

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
    float pL = padL();
    float tabsEnd = pL + count * tabW;
    float plusEnd = tabsEnd + PLUS_W * s;

    if ((float)px < pL)       return HTCAPTION;
    if ((float)px < tabsEnd)  return HTCLIENT;
    if ((float)px < plusEnd)   return HTCLIENT;
    if (g_sessions_active && (float)px < plusEnd + SESS_W * s) return HTCLIENT;
    return HTCAPTION;
}

// ---------------------------------------------------------------------------
// Session dropdown menu (Win32 popup)
// ---------------------------------------------------------------------------

#define IDM_SESSION_BASE  10000
#define IDM_SESSION_NEW   10999

static void ntab_show_session_menu(void) {
    int cnt = g_session_count;
    int activeIdx = g_active_session_idx;
    if (cnt <= 0) { attyx_create_session_direct(); return; }
    HMENU menu = CreatePopupMenu();
    for (int i = 0; i < cnt && i < ATTYX_MAX_SESSIONS; i++) {
        wchar_t name[ATTYX_SESSION_NAME_MAX];
        int n = MultiByteToWideChar(CP_UTF8, 0, g_session_names[i], -1,
                                     name, ATTYX_SESSION_NAME_MAX - 1);
        if (n <= 0) wcscpy(name, L"Session");
        UINT flags = MF_STRING;
        if (i == activeIdx) flags |= MF_CHECKED;
        AppendMenuW(menu, flags, IDM_SESSION_BASE + i, name);
    }
    AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
    AppendMenuW(menu, MF_STRING, IDM_SESSION_NEW, L"Create Session");
    POINT pt; GetCursorPos(&pt);
    int cmd = (int)TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY,
                                   pt.x, pt.y, 0, g_hwnd, NULL);
    DestroyMenu(menu);
    if (cmd == IDM_SESSION_NEW) {
        attyx_toggle_session_switcher();
    } else if (cmd >= IDM_SESSION_BASE && cmd < IDM_SESSION_BASE + cnt) {
        g_session_switch_id = (int)g_session_ids[cmd - IDM_SESSION_BASE];
    }
}

// ---------------------------------------------------------------------------
// Mouse interaction
// ---------------------------------------------------------------------------

int ntab_mouse_move(int px, int py, int clientW) {
    if (!g_native_tabs_enabled || s_drag_on) return 0;
    int count = g_native_tab_count;
    if (count < 1) count = 1;

    float barH = ntab_bar_height();
    int prev_tab = s_hovered_tab, prev_cl = s_hover_close;

    if ((float)py >= barH || py < 0 || (float)px >= (float)clientW - cap_w()) {
        s_hovered_tab = -1; s_hover_close = 0;
    } else {
        float s = sc();
        float tabW = tw(count, (float)clientW);
        float pL = padL();
        float tabsEnd = pL + count * tabW;
        float plusEnd = tabsEnd + PLUS_W * s;

        if ((float)px >= pL && (float)px < tabsEnd) {
            int idx = (int)(((float)px - pL) / tabW);
            if (idx >= count) idx = count - 1;
            s_hovered_tab = idx;
            if (count > 1) {
                float tabX = tx(idx, count, (float)clientW);
                float csz = CLOSE_SZ * s;
                float tH = barH - padT();
                float cx = tabX + tabW - csz - 8*s;
                float cy = padT() + (tH - csz) * 0.5f;
                s_hover_close = ((float)px >= cx && (float)px <= cx+csz &&
                                 (float)py >= cy && (float)py <= cy+csz);
            } else s_hover_close = 0;
        } else if ((float)px < plusEnd) {
            s_hovered_tab = count; s_hover_close = 0;
        } else if (g_sessions_active && (float)px < plusEnd + SESS_W * s) {
            s_hovered_tab = count + 1; s_hover_close = 0;
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

    float barH = ntab_bar_height();
    if ((float)py >= barH || py < 0) return 0;
    if ((float)px >= (float)clientW - cap_w()) return 0;

    float s = sc();
    float tabW = tw(count, (float)clientW);
    float pL = padL();
    float tabsEnd = pL + count * tabW;

    if ((float)px >= pL && (float)px < tabsEnd) {
        int idx = (int)(((float)px - pL) / tabW);
        if (idx >= count) idx = count - 1;
        if (count > 1 && s_hover_close) {
            g_native_tab_click = idx;
            attyx_dispatch_action(50);
            g_full_redraw = 1;
            return 1;
        }
        // Start drag tracking
        s_drag_on = 1; s_drag_go = 0; s_drag_tear = 0;
        s_drag_idx = idx; s_drag_slot = idx;
        s_drag_start_x = (float)px; s_drag_start_y = (float)py;
        s_drag_off_x = (float)px - tx(idx, count, (float)clientW);
        s_drag_x = (float)px;
        SetCapture(g_hwnd);
        return 1;
    } else if ((float)px < tabsEnd + PLUS_W * s) {
        attyx_dispatch_action(49);
        g_full_redraw = 1;
        return 1;
    } else if (g_sessions_active && (float)px < tabsEnd + PLUS_W * s + SESS_W * s) {
        ntab_show_session_menu();
        return 1;
    }
    return 0;
}

int ntab_mouse_drag(int px, int py, int clientW) {
    if (!s_drag_on) return 0;
    int count = g_native_tab_count;
    if (count < 1) count = 1;

    float fpx = (float)px, fpy = (float)py;
    if (!s_drag_go) {
        float dx = fpx - s_drag_start_x, dy = fpy - s_drag_start_y;
        if (dx*dx + dy*dy < DRAG_THRESH * DRAG_THRESH) return 0;
        s_drag_go = 1;
        // Switch to dragged tab immediately
        if (s_drag_idx != g_native_tab_active) {
            g_native_tab_click = s_drag_idx;
        }
    }
    s_drag_x = fpx;
    float barH = ntab_bar_height();
    int wasTear = s_drag_tear;
    s_drag_tear = (count > 1) && (fpy < -TEAR_DIST || fpy > barH + TEAR_DIST);
    if (!s_drag_tear) {
        float tabW = tw(count, (float)clientW);
        int slot = (int)((s_drag_x - s_drag_off_x + tabW * 0.5f - padL()) / tabW);
        if (slot < 0) slot = 0;
        if (slot >= count) slot = count - 1;
        s_drag_slot = slot;
    } else if (!wasTear) {
        s_drag_slot = s_drag_idx;
    }
    g_full_redraw = 1;
    return 1;
}

int ntab_mouse_up(int px, int py, int clientW) {
    if (!s_drag_on) return 0;
    ReleaseCapture();
    int wasGo = s_drag_go;
    int idx = s_drag_idx, slot = s_drag_slot;
    int count = g_native_tab_count;
    s_drag_on = 0; s_drag_go = 0;

    if (!wasGo) {
        // Simple click — switch tab
        s_drag_idx = -1; s_drag_slot = -1;
        if (idx >= 0 && idx < count && idx != g_native_tab_active) {
            g_native_tab_click = idx;
            g_full_redraw = 1;
        }
        return 1;
    }

    if (s_drag_tear) {
        // Tear off: close tab in current window, spawn new window
        s_drag_tear = 0;
        s_drag_idx = -1; s_drag_slot = -1;
        g_native_tab_click = idx;
        attyx_dispatch_action(50);
        attyx_spawn_new_window();
    } else if (slot != idx) {
        // Reorder: packed (from << 8) | to
        s_drag_idx = -1; s_drag_slot = -1;
        g_native_tab_reorder = (idx << 8) | slot;
    } else {
        s_drag_idx = -1; s_drag_slot = -1;
    }
    g_full_redraw = 1;
    return 1;
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
