// Attyx — Linux renderer (OpenGL 3.3 core): state, init/cleanup, drawFrame.
// GL/emit/selection/URL helpers live in linux_render_util.c

#include "linux_internal.h"

// ---------------------------------------------------------------------------
// Renderer state
// ---------------------------------------------------------------------------

GlyphCache   g_gc;
GLuint       g_solid_prog, g_text_prog;
GLint        g_vp_loc_solid, g_vp_loc_text, g_tex_loc;
GLuint       g_vao, g_vbo;
static GLuint       g_color_prog = 0;
static GLuint       g_color_vao  = 0;
static GLuint       g_color_vbo  = 0;
static Vertex*      g_bg_verts = NULL;
static Vertex*      g_text_verts = NULL;
static int          g_total_text_verts = 0;
static Vertex*      g_color_verts = NULL;
static int          g_total_color_verts = 0;
static AttyxCell*   g_cell_snapshot = NULL;
static int          g_cell_snapshot_cap = 0;

static int          g_prev_cursor_row = -1;
static int          g_prev_cursor_col = -1;
static int          g_prev_cursor_shape = -1;
static int          g_prev_cursor_vis = -1;
static int          g_blink_on = 1;
static double       g_blink_last_toggle = 0.0;
static float        g_trail_x = 0, g_trail_y = 0;
static int          g_trail_active = 0;
static double       g_trail_last_time = 0.0;
int                 g_full_redraw = 1;
static int          g_alloc_rows = 0;
static int          g_alloc_cols = 0;
static int          g_bg_vert_cap = 0;

float        g_cell_px_w = 0;
float        g_cell_px_h = 0;
float        g_content_scale = 1.0f;
volatile float g_cell_w_pts = 0;
volatile float g_cell_h_pts = 0;

// ---------------------------------------------------------------------------
// Renderer init / cleanup
// ---------------------------------------------------------------------------

void linux_renderer_init(void) {
    g_solid_prog = createProgram(kVertSrc, kFragSolidSrc);
    g_text_prog  = createProgram(kVertSrc, kFragTextSrc);
    g_vp_loc_solid = glGetUniformLocation(g_solid_prog, "viewport");
    g_vp_loc_text  = glGetUniformLocation(g_text_prog, "viewport");
    g_tex_loc      = glGetUniformLocation(g_text_prog, "tex");

    glGenVertexArrays(1, &g_vao);
    glGenBuffers(1, &g_vbo);

    // Color emoji program: premultiplied-alpha RGBA texture
    g_color_prog = createProgram(kVertSrc, kFragColorTextSrc);
    glGenVertexArrays(1, &g_color_vao);
    glGenBuffers(1, &g_color_vbo);
}

void linux_renderer_cleanup(void) {
    free(g_bg_verts);    g_bg_verts = NULL;
    free(g_text_verts);  g_text_verts = NULL;
    free(g_color_verts); g_color_verts = NULL;
    free(g_cell_snapshot); g_cell_snapshot = NULL;
    glDeleteBuffers(1, &g_vbo);
    glDeleteVertexArrays(1, &g_vao);
    glDeleteBuffers(1, &g_color_vbo);
    glDeleteVertexArrays(1, &g_color_vao);
    glDeleteProgram(g_solid_prog);
    glDeleteProgram(g_text_prog);
    glDeleteProgram(g_color_prog);
    glDeleteTextures(1, &g_gc.texture);
    glDeleteTextures(1, &g_gc.color_texture);
}

// ---------------------------------------------------------------------------
// Font rebuild (called from main loop when g_needs_font_rebuild is set)
// ---------------------------------------------------------------------------
void linux_rebuild_font(void) {
    // Capture ft_lib before overwriting g_gc.
    FT_Library ft_lib = g_gc.ft_lib;
    glDeleteTextures(1, &g_gc.texture);
    FT_Done_Face(g_gc.ft_face);

    g_gc = createGlyphCache(ft_lib, g_content_scale);
    g_cell_px_w = g_gc.glyph_w;
    g_cell_px_h = g_gc.glyph_h;
    g_cell_w_pts = g_cell_px_w / g_content_scale;
    g_cell_h_pts = g_cell_px_h / g_content_scale;

    // Snap window to new cell dimensions (logical pixels, not framebuffer).
    int newW = (int)(g_cols * g_cell_px_w / g_content_scale) + g_padding_left + g_padding_right;
    int newH = (int)(g_rows * g_cell_px_h / g_content_scale) + g_padding_top  + g_padding_bottom;
    glfwSetWindowSize(g_window, newW, newH);

    g_full_redraw = 1;
}

// ---------------------------------------------------------------------------
// Draw frame (main render loop body)
// ---------------------------------------------------------------------------
int drawFrame(void) {
    if (!g_cells || g_cols <= 0 || g_rows <= 0) return 0;

    uint64_t gen1 = g_cell_gen;
    if (gen1 & 1) return 0;

    int rows = g_rows;
    int cols = g_cols;
    int total = cols * rows;

    uint64_t dirty[4];
    for (int i = 0; i < 4; i++)
        dirty[i] = __sync_lock_test_and_set((volatile uint64_t*)&g_dirty[i], 0);

    int curRow = g_cursor_row;
    int curCol = g_cursor_col;
    int curShape = g_cursor_shape;
    int curVis = g_cursor_visible;

    int cursorChanged = (curRow != g_prev_cursor_row || curCol != g_prev_cursor_col
                         || curShape != g_prev_cursor_shape || curVis != g_prev_cursor_vis);

    int isBlinking = curVis && (curShape == 0 || curShape == 2 || curShape == 4);
    double now = glfwGetTime();
    if (cursorChanged) {
        g_blink_on = 1;
        g_blink_last_toggle = now;
    } else if (isBlinking) {
        if (now - g_blink_last_toggle >= 0.5) {
            g_blink_on = !g_blink_on;
            g_blink_last_toggle = now;
        }
    } else {
        g_blink_on = 1;
    }

    // Reallocate persistent buffers if grid size changed
    if (rows != g_alloc_rows || cols != g_alloc_cols) {
        free(g_bg_verts);
        free(g_text_verts);
        free(g_color_verts);
        free(g_cell_snapshot);

        g_bg_vert_cap = (total * 4 + cols + cols + ATTYX_SEARCH_VIS_MAX) * 6;
        g_bg_verts      = (Vertex*)calloc(g_bg_vert_cap, sizeof(Vertex));
        g_text_verts    = (Vertex*)calloc(total * 6, sizeof(Vertex));
        g_color_verts   = (Vertex*)calloc(total * 6, sizeof(Vertex));
        g_cell_snapshot = (AttyxCell*)malloc(sizeof(AttyxCell) * total);
        g_cell_snapshot_cap = total;
        g_total_text_verts  = 0;
        g_total_color_verts = 0;
        g_alloc_rows = rows;
        g_alloc_cols = cols;
        g_full_redraw = 1;
    }

    static uint32_t lastOverlayGen = 0;
    static uint32_t lastPopupGen = 0;
    int overlayChanged = (g_overlay_gen != lastOverlayGen);
    int popupChanged = (g_popup_gen != lastPopupGen);
    // Title updates must be checked before the early-return so they aren't
    // skipped when the grid is idle (no dirty rows / cursor changes).
    if (g_title_changed && g_window) {
        int tlen = g_title_len;
        if (tlen > 0 && tlen < ATTYX_TITLE_MAX) {
            char tbuf[ATTYX_TITLE_MAX];
            memcpy(tbuf, g_title_buf, tlen);
            tbuf[tlen] = 0;
            glfwSetWindowTitle(g_window, tbuf);
        }
        g_title_changed = 0;
    }

    if (!g_full_redraw && !dirtyAny(dirty) && !cursorChanged && !isBlinking && !g_search_active && !g_ctx_menu_open && !g_trail_active && !g_popup_trail_active && !overlayChanged && !popupChanged) return 0;

    if (g_cell_snapshot && g_cell_snapshot_cap >= total)
        memcpy(g_cell_snapshot, g_cells, sizeof(AttyxCell) * total);
    else
        return 0;

    uint64_t gen2 = g_cell_gen;
    if (gen1 != gen2) return 0;

    AttyxCell* cells = g_cell_snapshot;
    float gw = g_gc.glyph_w;
    float gh = g_gc.glyph_h;
    int fb_w, fb_h;
    glfwGetFramebufferSize(g_window, &fb_w, &fb_h);
    float sc = g_content_scale;
    float padL = g_padding_left   * sc;
    float padR = g_padding_right  * sc;
    float padT = g_padding_top    * sc;
    float padB = g_padding_bottom * sc;
    float availW = (float)fb_w - padL - padR;
    float availH = (float)fb_h - padT - padB;
    float cx = floorf((availW - cols * gw) * 0.5f);
    float cy = 0;
    if (cx < 0) cx = 0;
    if (cy < 0) cy = 0;
    float offX = padL + cx;
    float baseOffY = padT + cy;
    float offY = baseOffY + g_grid_top_offset * gh;
    float viewport[2] = { (float)fb_w, (float)fb_h };
    float atlasW = (float)g_gc.atlas_w;
    float glyphW = g_gc.glyph_w;
    float glyphH = g_gc.glyph_h;
    int atlasCols = g_gc.atlas_cols;
    int visibleRows = rows - g_grid_top_offset - g_grid_bottom_offset;
    if (visibleRows < 0) visibleRows = 0;
    int visibleTotal = visibleRows * cols;

    // Update bg vertices for dirty rows
    for (int row = 0; row < visibleRows; row++) {
        if (!g_full_redraw && !dirtyBitTest(dirty, row)) continue;
        for (int col = 0; col < cols; col++) {
            int i = row * cols + col;
            float x0 = offX + col * gw, y0 = offY + row * gh;
            float x1 = x0 + gw, y1 = y0 + gh;
            const AttyxCell* cell = &cells[i];
            float br, bg, bb, ba;
            if (cellIsSelected(row, col)) {
                if (g_theme_sel_bg_set) {
                    br = g_theme_sel_bg_r / 255.0f;
                    bg = g_theme_sel_bg_g / 255.0f;
                    bb = g_theme_sel_bg_b / 255.0f;
                } else {
                    br = 0.20f; bg = 0.40f; bb = 0.70f;
                }
                ba = 1.0f;
            } else {
                br = cell->bg_r / 255.0f;
                bg = cell->bg_g / 255.0f;
                bb = cell->bg_b / 255.0f;
                ba = (cell->flags & 4) ? g_background_opacity : 1.0f;
            }
            int bi = i * 6;
            g_bg_verts[bi+0] = (Vertex){ x0,y0, 0,0, br,bg,bb,ba };
            g_bg_verts[bi+1] = (Vertex){ x1,y0, 0,0, br,bg,bb,ba };
            g_bg_verts[bi+2] = (Vertex){ x0,y1, 0,0, br,bg,bb,ba };
            g_bg_verts[bi+3] = (Vertex){ x1,y0, 0,0, br,bg,bb,ba };
            g_bg_verts[bi+4] = (Vertex){ x1,y1, 0,0, br,bg,bb,ba };
            g_bg_verts[bi+5] = (Vertex){ x0,y1, 0,0, br,bg,bb,ba };
        }
    }

    // Zero out stale BG vertices for hidden rows (below visibleRows)
    if (visibleTotal < total) {
        memset(&g_bg_verts[visibleTotal * 6], 0, sizeof(Vertex) * 6 * (total - visibleTotal));
    }

    // Cursor quad (shape-aware)
    int cursorSlot = total * 6;
    memset(&g_bg_verts[cursorSlot], 0, sizeof(Vertex) * 6);
    int bgVertCount = total * 6;
    int drawCursor = curVis && g_blink_on
                     && curRow >= g_grid_top_offset && curRow < (g_grid_top_offset + visibleRows) && curCol >= 0 && curCol < cols;
    if (drawCursor) {
        float cx0 = offX + curCol * gw, cy0 = baseOffY + curRow * gh;
        float cr, cg_c, cb;
        if (g_theme_cursor_r >= 0) {
            cr = g_theme_cursor_r / 255.0f;
            cg_c = g_theme_cursor_g / 255.0f;
            cb = g_theme_cursor_b / 255.0f;
        } else {
            cr = 0.86f; cg_c = 0.86f; cb = 0.86f;
        }
        float rx0 = cx0, ry0 = cy0, rx1 = cx0 + gw, ry1 = cy0 + gh;

        switch (curShape) {
            case 0: case 1: break; // block
            case 2: case 3: { // underline
                float th = fmaxf(2.0f, 1.0f);
                ry0 = ry1 - th;
                break;
            }
            case 4: case 5: { // bar
                float th = fmaxf(2.0f, 1.0f);
                rx1 = rx0 + th;
                break;
            }
            default: break;
        }

        g_bg_verts[cursorSlot+0] = (Vertex){ rx0,ry0, 0,0, cr,cg_c,cb,1 };
        g_bg_verts[cursorSlot+1] = (Vertex){ rx1,ry0, 0,0, cr,cg_c,cb,1 };
        g_bg_verts[cursorSlot+2] = (Vertex){ rx0,ry1, 0,0, cr,cg_c,cb,1 };
        g_bg_verts[cursorSlot+3] = (Vertex){ rx1,ry0, 0,0, cr,cg_c,cb,1 };
        g_bg_verts[cursorSlot+4] = (Vertex){ rx1,ry1, 0,0, cr,cg_c,cb,1 };
        g_bg_verts[cursorSlot+5] = (Vertex){ rx0,ry1, 0,0, cr,cg_c,cb,1 };
        bgVertCount += 6;
    }

    // Cursor trail effect (Neovide-style: stretched comet tail)
    if (g_cursor_trail && g_cursor_visible && cursorChanged && g_prev_cursor_row >= 0) {
        int cellDist = abs(curRow - g_prev_cursor_row) + abs(curCol - g_prev_cursor_col);
        if (cellDist > 1) {
            g_trail_x = offX + g_prev_cursor_col * gw;
            g_trail_y = baseOffY + g_prev_cursor_row * gh;
            g_trail_active = 1;
            g_trail_last_time = now;
        }
    }
    if (g_trail_active && !g_cursor_visible) g_trail_active = 0;
    if (g_trail_active && g_cursor_trail && g_cursor_visible) {
        float targetX = offX + curCol * gw;
        float targetY = baseOffY + curRow * gh;
        float dt = (float)(now - g_trail_last_time);
        g_trail_last_time = now;
        float speed = 14.0f;
        float t = 1.0f - expf(-speed * dt);
        g_trail_x += (targetX - g_trail_x) * t;
        g_trail_y += (targetY - g_trail_y) * t;
        float dx = targetX - g_trail_x;
        float dy = targetY - g_trail_y;
        float dist = sqrtf(dx * dx + dy * dy);
        if (dist < 0.5f) {
            g_trail_active = 0;
        } else {
            float cr_t, cg_t, cb_t;
            if (g_theme_cursor_r >= 0) {
                cr_t = g_theme_cursor_r / 255.0f;
                cg_t = g_theme_cursor_g / 255.0f;
                cb_t = g_theme_cursor_b / 255.0f;
            } else {
                cr_t = 0.86f; cg_t = 0.86f; cb_t = 0.86f;
            }

            float alpha = 1.0f;

            // Cursor shape dimensions for the trail cross-axis
            float cw = gw, ch = gh;   // block (cases 0,1)
            float cyOff = 0;          // y offset within cell
            float cxOff = 0;          // x offset within cell
            switch (curShape) {
                case 2: case 3: { // underline
                    float th = fmaxf(2.0f, 1.0f);
                    cyOff = gh - th;
                    ch = th;
                    break;
                }
                case 4: case 5: { // bar
                    cw = fmaxf(2.0f, 1.0f);
                    break;
                }
                default: break;
            }

            // Convex hull of cursor rect at trail pos and cursor pos (hexagon)
            float tx0 = g_trail_x + cxOff, ty0 = g_trail_y + cyOff;
            float tx1 = tx0 + cw,           ty1 = ty0 + ch;
            float cx0 = targetX + cxOff,     cy0 = targetY + cyOff;
            float cx1 = cx0 + cw,            cy1 = cy0 + ch;

            float hex[6][2];
            if (dx >= 0 && dy >= 0) {
                hex[0][0]=tx0; hex[0][1]=ty0; hex[1][0]=tx1; hex[1][1]=ty0;
                hex[2][0]=cx1; hex[2][1]=cy0; hex[3][0]=cx1; hex[3][1]=cy1;
                hex[4][0]=cx0; hex[4][1]=cy1; hex[5][0]=tx0; hex[5][1]=ty1;
            } else if (dx >= 0) {
                hex[0][0]=tx0; hex[0][1]=ty1; hex[1][0]=tx1; hex[1][1]=ty1;
                hex[2][0]=cx1; hex[2][1]=cy1; hex[3][0]=cx1; hex[3][1]=cy0;
                hex[4][0]=cx0; hex[4][1]=cy0; hex[5][0]=tx0; hex[5][1]=ty0;
            } else if (dy >= 0) {
                hex[0][0]=tx1; hex[0][1]=ty0; hex[1][0]=tx0; hex[1][1]=ty0;
                hex[2][0]=cx0; hex[2][1]=cy0; hex[3][0]=cx0; hex[3][1]=cy1;
                hex[4][0]=cx1; hex[4][1]=cy1; hex[5][0]=tx1; hex[5][1]=ty1;
            } else {
                hex[0][0]=tx1; hex[0][1]=ty1; hex[1][0]=tx0; hex[1][1]=ty1;
                hex[2][0]=cx0; hex[2][1]=cy1; hex[3][0]=cx0; hex[3][1]=cy0;
                hex[4][0]=cx1; hex[4][1]=cy0; hex[5][0]=tx1; hex[5][1]=ty0;
            }

            if (bgVertCount + 12 <= g_bg_vert_cap) {
                for (int ti = 0; ti < 4; ti++) {
                    g_bg_verts[bgVertCount++] = (Vertex){ hex[0][0],hex[0][1], 0,0, cr_t,cg_t,cb_t,alpha };
                    g_bg_verts[bgVertCount++] = (Vertex){ hex[ti+1][0],hex[ti+1][1], 0,0, cr_t,cg_t,cb_t,alpha };
                    g_bg_verts[bgVertCount++] = (Vertex){ hex[ti+2][0],hex[ti+2][1], 0,0, cr_t,cg_t,cb_t,alpha };
                }
            }
            g_full_redraw = 1;
        }
    }

    // Hyperlink underlines: OSC 8 (always visible) + detected URLs (on hover)
    if (!g_sel_active) {
        uint32_t hoverLid = g_hover_link_id;
        float ulH = fmaxf(2.0f, 1.0f);

        // OSC 8 links: always show underline
        for (int i = 0; i < visibleTotal; i++) {
            uint32_t lid = cells[i].link_id;
            if (lid == 0) continue;
            if (bgVertCount + 6 > g_bg_vert_cap) break;
            float lr, lg, lb;
            if (lid == hoverLid) {
                lr = 0.4f; lg = 0.7f; lb = 1.0f;
            } else {
                lr = 0.25f; lg = 0.40f; lb = 0.65f;
            }
            int lrow = i / cols, lcol = i % cols;
            float lx0 = offX + lcol * gw;
            float lx1 = lx0 + gw;
            float ly1 = offY + (lrow + 1) * gh;
            float ly0 = ly1 - ulH;
            g_bg_verts[bgVertCount+0] = (Vertex){ lx0,ly0, 0,0, lr,lg,lb,1 };
            g_bg_verts[bgVertCount+1] = (Vertex){ lx1,ly0, 0,0, lr,lg,lb,1 };
            g_bg_verts[bgVertCount+2] = (Vertex){ lx0,ly1, 0,0, lr,lg,lb,1 };
            g_bg_verts[bgVertCount+3] = (Vertex){ lx1,ly0, 0,0, lr,lg,lb,1 };
            g_bg_verts[bgVertCount+4] = (Vertex){ lx1,ly1, 0,0, lr,lg,lb,1 };
            g_bg_verts[bgVertCount+5] = (Vertex){ lx0,ly1, 0,0, lr,lg,lb,1 };
            bgVertCount += 6;
        }

        // Detected URLs: show underline only when hovered
        int dRow = g_detected_url_row;
        int dStart = g_detected_url_start_col;
        int dEnd = g_detected_url_end_col;
        if (g_detected_url_len > 0 && dRow >= 0 && dRow < rows) {
            float lr = 0.4f, lg = 0.7f, lb = 1.0f;
            for (int c = dStart; c <= dEnd && c < cols; c++) {
                if (bgVertCount + 6 > g_bg_vert_cap) break;
                float lx0 = offX + c * gw;
                float lx1 = lx0 + gw;
                float ly1 = offY + (dRow + 1) * gh;
                float ly0 = ly1 - ulH;
                g_bg_verts[bgVertCount+0] = (Vertex){ lx0,ly0, 0,0, lr,lg,lb,1 };
                g_bg_verts[bgVertCount+1] = (Vertex){ lx1,ly0, 0,0, lr,lg,lb,1 };
                g_bg_verts[bgVertCount+2] = (Vertex){ lx0,ly1, 0,0, lr,lg,lb,1 };
                g_bg_verts[bgVertCount+3] = (Vertex){ lx1,ly0, 0,0, lr,lg,lb,1 };
                g_bg_verts[bgVertCount+4] = (Vertex){ lx1,ly1, 0,0, lr,lg,lb,1 };
                g_bg_verts[bgVertCount+5] = (Vertex){ lx0,ly1, 0,0, lr,lg,lb,1 };
                bgVertCount += 6;
            }
        }
    }

    // Search match highlights
    if (g_search_active) {
        int visCount = g_search_vis_count;
        int srchRow = g_search_cur_vis_row;
        int srchCs = g_search_cur_vis_cs;
        int srchCe = g_search_cur_vis_ce;
        for (int vi = 0; vi < visCount && vi < ATTYX_SEARCH_VIS_MAX; vi++) {
            AttyxSearchVis m = g_search_vis[vi];
            if (m.row < 0 || m.row >= visibleRows) continue;
            int isCurrent = (m.row == srchRow && m.col_start == srchCs && m.col_end == srchCe);
            float hr, hg, hb, ha;
            if (isCurrent) {
                hr = 1.0f; hg = 0.6f; hb = 0.0f; ha = 0.75f;
            } else {
                hr = 1.0f; hg = 0.6f; hb = 0.0f; ha = 0.28f;
            }
            for (int cc = m.col_start; cc < m.col_end && cc < cols; cc++) {
                if (bgVertCount + 6 > g_bg_vert_cap) break;
                float lx0 = offX + cc * gw, lx1 = lx0 + gw;
                float ly0 = offY + m.row * gh, ly1 = ly0 + gh;
                g_bg_verts[bgVertCount+0] = (Vertex){ lx0,ly0, 0,0, hr,hg,hb,ha };
                g_bg_verts[bgVertCount+1] = (Vertex){ lx1,ly0, 0,0, hr,hg,hb,ha };
                g_bg_verts[bgVertCount+2] = (Vertex){ lx0,ly1, 0,0, hr,hg,hb,ha };
                g_bg_verts[bgVertCount+3] = (Vertex){ lx1,ly0, 0,0, hr,hg,hb,ha };
                g_bg_verts[bgVertCount+4] = (Vertex){ lx1,ly1, 0,0, hr,hg,hb,ha };
                g_bg_verts[bgVertCount+5] = (Vertex){ lx0,ly1, 0,0, hr,hg,hb,ha };
                bgVertCount += 6;
            }
        }
    }

    // Underline + strikethrough decorations
    {
        float decoH = fmaxf(2.0f, 1.0f);
        for (int i = 0; i < visibleTotal; i++) {
            const AttyxCell* cell = &cells[i];
            if (cell->character == 0x10EEEE) continue;  // Kitty Unicode placeholder
            uint8_t fl = cell->flags;
            int hasUnderline = (fl & 2);
            int hasStrike = (fl & 32);
            if (!hasUnderline && !hasStrike) continue;
            int drow = i / cols, dcol = i % cols;
            float dr = cell->fg_r / 255.0f;
            float dg = cell->fg_g / 255.0f;
            float db = cell->fg_b / 255.0f;
            float dx0 = offX + dcol * gw, dx1 = dx0 + gw;
            if (hasUnderline && bgVertCount + 6 <= g_bg_vert_cap) {
                float uy1 = offY + (drow + 1) * gh;
                float uy0 = uy1 - decoH;
                g_bg_verts[bgVertCount+0] = (Vertex){ dx0,uy0, 0,0, dr,dg,db,1 };
                g_bg_verts[bgVertCount+1] = (Vertex){ dx1,uy0, 0,0, dr,dg,db,1 };
                g_bg_verts[bgVertCount+2] = (Vertex){ dx0,uy1, 0,0, dr,dg,db,1 };
                g_bg_verts[bgVertCount+3] = (Vertex){ dx1,uy0, 0,0, dr,dg,db,1 };
                g_bg_verts[bgVertCount+4] = (Vertex){ dx1,uy1, 0,0, dr,dg,db,1 };
                g_bg_verts[bgVertCount+5] = (Vertex){ dx0,uy1, 0,0, dr,dg,db,1 };
                bgVertCount += 6;
            }
            if (hasStrike && bgVertCount + 6 <= g_bg_vert_cap) {
                float sy0 = offY + drow * gh + gh * 0.5f - decoH * 0.5f;
                float sy1 = sy0 + decoH;
                g_bg_verts[bgVertCount+0] = (Vertex){ dx0,sy0, 0,0, dr,dg,db,1 };
                g_bg_verts[bgVertCount+1] = (Vertex){ dx1,sy0, 0,0, dr,dg,db,1 };
                g_bg_verts[bgVertCount+2] = (Vertex){ dx0,sy1, 0,0, dr,dg,db,1 };
                g_bg_verts[bgVertCount+3] = (Vertex){ dx1,sy0, 0,0, dr,dg,db,1 };
                g_bg_verts[bgVertCount+4] = (Vertex){ dx1,sy1, 0,0, dr,dg,db,1 };
                g_bg_verts[bgVertCount+5] = (Vertex){ dx0,sy1, 0,0, dr,dg,db,1 };
                bgVertCount += 6;
            }
        }
    }

    // Text vertices
    int ti = 0;
    int ci = 0;
    if (g_full_redraw || dirtyAny(dirty)) {
        for (int i = 0; i < visibleTotal; i++) {
            const AttyxCell* cell = &cells[i];
            uint32_t ch = cell->character;
            if (ch <= 32) continue;
            if (ch == 0x10EEEE) continue;  // Kitty Unicode placeholder

            int row = i / cols, col = i % cols;
            float x0 = offX + col * gw, y0 = offY + row * gh;
            float x1 = x0 + gw, y1 = y0 + gh;

            uint32_t key = ch;
            bool hasCombining = (cell->combining[0] != 0);
            if (hasCombining) key = combiningKey(ch, cell->combining[0], cell->combining[1]);

            int rawSlot = glyphCacheLookup(&g_gc, key);
            if (rawSlot < 0) {
                rawSlot = hasCombining
                    ? glyphCacheRasterizeCombined(&g_gc, ch, cell->combining[0], cell->combining[1])
                    : glyphCacheRasterize(&g_gc, ch);
                atlasW = (float)g_gc.atlas_w;
            }

            // Extract color flag (bit 29), wide flag (bit 30), and actual atlas slot index
            int isColor = (rawSlot & GLYPH_COLOR_BIT) ? 1 : 0;
            int wide    = (rawSlot & GLYPH_WIDE_BIT)  ? 1 : 0;
            int slot    = rawSlot & ~(GLYPH_WIDE_BIT | GLYPH_COLOR_BIT);

            int ac = slot % atlasCols;
            int ar = slot / atlasCols;
            float atlasH = (float)g_gc.atlas_h;
            float au0 = ac              * glyphW / atlasW;
            float av0 = ar              * glyphH / atlasH;
            float au1 = (ac + 1 + wide) * glyphW / atlasW;
            float av1 = (ar + 1)        * glyphH / atlasH;

            float x1w = wide ? x0 + 2.0f * gw : x1;

            if (isColor) {
                // Color emoji: vertex color = white, alpha = window opacity
                float wa = g_background_opacity < 1.0f ? g_background_opacity : 1.0f;
                g_color_verts[ci+0] = (Vertex){ x0,  y0, au0,av0, 1,1,1,wa };
                g_color_verts[ci+1] = (Vertex){ x1w, y0, au1,av0, 1,1,1,wa };
                g_color_verts[ci+2] = (Vertex){ x0,  y1, au0,av1, 1,1,1,wa };
                g_color_verts[ci+3] = (Vertex){ x1w, y0, au1,av0, 1,1,1,wa };
                g_color_verts[ci+4] = (Vertex){ x1w, y1, au1,av1, 1,1,1,wa };
                g_color_verts[ci+5] = (Vertex){ x0,  y1, au0,av1, 1,1,1,wa };
                ci += 6;
            } else {
                float fr, fg, fb;
                if (g_theme_sel_fg_set && cellIsSelected(row, col)) {
                    fr = g_theme_sel_fg_r / 255.0f;
                    fg = g_theme_sel_fg_g / 255.0f;
                    fb = g_theme_sel_fg_b / 255.0f;
                } else if (drawCursor && row == (curRow - g_grid_top_offset) && col == curCol
                           && (curShape == 0 || curShape == 1)) {
                    // Block cursor: use cell bg for contrast
                    fr = cell->bg_r / 255.0f;
                    fg = cell->bg_g / 255.0f;
                    fb = cell->bg_b / 255.0f;
                } else {
                    fr = cell->fg_r / 255.0f;
                    fg = cell->fg_g / 255.0f;
                    fb = cell->fg_b / 255.0f;
                }

                g_text_verts[ti+0] = (Vertex){ x0,  y0, au0,av0, fr,fg,fb,1 };
                g_text_verts[ti+1] = (Vertex){ x1w, y0, au1,av0, fr,fg,fb,1 };
                g_text_verts[ti+2] = (Vertex){ x0,  y1, au0,av1, fr,fg,fb,1 };
                g_text_verts[ti+3] = (Vertex){ x1w, y0, au1,av0, fr,fg,fb,1 };
                g_text_verts[ti+4] = (Vertex){ x1w, y1, au1,av1, fr,fg,fb,1 };
                g_text_verts[ti+5] = (Vertex){ x0,  y1, au0,av1, fr,fg,fb,1 };
                ti += 6;
            }
        }
        g_total_text_verts  = ti;
        g_total_color_verts = ci;
    } else {
        ti = g_total_text_verts;
        ci = g_total_color_verts;
    }

    g_prev_cursor_row   = curRow;
    g_prev_cursor_col   = curCol;
    g_prev_cursor_shape = curShape;
    g_prev_cursor_vis   = curVis;
    if (!g_trail_active && !g_popup_trail_active) g_full_redraw = 0;

    // --- GL draw ---
    // Gap quads fill all areas outside the centered grid, so clear to transparent.
    glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    glViewport(0, 0, fb_w, fb_h);

    glBindVertexArray(g_vao);

    // Fill gap areas outside the centered grid with the terminal background color.
    {
        float defR = g_theme_bg_r / 255.0f;
        float defG = g_theme_bg_g / 255.0f;
        float defB = g_theme_bg_b / 255.0f;
        float ba   = g_background_opacity;
        float gridRight  = offX + cols * gw;
        float gridBottom = offY + visibleRows * gh;
        Vertex gapVerts[24];
        int gvc = 0;
        if (offY > 0.5f)
            gvc = emitRect(gapVerts, gvc, 0, 0, (float)fb_w, offY, defR, defG, defB, ba);
        if (gridBottom + 0.5f < (float)fb_h)
            gvc = emitRect(gapVerts, gvc, 0, gridBottom, (float)fb_w, (float)fb_h - gridBottom, defR, defG, defB, ba);
        if (offX > 0.5f)
            gvc = emitRect(gapVerts, gvc, 0, offY, offX, (float)visibleRows * gh, defR, defG, defB, ba);
        if (gridRight + 0.5f < (float)fb_w)
            gvc = emitRect(gapVerts, gvc, gridRight, offY, (float)fb_w - gridRight, (float)visibleRows * gh, defR, defG, defB, ba);
        if (gvc > 0) {
            glEnable(GL_BLEND);
            glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
            glUseProgram(g_solid_prog);
            glUniform2f(g_vp_loc_solid, viewport[0], viewport[1]);
            glBindBuffer(GL_ARRAY_BUFFER, g_vbo);
            glBufferData(GL_ARRAY_BUFFER, sizeof(Vertex) * gvc, gapVerts, GL_DYNAMIC_DRAW);
            setupVertexAttribs();
            glDrawArrays(GL_TRIANGLES, 0, gvc);
            glDisable(GL_BLEND);
        }
    }

    // BG pass (blending on so search highlights respect alpha)
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glUseProgram(g_solid_prog);
    glUniform2f(g_vp_loc_solid, viewport[0], viewport[1]);
    glBindBuffer(GL_ARRAY_BUFFER, g_vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(Vertex) * bgVertCount,
                 g_bg_verts, GL_DYNAMIC_DRAW);
    setupVertexAttribs();
    glDrawArrays(GL_TRIANGLES, 0, bgVertCount);
    glDisable(GL_BLEND);

    // Text pass (grayscale glyphs)
    if (ti > 0) {
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glUseProgram(g_text_prog);
        glUniform2f(g_vp_loc_text, viewport[0], viewport[1]);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, g_gc.texture);
        glUniform1i(g_tex_loc, 0);
        glBufferData(GL_ARRAY_BUFFER, sizeof(Vertex) * ti,
                     g_text_verts, GL_DYNAMIC_DRAW);
        setupVertexAttribs();
        glDrawArrays(GL_TRIANGLES, 0, ti);
        glDisable(GL_BLEND);
    }

    // Color emoji pass (premultiplied RGBA)
    if (ci > 0) {
        glEnable(GL_BLEND);
        glBlendFuncSeparate(GL_ONE, GL_ONE_MINUS_SRC_ALPHA,
                            GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
        glUseProgram(g_color_prog);
        glBindVertexArray(g_color_vao);
        glBindBuffer(GL_ARRAY_BUFFER, g_color_vbo);
        glBufferData(GL_ARRAY_BUFFER, sizeof(Vertex) * ci,
                     g_color_verts, GL_DYNAMIC_DRAW);
        setupVertexAttribs();
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, g_gc.color_texture);
        glUniform1i(glGetUniformLocation(g_color_prog, "tex"), 0);
        float vp[2] = { viewport[0], viewport[1] };
        glUniform2fv(glGetUniformLocation(g_color_prog, "viewport"), 1, vp);
        glDrawArrays(GL_TRIANGLES, 0, ci);
        glDisable(GL_BLEND);
        // Restore standard VAO/VBO for subsequent passes
        glBindVertexArray(g_vao);
        glBindBuffer(GL_ARRAY_BUFFER, g_vbo);
    }

    // Overlay layers (debug card, etc.) — use baseOffY so overlays are NOT shifted
    drawOverlays(offX, baseOffY, gw, gh, viewport);
    lastOverlayGen = g_overlay_gen;

    // Popup terminal
    drawPopup(offX, offY, gw, gh, viewport);
    lastPopupGen = g_popup_gen;

    // IME preedit overlay
    if (g_ime_composing && g_ime_preedit_len > 0) {
        int pRow = g_ime_anchor_row;
        int pCol = g_ime_anchor_col;
        if (pRow >= 0 && pRow < rows && pCol >= 0 && pCol < cols) {
            char preeditCopy[ATTYX_IME_MAX_BYTES];
            int pLen = g_ime_preedit_len;
            if (pLen > ATTYX_IME_MAX_BYTES - 1) pLen = ATTYX_IME_MAX_BYTES - 1;
            memcpy(preeditCopy, g_ime_preedit, pLen);
            preeditCopy[pLen] = '\0';

            int preCharCount = 0;
            uint32_t preCPs[128];
            const uint8_t* p = (const uint8_t*)preeditCopy;
            const uint8_t* end = p + pLen;
            while (p < end && preCharCount < 128) {
                uint32_t cp = 0;
                if ((*p & 0x80) == 0)         { cp = *p++; }
                else if ((*p & 0xE0) == 0xC0) { cp = (*p & 0x1F); p++; if (p < end) { cp = (cp << 6) | (*p & 0x3F); p++; } }
                else if ((*p & 0xF0) == 0xE0) { cp = (*p & 0x0F); p++; for (int j = 0; j < 2 && p < end; j++) { cp = (cp << 6) | (*p & 0x3F); p++; } }
                else if ((*p & 0xF8) == 0xF0) { cp = (*p & 0x07); p++; for (int j = 0; j < 3 && p < end; j++) { cp = (cp << 6) | (*p & 0x3F); p++; } }
                else { p++; continue; }
                preCPs[preCharCount++] = cp;
            }

            int preCells = preCharCount;
            if (pCol + preCells > cols) preCells = cols - pCol;

            Vertex imeVerts[128 * 6 + 6];
            int iv = 0;
            for (int i = 0; i < preCells; i++) {
                float x0 = offX + (pCol + i) * gw, y0 = offY + pRow * gh;
                float x1 = x0 + gw, y1 = y0 + gh;
                float br = 0.20f, bg = 0.20f, bb = 0.30f;
                imeVerts[iv++] = (Vertex){ x0,y0, 0,0, br,bg,bb,1 };
                imeVerts[iv++] = (Vertex){ x1,y0, 0,0, br,bg,bb,1 };
                imeVerts[iv++] = (Vertex){ x0,y1, 0,0, br,bg,bb,1 };
                imeVerts[iv++] = (Vertex){ x1,y0, 0,0, br,bg,bb,1 };
                imeVerts[iv++] = (Vertex){ x1,y1, 0,0, br,bg,bb,1 };
                imeVerts[iv++] = (Vertex){ x0,y1, 0,0, br,bg,bb,1 };
            }
            float ulH = 2.0f;
            float ulY0 = offY + pRow * gh + gh - ulH, ulY1 = offY + pRow * gh + gh;
            float ulX0 = offX + pCol * gw, ulX1 = offX + (pCol + preCells) * gw;
            imeVerts[iv++] = (Vertex){ ulX0,ulY0, 0,0, 0.9f,0.9f,0.3f,1 };
            imeVerts[iv++] = (Vertex){ ulX1,ulY0, 0,0, 0.9f,0.9f,0.3f,1 };
            imeVerts[iv++] = (Vertex){ ulX0,ulY1, 0,0, 0.9f,0.9f,0.3f,1 };
            imeVerts[iv++] = (Vertex){ ulX1,ulY0, 0,0, 0.9f,0.9f,0.3f,1 };
            imeVerts[iv++] = (Vertex){ ulX1,ulY1, 0,0, 0.9f,0.9f,0.3f,1 };
            imeVerts[iv++] = (Vertex){ ulX0,ulY1, 0,0, 0.9f,0.9f,0.3f,1 };

            glUseProgram(g_solid_prog);
            glUniform2f(g_vp_loc_solid, viewport[0], viewport[1]);
            glBufferData(GL_ARRAY_BUFFER, sizeof(Vertex) * iv,
                         imeVerts, GL_DYNAMIC_DRAW);
            setupVertexAttribs();
            glDrawArrays(GL_TRIANGLES, 0, iv);

            // Preedit text glyphs
            Vertex imeTextVerts[128 * 6];
            int ig = 0;
            for (int i = 0; i < preCells; i++) {
                uint32_t cp = preCPs[i];
                if (cp <= 32) continue;
                float x0 = offX + (pCol + i) * gw, y0 = offY + pRow * gh;
                float x1 = x0 + gw, y1 = y0 + gh;
                int slot = glyphCacheLookup(&g_gc, cp);
                if (slot < 0) slot = glyphCacheRasterize(&g_gc, cp);
                int ac2 = slot % g_gc.atlas_cols;
                int ar2 = slot / g_gc.atlas_cols;
                float aW = (float)g_gc.atlas_w, aH = (float)g_gc.atlas_h;
                float au0 = ac2 * glyphW / aW, av0 = ar2 * glyphH / aH;
                float au1 = (ac2+1) * glyphW / aW, av1 = (ar2+1) * glyphH / aH;
                float fr = 0.95f, fg = 0.95f, fb = 0.95f;
                imeTextVerts[ig++] = (Vertex){ x0,y0, au0,av0, fr,fg,fb,1 };
                imeTextVerts[ig++] = (Vertex){ x1,y0, au1,av0, fr,fg,fb,1 };
                imeTextVerts[ig++] = (Vertex){ x0,y1, au0,av1, fr,fg,fb,1 };
                imeTextVerts[ig++] = (Vertex){ x1,y0, au1,av0, fr,fg,fb,1 };
                imeTextVerts[ig++] = (Vertex){ x1,y1, au1,av1, fr,fg,fb,1 };
                imeTextVerts[ig++] = (Vertex){ x0,y1, au0,av1, fr,fg,fb,1 };
            }
            if (ig > 0) {
                glEnable(GL_BLEND);
                glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
                glUseProgram(g_text_prog);
                glUniform2f(g_vp_loc_text, viewport[0], viewport[1]);
                glBindTexture(GL_TEXTURE_2D, g_gc.texture);
                glUniform1i(g_tex_loc, 0);
                glBufferData(GL_ARRAY_BUFFER, sizeof(Vertex) * ig,
                             imeTextVerts, GL_DYNAMIC_DRAW);
                setupVertexAttribs();
                glDrawArrays(GL_TRIANGLES, 0, ig);
                glDisable(GL_BLEND);
            }
        }
    }

    // Search bar is now rendered via the overlay system (drawOverlays above).

    // Context menu overlay (right-click menu: Copy, Paste, ---, Reload Config)
    if (g_ctx_menu_open) {
        float cmGw = g_gc.glyph_w, cmGh = g_gc.glyph_h;
        float padX = cmGw * 0.5f, padY = cmGh * 0.25f;
        float itemH = cmGh + padY * 2.0f;
        float sepH  = padY * 2.0f;
        float menuW = padX * 2.0f + 13.0f * cmGw; // 13 = len("Reload Config")
        float menuH = itemH * 3.0f + sepH;

        // Clamp to content area (centered grid bounds).
        float vpW = offX + cols * cmGw, vpH = offY + rows * cmGh;
        float menuX = g_ctx_menu_x, menuY = g_ctx_menu_y;
        if (menuX + menuW > vpW) menuX = vpW - menuW;
        if (menuY + menuH > vpH) menuY = vpH - menuH;
        if (menuX < offX) menuX = offX;
        if (menuY < offY) menuY = offY;

        // Item labels and Y offsets
        const char* labels[CTX_MENU_ITEM_COUNT] = { "Copy", "Paste", NULL, "Reload Config" };
        int labelLens[CTX_MENU_ITEM_COUNT]      = {  4,      5,      0,    13 };
        float itemY[CTX_MENU_ITEM_COUNT];
        itemY[CTX_MENU_ITEM_COPY]          = 0;
        itemY[CTX_MENU_ITEM_PASTE]         = itemH;
        itemY[CTX_MENU_ITEM_SEPARATOR]     = itemH * 2.0f;
        itemY[CTX_MENU_ITEM_RELOAD_CONFIG] = itemH * 2.0f + sepH;

        // Solid pass: background rect + hover highlight + separator line.
        // bg(6) + hover(6) + separator(6) = 18 max
        Vertex cmBg[18];
        int cmi = 0;
        cmi = emitRect(cmBg, cmi, menuX, menuY, menuW, menuH,
                       0.12f, 0.12f, 0.16f, 0.97f);
        if (g_ctx_menu_hover >= 0 && g_ctx_menu_hover != CTX_MENU_ITEM_SEPARATOR) {
            cmi = emitRect(cmBg, cmi, menuX, menuY + itemY[g_ctx_menu_hover],
                           menuW, itemH, 0.20f, 0.35f, 0.60f, 1.0f);
        }
        // Separator line
        float sepLineH = fmaxf(1.0f, 1.0f);
        float sepLineY = menuY + itemY[CTX_MENU_ITEM_SEPARATOR] + (sepH - sepLineH) * 0.5f;
        cmi = emitRect(cmBg, cmi, menuX + padX, sepLineY, menuW - padX * 2.0f, sepLineH,
                       0.30f, 0.30f, 0.35f, 1.0f);

        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glUseProgram(g_solid_prog);
        glUniform2f(g_vp_loc_solid, viewport[0], viewport[1]);
        glBufferData(GL_ARRAY_BUFFER, sizeof(Vertex) * cmi, cmBg, GL_DYNAMIC_DRAW);
        setupVertexAttribs();
        glDrawArrays(GL_TRIANGLES, 0, cmi);
        glDisable(GL_BLEND);

        // Text pass: item labels (skip separator).
        Vertex cmTv[22 * 6]; // 4+5+13 = 22 chars max
        int cti = 0;
        for (int mi = 0; mi < CTX_MENU_ITEM_COUNT; mi++) {
            if (mi == CTX_MENU_ITEM_SEPARATOR) continue;
            cti = emitString(cmTv, cti, &g_gc, labels[mi], labelLens[mi],
                             menuX + padX, menuY + itemY[mi] + padY,
                             cmGw, cmGh, 0.90f, 0.90f, 0.95f);
        }
        if (cti > 0) {
            glEnable(GL_BLEND);
            glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
            glUseProgram(g_text_prog);
            glUniform2f(g_vp_loc_text, viewport[0], viewport[1]);
            glBindTexture(GL_TEXTURE_2D, g_gc.texture);
            glUniform1i(g_tex_loc, 0);
            glBufferData(GL_ARRAY_BUFFER, sizeof(Vertex) * cti, cmTv, GL_DYNAMIC_DRAW);
            setupVertexAttribs();
            glDrawArrays(GL_TRIANGLES, 0, cti);
            glDisable(GL_BLEND);
        }
    }

    glBindVertexArray(0);
    return 1;
}
