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

// Padding: tabs float inside the bar with margins
#define BAR_PAD_TOP     6   // top margin above tabs
#define BAR_PAD_LEFT    8   // left margin before first tab
#define TAB_FONT_PT     11  // fixed tab title font size (uses terminal font family)

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

// Tab font: terminal font family at fixed small size
static void tab_gc_init(void) {
    if (s_tab_gc_ready) return;
    float scale = g_content_scale, fontSize = TAB_FONT_PT * scale;
    memset(&s_tab_gc, 0, sizeof(s_tab_gc));
    for (int i = 0; i < GLYPH_CACHE_CAP; i++) s_tab_gc.map[i].slot = -1;
    s_tab_gc.d3d_device = g_d3d_device;
    s_tab_gc.scale = scale;
    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    HRESULT hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED,
                     &IID_IDWriteFactory, (IUnknown**)&s_tab_gc.dw_factory);
    if (FAILED(hr)) return;
    // Use the terminal's configured font family (monospace) at fixed small size
    static wchar_t family[ATTYX_FONT_FAMILY_MAX];
    if (g_font_family_len > 0) {
        int n = MultiByteToWideChar(CP_UTF8, 0, g_font_family, g_font_family_len,
                                     family, ATTYX_FONT_FAMILY_MAX - 1);
        family[n] = 0;
    } else {
        wcscpy(family, L"Consolas");
    }
    IDWriteTextFormat* fmt = NULL;
    hr = IDWriteFactory_CreateTextFormat(s_tab_gc.dw_factory, family, NULL,
             DWRITE_FONT_WEIGHT_REGULAR, DWRITE_FONT_STYLE_NORMAL,
             DWRITE_FONT_STRETCH_NORMAL, fontSize, L"en-us", &fmt);
    if (FAILED(hr)) return;
    IDWriteTextFormat_SetWordWrapping(fmt, DWRITE_WORD_WRAPPING_NO_WRAP);
    s_tab_gc.dw_format = fmt;
    // Font face for glyph index lookups
    IDWriteFontCollection* coll = NULL;
    IDWriteFactory_GetSystemFontCollection(s_tab_gc.dw_factory, &coll, FALSE);
    if (coll) {
        UINT32 fi = 0; BOOL exists = FALSE;
        IDWriteFontCollection_FindFamilyName(coll, family, &fi, &exists);
        if (exists) {
            IDWriteFontFamily* fam = NULL;
            IDWriteFontCollection_GetFontFamily(coll, fi, &fam);
            if (fam) {
                IDWriteFont* font = NULL;
                IDWriteFontFamily_GetFirstMatchingFont(fam,
                    DWRITE_FONT_WEIGHT_REGULAR, DWRITE_FONT_STRETCH_NORMAL,
                    DWRITE_FONT_STYLE_NORMAL, &font);
                if (font) { IDWriteFont_CreateFontFace(font, &s_tab_gc.dw_face); IDWriteFont_Release(font); }
                IDWriteFontFamily_Release(fam);
            }
        }
        IDWriteFontCollection_Release(coll);
    }
    // Measure cell size
    IDWriteTextLayout* layout = NULL;
    hr = IDWriteFactory_CreateTextLayout(s_tab_gc.dw_factory, L"M", 1, fmt, 1000, 1000, &layout);
    float gw = 8, gh = 16, asc = 12;
    if (SUCCEEDED(hr) && layout) {
        DWRITE_TEXT_METRICS tm; IDWriteTextLayout_GetMetrics(layout, &tm);
        DWRITE_LINE_METRICS lm; UINT32 lc = 0;
        IDWriteTextLayout_GetLineMetrics(layout, &lm, 1, &lc);
        gw = roundf(tm.widthIncludingTrailingWhitespace);
        gh = roundf(lm.height); asc = roundf(lm.baseline);
        IDWriteTextLayout_Release(layout);
    }
    s_tab_gc.glyph_w = gw; s_tab_gc.glyph_h = gh;
    s_tab_gc.font_size = (int)fontSize;
    s_tab_gc.ascender = asc;
    s_tab_gc.baseline_y_offset = 0; s_tab_gc.x_offset = 0;
    // Atlas texture (32×16 grid)
    int cols = 32, rows = 16;
    s_tab_gc.atlas_cols = cols;
    s_tab_gc.atlas_w = (int)(gw * cols); s_tab_gc.atlas_h = (int)(gh * rows);
    s_tab_gc.next_slot = 0; s_tab_gc.max_slots = cols * rows;
    D3D11_TEXTURE2D_DESC td = {
        .Width = (UINT)s_tab_gc.atlas_w, .Height = (UINT)s_tab_gc.atlas_h,
        .MipLevels = 1, .ArraySize = 1, .Format = DXGI_FORMAT_R8_UNORM,
        .SampleDesc = { .Count = 1 }, .Usage = D3D11_USAGE_DEFAULT,
        .BindFlags = D3D11_BIND_SHADER_RESOURCE,
    };
    hr = ID3D11Device_CreateTexture2D(g_d3d_device, &td, NULL, &s_tab_gc.texture);
    if (FAILED(hr)) return;
    hr = ID3D11Device_CreateShaderResourceView(g_d3d_device,
             (ID3D11Resource*)s_tab_gc.texture, NULL, &s_tab_gc.texture_srv);
    if (FAILED(hr)) return;
    // D2D offscreen for glyph rasterization
    int bmpW = (int)(gw * 2), bmpH = (int)gh;
    hr = CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER,
                           &IID_IWICImagingFactory, (void**)&s_tab_gc.wic_factory);
    if (FAILED(hr)) return;
    hr = IWICImagingFactory_CreateBitmap(s_tab_gc.wic_factory, (UINT)bmpW, (UINT)bmpH,
             &GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnLoad, &s_tab_gc.wic_bitmap);
    if (FAILED(hr)) return;
    hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
                            &IID_ID2D1Factory, NULL, (void**)&s_tab_gc.d2d_factory);
    if (FAILED(hr)) return;
    D2D1_RENDER_TARGET_PROPERTIES rtp = {
        .type = D2D1_RENDER_TARGET_TYPE_SOFTWARE,
        .pixelFormat = { .format = DXGI_FORMAT_B8G8R8A8_UNORM, .alphaMode = D2D1_ALPHA_MODE_PREMULTIPLIED },
        .dpiX = 96, .dpiY = 96,
    };
    hr = ID2D1Factory_CreateWicBitmapRenderTarget(s_tab_gc.d2d_factory,
             s_tab_gc.wic_bitmap, &rtp, &s_tab_gc.d2d_rt);
    if (FAILED(hr)) return;
    D2D1_COLOR_F white = { 1, 1, 1, 1 };
    hr = ID2D1RenderTarget_CreateSolidColorBrush(s_tab_gc.d2d_rt, &white, NULL, &s_tab_gc.d2d_brush);
    if (FAILED(hr)) return;
    for (uint32_t ch = 32; ch < 127; ch++) glyphCacheRasterize(&s_tab_gc, ch);
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

static float tw(int n, float vpW) {
    float avail = vpW - cap_w() - PLUS_W * sc() - padL();
    float w = avail / (float)(n > 0 ? n : 1);
    float s = sc();
    if (w < TAB_MIN_W * s) w = TAB_MIN_W * s;
    if (w > TAB_MAX_W * s) w = TAB_MAX_W * s;
    return w;
}

static float tx(int i, int n, float vpW) { return padL() + i * tw(n, vpW); }

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
                vi = emitRoundTopRect(v, vi, sx, pT, tabW, tabH, rad, aR, aG, aB, 1.0f);
            slot++;
        }
        // Floating dragged tab
        float fx = s_drag_x - s_drag_off_x;
        if (fx < padL()) fx = padL();
        float maxFx = vpW - cap_w() - PLUS_W * s - tabW;
        if (fx > maxFx) fx = maxFx;
        vi = emitRoundTopRect(v, vi, fx, pT, tabW, tabH, rad, aR, aG, aB, 1.0f);
    } else {
        // --- Normal mode ---
        vi = emitRoundTopRect(v, vi, tx(active, count, vpW), pT, tabW, tabH,
                              rad, aR, aG, aB, 1.0f);

        // Hover tab (not active)
        if (s_hovered_tab >= 0 && s_hovered_tab < count && s_hovered_tab != active) {
            vi = emitRoundTopRect(v, vi, tx(s_hovered_tab, count, vpW), pT + 2*s,
                                  tabW, tabH - 2*s, rad, hR, hG, hB, 0.5f);
        }

        // Plus button hover
        if (s_hovered_tab == count) {
            float px = tx(count, count, vpW);
            vi = emitRoundTopRect(v, vi, px, pT + 2*s, PLUS_W * s, tabH - 2*s,
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
            ii = emitLine(iv, ii, cx+pad, cy+pad, cx+csz-pad, cy+csz-pad,
                          lw, fR, fG, fB, alpha);
            ii = emitLine(iv, ii, cx+csz-pad, cy+pad, cx+pad, cy+csz-pad,
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

            float textL = tabX + TAB_PAD * s;
            float closeW = (count > 1) ? (CLOSE_SZ + 12) * s : TAB_PAD * s;
            float textR = tabX + tabW - closeW;
            if (textR - textL < 10) continue;

            float textY = pT + (tabH - tgc->glyph_h) * 0.5f;
            wchar_t* title = s_titles[i];
            int tlen = s_title_lens[i];
            if (tlen <= 0) { title = L"Tab"; tlen = 3; }

            float cx = textL;
            for (int ch = 0; ch < tlen && cx + tgc->glyph_w <= textR; ch++) {
                uint32_t cp = (uint32_t)title[ch];
                if (cp == 0) break;
                int slot = glyphCacheLookup(tgc, cp);
                if (slot < 0) slot = glyphCacheRasterize(tgc, cp);
                if (slot < 0) { cx += tgc->glyph_w; continue; }

                int ac = slot % tgc->atlas_cols, ar = slot / tgc->atlas_cols;
                float u0 = (float)(ac * (int)tgc->glyph_w) / (float)tgc->atlas_w;
                float v0 = (float)(ar * (int)tgc->glyph_h) / (float)tgc->atlas_h;
                float u1 = u0 + tgc->glyph_w / (float)tgc->atlas_w;
                float v1 = v0 + tgc->glyph_h / (float)tgc->atlas_h;

                if (tvi + 6 <= maxTV)
                    tvi = winEmitQuad(tv, tvi, cx, textY, cx + tgc->glyph_w,
                                     textY + tgc->glyph_h, u0, v0, u1, v1,
                                     tfR, tfG, tfB, tfA);
                cx += tgc->glyph_w;
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
    float pL = padL();
    float tabsEnd = pL + count * tabW;
    float plusEnd = tabsEnd + PLUS_W * s;

    if ((float)px < pL)       return HTCAPTION;
    if ((float)px < tabsEnd)  return HTCLIENT;
    if ((float)px < plusEnd)   return HTCLIENT;
    return HTCAPTION;
}

// ---------------------------------------------------------------------------
// Mouse interaction
// ---------------------------------------------------------------------------

int ntab_mouse_move(int px, int py, int clientW) {
    if (!g_native_tabs_enabled || s_drag_on) return 0;
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
