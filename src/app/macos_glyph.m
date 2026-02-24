// Attyx — macOS glyph cache (Core Text rasterization)

#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>
#include <string.h>
#include <stdlib.h>
#include "macos_internal.h"

// Forward declarations (defined later in this file)
static CTFontRef createVerifiedFont(CFStringRef reqName, CGFloat fontSize);
static CTFontRef createFuzzyMatchFont(CFStringRef reqName, CGFloat fontSize);

// Fixed reference cell dimensions (in logical points) captured on the first
// createGlyphCache call. Percent-mode cell sizes are anchored to these values
// so that changing the font size does not affect the configured cell height/width.
static float s_ref_h_pt = 0.0f;
static float s_ref_w_pt = 0.0f;

/// Returns true if `cp` belongs to a Unicode range whose East Asian Width
/// property is W (Wide) or F (Fullwidth) — i.e. it occupies 2 terminal cells.
/// Characters with EAW = N / Na / H must return false even if the font
/// happens to draw them wider than one cell (e.g. regional indicators).
static bool canBeWide(uint32_t cp) {
    if (cp < 0x1100) return false;
    if (cp <= 0x115F) return true;   // Hangul Jamo
    if (cp == 0x2329 || cp == 0x232A) return true;
    if (cp >= 0x2E80 && cp <= 0x303E) return true;  // CJK Radicals, Kangxi, Bopomofo
    if (cp >= 0x3041 && cp <= 0x33FF) return true;  // Kana, CJK symbols, Compatibility
    if (cp >= 0x3400 && cp <= 0x4DBF) return true;  // CJK Unified Ext-A
    if (cp >= 0x4E00 && cp <= 0x9FFF) return true;  // CJK Unified
    if (cp >= 0xA000 && cp <= 0xA4CF) return true;  // Yi
    if (cp >= 0xA960 && cp <= 0xA97F) return true;  // Hangul Jamo Ext-A
    if (cp >= 0xAC00 && cp <= 0xD7AF) return true;  // Hangul Syllables
    if (cp >= 0xF900 && cp <= 0xFAFF) return true;  // CJK Compatibility Ideographs
    if (cp >= 0xFE10 && cp <= 0xFE6F) return true;  // Vertical / Compat forms
    if (cp >= 0xFF01 && cp <= 0xFF60) return true;  // Fullwidth ASCII
    if (cp >= 0xFFE0 && cp <= 0xFFE6) return true;  // Fullwidth signs
    if (cp >= 0x1B000 && cp <= 0x1B2FF) return true; // Kana Supplement / Extended
    if (cp >= 0x1F300 && cp <= 0x1F64F) return true; // Misc Symbols, Emoticons (NOT 1F1E0-1F1FF)
    if (cp >= 0x1F680 && cp <= 0x1F6FF) return true; // Transport & Map Symbols
    if (cp >= 0x1F7E0 && cp <= 0x1F7FF) return true; // Coloured circles/squares
    if (cp >= 0x1F900 && cp <= 0x1FAFF) return true; // Supplemental Symbols & Pictographs
    if (cp >= 0x20000 && cp <= 0x2FFFD) return true; // CJK Ext B–F
    if (cp >= 0x30000 && cp <= 0x3FFFD) return true; // CJK Ext G–H
    // Common emoji with Emoji_Presentation that are unambiguously 2-cell:
    if (cp == 0x231A || cp == 0x231B) return true;
    if (cp >= 0x23E9 && cp <= 0x23F3) return true;
    if (cp >= 0x25FD && cp <= 0x25FE) return true;
    if (cp == 0x2614 || cp == 0x2615) return true;
    if (cp >= 0x2648 && cp <= 0x2653) return true;
    if (cp == 0x267F || cp == 0x2693 || cp == 0x26A1) return true;
    if (cp == 0x26CE || cp == 0x26D4 || cp == 0x26EA) return true;
    if (cp == 0x26F2 || cp == 0x26F3 || cp == 0x26F5) return true;
    if (cp == 0x26FA || cp == 0x26FD) return true;
    if (cp == 0x2702 || cp == 0x2705) return true;
    if (cp == 0x2708) return true;                           // ✈ airplane
    if (cp >= 0x270A && cp <= 0x270B) return true;          // ✊✋ fists
    if (cp == 0x270D) return true;                           // ✍ writing hand
    if (cp == 0x2728) return true;
    if (cp == 0x2744 || cp == 0x2747) return true;
    if (cp == 0x274C || cp == 0x274E) return true;
    if (cp >= 0x2753 && cp <= 0x2755) return true;
    if (cp == 0x2757) return true;
    if (cp == 0x2763 || cp == 0x2764) return true;
    if (cp >= 0x2795 && cp <= 0x2797) return true;
    if (cp == 0x27A1 || cp == 0x27B0 || cp == 0x27BF) return true;
    if (cp == 0x2934 || cp == 0x2935) return true;
    if (cp >= 0x2B05 && cp <= 0x2B07) return true;
    if (cp == 0x2B1B || cp == 0x2B1C || cp == 0x2B50 || cp == 0x2B55) return true;
    return false;
}

static void glyphCacheInsert(GlyphCache* gc, uint32_t cp, int slot) {
    uint32_t idx = (cp * 2654435761u) % GLYPH_CACHE_CAP;
    for (int probe = 0; probe < GLYPH_CACHE_CAP; probe++) {
        uint32_t i = (idx + probe) % GLYPH_CACHE_CAP;
        if (gc->map[i].slot < 0 || gc->map[i].codepoint == cp) {
            gc->map[i].codepoint = cp;
            gc->map[i].slot = slot;
            return;
        }
    }
}

int glyphCacheLookup(GlyphCache* gc, uint32_t cp) {
    uint32_t idx = (cp * 2654435761u) % GLYPH_CACHE_CAP;
    for (int probe = 0; probe < GLYPH_CACHE_CAP; probe++) {
        uint32_t i = (idx + probe) % GLYPH_CACHE_CAP;
        if (gc->map[i].slot < 0) return -1;
        if (gc->map[i].codepoint == cp) return gc->map[i].slot;
    }
    return -1;
}

static void glyphCacheGrow(GlyphCache* gc) {
    int oldH = gc->atlas_h;
    int newRows = (gc->max_slots / gc->atlas_cols) * 2;
    int newH = (int)(gc->glyph_h * newRows);
    int newMaxSlots = gc->atlas_cols * newRows;

    // Grow grayscale atlas
    MTLTextureDescriptor* desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                           width:gc->atlas_w
                                                          height:newH
                                                       mipmapped:NO];
    id<MTLTexture> newTex = [gc->device newTextureWithDescriptor:desc];

    uint8_t* buf = (uint8_t*)calloc(gc->atlas_w * newH, 1);
    [gc->texture getBytes:buf
              bytesPerRow:gc->atlas_w
               fromRegion:MTLRegionMake2D(0, 0, gc->atlas_w, oldH)
              mipmapLevel:0];
    [newTex replaceRegion:MTLRegionMake2D(0, 0, gc->atlas_w, newH)
              mipmapLevel:0
                withBytes:buf
              bytesPerRow:gc->atlas_w];
    free(buf);
    gc->texture = newTex;

    // Grow color atlas in parallel (slots are shared — indices must stay consistent)
    uint8_t* cbuf = (uint8_t*)calloc(gc->atlas_w * newH * 4, 1);
    [gc->color_texture getBytes:cbuf
                    bytesPerRow:gc->atlas_w * 4
                     fromRegion:MTLRegionMake2D(0, 0, gc->atlas_w, oldH)
                    mipmapLevel:0];
    MTLTextureDescriptor* cd = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:gc->atlas_w height:newH mipmapped:NO];
    id<MTLTexture> newColorTex = [gc->device newTextureWithDescriptor:cd];
    [newColorTex replaceRegion:MTLRegionMake2D(0, 0, gc->atlas_w, newH)
                   mipmapLevel:0 withBytes:cbuf bytesPerRow:gc->atlas_w * 4];
    free(cbuf);
    gc->color_texture = newColorTex;

    gc->atlas_h = newH;
    gc->max_slots = newMaxSlots;
}

int glyphCacheRasterize(GlyphCache* gc, uint32_t cp) {
    int gw = (int)gc->glyph_w;
    int gh = (int)gc->glyph_h;

    // 1. UTF-16 encoding
    UniChar utf16[2];
    int utf16Len;
    if (cp <= 0xFFFF) {
        utf16[0] = (UniChar)cp;
        utf16Len = 1;
    } else {
        uint32_t u = cp - 0x10000;
        utf16[0] = (UniChar)(0xD800 + (u >> 10));
        utf16[1] = (UniChar)(0xDC00 + (u & 0x3FF));
        utf16Len = 2;
    }

    // 2. Glyph lookup: primary font → user fallbacks → system fallback
    CTFontRef drawFont = gc->font;
    CGGlyph glyph = 0;
    bool haveGlyph = CTFontGetGlyphsForCharacters(gc->font, utf16, &glyph, utf16Len)
                  && glyph != 0;
    if (!haveGlyph) {
        CGFloat fontSize = CTFontGetSize(gc->font);
        CTFontRef found = NULL;
        for (int fi = 0; fi < g_font_fallback_count; fi++) {
            CFStringRef name = CFStringCreateWithCString(NULL, g_font_fallback[fi],
                                                         kCFStringEncodingUTF8);
            CTFontRef candidate = createVerifiedFont(name, fontSize);
            if (!candidate) candidate = createFuzzyMatchFont(name, fontSize);
            CFRelease(name);
            if (candidate) {
                if (CTFontGetGlyphsForCharacters(candidate, utf16, &glyph, utf16Len)) {
                    found = candidate;
                    haveGlyph = true;
                    break;
                }
                CFRelease(candidate);
            }
        }
        if (found) {
            drawFont = found;
        } else {
            NSString* str = [[NSString alloc] initWithCharacters:utf16 length:utf16Len];
            CTFontRef fallback = CTFontCreateForString(gc->font, (__bridge CFStringRef)str,
                                                        CFRangeMake(0, str.length));
            if (fallback) {
                if (CTFontGetGlyphsForCharacters(fallback, utf16, &glyph, utf16Len)) {
                    drawFont = fallback;
                    haveGlyph = true;
                } else {
                    CFRelease(fallback);
                }
            }
        }
    }

    // 3. Classify: detect wide glyphs (advance or ink > 1.05× cell width).
    //    Wide glyphs get a 2-cell atlas slot and a 2×gw wide renderer quad.
    //    canBeWide() gates this check: characters with EAW = N/Na/H (e.g. regional
    //    indicator symbols U+1F1E0–U+1F1FF) must never be given a 2-cell slot even
    //    if the font happens to draw them wider than one cell — they are 1-cell
    //    characters in the terminal model, and 2-cell allocation causes bleed into
    //    adjacent cells.
    bool isPowerline = (cp >= 0xE0B0 && cp <= 0xE0D4);
    bool isBoxDraw   = (cp >= 0x2500 && cp <= 0x257F);
    bool isBlock     = (cp >= 0x2580 && cp <= 0x259F);
    bool wide = false;
    if (haveGlyph && !isPowerline && !isBlock && canBeWide(cp)) {
        CGRect bbox;
        CTFontGetBoundingRectsForGlyphs(drawFont, kCTFontOrientationDefault, &glyph, &bbox, 1);
        CGSize adv;
        CTFontGetAdvancesForGlyphs(drawFont, kCTFontOrientationDefault, &glyph, &adv, 1);
        float inkRight = (float)(bbox.origin.x + bbox.size.width);
        float srcW = fmaxf((float)adv.width, inkRight);
        wide = (srcW > (float)gw * 1.05f);
    }
    int renderW = wide ? 2 * gw : gw;

    // 4. Allocate atlas slot(s)
    int slot;
    if (wide) {
        // Ensure wide glyph doesn't split across atlas rows
        if (gc->next_slot % gc->atlas_cols == gc->atlas_cols - 1)
            gc->next_slot++;
        while (gc->next_slot + 1 >= gc->max_slots) glyphCacheGrow(gc);
        slot = gc->next_slot;
        gc->next_slot += 2;
    } else {
        if (gc->next_slot >= gc->max_slots) glyphCacheGrow(gc);
        slot = gc->next_slot++;
    }
    int ac = slot % gc->atlas_cols;
    int ar = slot / gc->atlas_cols;

    // 5. If no glyph was found, store a blank slot (all-zero pixels) and return.
    //    Block elements skip this: they are drawn as geometry, no glyph needed.
    if (!haveGlyph && !isBlock) {
        if (drawFont != gc->font) CFRelease(drawFont);
        glyphCacheInsert(gc, cp, slot);
        return slot;
    }

    // 5b. Color emoji path: detect Apple Color Emoji and rasterize into BGRA color atlas.
    if (haveGlyph && !isBlock) {
        CFStringRef familyName = CTFontCopyFamilyName(drawFont);
        bool isColorEmoji = (CFStringCompare(familyName, CFSTR("Apple Color Emoji"), 0)
                             == kCFCompareEqualTo);
        CFRelease(familyName);

        if (isColorEmoji) {
            CGColorSpaceRef rgbCS = CGColorSpaceCreateDeviceRGB();
            uint8_t* pixels = (uint8_t*)calloc(renderW * gh * 4, 1);
            CGContextRef ctx = CGBitmapContextCreate(pixels, renderW, gh, 8, renderW * 4,
                rgbCS, kCGBitmapByteOrder32Host | kCGImageAlphaPremultipliedFirst);
            CGColorSpaceRelease(rgbCS);

            NSString* str = [[NSString alloc] initWithCharacters:utf16 length:utf16Len];
            NSDictionary* attrs = @{(NSString*)kCTFontAttributeName: (__bridge id)drawFont};
            NSAttributedString* attrStr = [[NSAttributedString alloc]
                initWithString:str attributes:attrs];
            CTLineRef line = CTLineCreateWithAttributedString(
                (__bridge CFAttributedStringRef)attrStr);
            // Match the gray glyph path: wide uses x=0, narrow uses x_offset;
            // baseline_y centers the glyph in the cell (same as CTFontDrawGlyphs).
            float posX = wide ? 0.0f : (float)gc->x_offset;
            CGContextSetTextPosition(ctx, (CGFloat)posX, (CGFloat)gc->baseline_y);
            CTLineDraw(line, ctx);
            CFRelease(line);
            CGContextRelease(ctx);

            [gc->color_texture
                replaceRegion:MTLRegionMake2D(ac * gw, ar * gh, renderW, gh)
                  mipmapLevel:0 withBytes:pixels bytesPerRow:(NSUInteger)(renderW * 4)];
            free(pixels);

            if (drawFont != gc->font) CFRelease(drawFont);
            int encoded = (wide ? GLYPH_WIDE_BIT : 0) | GLYPH_COLOR_BIT | slot;
            glyphCacheInsert(gc, cp, encoded);
            return encoded;
        }
    }

    // 6. Create bitmap context (renderW × gh)
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    uint8_t* pixels = (uint8_t*)calloc(renderW * gh, 1);
    CGContextRef ctx = CGBitmapContextCreate(pixels, renderW, gh, 8, renderW, cs, kCGImageAlphaNone);
    CGColorSpaceRelease(cs);
    CGContextSetGrayFillColor(ctx, 1.0, 1.0);
    // Disable LCD subpixel smoothing — it fattens strokes in grayscale contexts.
    CGContextSetShouldSmoothFonts(ctx, NO);
    CGContextSetAllowsFontSmoothing(ctx, NO);

    // 7. Draw glyph into the bitmap
    if (isBoxDraw) {
        // Box-drawing (U+2500–U+257F): geometry-based rendering for pixel-perfect
        // thin lines at exactly 1 logical pixel — no font metrics involved.
        // Falls back to unscaled glyph draw for dashed/arc variants not in the table.
        if (!renderBoxDraw(ctx, cp, gw, gh, gc->scale)) {
            CGPoint pos = CGPointMake((float)gc->x_offset, gc->baseline_y);
            CTFontDrawGlyphs(drawFont, &glyph, &pos, 1, ctx);
        }
    } else if (isPowerline) {
        // Powerline glyphs (U+E0B0–U+E0D4): scale to fill the full cell so that
        // chevrons and hard-separators tile seamlessly regardless of cell height.
        CGSize adv;
        CTFontGetAdvancesForGlyphs(drawFont, kCTFontOrientationDefault, &glyph, &adv, 1);
        CGFloat asc  = CTFontGetAscent(drawFont);
        CGFloat desc = CTFontGetDescent(drawFont);
        CGFloat srcW = (adv.width > 1) ? adv.width : (CGFloat)gw;
        CGFloat srcH = asc + desc;
        if (srcH < 1) srcH = (CGFloat)gh;
        float sx = (float)gw / (float)srcW;
        float sy = (float)gh / (float)srcH;
        CGContextScaleCTM(ctx, sx, sy);
        CGPoint pos = CGPointMake(0.0f, (float)desc);
        CTFontDrawGlyphs(drawFont, &glyph, &pos, 1, ctx);
    } else if (isBlock) {
        // Render block/quadrant elements as pure geometry for pixel-perfect results.
        // Font-glyph bounding-box scaling doesn't preserve partial fills:
        // scaling ▄ (bbox height = gh/2) by gh/bbox.height = 2× yields a full block.
        // CG coordinate system: y=0 at bottom of context.
        bool drawn = false;
        if (cp >= 0x2581 && cp <= 0x2588) {
            // LOWER ONE-EIGHTH .. FULL BLOCK (U+2581–U+2588)
            int eighths = (int)(cp - 0x2580); // 1..8
            float blockH = roundf((float)gh * eighths / 8.0f);
            CGContextFillRect(ctx, CGRectMake(0, 0, (float)gw, blockH));
            drawn = true;
        } else if (cp == 0x2580) {
            // UPPER HALF BLOCK
            float halfH = roundf((float)gh / 2.0f);
            CGContextFillRect(ctx, CGRectMake(0, (float)gh - halfH, (float)gw, halfH));
            drawn = true;
        } else if (cp >= 0x2589 && cp <= 0x258F) {
            // LEFT SEVEN-EIGHTHS .. LEFT ONE-EIGHTH BLOCK (U+2589–U+258F)
            int eighths = (int)(0x2590 - cp); // 7..1
            float blockW = roundf((float)gw * eighths / 8.0f);
            CGContextFillRect(ctx, CGRectMake(0, 0, blockW, (float)gh));
            drawn = true;
        } else if (cp == 0x2590) {
            // RIGHT HALF BLOCK
            float halfW = roundf((float)gw / 2.0f);
            CGContextFillRect(ctx, CGRectMake((float)gw - halfW, 0, halfW, (float)gh));
            drawn = true;
        } else if (cp == 0x2594) {
            // UPPER ONE EIGHTH BLOCK
            float blockH = roundf((float)gh / 8.0f);
            CGContextFillRect(ctx, CGRectMake(0, (float)gh - blockH, (float)gw, blockH));
            drawn = true;
        } else if (cp == 0x2595) {
            // RIGHT ONE EIGHTH BLOCK
            float blockW = roundf((float)gw / 8.0f);
            CGContextFillRect(ctx, CGRectMake((float)gw - blockW, 0, blockW, (float)gh));
            drawn = true;
        } else if (cp >= 0x2596 && cp <= 0x259F) {
            // QUADRANT BLOCKS — bits: UL=1, UR=2, BL=4, BR=8
            static const int quadBits[] = {4, 8, 1, 13, 9, 7, 11, 2, 6, 14};
            int bits = quadBits[cp - 0x2596];
            float hw = roundf((float)gw / 2.0f);
            float hh = roundf((float)gh / 2.0f);
            if (bits & 1) CGContextFillRect(ctx, CGRectMake(0,  hh, hw,            (float)gh - hh)); // UL
            if (bits & 2) CGContextFillRect(ctx, CGRectMake(hw, hh, (float)gw - hw, (float)gh - hh)); // UR
            if (bits & 4) CGContextFillRect(ctx, CGRectMake(0,  0,  hw,            hh));              // BL
            if (bits & 8) CGContextFillRect(ctx, CGRectMake(hw, 0,  (float)gw - hw, hh));             // BR
            drawn = true;
        }
        if (!drawn && haveGlyph) {
            // Shade characters (U+2591–U+2593) and other unhandled block chars:
            // fall back to bbox-scaled glyph (they fill the full cell so scaling is fine).
            CGRect bbox;
            CTFontGetBoundingRectsForGlyphs(drawFont, kCTFontOrientationDefault, &glyph, &bbox, 1);
            if (bbox.size.width > 1 && bbox.size.height > 1) {
                float sx = (float)gw / (float)bbox.size.width;
                float sy = (float)gh / (float)bbox.size.height;
                CGContextScaleCTM(ctx, sx, sy);
                CGPoint pos = CGPointMake(-bbox.origin.x, -bbox.origin.y);
                CTFontDrawGlyphs(drawFont, &glyph, &pos, 1, ctx);
            } else {
                CGPoint pos = CGPointMake(gc->x_offset, gc->baseline_y);
                CTFontDrawGlyphs(drawFont, &glyph, &pos, 1, ctx);
            }
        }
    } else if (wide) {
        // Wide icon: draw at natural origin in the 2×gw context — no scaling needed.
        // The glyph's advance fills the wider slot; the renderer quad spans 2 cells.
        CGPoint pos = CGPointMake(0.0f, gc->baseline_y);
        CTFontDrawGlyphs(drawFont, &glyph, &pos, 1, ctx);
    } else {
        // Normal glyph: fits within one cell.
        // Check if the glyph's ink overflows the cell. If so, scale it down uniformly to fit.
        CGRect bbox;
        CTFontGetBoundingRectsForGlyphs(drawFont, kCTFontOrientationDefault, &glyph, &bbox, 1);
        float inkL = gc->x_offset + (float)bbox.origin.x;
        float inkR = inkL + (float)bbox.size.width;
        float inkB = gc->baseline_y + (float)bbox.origin.y;
        float inkT = inkB + (float)bbox.size.height;
        bool overflows = (inkR > (float)gw + 0.5f) || (inkT > (float)gh + 0.5f) ||
                         (inkL < -0.5f) || (inkB < -0.5f);
        if (overflows && bbox.size.width > 0.5 && bbox.size.height > 0.5) {
            float sx = (float)gw / (float)bbox.size.width;
            float sy = (float)gh / (float)bbox.size.height;
            float s  = fminf(sx, sy);
            if (s > 1.0f) s = 1.0f;
            CGContextScaleCTM(ctx, s, s);
            // Center the scaled glyph in the cell
            float posX = ((float)gw / s - (float)bbox.size.width) * 0.5f - (float)bbox.origin.x;
            float posY = ((float)gh / s - (float)bbox.size.height) * 0.5f - (float)bbox.origin.y;
            CGPoint pos = CGPointMake(posX, posY);
            CTFontDrawGlyphs(drawFont, &glyph, &pos, 1, ctx);
        } else {
            CGPoint pos = CGPointMake(gc->x_offset, gc->baseline_y);
            CTFontDrawGlyphs(drawFont, &glyph, &pos, 1, ctx);
        }
    }

    CGContextRelease(ctx);
    if (drawFont != gc->font) CFRelease(drawFont);

    // 8. Upload to atlas
    [gc->texture replaceRegion:MTLRegionMake2D(ac * gw, ar * gh, renderW, gh)
                   mipmapLevel:0
                     withBytes:pixels
                   bytesPerRow:renderW];
    free(pixels);

    // 9. Insert into map — encode wide flag in bit 30 of the slot value
    int encoded = wide ? (slot | GLYPH_WIDE_BIT) : slot;
    glyphCacheInsert(gc, cp, encoded);
    return encoded;
}

static CTFontRef createVerifiedFont(CFStringRef reqName, CGFloat fontSize) {
    CTFontRef candidate = CTFontCreateWithName(reqName, fontSize, NULL);
    if (!candidate) return NULL;

    CFStringRef resolvedFamily = CTFontCopyFamilyName(candidate);
    if (!resolvedFamily) { CFRelease(candidate); return NULL; }

    bool matches = (CFStringCompare(resolvedFamily, reqName, kCFCompareCaseInsensitive) == kCFCompareEqualTo);

    if (!matches) {
        CFStringRef resolvedFull = CTFontCopyFullName(candidate);
        if (resolvedFull) {
            matches = (CFStringCompare(resolvedFull, reqName, kCFCompareCaseInsensitive) == kCFCompareEqualTo);
            CFRelease(resolvedFull);
        }
    }
    if (!matches) {
        CFStringRef resolvedPS = CTFontCopyPostScriptName(candidate);
        if (resolvedPS) {
            matches = (CFStringCompare(resolvedPS, reqName, kCFCompareCaseInsensitive) == kCFCompareEqualTo);
            CFRelease(resolvedPS);
        }
    }

    CFRelease(resolvedFamily);
    if (matches) return candidate;
    CFRelease(candidate);
    return NULL;
}

static CFStringRef createNormalizedName(CFStringRef name) {
    CFMutableStringRef mut = CFStringCreateMutableCopy(NULL, 0, name);
    CFStringLowercase(mut, NULL);
    CFStringFindAndReplace(mut, CFSTR(" "), CFSTR(""), CFRangeMake(0, CFStringGetLength(mut)), 0);
    return mut;
}

static CTFontRef createFuzzyMatchFont(CFStringRef reqName, CGFloat fontSize) {
    CFStringRef normReq = createNormalizedName(reqName);
    CTFontRef result = NULL;

    CFArrayRef families = CTFontManagerCopyAvailableFontFamilyNames();
    if (families) {
        CFIndex count = CFArrayGetCount(families);
        for (CFIndex i = 0; i < count; i++) {
            CFStringRef family = (CFStringRef)CFArrayGetValueAtIndex(families, i);
            CFStringRef normFamily = createNormalizedName(family);
            // Exact normalized match, or prefix match in either direction.
            // This lets "JetBrains Mono Nerd" find "JetBrainsMono Nerd Font Mono".
            NSString* nsFamily = (__bridge NSString*)normFamily;
            NSString* nsReq    = (__bridge NSString*)normReq;
            BOOL matches = [nsFamily isEqualToString:nsReq]
                        || [nsFamily hasPrefix:nsReq]
                        || [nsReq hasPrefix:nsFamily];
            if (matches) {
                result = CTFontCreateWithName(family, fontSize, NULL);
                CFRelease(normFamily);
                break;
            }
            CFRelease(normFamily);
        }
        CFRelease(families);
    }
    CFRelease(normReq);
    return result;
}

GlyphCache createGlyphCache(id<MTLDevice> device, CGFloat scale) {
    CGFloat basePt = (g_font_size > 0) ? (CGFloat)g_font_size : 14.0;
    CGFloat fontSize = basePt * scale;

    CTFontRef font = NULL;

    if (g_font_family_len > 0) {
        CFStringRef reqName = CFStringCreateWithCString(NULL, g_font_family, kCFStringEncodingUTF8);
        font = createVerifiedFont(reqName, fontSize);
        if (!font) font = createFuzzyMatchFont(reqName, fontSize);
        if (!font) NSLog(@"[attyx] warning: font \"%s\" not found, trying fallbacks", g_font_family);
        CFRelease(reqName);
    }

    if (!font) {
        const char* fontEnv = getenv("ATTYX_FONT");
        if (fontEnv && fontEnv[0]) {
            CFStringRef reqName = CFStringCreateWithCString(NULL, fontEnv, kCFStringEncodingUTF8);
            font = createVerifiedFont(reqName, fontSize);
            if (!font) font = createFuzzyMatchFont(reqName, fontSize);
            CFRelease(reqName);
        }
    }

    if (!font) font = CTFontCreateWithName(CFSTR("Menlo-Regular"), fontSize, NULL);
    if (!font) font = CTFontCreateWithName(CFSTR("Monaco"), fontSize, NULL);
    if (!font) font = CTFontCreateWithName(CFSTR("Courier"), fontSize, NULL);

    CGFloat ascent  = CTFontGetAscent(font);
    CGFloat descent = CTFontGetDescent(font);
    CGFloat leading = CTFontGetLeading(font);

    UniChar ascii[95];
    CGGlyph glyphs[95];
    for (int i = 0; i < 95; i++) ascii[i] = (UniChar)(32 + i);
    CTFontGetGlyphsForCharacters(font, ascii, glyphs, 95);
    CGSize advances[95];
    CTFontGetAdvancesForGlyphs(font, kCTFontOrientationDefault, glyphs, advances, 95);
    float maxAdv = 0;
    for (int i = 0; i < 95; i++)
        if (advances[i].width > maxAdv) maxAdv = (float)advances[i].width;

    float naturalW = roundf(maxAdv);
    float naturalH = roundf((float)(ascent + descent + leading));
    float gw = naturalW;
    float gh = naturalH;

    // Capture fixed reference dimensions (in logical points) on first call.
    // Percent mode uses these so that cell size is independent of font size.
    if (s_ref_h_pt <= 0.0f) s_ref_h_pt = naturalH / (float)scale;
    if (s_ref_w_pt <= 0.0f) s_ref_w_pt = naturalW / (float)scale;

    if (g_cell_width > 0)
        gw = roundf((float)g_cell_width * (float)scale);
    else if (g_cell_width < 0)
        gw = roundf(s_ref_w_pt * (float)scale * (float)(-g_cell_width) / 100.0f);
    if (g_cell_height > 0)
        gh = roundf((float)g_cell_height * (float)scale);
    else if (g_cell_height < 0)
        gh = roundf(s_ref_h_pt * (float)scale * (float)(-g_cell_height) / 100.0f);

    float baseline_y = (float)descent + (gh - naturalH) / 2.0f;
    float x_offset = (gw - naturalW) / 2.0f;

    int cols = 32;
    int initRows = 32;
    int atlasW = (int)(gw * cols);
    int atlasH = (int)(gh * initRows);

    MTLTextureDescriptor* desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                           width:atlasW
                                                          height:atlasH
                                                       mipmapped:NO];
    id<MTLTexture> tex = [device newTextureWithDescriptor:desc];

    uint8_t* zeroes = (uint8_t*)calloc(atlasW * atlasH, 1);
    [tex replaceRegion:MTLRegionMake2D(0, 0, atlasW, atlasH)
           mipmapLevel:0
             withBytes:zeroes
           bytesPerRow:atlasW];
    free(zeroes);

    MTLTextureDescriptor* cd =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:atlasW height:atlasH
                                                       mipmapped:NO];
    id<MTLTexture> colorTex = [device newTextureWithDescriptor:cd];

    GlyphCache gc;
    memset((void*)&gc, 0, sizeof(gc));
    gc.texture       = tex;
    gc.color_texture = colorTex;
    gc.font       = (CTFontRef)CFRetain(font);
    gc.glyph_w    = gw;
    gc.glyph_h    = gh;
    gc.scale      = (float)scale;
    gc.descent    = descent;
    gc.baseline_y = baseline_y;
    gc.x_offset   = x_offset;
    gc.atlas_cols = cols;
    gc.atlas_w    = atlasW;
    gc.atlas_h    = atlasH;
    gc.next_slot  = 0;
    gc.max_slots  = cols * initRows;
    gc.device     = device;

    for (int i = 0; i < GLYPH_CACHE_CAP; i++) gc.map[i].slot = -1;

    for (uint32_t ch = 32; ch < 127; ch++) {
        glyphCacheRasterize(&gc, ch);
    }

    CFRelease(font);
    return gc;
}
