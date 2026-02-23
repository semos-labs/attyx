// Attyx — macOS glyph cache (Core Text rasterization)

#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>
#include <string.h>
#include <stdlib.h>
#include "macos_internal.h"

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
    if (gc->next_slot >= gc->max_slots) {
        glyphCacheGrow(gc);
    }

    int slot = gc->next_slot++;
    int ac = slot % gc->atlas_cols;
    int ar = slot / gc->atlas_cols;
    int gw = (int)gc->glyph_w;
    int gh = (int)gc->glyph_h;

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

    CTFontRef drawFont = gc->font;
    CGGlyph glyph;
    if (!CTFontGetGlyphsForCharacters(gc->font, utf16, &glyph, utf16Len)) {
        CGFloat fontSize = CTFontGetSize(gc->font);
        CTFontRef found = NULL;
        for (int fi = 0; fi < g_font_fallback_count; fi++) {
            CFStringRef name = CFStringCreateWithCString(NULL, g_font_fallback[fi],
                                                         kCFStringEncodingUTF8);
            CTFontRef candidate = CTFontCreateWithName(name, fontSize, NULL);
            CFRelease(name);
            if (candidate) {
                if (CTFontGetGlyphsForCharacters(candidate, utf16, &glyph, utf16Len)) {
                    found = candidate;
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
                } else {
                    CFRelease(fallback);
                    glyphCacheInsert(gc, cp, slot);
                    return slot;
                }
            } else {
                glyphCacheInsert(gc, cp, slot);
                return slot;
            }
        }
    }

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    uint8_t* pixels = (uint8_t*)calloc(gw * gh, 1);
    CGContextRef ctx = CGBitmapContextCreate(pixels, gw, gh, 8, gw, cs, kCGImageAlphaNone);
    CGColorSpaceRelease(cs);

    CGContextSetGrayFillColor(ctx, 1.0, 1.0);

    bool stretchToCell =
        (cp >= 0x2580 && cp <= 0x259F) ||  // Block Elements
        (cp >= 0xE0B0 && cp <= 0xE0D4);    // Powerline symbols

    if (stretchToCell) {
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
    } else {
        CGPoint pos = CGPointMake(gc->x_offset, gc->baseline_y);
        CTFontDrawGlyphs(drawFont, &glyph, &pos, 1, ctx);
    }

    CGContextRelease(ctx);

    if (drawFont != gc->font) CFRelease(drawFont);

    [gc->texture replaceRegion:MTLRegionMake2D(ac * gw, ar * gh, gw, gh)
                   mipmapLevel:0
                     withBytes:pixels
                   bytesPerRow:gw];
    free(pixels);

    glyphCacheInsert(gc, cp, slot);
    return slot;
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
            if (CFStringCompare(normReq, normFamily, 0) == kCFCompareEqualTo) {
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
