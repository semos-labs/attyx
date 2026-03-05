// Attyx — macOS font matching + glyph cache creation
// Extracted from macos_glyph.m to keep files under the 600-line limit.

#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>
#import <Metal/Metal.h>
#include "macos_internal.h"

// ---------------------------------------------------------------------------
// Font name verification and fuzzy matching
// ---------------------------------------------------------------------------

CTFontRef createVerifiedFont(CFStringRef reqName, CGFloat fontSize) {
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

CTFontRef createFuzzyMatchFont(CFStringRef reqName, CGFloat fontSize) {
    CFStringRef normReq = createNormalizedName(reqName);
    CTFontRef result = NULL;

    CFArrayRef families = CTFontManagerCopyAvailableFontFamilyNames();
    if (families) {
        CFIndex count = CFArrayGetCount(families);
        for (CFIndex i = 0; i < count; i++) {
            CFStringRef family = (CFStringRef)CFArrayGetValueAtIndex(families, i);
            CFStringRef normFamily = createNormalizedName(family);
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

// ---------------------------------------------------------------------------
// Glyph cache creation
// ---------------------------------------------------------------------------

// Fixed reference cell dimensions (in logical points) captured on the first
// createGlyphCache call. Percent-mode cell sizes are anchored to these values
// so that changing the font size does not affect the configured cell height/width.
static float s_ref_h_pt = 0.0f;
static float s_ref_w_pt = 0.0f;

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

    GlyphCache gc;
    memset((void*)&gc, 0, sizeof(gc));
    gc.texture       = tex;
    gc.color_texture = nil; // Lazy — created on first color glyph
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
