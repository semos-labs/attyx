// Attyx — Windows renderer utility functions
// Vertex emit helpers, selection/URL/word boundary, color conversion.
// Shared between windows_renderer.c, windows_overlay.c, windows_popup.c.

#ifdef _WIN32

#include "windows_internal.h"

// ---------------------------------------------------------------------------
// HLSL shader sources (inline strings — compiled at runtime via D3DCompile)
// ---------------------------------------------------------------------------

const char* kHlslVertSrc =
    "cbuffer CB : register(b0) { float2 viewport; };\n"
    "struct VS_IN  { float2 pos : POSITION; float2 uv : TEXCOORD; float4 col : COLOR; };\n"
    "struct VS_OUT { float4 pos : SV_POSITION; float2 uv : TEXCOORD; float4 col : COLOR; };\n"
    "VS_OUT main(VS_IN i) {\n"
    "    VS_OUT o;\n"
    "    float2 ndc = i.pos / viewport * 2.0 - 1.0;\n"
    "    ndc.y = -ndc.y;\n"
    "    o.pos = float4(ndc, 0.0, 1.0);\n"
    "    o.uv  = i.uv;\n"
    "    o.col = i.col;\n"
    "    return o;\n"
    "}\n";

const char* kHlslPixelSolidSrc =
    "struct PS_IN { float4 pos : SV_POSITION; float2 uv : TEXCOORD; float4 col : COLOR; };\n"
    "float4 main(PS_IN i) : SV_TARGET {\n"
    "    return i.col;\n"
    "}\n";

const char* kHlslPixelTextSrc =
    "Texture2D    tex : register(t0);\n"
    "SamplerState smp : register(s0);\n"
    "struct PS_IN { float4 pos : SV_POSITION; float2 uv : TEXCOORD; float4 col : COLOR; };\n"
    "float4 main(PS_IN i) : SV_TARGET {\n"
    "    float a = tex.Sample(smp, i.uv).r;\n"
    "    return float4(i.col.rgb, i.col.a * a);\n"
    "}\n";

// ---------------------------------------------------------------------------
// Vertex emit helpers
// ---------------------------------------------------------------------------

int winEmitRect(WinVertex* v, int i, float x, float y, float w, float h,
                float r, float g, float b, float a) {
    v[i+0] = (WinVertex){ x,   y,   0,0, r,g,b,a };
    v[i+1] = (WinVertex){ x+w, y,   0,0, r,g,b,a };
    v[i+2] = (WinVertex){ x,   y+h, 0,0, r,g,b,a };
    v[i+3] = (WinVertex){ x+w, y,   0,0, r,g,b,a };
    v[i+4] = (WinVertex){ x+w, y+h, 0,0, r,g,b,a };
    v[i+5] = (WinVertex){ x,   y+h, 0,0, r,g,b,a };
    return i + 6;
}

int winEmitQuad(WinVertex* v, int i,
                float x0, float y0, float x1, float y1,
                float u0, float v0, float u1, float v1,
                float r, float g, float b, float a) {
    v[i+0] = (WinVertex){ x0, y0, u0,v0, r,g,b,a };
    v[i+1] = (WinVertex){ x1, y0, u1,v0, r,g,b,a };
    v[i+2] = (WinVertex){ x0, y1, u0,v1, r,g,b,a };
    v[i+3] = (WinVertex){ x1, y0, u1,v0, r,g,b,a };
    v[i+4] = (WinVertex){ x1, y1, u1,v1, r,g,b,a };
    v[i+5] = (WinVertex){ x0, y1, u0,v1, r,g,b,a };
    return i + 6;
}

// ---------------------------------------------------------------------------
// Selection helpers
// ---------------------------------------------------------------------------

int winCellIsSelected(int row, int col) {
    if (!g_sel_active) return 0;
    if ((g_copy_mode || g_split_active) && g_pane_rect_rows > 0) {
        int pr = g_pane_rect_row, pc = g_pane_rect_col;
        if (row < pr || row >= pr + g_pane_rect_rows ||
            col < pc || col >= pc + g_pane_rect_cols) return 0;
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
// Grid-to-screen coordinate helpers
// ---------------------------------------------------------------------------

float winGridToScreenX(float offX, float gw, int col) {
    return offX + col * gw;
}

float winGridToScreenY(float offY, float gh, int row) {
    return offY + row * gh;
}

// ---------------------------------------------------------------------------
// Color conversion (bridge cell color to float RGBA)
// ---------------------------------------------------------------------------

void winCellBgColor(const AttyxCell* cell, int row, int col,
                    float* r, float* g, float* b, float* a) {
    if (winCellIsSelected(row, col)) {
        if (g_theme_sel_bg_set) {
            *r = g_theme_sel_bg_r / 255.0f;
            *g = g_theme_sel_bg_g / 255.0f;
            *b = g_theme_sel_bg_b / 255.0f;
        } else {
            *r = 0.20f; *g = 0.40f; *b = 0.70f;
        }
        *a = 1.0f;
    } else {
        *r = cell->bg_r / 255.0f;
        *g = cell->bg_g / 255.0f;
        *b = cell->bg_b / 255.0f;
        *a = (cell->flags & 4) ? g_background_opacity : 1.0f;
    }
}

void winCellFgColor(const AttyxCell* cell, int row, int col,
                    int drawCursor, int curRow, int curCol, int curShape,
                    float* r, float* g, float* b) {
    if (g_theme_sel_fg_set && winCellIsSelected(row, col)) {
        *r = g_theme_sel_fg_r / 255.0f;
        *g = g_theme_sel_fg_g / 255.0f;
        *b = g_theme_sel_fg_b / 255.0f;
    } else if (drawCursor && row == curRow && col == curCol &&
               (curShape == 0 || curShape == 1)) {
        *r = cell->bg_r / 255.0f;
        *g = cell->bg_g / 255.0f;
        *b = cell->bg_b / 255.0f;
    } else {
        *r = cell->fg_r / 255.0f;
        *g = cell->fg_g / 255.0f;
        *b = cell->fg_b / 255.0f;
    }
}

void winCursorColor(float* r, float* g, float* b) {
    if (g_theme_cursor_r >= 0) {
        *r = g_theme_cursor_r / 255.0f;
        *g = g_theme_cursor_g / 255.0f;
        *b = g_theme_cursor_b / 255.0f;
    } else {
        *r = 0.86f; *g = 0.86f; *b = 0.86f;
    }
}

#endif // _WIN32
