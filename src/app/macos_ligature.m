// Attyx — macOS ligature support (CoreText calt-based shaping)
//
// Programming fonts (Fira Code, JetBrains Mono) use the `calt` OpenType
// feature, not `liga`. With `calt`, glyph count stays the same but each
// glyph ID changes based on context. We shape runs of trigger characters,
// rasterize the entire shaped line as one bitmap, then slice it into
// per-cell atlas slots.

#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>
#include <string.h>
#include "macos_internal.h"

// ---------------------------------------------------------------------------
// Ligature key: hash a codepoint sequence into 0x40000000-0x7FFFFFFF range.
// ---------------------------------------------------------------------------

uint32_t ligatureKey(const uint32_t* cps, int count) {
    uint32_t h = (uint32_t)count;
    for (int i = 0; i < count; i++)
        h = h * 31 + cps[i];
    return (h & 0x3FFFFFFF) | 0x40000000;
}

// ---------------------------------------------------------------------------
// Trigger check: characters that commonly form programming font ligatures.
// ---------------------------------------------------------------------------

bool isLigaTrigger(uint32_t ch) {
    if (ch < 33 || ch > 126) return false;
    switch (ch) {
        case '!': case '#': case '$': case '%': case '&':
        case '*': case '+': case '-': case '.': case '/':
        case ':': case ';': case '<': case '=': case '>':
        case '?': case '@': case '\\': case '^': case '|':
        case '~': case '_':
            return true;
        default:
            return false;
    }
}

// ---------------------------------------------------------------------------
// Ligature result cache — maps sequence key → shaped atlas slots.
// ---------------------------------------------------------------------------

static LigaResult s_ligaCache[LIGA_RESULT_CAP];

void ligatureCacheClear(void) {
    memset(s_ligaCache, 0, sizeof(s_ligaCache));
}

static LigaResult* ligaCacheLookup(uint32_t key) {
    uint32_t idx = (key * 2654435761u) % LIGA_RESULT_CAP;
    for (int probe = 0; probe < 32; probe++) {
        uint32_t i = (idx + probe) % LIGA_RESULT_CAP;
        if (s_ligaCache[i].key == 0) return NULL;
        if (s_ligaCache[i].key == key) return &s_ligaCache[i];
    }
    return NULL;
}

static LigaResult* ligaCacheInsert(uint32_t key) {
    uint32_t idx = (key * 2654435761u) % LIGA_RESULT_CAP;
    for (int probe = 0; probe < 32; probe++) {
        uint32_t i = (idx + probe) % LIGA_RESULT_CAP;
        if (s_ligaCache[i].key == 0 || s_ligaCache[i].key == key) {
            s_ligaCache[i].key = key;
            return &s_ligaCache[i];
        }
    }
    // Cache full — evict at primary slot
    uint32_t i = idx % LIGA_RESULT_CAP;
    s_ligaCache[i].key = key;
    return &s_ligaCache[i];
}

// ---------------------------------------------------------------------------
// UTF-16 encoding helper
// ---------------------------------------------------------------------------

static int cpToUtf16(uint32_t cp, UniChar buf[2]) {
    if (cp <= 0xFFFF) { buf[0] = (UniChar)cp; return 1; }
    uint32_t u = cp - 0x10000;
    buf[0] = (UniChar)(0xD800 + (u >> 10));
    buf[1] = (UniChar)(0xDC00 + (u & 0x3FF));
    return 2;
}

// ---------------------------------------------------------------------------
// Shape and rasterize a run: renders the entire shaped line as one bitmap,
// then slices it into per-cell atlas slots. This lets CoreText handle all
// glyph positioning internally.
// ---------------------------------------------------------------------------

const LigaResult* shapeLigatureRun(GlyphCache* gc, const uint32_t* cps, int count) {
    if (count < 2 || count > MAX_LIGA_LEN) return NULL;

    uint32_t key = ligatureKey(cps, count);
    LigaResult* cached = ligaCacheLookup(key);
    if (cached) return cached;

    int gw = (int)gc->glyph_w;
    int gh = (int)gc->glyph_h;

    // Build UTF-16 string
    UniChar utf16[MAX_LIGA_LEN * 2];
    int utf16Len = 0;
    for (int i = 0; i < count; i++)
        utf16Len += cpToUtf16(cps[i], &utf16[utf16Len]);

    // Shape with CoreText (calt is enabled by default)
    NSString* str = [[NSString alloc] initWithCharacters:utf16 length:utf16Len];
    NSDictionary* attrs = @{(NSString*)kCTFontAttributeName: (__bridge id)gc->font};
    NSAttributedString* attrStr = [[NSAttributedString alloc]
        initWithString:str attributes:attrs];
    CTLineRef line = CTLineCreateWithAttributedString(
        (__bridge CFAttributedStringRef)attrStr);

    // Check if any glyph ID differs from unshaped individual lookup
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    CFIndex runCount = CFArrayGetCount(runs);
    bool hasAlternates = false;

    int pos = 0;
    for (CFIndex r = 0; r < runCount && pos < count; r++) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, r);
        CFIndex glyphCount = CTRunGetGlyphCount(run);
        CGGlyph glyphs[MAX_LIGA_LEN];
        int toGet = (int)glyphCount;
        if (pos + toGet > count) toGet = count - pos;
        CTRunGetGlyphs(run, CFRangeMake(0, toGet), glyphs);
        for (int g = 0; g < toGet && !hasAlternates; g++) {
            UniChar u16[2];
            int u16len = cpToUtf16(cps[pos + g], u16);
            CGGlyph unshaped = 0;
            CTFontGetGlyphsForCharacters(gc->font, u16, &unshaped, u16len);
            if (glyphs[g] != unshaped) hasAlternates = true;
        }
        pos += toGet;
    }

    LigaResult* result = ligaCacheInsert(key);
    result->count = (int8_t)count;
    result->hasAlternates = hasAlternates;
    memset(result->slots, 0xFF, sizeof(result->slots)); // -1

    if (!hasAlternates) {
        CFRelease(line);
        return result;
    }

    // Extract shaped glyph IDs and positions from CTRun, then rasterize
    // with CTFontDrawGlyphs (CTLineDraw is blank in grayscale contexts).
    int totalW = gw * count;
    CGGlyph shapedGlyphs[MAX_LIGA_LEN];
    CGPoint shapedPositions[MAX_LIGA_LEN];
    int shapedCount = 0;

    for (CFIndex r = 0; r < runCount && shapedCount < count; r++) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, r);
        CFIndex glyphCount = CTRunGetGlyphCount(run);
        int toGet = (int)glyphCount;
        if (shapedCount + toGet > count) toGet = count - shapedCount;
        CTRunGetGlyphs(run, CFRangeMake(0, toGet), &shapedGlyphs[shapedCount]);
        CTRunGetPositions(run, CFRangeMake(0, toGet), &shapedPositions[shapedCount]);
        shapedCount += toGet;
    }
    CFRelease(line);

    uint8_t* pixels = (uint8_t*)calloc(totalW * gh, 1);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(pixels, totalW, gh, 8, totalW,
                                             cs, kCGImageAlphaNone);
    CGColorSpaceRelease(cs);
    CGContextSetGrayFillColor(ctx, 1.0, 1.0);
    CGContextSetShouldSmoothFonts(ctx, NO);
    CGContextSetAllowsFontSmoothing(ctx, NO);

    // Draw all shaped glyphs at their CTRun positions (shifted by x_offset)
    CGPoint drawPositions[MAX_LIGA_LEN];
    for (int k = 0; k < shapedCount; k++) {
        drawPositions[k] = CGPointMake(
            shapedPositions[k].x + gc->x_offset,
            gc->baseline_y);
    }
    CTFontDrawGlyphs(gc->font, shapedGlyphs, drawPositions, shapedCount, ctx);
    CGContextRelease(ctx);

    // Slice into per-cell atlas slots
    for (int k = 0; k < count; k++) {
        if (gc->next_slot >= gc->max_slots) glyphCacheGrow(gc);
        int slot = gc->next_slot++;
        int ac = slot % gc->atlas_cols;
        int ar = slot / gc->atlas_cols;

        // Extract cell k's column from the wide bitmap
        uint8_t* cell_pixels = (uint8_t*)calloc(gw * gh, 1);
        for (int row = 0; row < gh; row++) {
            memcpy(&cell_pixels[row * gw],
                   &pixels[row * totalW + k * gw],
                   gw);
        }

        [gc->texture replaceRegion:MTLRegionMake2D(ac * gw, ar * gh, gw, gh)
                       mipmapLevel:0
                         withBytes:cell_pixels
                       bytesPerRow:gw];
        free(cell_pixels);
        result->slots[k] = slot;
    }

    free(pixels);
    return result;
}
