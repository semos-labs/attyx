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
    if (cp >= 0xE000 && cp <= 0xF8FF) return true;  // PUA (Nerd Font icons)
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
    if (cp >= 0x23F8 && cp <= 0x23FA) return true;
    if (cp >= 0x25FB && cp <= 0x25FE) return true;
    if (cp == 0x2614 || cp == 0x2615) return true;
    if (cp >= 0x2648 && cp <= 0x2653) return true;
    if (cp == 0x267F || cp == 0x2693 || cp == 0x26A1) return true;
    if (cp == 0x26CE || cp == 0x26D4 || cp == 0x26EA) return true;
    if (cp == 0x26F2 || cp == 0x26F3 || cp == 0x26F5) return true;
    if (cp == 0x26FA || cp == 0x26FD) return true;
    if (cp == 0x2702 || cp == 0x2705) return true;
    if (cp >= 0x2708 && cp <= 0x270D) return true;
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

    // Grow grayscale atlas
    uint8_t* buf = (uint8_t*)calloc(gc->atlas_w * newH, 1);
    glBindTexture(GL_TEXTURE_2D, gc->texture);
    glGetTexImage(GL_TEXTURE_2D, 0, GL_RED, GL_UNSIGNED_BYTE, buf);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, gc->atlas_w, newH, 0,
                 GL_RED, GL_UNSIGNED_BYTE, buf);
    free(buf);

    // Grow color atlas in parallel (slot indices must remain consistent)
    uint8_t* cbuf = (uint8_t*)calloc(gc->atlas_w * newH * 4, 1);
    glBindTexture(GL_TEXTURE_2D, gc->color_texture);
    glGetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_UNSIGNED_BYTE, cbuf);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, gc->atlas_w, newH, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, cbuf);
    free(cbuf);

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

    // Block elements are drawn as geometry — no glyph needed.
    bool isBlock = (cp >= 0x2580 && cp <= 0x259F);

    // 2. If no glyph found and not a geometry-drawn block char, return blank slot.
    if (gi == 0 && !isBlock) {
        if (face != gc->ft_face) FT_Done_Face(face);
        if (gc->next_slot >= gc->max_slots) glyphCacheGrow(gc);
        int blankSlot = gc->next_slot++;
        glyphCacheInsert(gc, cp, blankSlot);
        return blankSlot;
    }

    // 3. Render glyph so we can measure its bitmap extent.
    //    For color fonts, prefer FT_LOAD_COLOR to get BGRA bitmap.
    if (FT_HAS_COLOR(face)) {
        FT_Load_Glyph(face, gi, FT_LOAD_COLOR);
    } else {
        FT_Load_Glyph(face, gi, FT_LOAD_DEFAULT);
    }
    FT_Render_Glyph(face->glyph, FT_RENDER_MODE_NORMAL);
    FT_Bitmap* bmp = &face->glyph->bitmap;

    // 4. Classify: detect wide glyphs (ink or advance > 1.3× cell width).
    //    Wide glyphs get a 2-cell atlas slot and 2×gw renderer quad — same
    //    approach as Ghostty/WezTerm; the icon bleeds into the next cell at
    //    full size rather than being squished or clipped.
    bool isPowerline = (cp >= 0xE0B0 && cp <= 0xE0D4)
                    || (cp >= 0x2500 && cp <= 0x257F);
    // isBlock declared above (needed before the early-return check)
    bool wide = false;
    if (!isPowerline && !isBlock && canBeWide(cp)) {
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

    // 6. Color emoji path: FT_PIXEL_MODE_BGRA — upload premultiplied BGRA→RGBA to color atlas.
    bool isColorGlyph = (bmp->pixel_mode == FT_PIXEL_MODE_BGRA);
    if (isColorGlyph) {
        uint8_t* pixels = (uint8_t*)calloc(renderW * gh * 4, 1);
        int bx0 = face->glyph->bitmap_left;
        int by0 = (int)gc->ascender - face->glyph->bitmap_top;
        for (int dy = 0; dy < gh; dy++) {
            int src_row = dy - by0;
            if (src_row < 0 || src_row >= (int)bmp->rows) continue;
            for (int dx = 0; dx < renderW; dx++) {
                int src_col = dx - bx0;
                if (src_col < 0 || src_col >= (int)bmp->width) continue;
                int di = (dy * renderW + dx) * 4;
                int si = src_row * bmp->pitch + src_col * 4;
                // FreeType BGRA (premultiplied) → GL_RGBA: swap B↔R
                pixels[di+0] = bmp->buffer[si+2]; // R
                pixels[di+1] = bmp->buffer[si+1]; // G
                pixels[di+2] = bmp->buffer[si+0]; // B
                pixels[di+3] = bmp->buffer[si+3]; // A
            }
        }
        glBindTexture(GL_TEXTURE_2D, gc->color_texture);
        glTexSubImage2D(GL_TEXTURE_2D, 0, ac * gw, ar * gh, renderW, gh,
                        GL_RGBA, GL_UNSIGNED_BYTE, pixels);
        free(pixels);
        if (face != gc->ft_face) FT_Done_Face(face);
        int encoded = (wide ? GLYPH_WIDE_BIT : 0) | GLYPH_COLOR_BIT | slot;
        glyphCacheInsert(gc, cp, encoded);
        return encoded;
    }

    // 7. Render grayscale pixels into renderW × gh buffer
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
    } else if (isBlock) {
        // Render block/quadrant elements as pure geometry — no font glyph needed.
        // Pixel buffer is top-to-bottom: row 0 = top of cell, row gh-1 = bottom.
        bool drawn = false;
        if (cp >= 0x2581 && cp <= 0x2588) {
            // LOWER ONE-EIGHTH .. FULL BLOCK (U+2581–U+2588)
            int eighths = (int)(cp - 0x2580); // 1..8
            int blockH  = (int)roundf((float)gh * eighths / 8.0f);
            int y0 = gh - blockH;
            for (int dy = y0; dy < gh; dy++)
                for (int dx = 0; dx < gw; dx++)
                    pixels[dy * gw + dx] = 255;
            drawn = true;
        } else if (cp == 0x2580) {
            // UPPER HALF BLOCK
            int blockH = (int)roundf((float)gh / 2.0f);
            for (int dy = 0; dy < blockH; dy++)
                for (int dx = 0; dx < gw; dx++)
                    pixels[dy * gw + dx] = 255;
            drawn = true;
        } else if (cp >= 0x2589 && cp <= 0x258F) {
            // LEFT SEVEN-EIGHTHS .. LEFT ONE-EIGHTH BLOCK (U+2589–U+258F)
            int eighths = (int)(0x2590 - cp); // 7..1
            int blockW  = (int)roundf((float)gw * eighths / 8.0f);
            for (int dy = 0; dy < gh; dy++)
                for (int dx = 0; dx < blockW; dx++)
                    pixels[dy * gw + dx] = 255;
            drawn = true;
        } else if (cp == 0x2590) {
            // RIGHT HALF BLOCK
            int blockW = (int)roundf((float)gw / 2.0f);
            int x0 = gw - blockW;
            for (int dy = 0; dy < gh; dy++)
                for (int dx = x0; dx < gw; dx++)
                    pixels[dy * gw + dx] = 255;
            drawn = true;
        } else if (cp == 0x2594) {
            // UPPER ONE EIGHTH BLOCK
            int blockH = (int)roundf((float)gh / 8.0f);
            for (int dy = 0; dy < blockH; dy++)
                for (int dx = 0; dx < gw; dx++)
                    pixels[dy * gw + dx] = 255;
            drawn = true;
        } else if (cp == 0x2595) {
            // RIGHT ONE EIGHTH BLOCK
            int blockW = (int)roundf((float)gw / 8.0f);
            int x0 = gw - blockW;
            for (int dy = 0; dy < gh; dy++)
                for (int dx = x0; dx < gw; dx++)
                    pixels[dy * gw + dx] = 255;
            drawn = true;
        } else if (cp >= 0x2591 && cp <= 0x2593) {
            // SHADE CHARACTERS — render as solid fills at fractional brightness.
            // ░ = 25%, ▒ = 50%, ▓ = 75%
            static const uint8_t shadeVal[] = {64, 128, 191};
            uint8_t v = shadeVal[cp - 0x2591];
            for (int dy = 0; dy < gh; dy++)
                for (int dx = 0; dx < gw; dx++)
                    pixels[dy * gw + dx] = v;
            drawn = true;
        } else if (cp >= 0x2596 && cp <= 0x259F) {
            // QUADRANT BLOCKS — bits: UL=1, UR=2, BL=4, BR=8
            static const int quadBits[] = {4, 8, 1, 13, 9, 7, 11, 2, 6, 14};
            int bits = quadBits[cp - 0x2596];
            int hw = (int)roundf((float)gw / 2.0f);
            int hh = (int)roundf((float)gh / 2.0f);
            for (int dy = 0; dy < gh; dy++) {
                int isTop = (dy < hh);
                for (int dx = 0; dx < gw; dx++) {
                    int isLeft = (dx < hw);
                    int fill = 0;
                    if ( isTop &&  isLeft && (bits & 1)) fill = 1; // UL
                    if ( isTop && !isLeft && (bits & 2)) fill = 1; // UR
                    if (!isTop &&  isLeft && (bits & 4)) fill = 1; // BL
                    if (!isTop && !isLeft && (bits & 8)) fill = 1; // BR
                    if (fill) pixels[dy * gw + dx] = 255;
                }
            }
            drawn = true;
        }
        if (!drawn && bmp->width > 1 && bmp->rows > 1) {
            // Shade chars (U+2591–U+2593) and other unhandled: bbox-scale glyph.
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

    // Measure actual monospace cell width from a reference ASCII glyph.
    // max_advance includes double-width CJK glyphs and can be 2x too wide.
    float naturalW;
    if (FT_Load_Char(face, 'M', FT_LOAD_DEFAULT) == 0) {
        naturalW = (float)(face->glyph->advance.x >> 6);
    } else {
        naturalW = (float)(face->size->metrics.max_advance >> 6);
    }
    float gh = naturalH;
    float gw = naturalW;

    // Capture fixed reference dimensions (in logical points) on first call.
    // Percent mode uses these so that cell size is independent of font size.
    if (s_ref_h_pt <= 0.0f) s_ref_h_pt = naturalH / contentScale;
    if (s_ref_w_pt <= 0.0f) s_ref_w_pt = naturalW / contentScale;

    // Apply cell size from config:
    //   0   → auto
    //   > 0 → fixed absolute pixel value
    //   < 0 → percent: base × abs(value) / 100
    if (g_cell_width > 0)
        gw = roundf((float)g_cell_width * contentScale);
    else if (g_cell_width < 0)
        gw = roundf(s_ref_w_pt * contentScale * (float)(-g_cell_width) / 100.0f);
    if (g_cell_height > 0)
        gh = roundf((float)g_cell_height * contentScale);
    else if (g_cell_height < 0)
        gh = roundf(s_ref_h_pt * contentScale * (float)(-g_cell_height) / 100.0f);

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
