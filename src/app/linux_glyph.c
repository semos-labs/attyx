// Attyx — Linux glyph cache (FreeType + Fontconfig)
// Dynamic glyph atlas: rasterises codepoints on demand into a GL texture.

#include "linux_internal.h"

// ---------------------------------------------------------------------------
// Font discovery via Fontconfig
// ---------------------------------------------------------------------------

char* findFontPath(const char* family) {
    FcConfig* config = FcInitLoadConfigAndFonts();
    FcPattern* pat = FcPatternCreate();
    FcPatternAddString(pat, FC_FAMILY, (const FcChar8*)family);
    FcPatternAddInteger(pat, FC_SPACING, FC_MONO);
    FcConfigSubstitute(config, pat, FcMatchPattern);
    FcDefaultSubstitute(pat);

    FcResult result;
    FcPattern* match = FcFontMatch(config, pat, &result);
    char* path = NULL;
    if (match) {
        FcChar8* file;
        if (FcPatternGetString(match, FC_FILE, 0, &file) == FcResultMatch)
            path = strdup((char*)file);
        FcPatternDestroy(match);
    }
    FcPatternDestroy(pat);
    return path;
}

// Like findFontPath but without the monospace spacing constraint.
// Used for user-configured fallback fonts (e.g. symbol/icon fonts).
static char* findFontPathAny(const char* family) {
    char* path = findFontPath(family);
    if (path) return path;

    // Retry without FC_MONO — catches symbol fonts not tagged as monospace.
    FcConfig* config = FcInitLoadConfigAndFonts();
    FcPattern* pat = FcPatternCreate();
    FcPatternAddString(pat, FC_FAMILY, (const FcChar8*)family);
    FcConfigSubstitute(config, pat, FcMatchPattern);
    FcDefaultSubstitute(pat);

    FcResult result;
    FcPattern* match = FcFontMatch(config, pat, &result);
    path = NULL;
    if (match) {
        FcChar8* file;
        if (FcPatternGetString(match, FC_FILE, 0, &file) == FcResultMatch)
            path = strdup((char*)file);
        FcPatternDestroy(match);
    }
    FcPatternDestroy(pat);
    return path;
}

// ---------------------------------------------------------------------------
// Hash-map helpers
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

static void glyphCacheGrow(GlyphCache* gc) {
    int oldH = gc->atlas_h;
    (void)oldH;
    int newRows = (gc->max_slots / gc->atlas_cols) * 2;
    int newH = (int)(gc->glyph_h * newRows);
    int newMaxSlots = gc->atlas_cols * newRows;

    uint8_t* buf = (uint8_t*)calloc(gc->atlas_w * newH, 1);
    glBindTexture(GL_TEXTURE_2D, gc->texture);
    glGetTexImage(GL_TEXTURE_2D, 0, GL_RED, GL_UNSIGNED_BYTE, buf);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, gc->atlas_w, newH, 0,
                 GL_RED, GL_UNSIGNED_BYTE, buf);
    free(buf);

    gc->atlas_h = newH;
    gc->max_slots = newMaxSlots;
}

// ---------------------------------------------------------------------------
// Rasterize a single codepoint into the atlas
// ---------------------------------------------------------------------------

int glyphCacheRasterize(GlyphCache* gc, uint32_t cp) {
    int gw = (int)gc->glyph_w;
    int gh = (int)gc->glyph_h;

    // 1. Glyph index lookup: primary font → user fallbacks → system fallback
    FT_Face face = gc->ft_face;
    FT_UInt gi   = FT_Get_Char_Index(face, cp);

    if (gi == 0) {
        FT_Face fallback = NULL;
        for (int fi = 0; fi < g_font_fallback_count && gi == 0; fi++) {
            char* fbPath = findFontPathAny(g_font_fallback[fi]);
            if (!fbPath) continue;
            FT_Face candidate;
            if (FT_New_Face(gc->ft_lib, fbPath, 0, &candidate) == 0) {
                FT_Set_Pixel_Sizes(candidate, 0, (int)gc->glyph_h);
                FT_UInt cgi = FT_Get_Char_Index(candidate, cp);
                if (cgi != 0) {
                    gi = cgi;
                    fallback = candidate;
                    face = fallback;
                } else {
                    FT_Done_Face(candidate);
                }
            }
            free(fbPath);
        }

        if (gi == 0) {
            FcPattern* pat = FcPatternCreate();
            FcCharSet* cs = FcCharSetCreate();
            FcCharSetAddChar(cs, cp);
            FcPatternAddCharSet(pat, FC_CHARSET, cs);
            FcConfigSubstitute(NULL, pat, FcMatchPattern);
            FcDefaultSubstitute(pat);
            FcResult res;
            FcPattern* match = FcFontMatch(NULL, pat, &res);
            if (match) {
                FcChar8* file; int index = 0;
                FcPatternGetString(match, FC_FILE, 0, &file);
                FcPatternGetInteger(match, FC_INDEX, 0, &index);
                if (FT_New_Face(gc->ft_lib, (char*)file, index, &fallback) == 0) {
                    FT_Set_Pixel_Sizes(fallback, 0, (int)gc->glyph_h);
                    gi = FT_Get_Char_Index(fallback, cp);
                    if (gi != 0) face = fallback;
                }
                FcPatternDestroy(match);
            }
            FcCharSetDestroy(cs);
            FcPatternDestroy(pat);
        }
    }

    // 2. If no glyph found, allocate a blank slot and return
    if (gi == 0) {
        if (face != gc->ft_face) FT_Done_Face(face);
        if (gc->next_slot >= gc->max_slots) glyphCacheGrow(gc);
        int blankSlot = gc->next_slot++;
        glyphCacheInsert(gc, cp, blankSlot);
        return blankSlot;
    }

    // 3. Render glyph so we can measure its bitmap extent
    FT_Load_Glyph(face, gi, FT_LOAD_DEFAULT);
    FT_Render_Glyph(face->glyph, FT_RENDER_MODE_NORMAL);
    FT_Bitmap* bmp = &face->glyph->bitmap;

    // 4. Classify: detect wide glyphs (ink or advance > 1.3× cell width).
    //    Wide glyphs get a 2-cell atlas slot and 2×gw renderer quad — same
    //    approach as Ghostty/WezTerm; the icon bleeds into the next cell at
    //    full size rather than being squished or clipped.
    bool isPowerline = (cp >= 0xE0B0 && cp <= 0xE0D4)
                    || (cp >= 0x2500 && cp <= 0x257F);
    bool isBlock     = (cp >= 0x2580 && cp <= 0x259F);
    bool wide = false;
    if (!isPowerline && !isBlock) {
        int adv_px   = (int)(face->glyph->advance.x >> 6);
        int ink_right = face->glyph->bitmap_left + (int)bmp->width;
        int src_w    = adv_px > ink_right ? adv_px : ink_right;
        wide = (src_w > (int)(gw * 1.05f));
    }
    int renderW = wide ? 2 * gw : gw;

    // 5. Allocate atlas slot(s)
    int slot;
    if (wide) {
        if (gc->next_slot % gc->atlas_cols == gc->atlas_cols - 1)
            gc->next_slot++; // skip last column to avoid row split
        while (gc->next_slot + 1 >= gc->max_slots) glyphCacheGrow(gc);
        slot = gc->next_slot;
        gc->next_slot += 2;
    } else {
        if (gc->next_slot >= gc->max_slots) glyphCacheGrow(gc);
        slot = gc->next_slot++;
    }
    int ac = slot % gc->atlas_cols;
    int ar = slot / gc->atlas_cols;

    // 6. Render pixels into renderW × gh buffer
    uint8_t* pixels = (uint8_t*)calloc(renderW * gh, 1);

    if (isPowerline && bmp->rows > 0 && bmp->width > 0) {
        // Scale to full cell using advance × (asc+desc) as reference rect.
        int adv_px  = (int)(face->glyph->advance.x >> 6);
        if (adv_px < 1) adv_px = bmp->width;
        int asc_px  = (int)(face->size->metrics.ascender  >> 6);
        int desc_px = -(int)(face->size->metrics.descender >> 6);
        int srcH    = asc_px + desc_px;
        if (srcH < 1) srcH = bmp->rows;
        int srcW    = adv_px;
        if (srcW < 1) srcW = bmp->width;
        int bx0 = face->glyph->bitmap_left;
        int by0 = asc_px - face->glyph->bitmap_top;
        for (int dy = 0; dy < gh; dy++) {
            int src_row = (int)((float)dy / gh * srcH) - by0;
            if (src_row < 0 || src_row >= (int)bmp->rows) continue;
            for (int dx = 0; dx < gw; dx++) {
                int src_col = (int)((float)dx / gw * srcW) - bx0;
                if (src_col < 0 || src_col >= (int)bmp->width) continue;
                pixels[dy * gw + dx] = bmp->buffer[src_row * bmp->pitch + src_col];
            }
        }
    } else if (isBlock && bmp->width > 1 && bmp->rows > 1) {
        float sx = (float)gw / (float)bmp->width;
        float sy = (float)gh / (float)bmp->rows;
        for (int dy = 0; dy < gh; dy++) {
            int srcRow = (int)((float)dy / sy);
            if (srcRow >= (int)bmp->rows) srcRow = (int)bmp->rows - 1;
            for (int dx = 0; dx < gw; dx++) {
                int srcCol = (int)((float)dx / sx);
                if (srcCol >= (int)bmp->width) srcCol = (int)bmp->width - 1;
                pixels[dy * gw + dx] = bmp->buffer[srcRow * bmp->pitch + srcCol];
            }
        }
    } else {
        int bl    = face->glyph->bitmap_left;
        int bt    = face->glyph->bitmap_top;
        int asc   = (int)gc->ascender;
        int y_off = (int)gc->baseline_y_offset;
        // Wide: draw at natural position in renderW-wide buffer (no centering offset).
        // Normal: apply x_offset centering for the primary font cell width.
        int x_off = wide ? 0 : (int)gc->x_offset;
        for (unsigned row = 0; row < bmp->rows; row++) {
            int dy = asc - bt + (int)row + y_off;
            if (dy < 0 || dy >= gh) continue;
            for (unsigned col = 0; col < bmp->width; col++) {
                int dx = bl + (int)col + x_off;
                if (dx < 0 || dx >= renderW) continue;
                pixels[dy * renderW + dx] = bmp->buffer[row * bmp->pitch + col];
            }
        }
    }

    if (face != gc->ft_face) FT_Done_Face(face);

    // 7. Upload to atlas
    glBindTexture(GL_TEXTURE_2D, gc->texture);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    glTexSubImage2D(GL_TEXTURE_2D, 0, ac * gw, ar * gh, renderW, gh,
                    GL_RED, GL_UNSIGNED_BYTE, pixels);
    free(pixels);

    // 8. Insert into map — encode wide flag in bit 30
    int encoded = wide ? (slot | GLYPH_WIDE_BIT) : slot;
    glyphCacheInsert(gc, cp, encoded);
    return encoded;
}

// ---------------------------------------------------------------------------
// Initialize glyph cache: discover font, set up atlas texture
// ---------------------------------------------------------------------------

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
    float basePt = (g_font_size > 0) ? (float)g_font_size : 14.0f;
    int fontSize = (int)(basePt * contentScale);
    FT_Set_Pixel_Sizes(face, 0, fontSize);

    float ascender = (float)(face->size->metrics.ascender >> 6);
    float naturalH = (float)(face->size->metrics.height >> 6);
    float naturalW = (float)(face->size->metrics.max_advance >> 6);
    float gh = naturalH;
    float gw = naturalW;

    // Apply cell size from config:
    //   0   → auto
    //   > 0 → fixed absolute pixel value
    //   < 0 → percent: base × abs(value) / 100
    if (g_cell_width > 0)
        gw = roundf((float)g_cell_width * contentScale);
    else if (g_cell_width < 0)
        gw = roundf(gw * (float)(-g_cell_width) / 100.0f);
    if (g_cell_height > 0)
        gh = roundf((float)g_cell_height * contentScale);
    else if (g_cell_height < 0)
        gh = roundf(gh * (float)(-g_cell_height) / 100.0f);

    float baseline_y_offset = (gh - naturalH) / 2.0f;
    float x_offset = (gw - naturalW) / 2.0f;

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

    GlyphCache gc;
    memset(&gc, 0, sizeof(gc));
    gc.texture    = tex;
    gc.ft_lib     = ft_lib;
    gc.ft_face    = face;
    gc.glyph_w    = gw;
    gc.glyph_h    = gh;
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
