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

    // 3. Classify: detect wide glyphs (advance or ink > 1.3× cell width).
    //    Wide glyphs get a 2-cell atlas slot and a 2×gw wide renderer quad,
    //    matching the approach used by Ghostty/WezTerm — the icon renders at
    //    full size and bleeds into the next cell (which overdraw it if non-empty).
    bool isPowerline = (cp >= 0xE0B0 && cp <= 0xE0D4)
                    || (cp >= 0x2500 && cp <= 0x257F);
    bool isBlock     = (cp >= 0x2580 && cp <= 0x259F);
    bool wide = false;
    if (haveGlyph && !isPowerline && !isBlock) {
        CGRect bbox;
        CTFontGetBoundingRectsForGlyphs(drawFont, kCTFontOrientationDefault, &glyph, &bbox, 1);
        CGSize adv;
        CTFontGetAdvancesForGlyphs(drawFont, kCTFontOrientationDefault, &glyph, &adv, 1);
        float inkRight = (float)(bbox.origin.x + bbox.size.width);
        float srcW = fmaxf((float)adv.width, inkRight);
        wide = (srcW > (float)gw * 1.3f);
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

    // 5. If no glyph was found, store a blank slot (all-zero pixels) and return
    if (!haveGlyph) {
        if (drawFont != gc->font) CFRelease(drawFont);
        glyphCacheInsert(gc, cp, slot);
        return slot;
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
    if (isPowerline) {
        // Box-drawing (U+2500–U+257F) and powerline (U+E0B0–U+E0D4): scale to full
        // cell using advance × (asc+desc) as the source rect.  Vertical connectors (│)
        // then reach top/bottom regardless of cell_height percentage.
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
    } else if (wide) {
        // Wide icon: draw at natural origin in the 2×gw context — no scaling needed.
        // The glyph's advance fills the wider slot; the renderer quad spans 2 cells.
        CGPoint pos = CGPointMake(0.0f, gc->baseline_y);
        CTFontDrawGlyphs(drawFont, &glyph, &pos, 1, ctx);
    } else {
        // Normal glyph: fits within one cell.
        CGPoint pos = CGPointMake(gc->x_offset, gc->baseline_y);
        CTFontDrawGlyphs(drawFont, &glyph, &pos, 1, ctx);
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

    if (g_cell_width > 0)
        gw = roundf((float)g_cell_width * (float)scale);
    else if (g_cell_width < 0)
        gw = roundf(gw * (float)(-g_cell_width) / 100.0f);
    if (g_cell_height > 0)
        gh = roundf((float)g_cell_height * (float)scale);
    else if (g_cell_height < 0)
        gh = roundf(gh * (float)(-g_cell_height) / 100.0f);

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

    GlyphCache gc;
    memset((void*)&gc, 0, sizeof(gc));
    gc.texture    = tex;
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
