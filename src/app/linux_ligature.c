// Attyx — Linux ligature support (stub — requires HarfBuzz for full support)
//
// FreeType alone cannot perform GSUB ligature substitution. This file provides
// the ligature interface used by the renderer. Currently returns NULL
// for all sequences. To enable ligatures on Linux, HarfBuzz integration is
// needed (planned for a future release).

#include "linux_internal.h"

#ifdef __linux__

// ---------------------------------------------------------------------------
// Ligature key: hash a codepoint sequence into 0x40000000-0x7FFFFFFF range.
// ---------------------------------------------------------------------------

uint32_t ligatureKey(const uint32_t* cps, int count) {
    uint32_t h = (uint32_t)count;
    for (int i = 0; i < count; i++)
        h = h * 31 + cps[i];
    return (h & 0x3FFFFFFF) | 0x40000000;
}

// ---------------------------------------------------------------------------
// Trigger check: characters that commonly form programming font ligatures.
// ---------------------------------------------------------------------------

bool isLigaTrigger(uint32_t ch) {
    if (ch < 33 || ch > 126) return false;
    switch (ch) {
        case '!': case '#': case '$': case '%': case '&':
        case '*': case '+': case '-': case '.': case '/':
        case ':': case ';': case '<': case '=': case '>':
        case '?': case '@': case '\\': case '^': case '|':
        case '~': case '_':
            return true;
        default:
            return false;
    }
}

// ---------------------------------------------------------------------------
// Stub: no HarfBuzz available, so no shaping.
// ---------------------------------------------------------------------------

void ligatureCacheClear(void) {
    // No cache to clear without HarfBuzz.
}

const LigaResult* shapeLigatureRun(GlyphCache* gc, const uint32_t* cps, int count, int style) {
    (void)gc; (void)cps; (void)count; (void)style;
    return NULL;
}

#endif // __linux__
