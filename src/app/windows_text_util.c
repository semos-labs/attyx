// Attyx — Windows text utilities
// URL detection (simple prefix matching) and word boundary helpers.
// Shared by mouse/input/hover subsystems.

#ifdef _WIN32

#include "windows_internal.h"

// ---------------------------------------------------------------------------
// URL detection — simple http:// / https:// prefix scan
// ---------------------------------------------------------------------------

int detectUrlAtCell(int row, int col, int cols,
                    int *outStart, int *outEnd,
                    char *outUrl, int urlBufSize, int *outUrlLen) {
    if (!g_cells || cols <= 0 || col < 0 || col >= cols) return 0;
    int base = row * cols;

    // Scan left from col to find a potential URL start.
    int scanStart = col;
    int maxScanBack = (col > 2048) ? col - 2048 : 0;
    while (scanStart > maxScanBack) {
        uint32_t ch = g_cells[base + scanStart].character;
        if (ch <= 32 || ch == '"' || ch == '\'' || ch == '<' || ch == '>' ||
            ch == '(' || ch == ')' || ch == '[' || ch == ']' || ch == '{' || ch == '}')
            break;
        scanStart--;
    }
    if (g_cells[base + scanStart].character <= 32 || scanStart < col)
        scanStart++;

    // Check for http:// or https:// prefix at scanStart
    static const char* prefixes[] = { "https://", "http://" };
    static const int prefix_lens[] = { 8, 7 };
    int matchedPrefix = -1;
    for (int p = 0; p < 2; p++) {
        int plen = prefix_lens[p];
        if (scanStart + plen > cols) continue;
        int match = 1;
        for (int i = 0; i < plen; i++) {
            if ((uint32_t)prefixes[p][i] != g_cells[base + scanStart + i].character) {
                match = 0;
                break;
            }
        }
        if (match) { matchedPrefix = p; break; }
    }
    if (matchedPrefix < 0) return 0;

    // Scan right to find URL end (stop at whitespace, quotes, brackets)
    int scanEnd = scanStart + prefix_lens[matchedPrefix];
    while (scanEnd < cols) {
        uint32_t ch = g_cells[base + scanEnd].character;
        if (ch <= 32 || ch == '"' || ch == '\'' || ch == '<' || ch == '>' ||
            ch == '(' || ch == ')' || ch == '[' || ch == ']' || ch == '{' || ch == '}')
            break;
        scanEnd++;
    }
    scanEnd--; // last valid char

    // Strip trailing punctuation
    while (scanEnd > scanStart) {
        uint32_t ch = g_cells[base + scanEnd].character;
        if (ch == '.' || ch == ',' || ch == ';' || ch == ':' || ch == '!')
            scanEnd--;
        else
            break;
    }

    if (col < scanStart || col > scanEnd) return 0;

    // Build UTF-8 URL string
    int pos = 0;
    for (int i = scanStart; i <= scanEnd && pos < urlBufSize - 1; i++) {
        uint32_t ch = g_cells[base + i].character;
        if (ch < 0x80) {
            outUrl[pos++] = (char)ch;
        } else if (ch < 0x800 && pos + 1 < urlBufSize) {
            outUrl[pos++] = (char)(0xC0 | (ch >> 6));
            outUrl[pos++] = (char)(0x80 | (ch & 0x3F));
        } else if (ch < 0x10000 && pos + 2 < urlBufSize) {
            outUrl[pos++] = (char)(0xE0 | (ch >> 12));
            outUrl[pos++] = (char)(0x80 | ((ch >> 6) & 0x3F));
            outUrl[pos++] = (char)(0x80 | (ch & 0x3F));
        } else if (ch <= 0x10FFFF && pos + 3 < urlBufSize) {
            outUrl[pos++] = (char)(0xF0 | (ch >> 18));
            outUrl[pos++] = (char)(0x80 | ((ch >> 12) & 0x3F));
            outUrl[pos++] = (char)(0x80 | ((ch >> 6) & 0x3F));
            outUrl[pos++] = (char)(0x80 | (ch & 0x3F));
        }
    }
    outUrl[pos] = 0;

    *outStart = scanStart;
    *outEnd = scanEnd;
    *outUrlLen = pos;
    return 1;
}

// ---------------------------------------------------------------------------
// Word boundary helper (shared with mouse/input)
// ---------------------------------------------------------------------------

static int isWordCharPlatform(uint32_t ch) {
    if (ch == 0 || ch == ' ') return 0;
    if (ch == '_' || ch == '-') return 1;
    if (ch > 127) return 1;
    if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
        (ch >= '0' && ch <= '9')) return 1;
    return 0;
}

void findWordBounds(int row, int col, int cols, int *outStart, int *outEnd) {
    if (!g_cells || cols <= 0) { *outStart = col; *outEnd = col; return; }
    int base = row * cols;
    uint32_t ch = g_cells[base + col].character;
    int target = isWordCharPlatform(ch);
    int start = col;
    while (start > 0 && isWordCharPlatform(g_cells[base + start - 1].character) == target)
        start--;
    int end = col;
    while (end < cols - 1 && isWordCharPlatform(g_cells[base + end + 1].character) == target)
        end++;
    *outStart = start;
    *outEnd = end;
}

#endif // _WIN32
