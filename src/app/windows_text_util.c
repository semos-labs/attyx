// Attyx — Windows text utilities
// URL detection (simple prefix matching) and word boundary helpers.
// Shared by mouse/input/hover subsystems.

#ifdef _WIN32

#include "windows_internal.h"

// ---------------------------------------------------------------------------
// URL detection — simple http:// / https:// prefix scan
// ---------------------------------------------------------------------------

static int isUrlBreakChar(uint32_t ch) {
    if (ch <= 32) return 1;
    return (ch == '"' || ch == '\'' || ch == '<' || ch == '>' ||
            ch == '(' || ch == ')' || ch == '[' || ch == ']' ||
            ch == '{' || ch == '}');
}

// Logical-line URL detection. Walks g_row_wrapped to treat wrapped rows as
// one continuous string and emits (startRow, startCol)→(endRow, endCol).
int detectUrlAtCell(int row, int col, int cols,
                    int *outStartRow, int *outStartCol,
                    int *outEndRow, int *outEndCol,
                    char *outUrl, int urlBufSize, int *outUrlLen) {
    if (!g_cells || cols <= 0 || col < 0 || col >= cols ||
        row < 0 || row >= g_rows) return 0;

    const int max_rows = 32;
    int startR = row;
    while (startR > 0 && row - startR < max_rows / 2 && g_row_wrapped[startR - 1]) startR--;
    int endR = row;
    while (endR + 1 < g_rows && endR - row < max_rows / 2 && g_row_wrapped[endR]) endR++;
    const int line_rows = endR - startR + 1;
    const int total = line_rows * cols;
    const int clickIdx = (row - startR) * cols + col;

    // Scan left from clickIdx to find a potential URL start.
    int scanStart = clickIdx;
    while (scanStart > 0) {
        int r = startR + scanStart / cols;
        int c = scanStart % cols;
        if (isUrlBreakChar(g_cells[r * cols + c].character)) break;
        scanStart--;
    }
    {
        int r = startR + scanStart / cols;
        int c = scanStart % cols;
        if (isUrlBreakChar(g_cells[r * cols + c].character) || scanStart < clickIdx) {
            // Step past the break / past where we started scanning.
            if (isUrlBreakChar(g_cells[r * cols + c].character)) scanStart++;
        }
    }

    // Check for http:// or https:// prefix at scanStart.
    static const char* prefixes[] = { "https://", "http://" };
    static const int prefix_lens[] = { 8, 7 };
    int matchedPrefix = -1;
    for (int p = 0; p < 2; p++) {
        const int plen = prefix_lens[p];
        if (scanStart + plen > total) continue;
        int match = 1;
        for (int i = 0; i < plen; i++) {
            int idx = scanStart + i;
            int r = startR + idx / cols;
            int c = idx % cols;
            if ((uint32_t)prefixes[p][i] != g_cells[r * cols + c].character) { match = 0; break; }
        }
        if (match) { matchedPrefix = p; break; }
    }
    if (matchedPrefix < 0) return 0;

    // Scan right to find URL end.
    int scanEnd = scanStart + prefix_lens[matchedPrefix];
    while (scanEnd < total) {
        int r = startR + scanEnd / cols;
        int c = scanEnd % cols;
        if (isUrlBreakChar(g_cells[r * cols + c].character)) break;
        scanEnd++;
    }
    scanEnd--; // last valid char

    while (scanEnd > scanStart) {
        int r = startR + scanEnd / cols;
        int c = scanEnd % cols;
        uint32_t ch = g_cells[r * cols + c].character;
        if (ch == '.' || ch == ',' || ch == ';' || ch == ':' || ch == '!')
            scanEnd--;
        else
            break;
    }

    if (clickIdx < scanStart || clickIdx > scanEnd) return 0;

    int pos = 0;
    for (int i = scanStart; i <= scanEnd && pos < urlBufSize - 1; i++) {
        int r = startR + i / cols;
        int c = i % cols;
        uint32_t ch = g_cells[r * cols + c].character;
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

    *outStartRow = startR + scanStart / cols;
    *outStartCol = scanStart % cols;
    *outEndRow = startR + scanEnd / cols;
    *outEndCol = scanEnd % cols;
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
