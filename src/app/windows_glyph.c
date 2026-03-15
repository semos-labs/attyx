// Attyx — Windows glyph rasterization (DirectWrite + Direct2D)
// Rasterizes individual glyphs into a D3D11 atlas texture via a WIC bitmap
// render target. Handles styled variants (bold/italic), wide CJK/emoji,
// block elements, Powerline glyphs, and combining marks.

#ifdef _WIN32

#include "windows_internal.h"

// ---------------------------------------------------------------------------
// canBeWide — East Asian Width W/F detection (same as macOS/Linux)
// ---------------------------------------------------------------------------

static bool canBeWide(uint32_t cp) {
    if (cp < 0x1100) return false;
    if (cp <= 0x115F) return true;
    if (cp == 0x2329 || cp == 0x232A) return true;
    if (cp >= 0x2E80 && cp <= 0x303E) return true;
    if (cp >= 0x3041 && cp <= 0x33FF) return true;
    if (cp >= 0x3400 && cp <= 0x4DBF) return true;
    if (cp >= 0x4E00 && cp <= 0x9FFF) return true;
    if (cp >= 0xA000 && cp <= 0xA4CF) return true;
    if (cp >= 0xA960 && cp <= 0xA97F) return true;
    if (cp >= 0xAC00 && cp <= 0xD7AF) return true;
    if (cp >= 0xE000 && cp <= 0xF8FF) return true;
    if (cp >= 0xF900 && cp <= 0xFAFF) return true;
    if (cp >= 0xFE10 && cp <= 0xFE6F) return true;
    if (cp >= 0xFF01 && cp <= 0xFF60) return true;
    if (cp >= 0xFFE0 && cp <= 0xFFE6) return true;
    if (cp >= 0x1B000 && cp <= 0x1B2FF) return true;
    if (cp >= 0x1F300 && cp <= 0x1F64F) return true;
    if (cp >= 0x1F680 && cp <= 0x1F6FF) return true;
    if (cp >= 0x1F7E0 && cp <= 0x1F7FF) return true;
    if (cp >= 0x1F900 && cp <= 0x1FAFF) return true;
    if (cp >= 0x20000 && cp <= 0x2FFFD) return true;
    if (cp >= 0x30000 && cp <= 0x3FFFD) return true;
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
    if (cp >= 0x2708 && cp <= 0x270D) return true;
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

// ---------------------------------------------------------------------------
// Codepoint to UTF-16
// ---------------------------------------------------------------------------

static int cp_to_utf16(uint32_t cp, wchar_t buf[2]) {
    if (cp <= 0xFFFF) { buf[0] = (wchar_t)cp; return 1; }
    uint32_t u = cp - 0x10000;
    buf[0] = (wchar_t)(0xD800 + (u >> 10));
    buf[1] = (wchar_t)(0xDC00 + (u & 0x3FF));
    return 2;
}

// ---------------------------------------------------------------------------
// Hash-map helpers (same algorithm as macOS/Linux)
// ---------------------------------------------------------------------------

int glyphCacheLookup(GlyphCache* gc, uint32_t cp) {
    uint32_t idx = (cp * 2654435761u) % GLYPH_CACHE_CAP;
    for (int probe = 0; probe < GLYPH_CACHE_CAP; probe++) {
        uint32_t i = (idx + probe) % GLYPH_CACHE_CAP;
        if (gc->map[i].slot < 0) return -1;
        if (gc->map[i].codepoint == cp) return gc->map[i].slot;
    }
    return -1;
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

// ---------------------------------------------------------------------------
// Atlas grow (double height, copy old data)
// ---------------------------------------------------------------------------

void glyphCacheGrow(GlyphCache* gc) {
    int newRows = (gc->max_slots / gc->atlas_cols) * 2;
    int newH = (int)(gc->glyph_h * newRows);
    int newMaxSlots = gc->atlas_cols * newRows;

    // Create new grayscale atlas
    D3D11_TEXTURE2D_DESC desc = {
        .Width = (UINT)gc->atlas_w, .Height = (UINT)newH,
        .MipLevels = 1, .ArraySize = 1,
        .Format = DXGI_FORMAT_R8_UNORM,
        .SampleDesc = { .Count = 1, .Quality = 0 },
        .Usage = D3D11_USAGE_DEFAULT,
        .BindFlags = D3D11_BIND_SHADER_RESOURCE,
    };
    ID3D11Texture2D* newTex = NULL;
    ID3D11Device_CreateTexture2D(gc->d3d_device, &desc, NULL, &newTex);
    if (!newTex) return;

    // Copy old content
    ID3D11DeviceContext* ctx = NULL;
    ID3D11Device_GetImmediateContext(gc->d3d_device, &ctx);
    D3D11_BOX srcBox = { 0, 0, 0, (UINT)gc->atlas_w, (UINT)gc->atlas_h, 1 };
    ID3D11DeviceContext_CopySubresourceRegion(ctx, (ID3D11Resource*)newTex, 0,
                                               0, 0, 0,
                                               (ID3D11Resource*)gc->texture, 0, &srcBox);

    // Replace old texture
    if (gc->texture_srv) ID3D11ShaderResourceView_Release(gc->texture_srv);
    ID3D11Texture2D_Release(gc->texture);
    gc->texture = newTex;
    ID3D11Device_CreateShaderResourceView(gc->d3d_device, (ID3D11Resource*)newTex,
                                           NULL, &gc->texture_srv);

    // Grow color atlas if it exists
    if (gc->color_texture) {
        D3D11_TEXTURE2D_DESC cdesc = desc;
        cdesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        ID3D11Texture2D* newColor = NULL;
        ID3D11Device_CreateTexture2D(gc->d3d_device, &cdesc, NULL, &newColor);
        if (newColor) {
            ID3D11DeviceContext_CopySubresourceRegion(ctx, (ID3D11Resource*)newColor, 0,
                                                       0, 0, 0,
                                                       (ID3D11Resource*)gc->color_texture, 0,
                                                       &srcBox);
            if (gc->color_srv) ID3D11ShaderResourceView_Release(gc->color_srv);
            ID3D11Texture2D_Release(gc->color_texture);
            gc->color_texture = newColor;
            ID3D11Device_CreateShaderResourceView(gc->d3d_device, (ID3D11Resource*)newColor,
                                                   NULL, &gc->color_srv);
        }
    }

    ID3D11DeviceContext_Release(ctx);
    gc->atlas_h = newH;
    gc->max_slots = newMaxSlots;
}

// ---------------------------------------------------------------------------
// Render a glyph string into the WIC bitmap, extract grayscale pixels
// ---------------------------------------------------------------------------

static void render_glyph_to_pixels(GlyphCache* gc, const wchar_t* str, int strLen,
                                    IDWriteTextFormat* fmt, int renderW, int gh,
                                    float posX, uint8_t* pixels) {
    // Resize WIC bitmap if needed
    UINT bmpW = 0, bmpH = 0;
    IWICBitmap_GetSize(gc->wic_bitmap, &bmpW, &bmpH);
    if ((int)bmpW < renderW || (int)bmpH < gh) {
        // Recreate bitmap and render target at larger size
        int newW = renderW > (int)bmpW ? renderW : (int)bmpW;
        int newH = gh > (int)bmpH ? gh : (int)bmpH;
        ID2D1SolidColorBrush_Release(gc->d2d_brush);
        ID2D1RenderTarget_Release(gc->d2d_rt);
        IWICBitmap_Release(gc->wic_bitmap);
        IWICImagingFactory_CreateBitmap(gc->wic_factory, (UINT)newW, (UINT)newH,
                                         &GUID_WICPixelFormat32bppPBGRA,
                                         WICBitmapCacheOnLoad, &gc->wic_bitmap);
        D2D1_RENDER_TARGET_PROPERTIES rtProps = {
            .type = D2D1_RENDER_TARGET_TYPE_SOFTWARE,
            .pixelFormat = { DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED },
            .dpiX = 96.0f, .dpiY = 96.0f,
        };
        ID2D1Factory_CreateWicBitmapRenderTarget(gc->d2d_factory, gc->wic_bitmap,
                                                  &rtProps, &gc->d2d_rt);
        D2D1_COLOR_F white = { 1,1,1,1 };
        ID2D1RenderTarget_CreateSolidColorBrush(gc->d2d_rt, &white, NULL, &gc->d2d_brush);
    }

    // Clear and draw
    ID2D1RenderTarget_BeginDraw(gc->d2d_rt);
    D2D1_COLOR_F black = { 0, 0, 0, 0 };
    ID2D1RenderTarget_Clear(gc->d2d_rt, &black);
    D2D1_RECT_F layoutRect = { posX, gc->baseline_y_offset, (float)renderW, (float)gh };
    ID2D1RenderTarget_DrawText(gc->d2d_rt, str, (UINT32)strLen, fmt,
                                &layoutRect, (ID2D1Brush*)gc->d2d_brush,
                                D2D1_DRAW_TEXT_OPTIONS_NONE,
                                DWRITE_MEASURING_MODE_NATURAL);
    ID2D1RenderTarget_EndDraw(gc->d2d_rt, NULL, NULL);

    // Lock WIC bitmap and extract grayscale
    WICRect lockRect = { 0, 0, renderW, gh };
    IWICBitmapLock* lock = NULL;
    IWICBitmap_Lock(gc->wic_bitmap, &lockRect, WICBitmapLockRead, &lock);
    if (lock) {
        UINT bufSize = 0;
        BYTE* data = NULL;
        UINT stride = 0;
        IWICBitmapLock_GetStride(lock, &stride);
        IWICBitmapLock_GetDataPointer(lock, &bufSize, &data);
        // Convert BGRA premultiplied to grayscale (use alpha channel as coverage)
        for (int y = 0; y < gh; y++) {
            for (int x = 0; x < renderW; x++) {
                int si = y * (int)stride + x * 4;
                pixels[y * renderW + x] = data[si + 3]; // alpha = coverage
            }
        }
        IWICBitmapLock_Release(lock);
    }
}

// ---------------------------------------------------------------------------
// Upload pixels to atlas
// ---------------------------------------------------------------------------

static void upload_to_atlas(GlyphCache* gc, int ac, int ar, int renderW, int gh,
                             const uint8_t* pixels) {
    int gw = (int)gc->glyph_w;
    ID3D11DeviceContext* ctx = NULL;
    ID3D11Device_GetImmediateContext(gc->d3d_device, &ctx);
    D3D11_BOX box = {
        .left = (UINT)(ac * gw), .top = (UINT)(ar * gh), .front = 0,
        .right = (UINT)(ac * gw + renderW), .bottom = (UINT)(ar * gh + gh), .back = 1
    };
    ID3D11DeviceContext_UpdateSubresource(ctx, (ID3D11Resource*)gc->texture,
                                           0, &box, pixels, (UINT)renderW, 0);
    ID3D11DeviceContext_Release(ctx);
}

// ---------------------------------------------------------------------------
// Rasterize a single codepoint (or styled variant) into the atlas
// ---------------------------------------------------------------------------

int glyphCacheRasterize(GlyphCache* gc, uint32_t cp) {
    int gw = (int)gc->glyph_w;
    int gh = (int)gc->glyph_h;

    int styleBold   = (cp & GLYPH_BOLD_BIT)   ? 1 : 0;
    int styleItalic = (cp & GLYPH_ITALIC_BIT)  ? 1 : 0;
    uint32_t baseCp = cp & 0x1FFFFF;

    // Select styled format
    IDWriteTextFormat* fmt = gc->dw_format;
    if (styleBold && styleItalic && gc->dw_format_bold_italic)
        fmt = gc->dw_format_bold_italic;
    else if (styleBold && gc->dw_format_bold)
        fmt = gc->dw_format_bold;
    else if (styleItalic && gc->dw_format_italic)
        fmt = gc->dw_format_italic;

    // UTF-16 encode
    wchar_t utf16[2];
    int utf16Len = cp_to_utf16(baseCp, utf16);

    // Check if glyph exists
    IDWriteFontFace* face = gc->dw_face;
    if (styleBold && styleItalic && gc->dw_face_bold_italic)
        face = gc->dw_face_bold_italic;
    else if (styleBold && gc->dw_face_bold)
        face = gc->dw_face_bold;
    else if (styleItalic && gc->dw_face_italic)
        face = gc->dw_face_italic;

    uint32_t codepoints32[1] = { baseCp };
    UINT16 glyphIndex = 0;
    HRESULT hr = IDWriteFontFace_GetGlyphIndices(face, codepoints32, 1, &glyphIndex);
    bool haveGlyph = SUCCEEDED(hr) && glyphIndex != 0;

    // Fall back to regular face if styled face doesn't have the glyph
    if (!haveGlyph && face != gc->dw_face) {
        face = gc->dw_face;
        fmt = gc->dw_format;
        hr = IDWriteFontFace_GetGlyphIndices(face, codepoints32, 1, &glyphIndex);
        haveGlyph = SUCCEEDED(hr) && glyphIndex != 0;
    }

    // Classify special ranges
    bool isPowerline = (baseCp >= 0xE0B0 && baseCp <= 0xE0D4);
    bool isBoxDraw   = (baseCp >= 0x2500 && baseCp <= 0x257F);
    bool isBlock     = (baseCp >= 0x2580 && baseCp <= 0x259F);

    // Wide detection
    bool wide = false;
    if (haveGlyph && !isPowerline && !isBlock && canBeWide(baseCp)) {
        DWRITE_GLYPH_METRICS gm;
        IDWriteFontFace_GetDesignGlyphMetrics(face, &glyphIndex, 1, &gm, FALSE);
        DWRITE_FONT_METRICS fm;
        IDWriteFontFace_GetMetrics(face, &fm);
        float advPx = (float)gm.advanceWidth / (float)fm.designUnitsPerEm * (float)gc->font_size;
        wide = (advPx > (float)gw * 1.05f);
    }
    int renderW = wide ? 2 * gw : gw;

    // Allocate atlas slot(s)
    int slot;
    if (wide) {
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

    // Try user-configured fallback fonts if primary doesn't have the glyph
    IDWriteFontFace* fallbackFace = NULL;
    IDWriteTextFormat* fallbackFmt = NULL;
    if (!haveGlyph && !isBlock && !isBoxDraw) {
        for (int fi = 0; fi < g_font_fallback_count; fi++) {
            wchar_t fbWide[ATTYX_FONT_FAMILY_MAX];
            int fbLen = MultiByteToWideChar(CP_UTF8, 0, g_font_fallback[fi],
                (int)strlen(g_font_fallback[fi]), fbWide, ATTYX_FONT_FAMILY_MAX - 1);
            fbWide[fbLen] = 0;
            IDWriteFontFace* candidate = find_font_face(gc->dw_factory, fbWide,
                styleBold ? DWRITE_FONT_WEIGHT_BOLD : DWRITE_FONT_WEIGHT_REGULAR,
                styleItalic ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL);
            if (!candidate) continue;
            UINT16 fbIdx = 0;
            hr = IDWriteFontFace_GetGlyphIndices(candidate, codepoints32, 1, &fbIdx);
            if (SUCCEEDED(hr) && fbIdx != 0) {
                fallbackFace = candidate;
                fallbackFmt = create_format(gc->dw_factory, fbWide,
                    (float)gc->font_size,
                    styleBold ? DWRITE_FONT_WEIGHT_BOLD : DWRITE_FONT_WEIGHT_REGULAR,
                    styleItalic ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL);
                haveGlyph = true;
                face = candidate;
                if (fallbackFmt) fmt = fallbackFmt;
                break;
            }
            IDWriteFontFace_Release(candidate);
        }
    }

    // No glyph and not a geometry-drawn char: blank slot
    if (!haveGlyph && !isBlock && !isBoxDraw) {
        glyphCacheInsert(gc, cp, slot);
        if (fallbackFmt) IDWriteTextFormat_Release(fallbackFmt);
        return slot;
    }

    // Rasterize into pixel buffer
    uint8_t* pixels = (uint8_t*)calloc(renderW * gh, 1);

    if (isBoxDraw) {
        if (!renderBoxDraw(pixels, renderW, baseCp, gw, gh, gc->scale)) {
            // Fall back to DirectWrite glyph
            if (haveGlyph) {
                float posX = gc->x_offset;
                render_glyph_to_pixels(gc, utf16, utf16Len, fmt, renderW, gh, posX, pixels);
            }
        }
    } else if (isBlock) {
        // Block elements: pure geometry (pixel buffer is top-to-bottom)
        if (baseCp >= 0x2581 && baseCp <= 0x2588) {
            int eighths = (int)(baseCp - 0x2580);
            int blockH = (int)roundf((float)gh * eighths / 8.0f);
            int y0 = gh - blockH;
            for (int dy = y0; dy < gh; dy++)
                for (int dx = 0; dx < gw; dx++)
                    pixels[dy * gw + dx] = 255;
        } else if (baseCp == 0x2580) {
            int blockH = (int)roundf((float)gh / 2.0f);
            for (int dy = 0; dy < blockH; dy++)
                for (int dx = 0; dx < gw; dx++)
                    pixels[dy * gw + dx] = 255;
        } else if (baseCp >= 0x2589 && baseCp <= 0x258F) {
            int eighths = (int)(0x2590 - baseCp);
            int blockW = (int)roundf((float)gw * eighths / 8.0f);
            for (int dy = 0; dy < gh; dy++)
                for (int dx = 0; dx < blockW; dx++)
                    pixels[dy * gw + dx] = 255;
        } else if (baseCp == 0x2590) {
            int blockW = (int)roundf((float)gw / 2.0f);
            int x0 = gw - blockW;
            for (int dy = 0; dy < gh; dy++)
                for (int dx = x0; dx < gw; dx++)
                    pixels[dy * gw + dx] = 255;
        } else if (baseCp == 0x2594) {
            int blockH = (int)roundf((float)gh / 8.0f);
            for (int dy = 0; dy < blockH; dy++)
                for (int dx = 0; dx < gw; dx++)
                    pixels[dy * gw + dx] = 255;
        } else if (baseCp == 0x2595) {
            int blockW = (int)roundf((float)gw / 8.0f);
            int x0 = gw - blockW;
            for (int dy = 0; dy < gh; dy++)
                for (int dx = x0; dx < gw; dx++)
                    pixels[dy * gw + dx] = 255;
        } else if (baseCp >= 0x2591 && baseCp <= 0x2593) {
            static const uint8_t shadeVal[] = {64, 128, 191};
            uint8_t v = shadeVal[baseCp - 0x2591];
            for (int dy = 0; dy < gh; dy++)
                for (int dx = 0; dx < gw; dx++)
                    pixels[dy * gw + dx] = v;
        } else if (baseCp >= 0x2596 && baseCp <= 0x259F) {
            static const int quadBits[] = {4, 8, 1, 13, 9, 7, 11, 2, 6, 14};
            int bits = quadBits[baseCp - 0x2596];
            int hw = (int)roundf((float)gw / 2.0f);
            int hh = (int)roundf((float)gh / 2.0f);
            for (int dy = 0; dy < gh; dy++) {
                int isTop = (dy < hh);
                for (int dx = 0; dx < gw; dx++) {
                    int isLeft = (dx < hw);
                    int fill = 0;
                    if ( isTop &&  isLeft && (bits & 1)) fill = 1;
                    if ( isTop && !isLeft && (bits & 2)) fill = 1;
                    if (!isTop &&  isLeft && (bits & 4)) fill = 1;
                    if (!isTop && !isLeft && (bits & 8)) fill = 1;
                    if (fill) pixels[dy * gw + dx] = 255;
                }
            }
        }
    } else {
        // Normal/wide/Powerline glyph: render via DirectWrite + D2D
        float posX = wide ? 0.0f : gc->x_offset;
        render_glyph_to_pixels(gc, utf16, utf16Len, fmt, renderW, gh, posX, pixels);
    }

    // Upload to atlas
    upload_to_atlas(gc, ac, ar, renderW, gh, pixels);
    free(pixels);

    // Clean up fallback resources
    if (fallbackFmt) IDWriteTextFormat_Release(fallbackFmt);
    if (fallbackFace) IDWriteFontFace_Release(fallbackFace);

    int encoded = wide ? (slot | GLYPH_WIDE_BIT) : slot;
    glyphCacheInsert(gc, cp, encoded);
    return encoded;
}

// ---------------------------------------------------------------------------
// Combining mark support
// ---------------------------------------------------------------------------

uint32_t combiningKey(uint32_t base, uint32_t c1, uint32_t c2) {
    uint32_t h = base ^ (c1 * 0x9e3779b9) ^ (c2 * 0x517cc1b7);
    return (h & 0x7FFFFFFF) | 0x80000000;
}

int glyphCacheRasterizeCombined(GlyphCache* gc, uint32_t base, uint32_t c1, uint32_t c2) {
    int gw = (int)gc->glyph_w;
    int gh = (int)gc->glyph_h;

    // Build full string: base + combining marks
    wchar_t str[6];
    int strLen = cp_to_utf16(base, str);
    if (c1) strLen += cp_to_utf16(c1, &str[strLen]);
    if (c2) strLen += cp_to_utf16(c2, &str[strLen]);

    // Allocate atlas slot (combining chars are never wide)
    if (gc->next_slot >= gc->max_slots) glyphCacheGrow(gc);
    int slot = gc->next_slot++;
    int ac = slot % gc->atlas_cols;
    int ar = slot / gc->atlas_cols;

    // Render combined string
    uint8_t* pixels = (uint8_t*)calloc(gw * gh, 1);
    render_glyph_to_pixels(gc, str, strLen, gc->dw_format, gw, gh, gc->x_offset, pixels);

    // Upload to atlas
    upload_to_atlas(gc, ac, ar, gw, gh, pixels);
    free(pixels);

    uint32_t key = combiningKey(base, c1, c2);
    glyphCacheInsert(gc, key, slot);
    return slot;
}

#endif // _WIN32
