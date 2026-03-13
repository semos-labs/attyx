// Attyx — Windows ligature support (stub — DirectWrite shaping planned)
//
// DirectWrite can perform OpenType calt substitution via IDWriteTextAnalyzer.
// This file provides the ligature interface used by the renderer. Currently
// returns NULL for all sequences — same as the Linux stub.
// Can be upgraded to use IDWriteTextAnalyzer with DWRITE_FONT_FEATURE
// for full calt/liga shaping.

#ifdef _WIN32

#include "windows_internal.h"

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
// Stub: no DirectWrite shaping yet — returns NULL for all runs.
// ---------------------------------------------------------------------------

void ligatureCacheClear(void) {
    // No cache to clear yet.
}

const LigaResult* shapeLigatureRun(GlyphCache* gc, const uint32_t* cps, int count, int style) {
    (void)gc; (void)cps; (void)count; (void)style;
    return NULL;
}

#endif // _WIN32
