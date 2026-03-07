// Attyx — Linux platform layer (GLFW + OpenGL 3.3 + FreeType + Fontconfig)
// This file contains: globals, bridge functions, entry point.
// Glyph cache:  linux_glyph.c
// Renderer:     linux_render.c
// Input:        linux_input.c

#include "linux_internal.h"
#include <png.h>

// ---------------------------------------------------------------------------
// Shared state definitions
// ---------------------------------------------------------------------------

AttyxCell* g_cells = NULL;
int g_cols = 0;
int g_rows = 0;
static volatile int g_glfw_ready = 0;
volatile uint64_t g_cell_gen = 0;
volatile int g_cursor_row = 0;
volatile int g_cursor_col = 0;
volatile int g_should_quit = 0;

volatile int g_bracketed_paste = 0;
volatile int g_cursor_keys_app = 0;

volatile int g_mouse_tracking = 0;
volatile int g_mouse_sgr = 0;

volatile int g_viewport_offset = 0;
volatile int g_scrollback_count = 0;
volatile int g_alt_screen = 0;

volatile int g_sel_start_row = -1, g_sel_start_col = -1;
volatile int g_sel_end_row = -1, g_sel_end_col = -1;
volatile int g_sel_active = 0;

volatile uint8_t g_row_wrapped[ATTYX_MAX_ROWS] = {0};

volatile int g_cursor_shape   = 0;
volatile int g_cursor_visible = 1;
volatile int g_cursor_trail   = 0;
volatile int g_font_ligatures = 1;

char         g_title_buf[ATTYX_TITLE_MAX];
volatile int g_title_len     = 0;
volatile int g_title_changed = 0;

volatile int  g_ime_composing    = 0;
volatile int  g_ime_cursor_index = -1;
volatile int  g_ime_anchor_row   = 0;
volatile int  g_ime_anchor_col   = 0;
char          g_ime_preedit[ATTYX_IME_MAX_BYTES];
volatile int  g_ime_preedit_len  = 0;

// Font config (written by Zig at startup)
char         g_font_family[ATTYX_FONT_FAMILY_MAX];
volatile int g_font_family_len = 0;
volatile int g_font_size       = 14;
volatile int g_default_font_size = 14;
volatile int g_cell_width      = 0;
volatile int g_cell_height     = 0;
char         g_font_fallback[ATTYX_FONT_FALLBACK_MAX][ATTYX_FONT_FAMILY_MAX];
volatile int g_font_fallback_count = 0;

// Search state globals
char          g_search_query[ATTYX_SEARCH_QUERY_MAX];
volatile int  g_search_query_len  = 0;
volatile int  g_search_active     = 0;
volatile int  g_search_gen        = 0;
volatile int  g_search_nav_delta  = 0;
volatile int  g_search_total      = 0;
volatile int  g_search_current    = 0;
AttyxSearchVis g_search_vis[ATTYX_SEARCH_VIS_MAX];
volatile int  g_search_vis_count  = 0;
volatile int  g_search_cur_vis_row = -1;
volatile int  g_search_cur_vis_cs  = 0;
volatile int  g_search_cur_vis_ce  = 0;

volatile uint32_t g_hover_link_id = 0;
volatile int g_hover_row = -1;

char g_detected_url[DETECTED_URL_MAX];
volatile int g_detected_url_len = 0;
volatile int g_detected_url_row = -1;
volatile int g_detected_url_start_col = 0;
volatile int g_detected_url_end_col = 0;

AttyxImagePlacement g_image_placements[ATTYX_MAX_IMAGE_PLACEMENTS];
volatile int      g_image_placement_count = 0;
volatile uint64_t g_image_gen = 0;

AttyxImagePlacement g_popup_image_placements[ATTYX_POPUP_MAX_IMAGE_PLACEMENTS];
volatile int        g_popup_image_placement_count = 0;

volatile uint64_t g_dirty[4] = {0,0,0,0};
volatile int g_pending_resize_rows = 0;
volatile int g_pending_resize_cols = 0;

// Context menu state
int   g_ctx_menu_open  = 0;
float g_ctx_menu_x     = 0;
float g_ctx_menu_y     = 0;
int   g_ctx_menu_hover = -1;

// GLFW window handle (shared with input and render)
GLFWwindow* g_window = NULL;

// Overlay system
AttyxOverlayDesc  g_overlay_descs[ATTYX_OVERLAY_MAX_LAYERS];
AttyxOverlayCell  g_overlay_cells[ATTYX_OVERLAY_MAX_LAYERS][ATTYX_OVERLAY_MAX_CELLS];
volatile int      g_overlay_count = 0;
volatile uint32_t g_overlay_gen   = 0;

// Popup terminal
AttyxPopupDesc    g_popup_desc;
AttyxOverlayCell  g_popup_cells[ATTYX_POPUP_MAX_CELLS];
volatile uint32_t g_popup_gen    = 0;

// ---------------------------------------------------------------------------
// Bridge function implementations
// ---------------------------------------------------------------------------

void attyx_set_cursor(int row, int col) {
    g_cursor_row = row;
    g_cursor_col = col;
}

void attyx_request_quit(void) { g_should_quit = 1; }
int  attyx_should_quit(void)  { return g_should_quit; }

void attyx_set_mode_flags(int bracketed_paste, int cursor_keys_app) {
    g_bracketed_paste = bracketed_paste;
    g_cursor_keys_app = cursor_keys_app;
}

void attyx_set_mouse_mode(int tracking, int sgr) {
    g_mouse_tracking = tracking;
    g_mouse_sgr = sgr;
}

void attyx_mark_all_dirty(void) {
    for (int i = 0; i < 4; i++)
        __sync_fetch_and_or((volatile uint64_t*)&g_dirty[i], ~(uint64_t)0);
    if (g_glfw_ready) glfwPostEmptyEvent();
}

void attyx_scroll_viewport(int delta) {
    int cur = g_viewport_offset;
    int sb = g_scrollback_count;
    int nv = cur + delta;
    if (nv < 0) nv = 0;
    if (nv > sb) nv = sb;
    g_viewport_offset = nv;
    // Dirty bits are set by the PTY thread after it updates the cell buffer
    // for the new viewport offset.  Setting them here would cause the renderer
    // to draw stale cells (old viewport content), producing artifacts.
}

void attyx_set_dirty(const uint64_t dirty[4]) {
    for (int i = 0; i < 4; i++)
        __sync_fetch_and_or((volatile uint64_t*)&g_dirty[i], dirty[i]);
    if (g_glfw_ready) glfwPostEmptyEvent();
}

void attyx_set_grid_size(int cols, int rows) {
    g_cols = cols;
    g_rows = rows;
}

void attyx_begin_cell_update(void) {
    __sync_fetch_and_add(&g_cell_gen, 1);
}

void attyx_end_cell_update(void) {
    __sync_fetch_and_add(&g_cell_gen, 1);
    if (g_glfw_ready) glfwPostEmptyEvent();
}

int attyx_check_resize(int* out_rows, int* out_cols) {
    int pr = g_pending_resize_rows;
    int pc = g_pending_resize_cols;
    if (pr <= 0 || pc <= 0) return 0;
    if (pr == g_rows && pc == g_cols) return 0;
    *out_rows = pr;
    *out_cols = pc;
    g_pending_resize_rows = 0;
    g_pending_resize_cols = 0;
    return 1;
}

// ---------------------------------------------------------------------------
// Window icon (PNG → RGBA via libpng → glfwSetWindowIcon)
// ---------------------------------------------------------------------------

typedef struct { const uint8_t* data; int len; int pos; } PngMem;

static void png_read_mem(png_structp png, png_bytep out, png_size_t n) {
    PngMem* s = (PngMem*)png_get_io_ptr(png);
    if (s->pos + (int)n > s->len) return;
    memcpy(out, s->data + s->pos, n);
    s->pos += (int)n;
}

static void linux_set_window_icon(GLFWwindow* win) {
    if (g_icon_png_len <= 0) return;

    png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
    if (!png) return;
    png_infop info = png_create_info_struct(png);
    if (!info) { png_destroy_read_struct(&png, NULL, NULL); return; }
    if (setjmp(png_jmpbuf(png))) { png_destroy_read_struct(&png, &info, NULL); return; }

    PngMem src = { g_icon_png, g_icon_png_len, 0 };
    png_set_read_fn(png, &src, png_read_mem);
    png_read_info(png, info);

    int w = (int)png_get_image_width(png, info);
    int h = (int)png_get_image_height(png, info);
    png_byte ct = png_get_color_type(png, info);
    png_byte bd = png_get_bit_depth(png, info);

    if (bd == 16) png_set_strip_16(png);
    if (ct == PNG_COLOR_TYPE_PALETTE) png_set_palette_to_rgb(png);
    if (ct == PNG_COLOR_TYPE_GRAY && bd < 8) png_set_expand_gray_1_2_4_to_8(png);
    if (png_get_valid(png, info, PNG_INFO_tRNS)) png_set_tRNS_to_alpha(png);
    if (ct == PNG_COLOR_TYPE_RGB || ct == PNG_COLOR_TYPE_GRAY || ct == PNG_COLOR_TYPE_PALETTE)
        png_set_filler(png, 0xFF, PNG_FILLER_AFTER);
    if (ct == PNG_COLOR_TYPE_GRAY || ct == PNG_COLOR_TYPE_GRAY_ALPHA)
        png_set_gray_to_rgb(png);
    png_read_update_info(png, info);

    uint8_t* pixels = (uint8_t*)malloc((size_t)w * (size_t)h * 4);
    if (!pixels) { png_destroy_read_struct(&png, &info, NULL); return; }

    png_bytep* rows = (png_bytep*)malloc((size_t)h * sizeof(png_bytep));
    if (!rows) { free(pixels); png_destroy_read_struct(&png, &info, NULL); return; }
    for (int y = 0; y < h; y++) rows[y] = pixels + y * w * 4;
    png_read_image(png, rows);
    free(rows);
    png_destroy_read_struct(&png, &info, NULL);

    GLFWimage img = { w, h, pixels };
    glfwSetWindowIcon(win, 1, &img);
    free(pixels);
}

// ---------------------------------------------------------------------------
// Platform close window (called from Zig dispatch)
// ---------------------------------------------------------------------------

void attyx_platform_close_window(void) {
    glfwSetWindowShouldClose(g_window, 1);
}

void attyx_platform_notify(const char* title, const char* body) {
    // Linux: use notify-send if available
    if (!body || body[0] == '\0') return;
    pid_t pid = fork();
    if (pid == 0) {
        const char* t = (title && title[0]) ? title : "Attyx";
        execlp("notify-send", "notify-send", t, body, (char*)NULL);
        _exit(1); // execlp failed
    }
}

// ---------------------------------------------------------------------------
// Spawn new window (new process)
// ---------------------------------------------------------------------------

void attyx_spawn_new_window(void) {
    char exe[4096];
    ssize_t len = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
    if (len <= 0) return;
    exe[len] = '\0';
    pid_t pid = fork();
    if (pid == 0) {
        char* argv[] = { exe, NULL };
        execv(exe, argv);
        _exit(1);
    }
}

// ---------------------------------------------------------------------------
// Hot-reload: apply window property changes (decorations, padding, opacity)
// Called from main loop when g_needs_window_update is set.
// ---------------------------------------------------------------------------

void attyx_apply_window_update(void) {
    if (!g_window) return;

    // Decorations — GLFW supports toggling at runtime
    glfwSetWindowAttrib(g_window, GLFW_DECORATED, g_window_decorations ? GLFW_TRUE : GLFW_FALSE);

    // Opacity — GLFW can't toggle framebuffer transparency at runtime
    // (GLFW_TRANSPARENT_FRAMEBUFFER is a creation hint, not a window attribute).
    // Log a note if the user changed it.
    static float last_opacity = -1.0f;
    if (last_opacity < 0.0f) last_opacity = g_background_opacity;
    int was_transparent = (last_opacity < 1.0f);
    int now_transparent = (g_background_opacity < 1.0f);
    if (was_transparent != now_transparent) {
        ATTYX_LOG_WARN("config", "background.opacity transparency change requires restart on Linux");
    }
    last_opacity = g_background_opacity;

    // Padding — trigger resize recalculation using current framebuffer size
    int fb_w, fb_h;
    glfwGetFramebufferSize(g_window, &fb_w, &fb_h);
    if (g_cell_px_w > 0 && g_cell_px_h > 0) {
        float padPxW = (float)(g_padding_left + g_padding_right) * g_content_scale;
        float padPxH = (float)(g_padding_top  + g_padding_bottom) * g_content_scale;
        int new_cols = (int)((fb_w - padPxW) / g_cell_px_w + 0.01f);
        int new_rows = (int)((fb_h - padPxH) / g_cell_px_h + 0.01f);
        if (new_cols < 1) new_cols = 1;
        if (new_rows < 1) new_rows = 1;
        if (new_cols > ATTYX_MAX_COLS) new_cols = ATTYX_MAX_COLS;
        if (new_rows > ATTYX_MAX_ROWS) new_rows = ATTYX_MAX_ROWS;
        g_pending_resize_rows = new_rows;
        g_pending_resize_cols = new_cols;
    }
    g_full_redraw = 1;
    attyx_mark_all_dirty();
}

// ---------------------------------------------------------------------------
// C entry point called from Zig
// ---------------------------------------------------------------------------

void attyx_run(AttyxCell* cells, int cols, int rows) {
    g_cells = cells;
    g_cols  = cols;
    g_rows  = rows;

    linux_set_error_callback();
    if (!glfwInit()) {
        ATTYX_LOG_ERR("platform", "failed to initialize GLFW");
        return;
    }
    g_glfw_ready = 1;

    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 3);
    glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);

    // Get content scale for HiDPI
    GLFWmonitor* primary = glfwGetPrimaryMonitor();
    float xscale = 1.0f, yscale = 1.0f;
    if (primary) glfwGetMonitorContentScale(primary, &xscale, &yscale);
    g_content_scale = xscale;

    // Initialize FreeType
    FT_Library ft_lib;
    if (FT_Init_FreeType(&ft_lib) != 0) {
        ATTYX_LOG_ERR("platform", "FreeType init failed");
        glfwTerminate();
        return;
    }

    // Create temporary context to initialize GL (needed for glyph cache texture)
    GLFWwindow* tmpWin = glfwCreateWindow(1, 1, "", NULL, NULL);
    glfwMakeContextCurrent(tmpWin);

    // Create glyph cache (needs GL context for texture creation)
    g_gc = createGlyphCache(ft_lib, xscale);
    g_cell_px_w = g_gc.glyph_w;
    g_cell_px_h = g_gc.glyph_h;
    g_cell_w_pts = g_cell_px_w / xscale;
    g_cell_h_pts = g_cell_px_h / yscale;

    glfwDestroyWindow(tmpWin);

    // Create the real window
    int winW = (int)(cols * g_cell_px_w / xscale) + g_padding_left + g_padding_right;
    int winH = (int)(rows * g_cell_px_h / yscale) + g_padding_top  + g_padding_bottom;

    if (g_background_opacity < 1.0f) {
        glfwWindowHint(GLFW_TRANSPARENT_FRAMEBUFFER, GLFW_TRUE);
    }
    if (!g_window_decorations) {
        glfwWindowHint(GLFW_DECORATED, GLFW_FALSE);
    }

    g_window = glfwCreateWindow(winW, winH, "Attyx", NULL, NULL);
    if (!g_window) {
        ATTYX_LOG_ERR("platform", "failed to create window");
        FT_Done_Face(g_gc.ft_face);
        FT_Done_FreeType(ft_lib);
        glfwTerminate();
        return;
    }

    glfwMakeContextCurrent(g_window);
    // Disable vsync — we manage frame pacing manually.  With vsync on,
    // glfwSwapBuffers blocks until the next display refresh (~16ms).
    // During that block, GLFW cannot deliver input events, so keystrokes
    // queue up behind the swap and typing feels laggy.
    glfwSwapInterval(0);

    // Set window icon from embedded PNG.
    linux_set_window_icon(g_window);

    // Re-create glyph cache texture in the new context
    GLuint tex;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);

    // Re-rasterize all cached glyphs in the new context.
    {
        int oldAtlasW = g_gc.atlas_w, oldAtlasH = g_gc.atlas_h;
        uint8_t* zeroes = (uint8_t*)calloc(oldAtlasW * oldAtlasH, 1);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, oldAtlasW, oldAtlasH, 0,
                     GL_RED, GL_UNSIGNED_BYTE, zeroes);
        free(zeroes);
        g_gc.texture = tex;
        g_gc.next_slot = 0;
        for (int i = 0; i < GLYPH_CACHE_CAP; i++) g_gc.map[i].slot = -1;
        for (uint32_t ch = 32; ch < 127; ch++)
            glyphCacheRasterize(&g_gc, ch);
    }

    // Initialize renderer (shader programs, VAO/VBO)
    linux_renderer_init();

    // Register GLFW window callbacks
    linux_register_callbacks(g_window);

    // Main loop — use glfwWaitEventsTimeout to sleep when idle instead of
    // busy-spinning with glfwPollEvents.  The PTY thread wakes us via
    // glfwPostEmptyEvent (called from attyx_end_cell_update / attyx_mark_all_dirty).
    // Timeout of 0.5s ensures cursor blink updates even when fully idle.
    //
    // Frame pacing: vsync is disabled to avoid blocking input delivery during
    // glfwSwapBuffers.  Instead we cap to ~60fps manually — if we drew a frame
    // less than 16ms ago, we use a short wait to avoid busy-spinning.
    double last_swap_time = 0;
    const double frame_interval = 1.0 / 60.0; // ~16.67ms

    while (!glfwWindowShouldClose(g_window) && !g_should_quit) {
        double now = glfwGetTime();
        double since_last = now - last_swap_time;
        double wait = (since_last < frame_interval)
            ? (frame_interval - since_last) : 0.5;
        // Clamp: never wait longer than 0.5s (cursor blink), never negative
        if (wait > 0.5) wait = 0.5;

        glfwWaitEventsTimeout(wait);

        if (g_needs_font_rebuild) {
            g_needs_font_rebuild = 0;
            linux_rebuild_font();
        }
        if (g_needs_window_update) {
            g_needs_window_update = 0;
            attyx_apply_window_update();
        }
        if (drawFrame()) {
            glfwSwapBuffers(g_window);
            last_swap_time = glfwGetTime();
        }
    }

    g_should_quit = 1;

    // Cleanup renderer resources (buffers, GL objects, texture)
    linux_renderer_cleanup();

    FT_Done_Face(g_gc.ft_face);
    FT_Done_FreeType(ft_lib);
    glfwDestroyWindow(g_window);
    glfwTerminate();
}
