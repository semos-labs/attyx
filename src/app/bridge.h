#ifndef ATTYX_BRIDGE_H
#define ATTYX_BRIDGE_H

#include <stdint.h>

#define ATTYX_MAX_ROWS 256
#define ATTYX_MAX_COLS 512

typedef struct {
    uint32_t character;
    uint8_t fg_r, fg_g, fg_b;
    uint8_t bg_r, bg_g, bg_b;
    uint8_t flags; // bit 0 = bold, bit 1 = underline, bit 2 = default bg (apply opacity)
    uint32_t link_id; // hyperlink ID (0 = none), maps to engine's link table
} AttyxCell;

// Blocks until the window is closed. Reads cells each frame (live).
void attyx_run(AttyxCell* cells, int cols, int rows);

// Update cursor position (called from PTY thread).
void attyx_set_cursor(int row, int col);

// Signal the window to close (called from PTY thread on child exit).
void attyx_request_quit(void);

// Check if the window has been closed (polled by PTY thread).
int attyx_should_quit(void);

// Send keyboard input to the PTY (called from main/Cocoa thread).
// Implemented in Zig (ui2.zig).
void attyx_send_input(const uint8_t* bytes, int len);

// Update terminal mode flags (called from PTY thread after engine.feed).
void attyx_set_mode_flags(int bracketed_paste, int cursor_keys_app);

// Update mouse mode flags (called from PTY thread after engine.feed).
// tracking: 0=off, 1=x10, 2=button_event, 3=any_event
// sgr: 1 if SGR 1006 encoding is enabled
void attyx_set_mouse_mode(int tracking, int sgr);

// Mark rows dirty (atomic OR). Called from PTY thread; renderer reads + clears.
// dirty is a 4-element uint64_t array (256-row bitset).
void attyx_set_dirty(const uint64_t dirty[4]);

// Update the active grid dimensions (called from PTY thread after resize).
void attyx_set_grid_size(int cols, int rows);

// Check for a pending resize request from the renderer (window resize).
// Returns 1 if a resize is pending (writing new dimensions into out_rows/out_cols),
// 0 otherwise. Called from PTY thread.
int attyx_check_resize(int* out_rows, int* out_cols);

// Seqlock for cell buffer: PTY thread calls begin/end around cell updates.
// Renderer checks the generation to detect torn reads.
void attyx_begin_cell_update(void);
void attyx_end_cell_update(void);

// Viewport scrollback: 0 = pinned to bottom (live screen), >0 = scrolled up.
// Called from main thread (scroll wheel / keyboard); PTY thread reads and bumps.
extern volatile int g_viewport_offset;
extern volatile int g_scrollback_count;
extern volatile int g_alt_screen;

// Adjust viewport offset by delta lines. Clamps to [0, g_scrollback_count].
// Marks all rows dirty so the renderer redraws.
void attyx_scroll_viewport(int delta);

// Mark all rows dirty (used after viewport changes).
void attyx_mark_all_dirty(void);

// Selection bounds (viewport-relative, 0-indexed). -1 = no selection.
extern volatile int g_sel_start_row, g_sel_start_col;
extern volatile int g_sel_end_row, g_sel_end_col;
extern volatile int g_sel_active;

// Cursor shape and visibility (written by PTY thread, read by renderer).
// shape: 0=blinking_block, 1=steady_block, 2=blinking_underline,
//        3=steady_underline, 4=blinking_bar, 5=steady_bar
extern volatile int g_cursor_shape;
extern volatile int g_cursor_visible;   // 1=visible, 0=hidden

// Window title (written by PTY thread, read by renderer).
#define ATTYX_TITLE_MAX 256
extern char          g_title_buf[ATTYX_TITLE_MAX];
extern volatile int  g_title_len;
extern volatile int  g_title_changed;   // set to 1 by PTY thread; renderer clears to 0

// Hyperlink URI lookup (implemented in Zig, called from renderer thread).
// Copies the URI for the given link_id into buf. Returns byte count, or 0 if not found.
int attyx_get_link_uri(uint32_t link_id, char* buf, int buf_len);

// IME composition state (written by main/Cocoa thread, read by renderer).
#define ATTYX_IME_MAX_BYTES 256

extern volatile int  g_ime_composing;      // 1 while IME preedit is active
extern volatile int  g_ime_cursor_index;   // byte offset of caret within preedit (-1 = end)
extern volatile int  g_ime_anchor_row;     // grid row where composition started
extern volatile int  g_ime_anchor_col;     // grid col where composition started
extern char          g_ime_preedit[ATTYX_IME_MAX_BYTES]; // current preedit UTF-8 (not volatile — guarded by g_ime_composing)
extern volatile int  g_ime_preedit_len;    // byte length of preedit text

// ---------------------------------------------------------------------------
// Font config (written by Zig at startup, read by renderer)
// ---------------------------------------------------------------------------

#define ATTYX_FONT_FAMILY_MAX 128
extern char          g_font_family[ATTYX_FONT_FAMILY_MAX];
extern volatile int  g_font_family_len;
extern volatile int  g_font_size;       // points
extern volatile int  g_cell_width;      // 0=auto, >0=fixed pts, <0=(-N)% of font-derived
extern volatile int  g_cell_height;     // 0=auto, >0=fixed pts, <0=(-N)% of font-derived

#define ATTYX_FONT_FALLBACK_MAX 8
extern char          g_font_fallback[ATTYX_FONT_FALLBACK_MAX][ATTYX_FONT_FAMILY_MAX];
extern volatile int  g_font_fallback_count;

// ---------------------------------------------------------------------------
// In-terminal search state
// ---------------------------------------------------------------------------

#define ATTYX_SEARCH_QUERY_MAX 256
#define ATTYX_SEARCH_VIS_MAX   512

typedef struct { int row; int col_start; int col_end; } AttyxSearchVis;

// UI thread -> PTY thread
extern char          g_search_query[ATTYX_SEARCH_QUERY_MAX];
extern volatile int  g_search_query_len;
extern volatile int  g_search_active;       // 1 = search bar open
extern volatile int  g_search_gen;          // bumped on each query change

// Navigation: UI thread atomically adds +1 (next) or -1 (prev); PTY thread
// atomically reads-and-resets to 0 after processing.
extern volatile int  g_search_nav_delta;

// PTY thread -> UI thread (results for rendering)
extern volatile int  g_search_total;        // total match count
extern volatile int  g_search_current;      // 0-based current match index
extern AttyxSearchVis g_search_vis[ATTYX_SEARCH_VIS_MAX];
extern volatile int  g_search_vis_count;    // matches visible in viewport
extern volatile int  g_search_cur_vis_row;  // viewport-row of current match (-1 = off-screen)
extern volatile int  g_search_cur_vis_cs;   // current match col_start (viewport)
extern volatile int  g_search_cur_vis_ce;   // current match col_end (viewport)

// ---------------------------------------------------------------------------
// Config reload
// ---------------------------------------------------------------------------

// Set to 1 (atomically) to trigger a config reload on the next PTY thread tick.
// Also written by SIGUSR1 handler. Read-and-reset by PTY thread.
extern volatile int g_needs_reload_config;

// Set g_needs_reload_config = 1. Safe to call from any thread (signal-safe).
// Implemented in Zig (ui2.zig).
void attyx_trigger_config_reload(void);

// Set to 1 by PTY thread when font config changes (family, size, fallbacks, cell dims).
// Main render thread reads, rebuilds the glyph cache + resizes window, then clears.
extern volatile int g_needs_font_rebuild;

// ---------------------------------------------------------------------------
// App icon (PNG bytes embedded at build time via @embedFile)
// ---------------------------------------------------------------------------

extern const uint8_t* g_icon_png;
extern int            g_icon_png_len;

// ---------------------------------------------------------------------------
// Background transparency and blur (written by Zig at startup)
// ---------------------------------------------------------------------------

extern volatile float g_background_opacity; // 0.0 = transparent, 1.0 = opaque
extern volatile int   g_background_blur;    // >0 = blur enabled (macOS: NSVisualEffectView)
extern volatile int   g_window_decorations; // 1 = show title bar, 0 = hide title bar

// Window padding in logical pixels (written by Zig at startup)
extern volatile int g_padding_left;
extern volatile int g_padding_right;
extern volatile int g_padding_top;
extern volatile int g_padding_bottom;

// ---------------------------------------------------------------------------
// Logging bridge (implemented in ui2.zig / main.zig stub)
// ---------------------------------------------------------------------------

// Levels: 0=err, 1=warn, 2=info, 3=debug, 4=trace
void attyx_log(int level, const char* scope, const char* msg);

#define ATTYX_LOG_ERR(scope, fmt, ...)   do { char _lb[1024]; snprintf(_lb, sizeof(_lb), fmt, ##__VA_ARGS__); attyx_log(0, scope, _lb); } while(0)
#define ATTYX_LOG_WARN(scope, fmt, ...)  do { char _lb[1024]; snprintf(_lb, sizeof(_lb), fmt, ##__VA_ARGS__); attyx_log(1, scope, _lb); } while(0)
#define ATTYX_LOG_INFO(scope, fmt, ...)  do { char _lb[1024]; snprintf(_lb, sizeof(_lb), fmt, ##__VA_ARGS__); attyx_log(2, scope, _lb); } while(0)
#define ATTYX_LOG_DEBUG(scope, fmt, ...) do { char _lb[1024]; snprintf(_lb, sizeof(_lb), fmt, ##__VA_ARGS__); attyx_log(3, scope, _lb); } while(0)
#define ATTYX_LOG_TRACE(scope, fmt, ...) do { char _lb[1024]; snprintf(_lb, sizeof(_lb), fmt, ##__VA_ARGS__); attyx_log(4, scope, _lb); } while(0)

#endif
