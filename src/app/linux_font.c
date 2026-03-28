// Attyx — Linux font discovery + glyph cache creation
// Extracted from linux_glyph.c to keep files under the 600-line limit.

#ifdef __linux__

#include "linux_internal.h"

// (removed: static s_ref_h_pt / s_ref_w_pt — percent mode is now
// relative to the current font's natural dimensions, not the initial ones)

// Find a styled variant (bold/italic) of a font family via Fontconfig.
static char* findFontPathStyled(const char* family, int wantBold, int wantItalic) {
    FcConfig* config = FcInitLoadConfigAndFonts();
    FcPattern* pat = FcPatternCreate();
    FcPatternAddString(pat, FC_FAMILY, (const FcChar8*)family);
    FcPatternAddInteger(pat, FC_SPACING, FC_MONO);
    if (wantBold)
        FcPatternAddInteger(pat, FC_WEIGHT, FC_WEIGHT_BOLD);
    if (wantItalic)
        FcPatternAddInteger(pat, FC_SLANT, FC_SLANT_ITALIC);
    FcConfigSubstitute(config, pat, FcMatchPattern);
    FcDefaultSubstitute(pat);

    FcResult result;
    FcPattern* match = FcFontMatch(config, pat, &result);
    char* path = NULL;
    if (match) {
        // Verify the match actually has the requested style
        int matchWeight = 0, matchSlant = 0;
        FcPatternGetInteger(match, FC_WEIGHT, 0, &matchWeight);
        FcPatternGetInteger(match, FC_SLANT, 0, &matchSlant);
        bool ok = true;
        if (wantBold && matchWeight < FC_WEIGHT_BOLD) ok = false;
        if (wantItalic && matchSlant < FC_SLANT_ITALIC) ok = false;
        if (ok) {
            FcChar8* file;
            if (FcPatternGetString(match, FC_FILE, 0, &file) == FcResultMatch)
                path = strdup((char*)file);
        }
        FcPatternDestroy(match);
    }
    FcPatternDestroy(pat);
    FcConfigDestroy(config);
    return path;
}

static FT_Face loadStyledFace(FT_Library ft_lib, const char* family, int fontSize,
                               int wantBold, int wantItalic) {
    char* path = findFontPathStyled(family, wantBold, wantItalic);
    if (!path) return NULL;
    FT_Face face;
    if (FT_New_Face(ft_lib, path, 0, &face) != 0) {
        free(path);
        return NULL;
    }
    free(path);
    FT_Set_Pixel_Sizes(face, 0, fontSize);
    return face;
}

GlyphCache createGlyphCache(FT_Library ft_lib, float contentScale) {
    // Font family: prefer config (g_font_family), fall back to env, then defaults.
    char* fontPath = NULL;
    if (g_font_family_len > 0)
        fontPath = findFontPath(g_font_family);
    if (!fontPath) {
        const char* fontEnv = getenv("ATTYX_FONT");
        if (fontEnv && fontEnv[0])
            fontPath = findFontPath(fontEnv);
    }
    if (!fontPath) fontPath = findFontPath("Monospace");
    if (!fontPath) fontPath = findFontPath("DejaVu Sans Mono");
    if (!fontPath) fontPath = findFontPath("Courier");
    if (!fontPath) {
        ATTYX_LOG_ERR("glyph", "no monospace font found");
        exit(1);
    }

    FT_Face face;
    if (FT_New_Face(ft_lib, fontPath, 0, &face) != 0) {
        ATTYX_LOG_ERR("glyph", "failed to load font: %s", fontPath);
        free(fontPath);
        exit(1);
    }
    free(fontPath);

    // Font size: prefer config (g_font_size), in points.
    // Convert points to pixels: 1pt = 1/72 inch, standard desktop = 96 DPI,
    // so px = pt * 96/72 * contentScale.  This matches how Ghostty, Kitty,
    // and other terminals size fonts on Linux.
    float basePt = (g_font_size > 0) ? (float)g_font_size : 14.0f;
    int fontSize = (int)(basePt * contentScale * 96.0f / 72.0f + 0.5f);
    FT_Set_Pixel_Sizes(face, 0, fontSize);

    // Use /64.0f (not >>6) to preserve sub-pixel precision from FreeType's
    // 26.6 fixed-point metrics.  At small font sizes (e.g. 8pt) the fractional
    // part matters — truncation can shift glyphs by a full pixel and produce
    // wrong cell dimensions when percentage overrides are applied.
    float ascender = face->size->metrics.ascender / 64.0f;
    float naturalH = face->size->metrics.height / 64.0f;

    // Measure actual monospace cell width from a reference ASCII glyph.
    float naturalW;
    if (FT_Load_Char(face, 'M', FT_LOAD_DEFAULT) == 0) {
        naturalW = face->glyph->advance.x / 64.0f;
    } else {
        naturalW = face->size->metrics.max_advance / 64.0f;
    }
    float gh = naturalH;
    float gw = naturalW;

    // Apply cell size overrides.
    // Percent mode: relative to the current font's natural dimensions,
    // so cell proportions scale correctly when font size changes.
    if (g_cell_width > 0)
        gw = roundf((float)g_cell_width * contentScale);
    else if (g_cell_width < 0)
        gw = roundf(naturalW * (float)(-g_cell_width) / 100.0f);
    if (g_cell_height > 0)
        gh = roundf((float)g_cell_height * contentScale);
    else if (g_cell_height < 0)
        gh = roundf(naturalH * (float)(-g_cell_height) / 100.0f);

    float baseline_y_offset = (gh - naturalH) / 2.0f;
    float x_offset = (gw - naturalW) / 2.0f;

    ATTYX_LOG_INFO("glyph", "font: base=%.0fpt scale=%.2f fontSize=%dpx",
        basePt, contentScale, fontSize);
    ATTYX_LOG_INFO("glyph", "font: ascender=%.2f height=%.2f advance=%.2f (raw 26.6: asc=%ld h=%ld adv=%ld)",
        ascender, naturalH, naturalW,
        face->size->metrics.ascender, face->size->metrics.height,
        FT_Load_Char(face, 'M', FT_LOAD_DEFAULT) == 0 ? face->glyph->advance.x : face->size->metrics.max_advance);
    ATTYX_LOG_INFO("glyph", "font: cell_w_cfg=%d cell_h_cfg=%d -> gw=%.1f gh=%.1f",
        g_cell_width, g_cell_height, gw, gh);
    ATTYX_LOG_INFO("glyph", "font: baseline_y_off=%.2f x_off=%.2f", baseline_y_offset, x_offset);

    int cols = 32;
    int initRows = 32;
    int atlasW = (int)(gw * cols);
    int atlasH = (int)(gh * initRows);

    GLuint tex;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);

    uint8_t* zeroes = (uint8_t*)calloc(atlasW * atlasH, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, atlasW, atlasH, 0,
                 GL_RED, GL_UNSIGNED_BYTE, zeroes);
    free(zeroes);

    GLuint colorTex;
    glGenTextures(1, &colorTex);
    glBindTexture(GL_TEXTURE_2D, colorTex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, atlasW, atlasH, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, NULL);

    GlyphCache gc;
    memset(&gc, 0, sizeof(gc));
    gc.texture       = tex;
    gc.color_texture = colorTex;
    gc.ft_lib     = ft_lib;
    gc.ft_face    = face;

    // Load bold/italic/bold-italic face variants (NULL if unavailable).
    const char* family = (g_font_family_len > 0) ? g_font_family : "Monospace";
    gc.ft_bold         = loadStyledFace(ft_lib, family, fontSize, 1, 0);
    gc.ft_italic       = loadStyledFace(ft_lib, family, fontSize, 0, 1);
    gc.ft_bold_italic  = loadStyledFace(ft_lib, family, fontSize, 1, 1);
    gc.glyph_w    = gw;
    gc.glyph_h    = gh;
    gc.font_size  = fontSize;
    gc.scale      = contentScale;
    gc.ascender   = ascender;
    gc.baseline_y_offset = baseline_y_offset;
    gc.x_offset   = x_offset;
    gc.atlas_cols = cols;
    gc.atlas_w    = atlasW;
    gc.atlas_h    = atlasH;
    gc.next_slot  = 0;
    gc.max_slots  = cols * initRows;

    for (int i = 0; i < GLYPH_CACHE_CAP; i++) gc.map[i].slot = -1;

    for (uint32_t ch = 32; ch < 127; ch++)
        glyphCacheRasterize(&gc, ch);

    return gc;
}

#endif // __linux__
