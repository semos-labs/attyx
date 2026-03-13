// Attyx — Windows font loading (DirectWrite)
// Font matching by family name, metrics extraction, glyph cache atlas creation.
// Uses COM C API via COBJMACROS (IDWriteFactory_CreateTextFormat style).

#ifdef _WIN32

#include "windows_internal.h"

// ---------------------------------------------------------------------------
// Font discovery helpers
// ---------------------------------------------------------------------------

// Try to find a font matching the given family name in the system collection.
// Returns a font face or NULL. Caller must release.
static IDWriteFontFace* find_font_face(IDWriteFactory* factory, const wchar_t* family,
                                        DWRITE_FONT_WEIGHT weight,
                                        DWRITE_FONT_STYLE style) {
    IDWriteFontCollection* collection = NULL;
    HRESULT hr = IDWriteFactory_GetSystemFontCollection(factory, &collection, FALSE);
    if (FAILED(hr) || !collection) return NULL;

    UINT32 index = 0;
    BOOL exists = FALSE;
    IDWriteFontCollection_FindFamilyName(collection, family, &index, &exists);
    if (!exists) {
        IDWriteFontCollection_Release(collection);
        return NULL;
    }

    IDWriteFontFamily* fam = NULL;
    IDWriteFontCollection_GetFontFamily(collection, index, &fam);
    IDWriteFontCollection_Release(collection);
    if (!fam) return NULL;

    IDWriteFont* font = NULL;
    hr = IDWriteFontFamily_GetFirstMatchingFont(fam, weight, DWRITE_FONT_STRETCH_NORMAL,
                                                 style, &font);
    IDWriteFontFamily_Release(fam);
    if (FAILED(hr) || !font) return NULL;

    IDWriteFontFace* face = NULL;
    IDWriteFont_CreateFontFace(font, &face);
    IDWriteFont_Release(font);
    return face;
}

// Create a text format for a given family/weight/style at the specified size.
static IDWriteTextFormat* create_format(IDWriteFactory* factory, const wchar_t* family,
                                         float fontSize,
                                         DWRITE_FONT_WEIGHT weight,
                                         DWRITE_FONT_STYLE style) {
    IDWriteTextFormat* fmt = NULL;
    HRESULT hr = IDWriteFactory_CreateTextFormat(
        factory, family, NULL, weight, style,
        DWRITE_FONT_STRETCH_NORMAL, fontSize, L"en-us", &fmt);
    if (FAILED(hr)) return NULL;
    IDWriteTextFormat_SetWordWrapping(fmt, DWRITE_WORD_WRAPPING_NO_WRAP);
    return fmt;
}

// Convert UTF-8 family name to wide string. Returns static buffer.
static const wchar_t* family_to_wide(const char* family, int len) {
    static wchar_t buf[ATTYX_FONT_FAMILY_MAX];
    if (len <= 0) return L"Consolas";
    int n = MultiByteToWideChar(CP_UTF8, 0, family, len, buf, ATTYX_FONT_FAMILY_MAX - 1);
    buf[n] = 0;
    return buf;
}

// ---------------------------------------------------------------------------
// Metrics measurement
// ---------------------------------------------------------------------------

static void measure_cell(IDWriteFactory* factory, IDWriteTextFormat* fmt,
                          float* outW, float* outH, float* outAscender) {
    // Create a layout with a reference character to measure cell size
    IDWriteTextLayout* layout = NULL;
    HRESULT hr = IDWriteFactory_CreateTextLayout(factory, L"M", 1, fmt, 1000.0f, 1000.0f, &layout);
    if (FAILED(hr) || !layout) {
        *outW = 8.0f; *outH = 16.0f; *outAscender = 12.0f;
        return;
    }

    DWRITE_TEXT_METRICS metrics;
    IDWriteTextLayout_GetMetrics(layout, &metrics);

    DWRITE_LINE_METRICS lineMetrics;
    UINT32 lineCount = 0;
    IDWriteTextLayout_GetLineMetrics(layout, &lineMetrics, 1, &lineCount);

    float adv = metrics.widthIncludingTrailingWhitespace;
    float lineH = lineMetrics.height;
    float baseline = lineMetrics.baseline;

    IDWriteTextLayout_Release(layout);

    *outW = roundf(adv);
    *outH = roundf(lineH);
    *outAscender = roundf(baseline);
}

// ---------------------------------------------------------------------------
// D2D / WIC off-screen rendering setup
// ---------------------------------------------------------------------------

static int init_d2d_offscreen(GlyphCache* gc, int bmpW, int bmpH) {
    // Create WIC factory
    HRESULT hr = CoCreateInstance(&CLSID_WICImagingFactory, NULL,
                                   CLSCTX_INPROC_SERVER,
                                   &IID_IWICImagingFactory,
                                   (void**)&gc->wic_factory);
    if (FAILED(hr)) return 0;

    // Create WIC bitmap for off-screen rendering
    hr = IWICImagingFactory_CreateBitmap(gc->wic_factory,
                                          (UINT)bmpW, (UINT)bmpH,
                                          &GUID_WICPixelFormat32bppPBGRA,
                                          WICBitmapCacheOnLoad,
                                          &gc->wic_bitmap);
    if (FAILED(hr)) return 0;

    // Create D2D factory
    hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
                            &IID_ID2D1Factory, NULL,
                            (void**)&gc->d2d_factory);
    if (FAILED(hr)) return 0;

    // Create D2D render target from WIC bitmap
    D2D1_RENDER_TARGET_PROPERTIES rtProps = {
        .type = D2D1_RENDER_TARGET_TYPE_SOFTWARE,
        .pixelFormat = {
            .format = DXGI_FORMAT_B8G8R8A8_UNORM,
            .alphaMode = D2D1_ALPHA_MODE_PREMULTIPLIED,
        },
        .dpiX = 96.0f, .dpiY = 96.0f,
        .usage = D2D1_RENDER_TARGET_USAGE_NONE,
        .minLevel = D2D1_FEATURE_LEVEL_DEFAULT,
    };
    hr = ID2D1Factory_CreateWicBitmapRenderTarget(gc->d2d_factory,
                                                    gc->wic_bitmap,
                                                    &rtProps,
                                                    &gc->d2d_rt);
    if (FAILED(hr)) return 0;

    // Create brush for drawing text
    D2D1_COLOR_F white = { 1.0f, 1.0f, 1.0f, 1.0f };
    hr = ID2D1RenderTarget_CreateSolidColorBrush(gc->d2d_rt, &white, NULL, &gc->d2d_brush);
    if (FAILED(hr)) return 0;

    return 1;
}

// ---------------------------------------------------------------------------
// Public: initialize font system and create glyph cache
// ---------------------------------------------------------------------------

int windows_font_init(GlyphCache* gc, ID3D11Device* device, float scale) {
    memset(gc, 0, sizeof(*gc));
    for (int i = 0; i < GLYPH_CACHE_CAP; i++) gc->map[i].slot = -1;

    gc->d3d_device = device;
    gc->scale = scale;

    // Initialize COM (needed for DirectWrite + WIC)
    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);

    // Create DirectWrite factory
    HRESULT hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED,
                                      &IID_IDWriteFactory,
                                      (IUnknown**)&gc->dw_factory);
    if (FAILED(hr)) return 0;

    // Font family selection
    const wchar_t* family = family_to_wide(g_font_family, g_font_family_len);

    // Verify font exists, fall back through defaults
    IDWriteFontFace* testFace = find_font_face(gc->dw_factory, family,
                                                DWRITE_FONT_WEIGHT_REGULAR,
                                                DWRITE_FONT_STYLE_NORMAL);
    if (!testFace) {
        static const wchar_t* fallbacks[] = { L"Cascadia Mono", L"Consolas", L"Courier New" };
        for (int i = 0; i < 3; i++) {
            testFace = find_font_face(gc->dw_factory, fallbacks[i],
                                       DWRITE_FONT_WEIGHT_REGULAR,
                                       DWRITE_FONT_STYLE_NORMAL);
            if (testFace) { family = fallbacks[i]; break; }
        }
    }
    if (!testFace) return 0;

    // Font size in DIPs (points * scale)
    float basePt = (g_font_size > 0) ? (float)g_font_size : 14.0f;
    float fontSize = basePt * scale;
    gc->font_size = (int)fontSize;

    // Create text formats (regular, bold, italic, bold-italic)
    gc->dw_format = create_format(gc->dw_factory, family, fontSize,
                                   DWRITE_FONT_WEIGHT_REGULAR, DWRITE_FONT_STYLE_NORMAL);
    gc->dw_format_bold = create_format(gc->dw_factory, family, fontSize,
                                        DWRITE_FONT_WEIGHT_BOLD, DWRITE_FONT_STYLE_NORMAL);
    gc->dw_format_italic = create_format(gc->dw_factory, family, fontSize,
                                          DWRITE_FONT_WEIGHT_REGULAR, DWRITE_FONT_STYLE_ITALIC);
    gc->dw_format_bold_italic = create_format(gc->dw_factory, family, fontSize,
                                               DWRITE_FONT_WEIGHT_BOLD, DWRITE_FONT_STYLE_ITALIC);

    // Store font faces for glyph index lookups
    gc->dw_face = testFace;
    gc->dw_face_bold = find_font_face(gc->dw_factory, family,
                                       DWRITE_FONT_WEIGHT_BOLD, DWRITE_FONT_STYLE_NORMAL);
    gc->dw_face_italic = find_font_face(gc->dw_factory, family,
                                         DWRITE_FONT_WEIGHT_REGULAR, DWRITE_FONT_STYLE_ITALIC);
    gc->dw_face_bold_italic = find_font_face(gc->dw_factory, family,
                                              DWRITE_FONT_WEIGHT_BOLD, DWRITE_FONT_STYLE_ITALIC);

    // Measure cell dimensions
    float naturalW, naturalH, ascender;
    measure_cell(gc->dw_factory, gc->dw_format, &naturalW, &naturalH, &ascender);

    float gw = naturalW, gh = naturalH;
    // Apply cell size overrides
    if (g_cell_width > 0)
        gw = roundf((float)g_cell_width * scale);
    else if (g_cell_width < 0)
        gw = roundf(naturalW * (float)(-g_cell_width) / 100.0f);
    if (g_cell_height > 0)
        gh = roundf((float)g_cell_height * scale);
    else if (g_cell_height < 0)
        gh = roundf(naturalH * (float)(-g_cell_height) / 100.0f);

    gc->glyph_w = gw;
    gc->glyph_h = gh;
    gc->ascender = ascender;
    gc->baseline_y_offset = (gh - naturalH) / 2.0f;
    gc->x_offset = (gw - naturalW) / 2.0f;

    // Create atlas texture
    int cols = 32;
    int initRows = 32;
    gc->atlas_cols = cols;
    gc->atlas_w = (int)(gw * cols);
    gc->atlas_h = (int)(gh * initRows);
    gc->next_slot = 0;
    gc->max_slots = cols * initRows;

    D3D11_TEXTURE2D_DESC texDesc = {
        .Width = (UINT)gc->atlas_w, .Height = (UINT)gc->atlas_h,
        .MipLevels = 1, .ArraySize = 1,
        .Format = DXGI_FORMAT_R8_UNORM,
        .SampleDesc = { .Count = 1, .Quality = 0 },
        .Usage = D3D11_USAGE_DEFAULT,
        .BindFlags = D3D11_BIND_SHADER_RESOURCE,
    };
    hr = ID3D11Device_CreateTexture2D(device, &texDesc, NULL, &gc->texture);
    if (FAILED(hr)) return 0;
    hr = ID3D11Device_CreateShaderResourceView(device, (ID3D11Resource*)gc->texture,
                                                NULL, &gc->texture_srv);
    if (FAILED(hr)) return 0;

    // Color atlas is lazy-allocated on first emoji glyph
    gc->color_texture = NULL;
    gc->color_srv = NULL;

    // Initialize D2D off-screen rendering (bitmap sized for one glyph cell × 2 for wide)
    int bmpW = (int)(gw * 2);
    int bmpH = (int)gh;
    if (!init_d2d_offscreen(gc, bmpW, bmpH)) return 0;

    // Pre-rasterize printable ASCII
    for (uint32_t ch = 32; ch < 127; ch++)
        glyphCacheRasterize(gc, ch);

    return 1;
}

// ---------------------------------------------------------------------------
// Cleanup
// ---------------------------------------------------------------------------

void windows_font_cleanup(GlyphCache* gc) {
    if (gc->d2d_brush)     { ID2D1SolidColorBrush_Release(gc->d2d_brush); gc->d2d_brush = NULL; }
    if (gc->d2d_rt)        { ID2D1RenderTarget_Release(gc->d2d_rt); gc->d2d_rt = NULL; }
    if (gc->d2d_factory)   { ID2D1Factory_Release(gc->d2d_factory); gc->d2d_factory = NULL; }
    if (gc->wic_bitmap)    { IWICBitmap_Release(gc->wic_bitmap); gc->wic_bitmap = NULL; }
    if (gc->wic_factory)   { IWICImagingFactory_Release(gc->wic_factory); gc->wic_factory = NULL; }

    if (gc->dw_face)            { IDWriteFontFace_Release(gc->dw_face); gc->dw_face = NULL; }
    if (gc->dw_face_bold)       { IDWriteFontFace_Release(gc->dw_face_bold); gc->dw_face_bold = NULL; }
    if (gc->dw_face_italic)     { IDWriteFontFace_Release(gc->dw_face_italic); gc->dw_face_italic = NULL; }
    if (gc->dw_face_bold_italic){ IDWriteFontFace_Release(gc->dw_face_bold_italic); gc->dw_face_bold_italic = NULL; }

    if (gc->dw_format)            { IDWriteTextFormat_Release(gc->dw_format); gc->dw_format = NULL; }
    if (gc->dw_format_bold)       { IDWriteTextFormat_Release(gc->dw_format_bold); gc->dw_format_bold = NULL; }
    if (gc->dw_format_italic)     { IDWriteTextFormat_Release(gc->dw_format_italic); gc->dw_format_italic = NULL; }
    if (gc->dw_format_bold_italic){ IDWriteTextFormat_Release(gc->dw_format_bold_italic); gc->dw_format_bold_italic = NULL; }

    if (gc->dw_factory) { IDWriteFactory_Release(gc->dw_factory); gc->dw_factory = NULL; }

    if (gc->texture_srv)  { ID3D11ShaderResourceView_Release(gc->texture_srv); gc->texture_srv = NULL; }
    if (gc->texture)      { ID3D11Texture2D_Release(gc->texture); gc->texture = NULL; }
    if (gc->color_srv)    { ID3D11ShaderResourceView_Release(gc->color_srv); gc->color_srv = NULL; }
    if (gc->color_texture){ ID3D11Texture2D_Release(gc->color_texture); gc->color_texture = NULL; }
}

#endif // _WIN32
