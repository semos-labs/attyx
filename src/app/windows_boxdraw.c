// Attyx — Windows box-drawing renderer (U+2500-U+257F)
// Renders box-drawing characters as filled rects into a pixel buffer.
// Strokes are exactly 1 logical pixel (light) or 2 logical pixels (heavy),
// independent of font metrics. Same segment encoding as macos_boxdraw.m.

#ifdef _WIN32

#include "windows_internal.h"

// ---------------------------------------------------------------------------
// Pixel-buffer rect fill helpers (top-to-bottom pixel layout)
// ---------------------------------------------------------------------------

// Fill a horizontal rect centered on yc, from x0 to x1, height w
static void hline(uint8_t* pixels, int stride,
                  float x0, float x1, float yc, float w, int gh) {
    int iy0 = (int)(yc - roundf(w * 0.5f));
    int iy1 = iy0 + (int)w;
    int ix0 = (int)x0;
    int ix1 = (int)x1;
    if (iy0 < 0) iy0 = 0;
    if (iy1 > gh) iy1 = gh;
    if (ix0 < 0) ix0 = 0;
    if (ix1 > stride) ix1 = stride;
    for (int y = iy0; y < iy1; y++)
        for (int x = ix0; x < ix1; x++)
            pixels[y * stride + x] = 255;
}

// Fill a vertical rect centered on xc, from y0 to y1, width w
static void vline(uint8_t* pixels, int stride,
                  float y0, float y1, float xc, float w, int gh) {
    int iy0 = (int)y0;
    int iy1 = (int)y1;
    int ix0 = (int)(xc - roundf(w * 0.5f));
    int ix1 = ix0 + (int)w;
    if (iy0 < 0) iy0 = 0;
    if (iy1 > gh) iy1 = gh;
    if (ix0 < 0) ix0 = 0;
    if (ix1 > stride) ix1 = stride;
    for (int y = iy0; y < iy1; y++)
        for (int x = ix0; x < ix1; x++)
            pixels[y * stride + x] = 255;
}

// ---------------------------------------------------------------------------
// Segment encoding table — (r<<6)|(l<<4)|(d<<2)|u, 0=none 1=light 2=heavy
// 0x00 = fall back to glyph (dashed variants)
// ---------------------------------------------------------------------------

static const uint8_t kSegs[76] = {
    // 2500 -  ━  │  ┃  ┄  ┅  ┆  ┇  ┈  ┉  ┊  ┋
    0x50,0xA0,0x05,0x0A, 0,0,0,0,0,0,0,0,
    // 250C ┌  ┍  ┎  ┏  ┐  ┑  ┒  ┓  └  ┕  ┖  ┗  ┘  ┙  ┚  ┛
    0x44,0x84,0x48,0x88, 0x14,0x24,0x18,0x28, 0x41,0x81,0x42,0x82, 0x11,0x21,0x12,0x22,
    // 251C ├  ┝  ┞  ┟  ┠  ┡  ┢  ┣  ┤  ┥  ┦  ┧  ┨  ┩  ┪  ┫
    0x45,0x85,0x46,0x49,0x4A,0x86,0x89,0x8A, 0x15,0x25,0x16,0x19,0x1A,0x26,0x29,0x2A,
    // 252C ┬  ┭  ┮  ┯  ┰  ┱  ┲  ┳  ┴  ┵  ┶  ┷  ┸  ┹  ┺  ┻
    0x54,0x64,0x94,0xA4, 0x58,0x68,0x98,0xA8, 0x51,0x61,0x91,0xA1, 0x52,0x62,0x92,0xA2,
    // 253C ┼  ┽  ┾  ┿  ╀  ╁  ╂  ╃  ╄  ╅  ╆  ╇  ╈  ╉  ╊  ╋
    0x55,0x65,0x95,0xA5, 0x56,0x59,0x5A,0x66, 0x96,0x69,0x99,0xA6, 0xA9,0x6A,0x9A,0xAA,
};

// Half-segment table (2574-257F)
static const uint8_t kHalf[12] = {
    0x10,0x01,0x40,0x04, 0x20,0x02,0x80,0x08, 0x90,0x09,0x60,0x06,
};

// Draw segments described by an encoding byte.
static void drawSegs(uint8_t* pixels, int stride, int gh,
                     uint8_t enc,
                     float gw, float fgh, float cx, float cy,
                     float lw, float hw) {
    int r = (enc >> 6) & 3, l = (enc >> 4) & 3;
    int d = (enc >> 2) & 3, u = enc & 3;
    float rw = r==2?hw:lw, lw2=l==2?hw:lw, dw=d==2?hw:lw, uw=u==2?hw:lw;
    float mv = (d||u) ? fmaxf(d?dw:0, u?uw:0) : 0;
    float mh = (r||l) ? fmaxf(r?rw:0, l?lw2:0) : 0;
    float ext_h = roundf(mv * 0.5f);
    float ext_v = roundf(mh * 0.5f);
    if (r) hline(pixels, stride, cx - ext_h, gw,          cy, rw, gh);
    if (l) hline(pixels, stride, 0,          cx + ext_h,  cy, lw2, gh);
    if (d) vline(pixels, stride, cy - ext_v, fgh,         cx, dw, gh);
    if (u) vline(pixels, stride, 0,          cy + ext_v,  cx, uw, gh);
}

// ---------------------------------------------------------------------------
// Double-line characters (U+2550-U+256C)
// ---------------------------------------------------------------------------

static int drawDouble(uint8_t* pixels, int stride, int gh,
                      uint32_t cp,
                      float gw, float fgh, float cx, float cy,
                      float lw, float off) {
    float e = roundf(lw * 0.5f);
    #define H(x0,x1,yc) hline(pixels,stride,(x0),(x1),(yc),lw,gh)
    #define V(y0,y1,xc) vline(pixels,stride,(y0),(y1),(xc),lw,gh)
    switch (cp) {
    case 0x2550: H(0,gw,cy-off); H(0,gw,cy+off); break;
    case 0x2551: V(0,fgh,cx-off); V(0,fgh,cx+off); break;
    case 0x2554: V(0,cy+off+e,cx-off); V(0,cy-off+e,cx+off); H(cx-off-e,gw,cy+off); H(cx+off-e,gw,cy-off); break;
    case 0x2557: V(0,cy+off+e,cx+off); V(0,cy-off+e,cx-off); H(0,cx+off+e,cy+off); H(0,cx-off+e,cy-off); break;
    case 0x255A: V(cy-off-e,fgh,cx-off); V(cy+off-e,fgh,cx+off); H(cx-off-e,gw,cy-off); H(cx+off-e,gw,cy+off); break;
    case 0x255D: V(cy-off-e,fgh,cx+off); V(cy+off-e,fgh,cx-off); H(0,cx+off+e,cy-off); H(0,cx-off+e,cy+off); break;
    case 0x2560: V(0,cy-off+e,cx-off); V(cy+off-e,fgh,cx-off); V(0,fgh,cx+off); H(cx-off-e,gw,cy-off); H(cx-off-e,gw,cy+off); break;
    case 0x2563: V(0,cy-off+e,cx+off); V(cy+off-e,fgh,cx+off); V(0,fgh,cx-off); H(0,cx+off+e,cy-off); H(0,cx+off+e,cy+off); break;
    case 0x2566: H(0,gw,cy+off); H(0,gw,cy-off); V(0,cy+off+e,cx-off); V(0,cy-off+e,cx+off); break;
    case 0x2569: H(0,gw,cy-off); H(0,gw,cy+off); V(cy-off-e,fgh,cx-off); V(cy+off-e,fgh,cx+off); break;
    case 0x256C: H(0,gw,cy-off); H(0,gw,cy+off); V(0,cy-off+e,cx-off); V(cy+off-e,fgh,cx-off); V(0,cy-off+e,cx+off); V(cy+off-e,fgh,cx+off); break;
    // Mixed single+double
    case 0x2552: V(0,cy+off+e,cx); H(cx-e,gw,cy-off); H(cx-e,gw,cy+off); break;
    case 0x2555: V(0,cy+off+e,cx); H(0,cx+e,cy-off); H(0,cx+e,cy+off); break;
    case 0x2558: V(cy-off-e,fgh,cx); H(cx-e,gw,cy-off); H(cx-e,gw,cy+off); break;
    case 0x255B: V(cy-off-e,fgh,cx); H(0,cx+e,cy-off); H(0,cx+e,cy+off); break;
    case 0x2553: H(cx-off-e,gw,cy); V(0,cy+e,cx-off); V(0,cy+e,cx+off); break;
    case 0x2556: H(0,cx+off+e,cy); V(0,cy+e,cx-off); V(0,cy+e,cx+off); break;
    case 0x2559: H(cx-off-e,gw,cy); V(cy-e,fgh,cx-off); V(cy-e,fgh,cx+off); break;
    case 0x255C: H(0,cx+off+e,cy); V(cy-e,fgh,cx-off); V(cy-e,fgh,cx+off); break;
    case 0x255E: V(0,fgh,cx); H(cx-e,gw,cy-off); H(cx-e,gw,cy+off); break;
    case 0x2561: V(0,fgh,cx); H(0,cx+e,cy-off); H(0,cx+e,cy+off); break;
    case 0x255F: V(0,fgh,cx-off); V(0,fgh,cx+off); H(cx-off-e,gw,cy); break;
    case 0x2562: V(0,fgh,cx-off); V(0,fgh,cx+off); H(0,cx+off+e,cy); break;
    case 0x2564: V(0,cy+e,cx); H(0,gw,cy-off); H(0,gw,cy+off); break;
    case 0x2567: V(cy-e,fgh,cx); H(0,gw,cy-off); H(0,gw,cy+off); break;
    case 0x2565: H(0,gw,cy); V(0,cy+e,cx-off); V(0,cy+e,cx+off); break;
    case 0x2568: H(0,gw,cy); V(cy-e,fgh,cx-off); V(cy-e,fgh,cx+off); break;
    case 0x256A: V(0,fgh,cx); H(0,gw,cy-off); H(0,gw,cy+off); break;
    case 0x256B: V(0,fgh,cx-off); V(0,fgh,cx+off); H(0,gw,cy); break;
    default: return 0;
    }
    #undef H
    #undef V
    return 1;
}

// ---------------------------------------------------------------------------
// Arc corners (U+256D-U+2570) — pixel approximation of quarter circle
// ---------------------------------------------------------------------------

static void drawArcCorner(uint8_t* pixels, int stride, int gh,
                          uint32_t cp, float gw, float fgh,
                          float cx, float cy, float lw) {
    float r = fminf(cx, cy);
    int ilw = (int)lw;
    if (ilw < 1) ilw = 1;
    // Quarter-circle rasterization using Bresenham-style approach
    float arcCx, arcCy;
    int drawRight, drawDown; // direction of straight segments
    switch (cp) {
    case 0x256D: arcCx = cx + r; arcCy = cy - r; drawRight = 1; drawDown = 0; break; // top-left
    case 0x256E: arcCx = cx - r; arcCy = cy - r; drawRight = 0; drawDown = 0; break; // top-right
    case 0x256F: arcCx = cx - r; arcCy = cy + r; drawRight = 0; drawDown = 1; break; // bottom-right
    case 0x2570: arcCx = cx + r; arcCy = cy + r; drawRight = 1; drawDown = 1; break; // bottom-left
    default: return;
    }

    // Draw the arc as a series of anti-aliased pixels
    int steps = (int)(r * 4);
    if (steps < 16) steps = 16;
    float pi2 = 3.14159265f / 2.0f;
    for (int i = 0; i <= steps; i++) {
        float t = (float)i / (float)steps * pi2;
        float ax = arcCx + r * cosf(t + pi2 * (cp == 0x256D ? 1 : cp == 0x256E ? 0 : cp == 0x256F ? 3 : 2));
        float ay = arcCy + r * sinf(t + pi2 * (cp == 0x256D ? 1 : cp == 0x256E ? 0 : cp == 0x256F ? 3 : 2));
        for (int dy = 0; dy < ilw; dy++) {
            for (int dx = 0; dx < ilw; dx++) {
                int px = (int)(ax - ilw * 0.5f) + dx;
                int py = (int)(ay - ilw * 0.5f) + dy;
                if (px >= 0 && px < stride && py >= 0 && py < gh)
                    pixels[py * stride + px] = 255;
            }
        }
    }
    // Straight segments extending to cell edges
    if (drawRight)
        hline(pixels, stride, cx + r, gw, cy, lw, gh);
    else
        hline(pixels, stride, 0, cx - r, cy, lw, gh);
    if (drawDown)
        vline(pixels, stride, cy + r, fgh, cx, lw, gh);
    else
        vline(pixels, stride, 0, cy - r, cx, lw, gh);
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

int renderBoxDraw(uint8_t* pixels, int stride, uint32_t cp,
                  int gw_i, int gh_i, float scale) {
    float gw = (float)gw_i, gh = (float)gh_i;
    float lw = roundf(scale);
    float hw = roundf(scale * 2.0f);
    float off = lw;
    float cx = roundf(gw * 0.5f);
    float cy = roundf(gh * 0.5f);
    if (lw < 1.0f) lw = 1.0f;
    if (hw < 2.0f) hw = 2.0f;

    if (cp >= 0x2500 && cp <= 0x254B) {
        uint8_t enc = kSegs[cp - 0x2500];
        if (!enc) return 0;
        drawSegs(pixels, stride, gh_i, enc, gw, gh, cx, cy, lw, hw);
        return 1;
    }
    if (cp >= 0x2550 && cp <= 0x256C)
        return drawDouble(pixels, stride, gh_i, cp, gw, gh, cx, cy, lw, off);
    if (cp >= 0x256D && cp <= 0x2570) {
        drawArcCorner(pixels, stride, gh_i, cp, gw, gh, cx, cy, lw);
        return 1;
    }
    if (cp >= 0x2574 && cp <= 0x257F) {
        uint8_t enc = kHalf[cp - 0x2574];
        if (!enc) return 0;
        drawSegs(pixels, stride, gh_i, enc, gw, gh, cx, cy, lw, hw);
        return 1;
    }
    return 0;
}

#endif // _WIN32
