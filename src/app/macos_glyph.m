// Attyx — macOS glyph cache (Core Text rasterization)

#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>
#include <string.h>
#include <stdlib.h>
#include "macos_internal.h"

// Font matching helpers (defined in macos_font.m)
extern CTFontRef createVerifiedFont(CFStringRef reqName, CGFloat fontSize);
extern CTFontRef createFuzzyMatchFont(CFStringRef reqName, CGFloat fontSize);

// createGlyphCache() and reference cell statics are in macos_font.m.

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
    // SMP emoji below the main ranges
    if (cp == 0x1F004) return true;                          // 🀄 Mahjong Red Dragon
    if (cp == 0x1F0CF) return true;                          // 🃏 Joker
    if (cp == 0x1F18E) return true;                          // 🆎 AB button
    if (cp >= 0x1F191 && cp <= 0x1F19A) return true;        // 🆑-🆚 squared symbols
    if (cp == 0x1F201 || cp == 0x1F202) return true;        // 🈁🈂
    if (cp == 0x1F21A) return true;                          // 🈚
    if (cp == 0x1F22F) return true;                          // 🈯
    if (cp >= 0x1F232 && cp <= 0x1F23A) return true;        // 🈲-🈺
    if (cp >= 0x1F250 && cp <= 0x1F251) return true;        // 🉐🉑
    // Common emoji with Emoji_Presentation that are unambiguously 2-cell:
    if (cp == 0x231A || cp == 0x231B) return true;
    if (cp >= 0x23E9 && cp <= 0x23F3) return true;
    if (cp >= 0x23F8 && cp <= 0x23FA) return true;           // ⏸⏹⏺
    if (cp >= 0x25FB && cp <= 0x25FE) return true;
    if (cp == 0x2614 || cp == 0x2615) return true;
    if (cp >= 0x2648 && cp <= 0x2653) return true;
    if (cp == 0x267F || cp == 0x2693 || cp == 0x26A1) return true;
    if (cp >= 0x26AA && cp <= 0x26AB) return true;           // ⚪⚫
    if (cp >= 0x26BD && cp <= 0x26BE) return true;           // ⚽⚾
    if (cp >= 0x26C4 && cp <= 0x26C5) return true;           // ⛄⛅
    if (cp == 0x26CE || cp == 0x26D4 || cp == 0x26EA) return true;
    if (cp == 0x26F2 || cp == 0x26F3 || cp == 0x26F5) return true;
    if (cp == 0x26FA || cp == 0x26FD) return true;
    if (cp == 0x2702 || cp == 0x2705) return true;
    if (cp >= 0x2708 && cp <= 0x270D) return true;           // ✈-✍
    if (cp == 0x270F || cp == 0x2712 || cp == 0x2714 || cp == 0x2716) return true;
    if (cp == 0x271D || cp == 0x2721 || cp == 0x2728) return true;
    if (cp == 0x2733 || cp == 0x2734 || cp == 0x2744 || cp == 0x2747) return true;
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

void glyphCacheInsert(GlyphCache* gc, uint32_t cp, int slot) {
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

void glyphCacheGrow(GlyphCache* gc) {
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

    // Grow color atlas only if it has been created (lazy allocation).
    if (gc->color_texture) {
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
    }

    gc->atlas_h = newH;
    gc->max_slots = newMaxSlots;
}

/// Returns true if the codepoint belongs to a Unicode range commonly occupied
/// by emoji.  Used to prefer Apple Color Emoji over monochrome fallbacks.
static bool isEmojiRange(uint32_t cp) {
    if (cp >= 0x1F000 && cp <= 0x1FAFF) return true;
    if (cp >= 0x2600 && cp <= 0x27BF)   return true;  // Misc Symbols, Dingbats
    if (cp >= 0x2300 && cp <= 0x23FF)   return true;  // Misc Technical
    if (cp >= 0x2B00 && cp <= 0x2BFF)   return true;  // Misc Symbols & Arrows
    if (cp >= 0x2900 && cp <= 0x297F)   return true;  // Supplemental Arrows-B
    return false;
}

int glyphCacheRasterize(GlyphCache* gc, uint32_t cp) {
    int gw = (int)gc->glyph_w;
    int gh = (int)gc->glyph_h;

    // Extract style bits and base codepoint from the key.
    int styleBold   = (cp & GLYPH_BOLD_BIT)   ? 1 : 0;
    int styleItalic = (cp & GLYPH_ITALIC_BIT)  ? 1 : 0;
    uint32_t baseCp = cp & 0x1FFFFF;

    // 1. UTF-16 encoding
    UniChar utf16[2];
    int utf16Len;
    if (baseCp <= 0xFFFF) {
        utf16[0] = (UniChar)baseCp;
        utf16Len = 1;
    } else {
        uint32_t u = baseCp - 0x10000;
        utf16[0] = (UniChar)(0xD800 + (u >> 10));
        utf16[1] = (UniChar)(0xDC00 + (u & 0x3FF));
        utf16Len = 2;
    }

    // 2. Select styled font, then glyph lookup: styled font → primary → fallbacks
    //    For emoji codepoints, prefer Apple Color Emoji over monochrome fonts.
    CTFontRef styledFont = gc->font;
    if (styleBold && styleItalic)      styledFont = gc->font_bold_italic;
    else if (styleBold)                styledFont = gc->font_bold;
    else if (styleItalic)              styledFont = gc->font_italic;
    CTFontRef drawFont = styledFont;
    CGGlyph glyph = 0;
    bool haveGlyph = CTFontGetGlyphsForCharacters(styledFont, utf16, &glyph, utf16Len)
                  && glyph != 0;

    // For emoji codepoints: if the primary font has a glyph, check whether it's
    // actually Apple Color Emoji.  If not, try Apple Color Emoji explicitly so
    // that emoji always render in full colour rather than monochrome outlines.
    if (haveGlyph && isEmojiRange(baseCp)) {
        CFStringRef familyName = CTFontCopyFamilyName(drawFont);
        bool isColor = (CFStringCompare(familyName, CFSTR("Apple Color Emoji"), 0)
                        == kCFCompareEqualTo);
        CFRelease(familyName);
        if (!isColor) {
            CGFloat fontSize = CTFontGetSize(gc->font);
            CTFontRef colorFont = CTFontCreateWithName(CFSTR("Apple Color Emoji"),
                                                        fontSize, NULL);
            if (colorFont) {
                CGGlyph colorGlyph = 0;
                if (CTFontGetGlyphsForCharacters(colorFont, utf16, &colorGlyph, utf16Len)
                    && colorGlyph != 0) {
                    drawFont = colorFont;
                    glyph = colorGlyph;
                } else {
                    CFRelease(colorFont);
                }
            }
        }
    }

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
    bool isPowerline = (baseCp >= 0xE0B0 && baseCp <= 0xE0D4);
    bool isBoxDraw   = (baseCp >= 0x2500 && baseCp <= 0x257F);
    bool isBlock     = (baseCp >= 0x2580 && baseCp <= 0x259F);
    bool wide = false;
    if (haveGlyph && !isPowerline && !isBlock && canBeWide(baseCp)) {
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
        if (drawFont != gc->font && drawFont != gc->font_bold
                && drawFont != gc->font_italic && drawFont != gc->font_bold_italic)
                CFRelease(drawFont);
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
            // Lazy-create color atlas on first color glyph.
            if (!gc->color_texture) {
                MTLTextureDescriptor* cd = [MTLTextureDescriptor
                    texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                 width:gc->atlas_w height:gc->atlas_h
                                             mipmapped:NO];
                gc->color_texture = [gc->device newTextureWithDescriptor:cd];
            }

            CGColorSpaceRef rgbCS = CGColorSpaceCreateDeviceRGB();
            uint8_t* pixels = (uint8_t*)calloc(renderW * gh * 4, 1);
            CGContextRef ctx = CGBitmapContextCreate(pixels, renderW, gh, 8, renderW * 4,
                rgbCS, kCGBitmapByteOrder32Host | kCGImageAlphaPremultipliedFirst);
            CGColorSpaceRelease(rgbCS);

            // Use CTFontDrawGlyphs (not CTLineDraw) — more reliable for color
            // emoji rendering; CTLineDraw can produce blank output in some contexts.
            CGPoint pos = CGPointMake(wide ? 0.0 : (CGFloat)gc->x_offset,
                                     (CGFloat)gc->baseline_y);
            CTFontDrawGlyphs(drawFont, &glyph, &pos, 1, ctx);
            CGContextRelease(ctx);

            [gc->color_texture
                replaceRegion:MTLRegionMake2D(ac * gw, ar * gh, renderW, gh)
                  mipmapLevel:0 withBytes:pixels bytesPerRow:(NSUInteger)(renderW * 4)];
            free(pixels);

            if (drawFont != gc->font && drawFont != gc->font_bold
                && drawFont != gc->font_italic && drawFont != gc->font_bold_italic)
                CFRelease(drawFont);
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
        if (!renderBoxDraw(ctx, baseCp, gw, gh, gc->scale)) {
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
        if (baseCp >= 0x2581 && baseCp <= 0x2588) {
            // LOWER ONE-EIGHTH .. FULL BLOCK (U+2581–U+2588)
            int eighths = (int)(baseCp - 0x2580); // 1..8
            float blockH = roundf((float)gh * eighths / 8.0f);
            CGContextFillRect(ctx, CGRectMake(0, 0, (float)gw, blockH));
            drawn = true;
        } else if (baseCp == 0x2580) {
            // UPPER HALF BLOCK
            float halfH = roundf((float)gh / 2.0f);
            CGContextFillRect(ctx, CGRectMake(0, (float)gh - halfH, (float)gw, halfH));
            drawn = true;
        } else if (baseCp >= 0x2589 && baseCp <= 0x258F) {
            // LEFT SEVEN-EIGHTHS .. LEFT ONE-EIGHTH BLOCK (U+2589–U+258F)
            int eighths = (int)(0x2590 - baseCp); // 7..1
            float blockW = roundf((float)gw * eighths / 8.0f);
            CGContextFillRect(ctx, CGRectMake(0, 0, blockW, (float)gh));
            drawn = true;
        } else if (baseCp == 0x2590) {
            // RIGHT HALF BLOCK
            float halfW = roundf((float)gw / 2.0f);
            CGContextFillRect(ctx, CGRectMake((float)gw - halfW, 0, halfW, (float)gh));
            drawn = true;
        } else if (baseCp == 0x2594) {
            // UPPER ONE EIGHTH BLOCK
            float blockH = roundf((float)gh / 8.0f);
            CGContextFillRect(ctx, CGRectMake(0, (float)gh - blockH, (float)gw, blockH));
            drawn = true;
        } else if (baseCp == 0x2595) {
            // RIGHT ONE EIGHTH BLOCK
            float blockW = roundf((float)gw / 8.0f);
            CGContextFillRect(ctx, CGRectMake((float)gw - blockW, 0, blockW, (float)gh));
            drawn = true;
        } else if (baseCp >= 0x2591 && baseCp <= 0x2593) {
            // SHADE CHARACTERS — render as solid fills at fractional brightness.
            // ░ = 25%, ▒ = 50%, ▓ = 75%
            static const float shadeAlpha[] = {0.25f, 0.50f, 0.75f};
            float a = shadeAlpha[baseCp - 0x2591];
            CGContextSetGrayFillColor(ctx, 1.0f, a);
            CGContextFillRect(ctx, CGRectMake(0, 0, (float)gw, (float)gh));
            CGContextSetGrayFillColor(ctx, 1.0f, 1.0f); // restore
            drawn = true;
        } else if (baseCp >= 0x2596 && baseCp <= 0x259F) {
            // QUADRANT BLOCKS — bits: UL=1, UR=2, BL=4, BR=8
            static const int quadBits[] = {4, 8, 1, 13, 9, 7, 11, 2, 6, 14};
            int bits = quadBits[baseCp - 0x2596];
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
    if (drawFont != gc->font && drawFont != gc->font_bold
                && drawFont != gc->font_italic && drawFont != gc->font_bold_italic)
                CFRelease(drawFont);

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

// ---------------------------------------------------------------------------
// Combining mark support
// ---------------------------------------------------------------------------

uint32_t combiningKey(uint32_t base, uint32_t c1, uint32_t c2) {
    uint32_t h = base ^ (c1 * 0x9e3779b9) ^ (c2 * 0x517cc1b7);
    return (h & 0x7FFFFFFF) | 0x80000000; // high bit distinguishes from plain codepoints
}

/// Encode a codepoint as UTF-16 into buf. Returns number of UniChar units written.
static int cpToUtf16(uint32_t cp, UniChar buf[2]) {
    if (cp <= 0xFFFF) { buf[0] = (UniChar)cp; return 1; }
    uint32_t u = cp - 0x10000;
    buf[0] = (UniChar)(0xD800 + (u >> 10));
    buf[1] = (UniChar)(0xDC00 + (u & 0x3FF));
    return 2;
}

int glyphCacheRasterizeCombined(GlyphCache* gc, uint32_t base, uint32_t c1, uint32_t c2) {
    int gw = (int)gc->glyph_w;
    int gh = (int)gc->glyph_h;

    // 1. Font fallback for the base character (same chain as regular rasterizer)
    UniChar baseUtf16[2];
    int baseLen = cpToUtf16(base, baseUtf16);

    CTFontRef drawFont = gc->font;
    bool ownFont = false;
    CGGlyph baseGlyph = 0;
    bool haveGlyph = CTFontGetGlyphsForCharacters(gc->font, baseUtf16, &baseGlyph, baseLen)
                  && baseGlyph != 0;
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
                if (CTFontGetGlyphsForCharacters(candidate, baseUtf16, &baseGlyph, baseLen)) {
                    found = candidate;
                    haveGlyph = true;
                    break;
                }
                CFRelease(candidate);
            }
        }
        if (found) {
            drawFont = found;
            ownFont = true;
        } else {
            // System fallback via full string
            UniChar fullUtf16[6];
            int fullLen = 0;
            uint32_t cps[3] = { base, c1, c2 };
            for (int i = 0; i < 3; i++) {
                if (cps[i] == 0) continue;
                fullLen += cpToUtf16(cps[i], &fullUtf16[fullLen]);
            }
            NSString* fullStr = [[NSString alloc] initWithCharacters:fullUtf16 length:fullLen];
            CTFontRef fallback = CTFontCreateForString(gc->font, (__bridge CFStringRef)fullStr,
                                                        CFRangeMake(0, fullStr.length));
            if (fallback) {
                if (CTFontGetGlyphsForCharacters(fallback, baseUtf16, &baseGlyph, baseLen))
                    haveGlyph = true;
                drawFont = fallback;
                ownFont = true;
            }
        }
    }

    // 2. Allocate atlas slot (Thai is never wide)
    if (gc->next_slot >= gc->max_slots) glyphCacheGrow(gc);
    int slot = gc->next_slot++;
    int ac = slot % gc->atlas_cols;
    int ar = slot / gc->atlas_cols;

    if (!haveGlyph) {
        // No glyph found — store blank slot
        if (ownFont) CFRelease(drawFont);
        uint32_t key = combiningKey(base, c1, c2);
        glyphCacheInsert(gc, key, slot);
        return slot;
    }

    // 3. Create bitmap context (same setup as regular rasterizer)
    uint8_t* pixels = (uint8_t*)calloc(gw * gh, 1);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(pixels, gw, gh, 8, gw, cs, kCGImageAlphaNone);
    CGColorSpaceRelease(cs);
    CGContextSetGrayFillColor(ctx, 1.0, 1.0);
    CGContextSetShouldSmoothFonts(ctx, NO);
    CGContextSetAllowsFontSmoothing(ctx, NO);

    // 4. Draw base glyph at cell origin — identical to regular rasterizer path.
    //    This is proven to work for Thai characters.
    CGPoint pos = CGPointMake(gc->x_offset, gc->baseline_y);
    CTFontDrawGlyphs(drawFont, &baseGlyph, &pos, 1, ctx);

    // 5. Overlay combining marks at the same position.
    //    The font's glyph metrics handle vertical placement (above/below base).
    uint32_t marks[2] = { c1, c2 };
    for (int m = 0; m < 2; m++) {
        if (marks[m] == 0) continue;
        UniChar markUtf16[2];
        int markLen = cpToUtf16(marks[m], markUtf16);
        CGGlyph markGlyph = 0;
        if (CTFontGetGlyphsForCharacters(drawFont, markUtf16, &markGlyph, markLen)
            && markGlyph != 0) {
            CTFontDrawGlyphs(drawFont, &markGlyph, &pos, 1, ctx);
        }
    }

    CGContextRelease(ctx);
    if (ownFont) CFRelease(drawFont);

    // 6. Upload to atlas
    [gc->texture replaceRegion:MTLRegionMake2D(ac * gw, ar * gh, gw, gh)
                   mipmapLevel:0
                     withBytes:pixels
                   bytesPerRow:gw];
    free(pixels);

    uint32_t key = combiningKey(base, c1, c2);
    glyphCacheInsert(gc, key, slot);
    return slot;
}

// createGlyphCache() is defined in macos_font.m
