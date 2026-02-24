// Attyx — geometry-based box-drawing renderer (U+2500–U+257F)
// Renders box-drawing characters as filled rects so strokes are always exactly
// 1 logical pixel (lw = roundf(scale)) regardless of font metrics or line spacing.

#import <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include "macos_internal.h"

// Horizontal rect centered on yc, from x0 to x1, height w
#define HLINE(x0,x1,yc,w) \
    CGContextFillRect(ctx, CGRectMake((x0),(yc)-roundf((w)*0.5f),(x1)-(x0),(w)))
// Vertical rect centered on xc, from y0 to y1, width w
#define VLINE(y0,y1,xc,w) \
    CGContextFillRect(ctx, CGRectMake((xc)-roundf((w)*0.5f),(y0),(w),(y1)-(y0)))

// ---------------------------------------------------------------------------
// Single/heavy line segment table — (r<<6)|(l<<4)|(d<<2)|u, 0=none 1=light 2=heavy
// 0x00 = fall back to glyph (dashed variants)
// ---------------------------------------------------------------------------

static const uint8_t kSegs[76] = {
    // 2500 ─  ━  │  ┃  ┄  ┅  ┆  ┇  ┈  ┉  ┊  ┋
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

// Half-segment table (2574–257F): same encoding, segments go only to cell edge
static const uint8_t kHalf[12] = {
    // 2574 ╴  ╵  ╶  ╷  ╸  ╹  ╺  ╻  ╼  ╽  ╾  ╿
    0x10,0x01,0x40,0x04, 0x20,0x02,0x80,0x08, 0x90,0x09,0x60,0x06,
};

// Draw segments described by an encoding byte. Each segment goes from the
// cell edge to (and slightly past) the center, so junctions are always filled.
static void drawSegs(CGContextRef ctx, uint8_t enc,
                     float gw, float gh, float cx, float cy,
                     float lw, float hw) {
    int r = (enc >> 6) & 3, l = (enc >> 4) & 3;
    int d = (enc >> 2) & 3, u = enc & 3;
    float rw = r==2?hw:lw, lw2=l==2?hw:lw, dw=d==2?hw:lw, uw=u==2?hw:lw;
    // Max perpendicular widths (used to extend segments past center for clean junctions)
    float mv = (d||u) ? fmaxf(d?dw:0, u?uw:0) : 0;  // max vert width
    float mh = (r||l) ? fmaxf(r?rw:0, l?lw2:0) : 0; // max horiz width
    // Segments extend from edge to cx±mv/2 or cy±mh/2 to cover the junction pixel
    float ext_h = roundf(mv * 0.5f);
    float ext_v = roundf(mh * 0.5f);
    if (r) HLINE(cx - ext_h, gw,  cy, rw);
    if (l) HLINE(0, cx + ext_h,   cy, lw2);
    if (d) VLINE(0, cy + ext_v,   cx, dw);
    if (u) VLINE(cy - ext_v, gh,  cx, uw);
}

// Draw double-line characters (U+2550–U+256C)
static int drawDouble(CGContextRef ctx, uint32_t cp,
                      float gw, float gh, float cx, float cy,
                      float lw, float off) {
    // e = half stroke width; extend each segment past its junction point by e
    // so perpendicular segments overlap cleanly (same trick as drawSegs ext_h/ext_v).
    float e = roundf(lw * 0.5f);
    switch (cp) {
    case 0x2550: HLINE(0,gw,cy-off,lw); HLINE(0,gw,cy+off,lw); break; // ═
    case 0x2551: VLINE(0,gh,cx-off,lw); VLINE(0,gh,cx+off,lw); break; // ║

    // Corners — double both directions
    case 0x2554: // ╔ down+right
        VLINE(0,cy+off+e,cx-off,lw); VLINE(0,cy-off+e,cx+off,lw);
        HLINE(cx-off-e,gw,cy+off,lw); HLINE(cx+off-e,gw,cy-off,lw); break;
    case 0x2557: // ╗ down+left
        VLINE(0,cy+off+e,cx+off,lw); VLINE(0,cy-off+e,cx-off,lw);
        HLINE(0,cx+off+e,cy+off,lw); HLINE(0,cx-off+e,cy-off,lw); break;
    case 0x255A: // ╚ up+right
        VLINE(cy-off-e,gh,cx-off,lw); VLINE(cy+off-e,gh,cx+off,lw);
        HLINE(cx-off-e,gw,cy-off,lw); HLINE(cx+off-e,gw,cy+off,lw); break;
    case 0x255D: // ╝ up+left
        VLINE(cy-off-e,gh,cx+off,lw); VLINE(cy+off-e,gh,cx-off,lw);
        HLINE(0,cx+off+e,cy-off,lw); HLINE(0,cx-off+e,cy+off,lw); break;

    // T-junctions — double all three directions
    case 0x2560: // ╠ vert+right
        VLINE(0,cy-off+e,cx-off,lw); VLINE(cy+off-e,gh,cx-off,lw);
        VLINE(0,gh,cx+off,lw);
        HLINE(cx-off-e,gw,cy-off,lw); HLINE(cx-off-e,gw,cy+off,lw); break;
    case 0x2563: // ╣ vert+left
        VLINE(0,cy-off+e,cx+off,lw); VLINE(cy+off-e,gh,cx+off,lw);
        VLINE(0,gh,cx-off,lw);
        HLINE(0,cx+off+e,cy-off,lw); HLINE(0,cx+off+e,cy+off,lw); break;
    case 0x2566: // ╦ down+horiz
        HLINE(0,gw,cy+off,lw); HLINE(0,gw,cy-off,lw);
        VLINE(0,cy+off+e,cx-off,lw); VLINE(0,cy-off+e,cx+off,lw); break;
    case 0x2569: // ╩ up+horiz
        HLINE(0,gw,cy-off,lw); HLINE(0,gw,cy+off,lw);
        VLINE(cy-off-e,gh,cx-off,lw); VLINE(cy+off-e,gh,cx+off,lw); break;
    case 0x256C: // ╬ cross
        HLINE(0,gw,cy-off,lw); HLINE(0,gw,cy+off,lw);
        VLINE(0,cy-off+e,cx-off,lw); VLINE(cy+off-e,gh,cx-off,lw);
        VLINE(0,cy-off+e,cx+off,lw); VLINE(cy+off-e,gh,cx+off,lw); break;

    // Mixed single+double corners (single down/up + double horiz)
    case 0x2552: // ╒ single-down, double-right
        VLINE(0,cy+off+e,cx,lw); HLINE(cx-e,gw,cy-off,lw); HLINE(cx-e,gw,cy+off,lw); break;
    case 0x2555: // ╕ single-down, double-left
        VLINE(0,cy+off+e,cx,lw); HLINE(0,cx+e,cy-off,lw); HLINE(0,cx+e,cy+off,lw); break;
    case 0x2558: // ╘ single-up, double-right
        VLINE(cy-off-e,gh,cx,lw); HLINE(cx-e,gw,cy-off,lw); HLINE(cx-e,gw,cy+off,lw); break;
    case 0x255B: // ╛ single-up, double-left
        VLINE(cy-off-e,gh,cx,lw); HLINE(0,cx+e,cy-off,lw); HLINE(0,cx+e,cy+off,lw); break;
    // Mixed single+double corners (double down/up + single horiz)
    case 0x2553: // ╓ double-down, single-right
        HLINE(cx-off-e,gw,cy,lw); VLINE(0,cy+e,cx-off,lw); VLINE(0,cy+e,cx+off,lw); break;
    case 0x2556: // ╖ double-down, single-left
        HLINE(0,cx+off+e,cy,lw); VLINE(0,cy+e,cx-off,lw); VLINE(0,cy+e,cx+off,lw); break;
    case 0x2559: // ╙ double-up, single-right
        HLINE(cx-off-e,gw,cy,lw); VLINE(cy-e,gh,cx-off,lw); VLINE(cy-e,gh,cx+off,lw); break;
    case 0x255C: // ╜ double-up, single-left
        HLINE(0,cx+off+e,cy,lw); VLINE(cy-e,gh,cx-off,lw); VLINE(cy-e,gh,cx+off,lw); break;
    // Mixed T-junctions
    case 0x255E: // ╞ single-vert, double-right
        VLINE(0,gh,cx,lw); HLINE(cx-e,gw,cy-off,lw); HLINE(cx-e,gw,cy+off,lw); break;
    case 0x2561: // ╡ single-vert, double-left
        VLINE(0,gh,cx,lw); HLINE(0,cx+e,cy-off,lw); HLINE(0,cx+e,cy+off,lw); break;
    case 0x255F: // ╟ double-vert, single-right
        VLINE(0,gh,cx-off,lw); VLINE(0,gh,cx+off,lw); HLINE(cx-off-e,gw,cy,lw); break;
    case 0x2562: // ╢ double-vert, single-left
        VLINE(0,gh,cx-off,lw); VLINE(0,gh,cx+off,lw); HLINE(0,cx+off+e,cy,lw); break;
    case 0x2564: // ╤ single-down, double-horiz
        VLINE(0,cy+e,cx,lw); HLINE(0,gw,cy-off,lw); HLINE(0,gw,cy+off,lw); break;
    case 0x2567: // ╧ single-up, double-horiz
        VLINE(cy-e,gh,cx,lw); HLINE(0,gw,cy-off,lw); HLINE(0,gw,cy+off,lw); break;
    case 0x2565: // ╥ double-down, single-horiz
        HLINE(0,gw,cy,lw); VLINE(0,cy+e,cx-off,lw); VLINE(0,cy+e,cx+off,lw); break;
    case 0x2568: // ╨ double-up, single-horiz
        HLINE(0,gw,cy,lw); VLINE(cy-e,gh,cx-off,lw); VLINE(cy-e,gh,cx+off,lw); break;
    case 0x256A: // ╪ single-vert, double-horiz
        VLINE(0,gh,cx,lw); HLINE(0,gw,cy-off,lw); HLINE(0,gw,cy+off,lw); break;
    case 0x256B: // ╫ double-vert, single-horiz
        VLINE(0,gh,cx-off,lw); VLINE(0,gh,cx+off,lw); HLINE(0,gw,cy,lw); break;
    default: return 0;
    }
    return 1;
}

// Draw a rounded corner using CGContextAddArc — CG computes the arc natively.
// Each corner: straight segment → circular quarter-arc → straight segment.
// r = min(cx,cy) so the arc is always circular; straights extend to cell edges.
static void drawArcCorner(CGContextRef ctx, uint32_t cp,
                          float gw, float gh, float cx, float cy, float lw) {
    float r = fminf(cx, cy);
    CGContextSetGrayStrokeColor(ctx, 1.0f, 1.0f);
    CGContextSetLineWidth(ctx, lw);
    CGContextSetLineCap(ctx, kCGLineCapButt);
    CGContextBeginPath(ctx);
    switch (cp) {
    case 0x256D: // ╭
        CGContextMoveToPoint(ctx, gw, cy);
        CGContextAddLineToPoint(ctx, cx + r, cy);
        CGContextAddArc(ctx, cx + r, cy - r, r, M_PI_2, M_PI, 0);
        CGContextAddLineToPoint(ctx, cx, 0);
        break;
    case 0x256E: // ╮
        CGContextMoveToPoint(ctx, 0, cy);
        CGContextAddLineToPoint(ctx, cx - r, cy);
        CGContextAddArc(ctx, cx - r, cy - r, r, M_PI_2, 0, 1);
        CGContextAddLineToPoint(ctx, cx, 0);
        break;
    case 0x256F: // ╯
        CGContextMoveToPoint(ctx, 0, cy);
        CGContextAddLineToPoint(ctx, cx - r, cy);
        CGContextAddArc(ctx, cx - r, cy + r, r, -M_PI_2, 0, 0);
        CGContextAddLineToPoint(ctx, cx, gh);
        break;
    case 0x2570: // ╰
        CGContextMoveToPoint(ctx, gw, cy);
        CGContextAddLineToPoint(ctx, cx + r, cy);
        CGContextAddArc(ctx, cx + r, cy + r, r, -M_PI_2, M_PI, 1);
        CGContextAddLineToPoint(ctx, cx, gh);
        break;
    }
    CGContextStrokePath(ctx);
}

// ---------------------------------------------------------------------------
// Public entry point called from glyphCacheRasterize
// ---------------------------------------------------------------------------

int renderBoxDraw(CGContextRef ctx, uint32_t cp, int gw_i, int gh_i, float scale) {
    float gw = (float)gw_i, gh = (float)gh_i;
    float lw = roundf(scale);          // light stroke = 1 logical pixel
    float hw = roundf(scale * 2.0f);   // heavy stroke = 2 logical pixels
    float off = lw;                     // double-line offset = stroke width → gap equals stroke
    float cx = roundf(gw * 0.5f);
    float cy = roundf(gh * 0.5f);

    if (cp >= 0x2500 && cp <= 0x254B) {
        uint8_t enc = kSegs[cp - 0x2500];
        if (!enc) return 0;
        drawSegs(ctx, enc, gw, gh, cx, cy, lw, hw);
        return 1;
    }
    if (cp >= 0x2550 && cp <= 0x256C)
        return drawDouble(ctx, cp, gw, gh, cx, cy, lw, off);
    // Light arc corners (U+256D–U+2570): quarter-ellipse Bezier arcs spanning
    // from one cell-edge midpoint to the other, stroke width = lw.
    if (cp >= 0x256D && cp <= 0x2570) {
        drawArcCorner(ctx, cp, gw, gh, cx, cy, lw);
        return 1;
    }
    if (cp >= 0x2574 && cp <= 0x257F) {
        uint8_t enc = kHalf[cp - 0x2574];
        if (!enc) return 0;
        drawSegs(ctx, enc, gw, gh, cx, cy, lw, hw);
        return 1;
    }
    return 0;
}

#undef HLINE
#undef VLINE
