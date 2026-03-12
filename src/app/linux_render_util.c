// Attyx — Linux renderer utility functions
// GLSL shaders, GL helpers, emit helpers, UTF-8 encode, selection/URL/word-boundary helpers.

#include "linux_internal.h"

// ---------------------------------------------------------------------------
// GLSL shader sources (OpenGL 3.3 core — port of Metal shaders)
// ---------------------------------------------------------------------------

const char* kVertSrc =
    "#version 330 core\n"
    "layout(location = 0) in vec2 aPos;\n"
    "layout(location = 1) in vec2 aTexCoord;\n"
    "layout(location = 2) in vec4 aColor;\n"
    "uniform vec2 viewport;\n"
    "out vec2 vTexCoord;\n"
    "out vec4 vColor;\n"
    "void main() {\n"
    "    vec2 pos = aPos / viewport * 2.0 - 1.0;\n"
    "    pos.y = -pos.y;\n"
    "    gl_Position = vec4(pos, 0.0, 1.0);\n"
    "    vTexCoord = aTexCoord;\n"
    "    vColor = aColor;\n"
    "}\n";

const char* kFragSolidSrc =
    "#version 330 core\n"
    "in vec4 vColor;\n"
    "out vec4 fragColor;\n"
    "void main() {\n"
    "    fragColor = vColor;\n"
    "}\n";

const char* kFragTextSrc =
    "#version 330 core\n"
    "in vec2 vTexCoord;\n"
    "in vec4 vColor;\n"
    "uniform sampler2D tex;\n"
    "out vec4 fragColor;\n"
    "void main() {\n"
    "    float a = texture(tex, vTexCoord).r;\n"
    "    fragColor = vec4(vColor.rgb, vColor.a * a);\n"
    "}\n";

const char* kFragColorTextSrc =
    "#version 330 core\n"
    "in vec2 vTexCoord;\n"
    "in vec4 vColor;\n"
    "uniform sampler2D tex;\n"
    "out vec4 fragColor;\n"
    "void main() {\n"
    "    vec4 c = texture(tex, vTexCoord);\n"
    // Premultiplied RGBA; scale by vertex alpha for window opacity.
    "    fragColor = vec4(c.rgb * vColor.a, c.a * vColor.a);\n"
    "}\n";

// ---------------------------------------------------------------------------
// GL helpers
// ---------------------------------------------------------------------------

GLuint compileShader(GLenum type, const char* src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char gl_log[512];
        glGetShaderInfoLog(s, sizeof(gl_log), NULL, gl_log);
        ATTYX_LOG_ERR("render", "shader error: %s", gl_log);
    }
    return s;
}

GLuint createProgram(const char* vertSrc, const char* fragSrc) {
    GLuint vs = compileShader(GL_VERTEX_SHADER, vertSrc);
    GLuint fs = compileShader(GL_FRAGMENT_SHADER, fragSrc);
    GLuint prog = glCreateProgram();
    glAttachShader(prog, vs);
    glAttachShader(prog, fs);
    glLinkProgram(prog);
    GLint ok;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok) {
        char gl_log[512];
        glGetProgramInfoLog(prog, sizeof(gl_log), NULL, gl_log);
        ATTYX_LOG_ERR("render", "link error: %s", gl_log);
    }
    glDeleteShader(vs);
    glDeleteShader(fs);
    return prog;
}

void setupVertexAttribs(void) {
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, sizeof(Vertex),
                          (void*)offsetof(Vertex, px));
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, sizeof(Vertex),
                          (void*)offsetof(Vertex, u));
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(2, 4, GL_FLOAT, GL_FALSE, sizeof(Vertex),
                          (void*)offsetof(Vertex, r));
    glEnableVertexAttribArray(2);
}

// ---------------------------------------------------------------------------
// UTF-8 encode helper
// ---------------------------------------------------------------------------

int utf8Encode(uint32_t cp, uint8_t* buf) {
    if (cp < 0x80)    { buf[0] = (uint8_t)cp; return 1; }
    if (cp < 0x800)   { buf[0] = 0xC0|(cp>>6); buf[1] = 0x80|(cp&0x3F); return 2; }
    if (cp < 0x10000) { buf[0] = 0xE0|(cp>>12); buf[1] = 0x80|((cp>>6)&0x3F); buf[2] = 0x80|(cp&0x3F); return 3; }
    if (cp < 0x110000){ buf[0] = 0xF0|(cp>>18); buf[1] = 0x80|((cp>>12)&0x3F); buf[2] = 0x80|((cp>>6)&0x3F); buf[3] = 0x80|(cp&0x3F); return 4; }
    return 0;
}

// ---------------------------------------------------------------------------
// Vertex emit helpers
// ---------------------------------------------------------------------------

int emitRect(Vertex* v, int i, float x, float y, float w, float h,
             float r, float g, float b, float a) {
    v[i+0] = (Vertex){ x,   y,   0,0, r,g,b,a };
    v[i+1] = (Vertex){ x+w, y,   0,0, r,g,b,a };
    v[i+2] = (Vertex){ x,   y+h, 0,0, r,g,b,a };
    v[i+3] = (Vertex){ x+w, y,   0,0, r,g,b,a };
    v[i+4] = (Vertex){ x+w, y+h, 0,0, r,g,b,a };
    v[i+5] = (Vertex){ x,   y+h, 0,0, r,g,b,a };
    return i + 6;
}

int emitTri(Vertex* v, int i,
            float x0, float y0, float x1, float y1, float x2, float y2,
            float r, float g, float b, float a) {
    v[i+0] = (Vertex){ x0,y0, 0,0, r,g,b,a };
    v[i+1] = (Vertex){ x1,y1, 0,0, r,g,b,a };
    v[i+2] = (Vertex){ x2,y2, 0,0, r,g,b,a };
    return i + 3;
}

int emitGlyph(Vertex* v, int i, GlyphCache* gc, uint32_t cp,
              float x, float y, float gw, float gh,
              float r, float g, float b) {
    int slot = glyphCacheLookup(gc, cp);
    if (slot < 0) slot = glyphCacheRasterize(gc, cp);
    float aW = (float)gc->atlas_w, aH = (float)gc->atlas_h;
    float gW = gc->glyph_w, gH = gc->glyph_h;
    int ac = slot % gc->atlas_cols, ar = slot / gc->atlas_cols;
    float u0 = ac * gW / aW, u1 = (ac+1) * gW / aW;
    float v0 = ar * gH / aH, v1 = (ar+1) * gH / aH;
    v[i+0] = (Vertex){ x,    y,    u0,v0, r,g,b,1 };
    v[i+1] = (Vertex){ x+gw, y,    u1,v0, r,g,b,1 };
    v[i+2] = (Vertex){ x,    y+gh, u0,v1, r,g,b,1 };
    v[i+3] = (Vertex){ x+gw, y,    u1,v0, r,g,b,1 };
    v[i+4] = (Vertex){ x+gw, y+gh, u1,v1, r,g,b,1 };
    v[i+5] = (Vertex){ x,    y+gh, u0,v1, r,g,b,1 };
    return i + 6;
}

int emitString(Vertex* v, int i, GlyphCache* gc,
               const char* str, int len, float x, float y,
               float gw, float gh, float r, float g, float b) {
    for (int c = 0; c < len; c++) {
        uint32_t cp = (uint8_t)str[c];
        if (cp <= 32) continue;
        i = emitGlyph(v, i, gc, cp, x + c * gw, y, gw, gh, r, g, b);
    }
    return i;
}

// ---------------------------------------------------------------------------
// Selection helpers
// ---------------------------------------------------------------------------

int cellIsSelected(int row, int col) {
    if (!g_sel_active) return 0;
    // With splits, clip selection to focused pane rect
    if ((g_copy_mode || g_split_active) && g_pane_rect_rows > 0) {
        int pr = g_pane_rect_row, pc = g_pane_rect_col;
        if (row < pr || row >= pr + g_pane_rect_rows || col < pc || col >= pc + g_pane_rect_cols) return 0;
    }
    int sr = g_sel_start_row, sc = g_sel_start_col;
    int er = g_sel_end_row, ec = g_sel_end_col;
    if (g_sel_block) {
        int minR = sr < er ? sr : er, maxR = sr > er ? sr : er;
        int minC = sc < ec ? sc : ec, maxC = sc > ec ? sc : ec;
        return row >= minR && row <= maxR && col >= minC && col <= maxC;
    }
    if (sr > er || (sr == er && sc > ec)) {
        int tr = sr, tc = sc; sr = er; sc = ec; er = tr; ec = tc;
    }
    if (row < sr || row > er) return 0;
    if (row == sr && row == er) return col >= sc && col <= ec;
    if (row == sr) return col >= sc;
    if (row == er) return col <= ec;
    return 1;
}

// ---------------------------------------------------------------------------
// URL detection helpers
// ---------------------------------------------------------------------------

static int isUrlChar(uint32_t ch) {
    if (ch <= 32 || ch == 127) return 0;
    if (ch == '<' || ch == '>' || ch == '"' || ch == '`') return 0;
    if (ch == '{' || ch == '}') return 0;
    return 1;
}

static int isTrailingPunct(uint32_t ch) {
    return (ch == '.' || ch == ',' || ch == ';' || ch == ':' ||
            ch == '!' || ch == '?' || ch == '\'' || ch == '"' ||
            ch == ')' || ch == ']' || ch == '>');
}

int detectUrlAtCell(int row, int col, int cols,
                    int *outStart, int *outEnd,
                    char *outUrl, int urlBufSize, int *outUrlLen) {
    if (!g_cells || cols <= 0) return 0;
    int base = row * cols;

    char rowText[1024];
    int len = cols < 1023 ? cols : 1023;
    for (int i = 0; i < len; i++) {
        uint32_t ch = g_cells[base + i].character;
        rowText[i] = (ch >= 32 && ch < 127) ? (char)ch : ' ';
    }
    rowText[len] = '\0';

    const char *schemes[] = { "https://", "http://" };
    const int schemeLens[] = { 8, 7 };

    for (int s = 0; s < 2; s++) {
        const char *haystack = rowText;
        while (1) {
            const char *found = strstr(haystack, schemes[s]);
            if (!found) break;
            int startCol = (int)(found - rowText);
            int endCol = startCol + schemeLens[s];

            while (endCol < len && isUrlChar(g_cells[base + endCol].character))
                endCol++;
            endCol--;

            while (endCol > startCol + schemeLens[s] && isTrailingPunct(g_cells[base + endCol].character))
                endCol--;

            {
                int opens = 0, closes = 0;
                for (int i = startCol; i <= endCol; i++) {
                    uint32_t ch = g_cells[base + i].character;
                    if (ch == '(') opens++;
                    if (ch == ')') closes++;
                }
                while (opens > closes && endCol + 1 < len && g_cells[base + endCol + 1].character == ')') {
                    endCol++;
                    closes++;
                }
            }

            if (col >= startCol && col <= endCol) {
                *outStart = startCol;
                *outEnd = endCol;
                int urlLen = endCol - startCol + 1;
                if (urlLen >= urlBufSize) urlLen = urlBufSize - 1;
                for (int i = 0; i < urlLen; i++) {
                    uint32_t ch = g_cells[base + startCol + i].character;
                    outUrl[i] = (ch >= 32 && ch < 127) ? (char)ch : '?';
                }
                outUrl[urlLen] = '\0';
                *outUrlLen = urlLen;
                return 1;
            }
            haystack = found + 1;
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Word boundary helpers for double-click selection
// ---------------------------------------------------------------------------

static int isWordChar(uint32_t ch) {
    if (ch == 0 || ch == ' ') return 0;
    if (ch == '_' || ch == '-') return 1;
    if (ch > 127) return 1;
    if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
        (ch >= '0' && ch <= '9')) return 1;
    return 0;
}

void findWordBounds(int row, int col, int cols, int* outStart, int* outEnd) {
    if (!g_cells || cols <= 0) { *outStart = col; *outEnd = col; return; }
    int base = row * cols;
    uint32_t ch = g_cells[base + col].character;
    int target = isWordChar(ch);

    int start = col;
    while (start > 0 && isWordChar(g_cells[base + start - 1].character) == target)
        start--;
    int end = col;
    while (end < cols - 1 && isWordChar(g_cells[base + end + 1].character) == target)
        end++;

    *outStart = start;
    *outEnd = end;
}
