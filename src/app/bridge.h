#ifndef ATTYX_BRIDGE_H
#define ATTYX_BRIDGE_H

#include <stdint.h>

#define ATTYX_MAX_ROWS 256
#define ATTYX_MAX_COLS 512

typedef struct {
    uint32_t character;
    uint32_t combining[2]; // combining marks (0 = none)
    uint8_t fg_r, fg_g, fg_b;
    uint8_t bg_r, bg_g, bg_b;
    uint8_t flags; // bit 0 = bold, bit 1 = underline, bit 2 = default bg (apply opacity), bit 3 = dim, bit 4 = italic, bit 5 = strikethrough
    uint32_t link_id; // hyperlink ID (0 = none), maps to engine's link table
} AttyxCell;

// Blocks until the window is closed. Reads cells each frame (live).
void attyx_run(AttyxCell* cells, int cols, int rows);

// Update cursor position (called from PTY thread).
void attyx_set_cursor(int row, int col);
extern volatile int g_cursor_row;
extern volatile int g_cursor_col;

// Number of grid rows to shift terminal content down (for search bar padding).
// Overlays are NOT shifted — they render at the original offY.
extern volatile int g_grid_top_offset;
extern volatile int g_grid_bottom_offset;
extern volatile int g_statusbar_visible;
extern volatile int g_statusbar_position; // 0=top, 1=bottom
extern volatile int g_tab_bar_visible;

// Spawn a new attyx process (new window with fresh shell session).
void attyx_spawn_new_window(void);

// Signal the window to close (called from PTY thread on child exit).
void attyx_request_quit(void);

// Check if the window has been closed (polled by PTY thread).
int attyx_should_quit(void);

// Send keyboard input to the PTY (called from main/Cocoa thread).
// Implemented in Zig (terminal.zig).
void attyx_send_input(const uint8_t* bytes, int len);

// Clear screen and scrollback (Cmd+K / Ctrl+Shift+K).
// Signals the PTY thread to clear the engine state directly and send
// a form feed to the shell for prompt redraw.
void attyx_clear_screen(void);

// Copy text to system clipboard (callable from any thread).
void attyx_clipboard_copy(const char* text, int len);

// Handle a key event from the platform layer. Encodes using xterm or Kitty
// protocol depending on terminal state, then writes to PTY.
// key: KeyCode enum value, mods: modifier bitmask (bit0=shift,1=alt,2=ctrl,3=super),
// event_type: 1=press,2=repeat,3=release, codepoint: Unicode codepoint (for KeyCode.codepoint)
void attyx_handle_key(uint16_t key, uint8_t mods, uint8_t event_type, uint32_t codepoint);

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

// Per-row soft-wrap flag (viewport-relative, updated inside seqlock).
// 1 = row was soft-wrapped (auto-wrap at right edge), 0 = hard newline.
extern volatile uint8_t g_row_wrapped[ATTYX_MAX_ROWS];

// Kitty keyboard protocol flags (written by PTY thread, read by main thread).
extern volatile int g_kitty_kbd_flags;

// Cursor shape and visibility (written by PTY thread, read by renderer).
// shape: 0=blinking_block, 1=steady_block, 2=blinking_underline,
//        3=steady_underline, 4=blinking_bar, 5=steady_bar
extern volatile int g_cursor_shape;
extern volatile int g_cursor_visible;   // 1=visible, 0=hidden
extern volatile int g_cursor_trail;     // 1=trail enabled, 0=disabled

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

// Grid-based search input: input thread -> PTY thread (Zig-side)
void attyx_search_insert_char(uint32_t codepoint);
void attyx_search_cmd(int cmd);  // 1=backspace 2=delete 3=left 4=right 5=home 6=end 7=dismiss 8=next 9=prev

// AI edit prompt input: input thread -> PTY thread (Zig-side)
extern volatile int g_ai_prompt_active;  // 1 = AI edit prompt has focus (Zig-owned)
void attyx_ai_prompt_insert_char(uint32_t codepoint);
void attyx_ai_prompt_cmd(int cmd);  // 1=backspace 2=delete 3=left 4=right 5=home 6=end 7=cancel 8=submit

// Session picker input: input thread -> PTY thread (Zig-side)
extern volatile int g_session_picker_active;  // 1 = session picker overlay has focus
void attyx_picker_insert_char(uint32_t codepoint);
void attyx_picker_cmd(int cmd);  // 1=bs 7=esc 8=enter 9=up 10=down 11=ctrl_r 12=ctrl_x 13=ctrl_u

// ---------------------------------------------------------------------------
// Config reload
// ---------------------------------------------------------------------------

// Set to 1 (atomically) to trigger a config reload on the next PTY thread tick.
// Also written by SIGUSR1 handler. Read-and-reset by PTY thread.
extern volatile int g_needs_reload_config;

// Set g_needs_reload_config = 1. Safe to call from any thread (signal-safe).
// Implemented in Zig (terminal.zig).
void attyx_trigger_config_reload(void);

// Set to 1 by PTY thread when font config changes (family, size, fallbacks, cell dims).
// Main render thread reads, rebuilds the glyph cache + resizes window, then clears.
extern volatile int g_needs_font_rebuild;

// Set to 1 by PTY thread when window properties change (opacity, blur, decorations, padding).
// Main render thread reads, applies updates via attyx_apply_window_update(), then clears.
extern volatile int g_needs_window_update;
void attyx_apply_window_update(void);

// ---------------------------------------------------------------------------
// App icon (PNG bytes embedded at build time via @embedFile)
// ---------------------------------------------------------------------------

extern const uint8_t* g_icon_png;
extern int            g_icon_png_len;

extern const uint8_t* g_app_version;
extern int            g_app_version_len;

// ---------------------------------------------------------------------------
// Background transparency and blur (written by Zig at startup)
// ---------------------------------------------------------------------------

extern volatile float g_background_opacity; // 0.0 = transparent, 1.0 = opaque
extern volatile int   g_background_blur;    // >0 = blur enabled (macOS: NSVisualEffectView)
extern volatile int   g_window_decorations; // 1 = show title bar, 0 = hide title bar

// ---------------------------------------------------------------------------
// Theme colors (written by Zig at startup and on config reload)
// ---------------------------------------------------------------------------

// Cursor color components (0–255). g_theme_cursor_r < 0 means "use foreground color".
extern volatile int g_theme_cursor_r;
extern volatile int g_theme_cursor_g;
extern volatile int g_theme_cursor_b;

// Selection highlight background. g_theme_sel_bg_set=0 means use renderer default.
extern volatile int g_theme_sel_bg_set;
extern volatile int g_theme_sel_bg_r;
extern volatile int g_theme_sel_bg_g;
extern volatile int g_theme_sel_bg_b;

// Selection highlight foreground. g_theme_sel_fg_set=0 means use cell foreground.
extern volatile int g_theme_sel_fg_set;
extern volatile int g_theme_sel_fg_r;
extern volatile int g_theme_sel_fg_g;
extern volatile int g_theme_sel_fg_b;

// Theme background color (0–255), used for gap/padding quads.
extern volatile int g_theme_bg_r;
extern volatile int g_theme_bg_g;
extern volatile int g_theme_bg_b;

// Window padding in logical pixels (written by Zig at startup)
extern volatile int g_padding_left;
extern volatile int g_padding_right;
extern volatile int g_padding_top;
extern volatile int g_padding_bottom;

// Cell dimensions in points (written by renderer after glyph cache creation / font rebuild)
extern volatile float g_cell_w_pts;
extern volatile float g_cell_h_pts;

// ---------------------------------------------------------------------------
// Kitty graphics image placements (written by PTY thread inside seqlock,
// read by renderer thread)
// ---------------------------------------------------------------------------

#define ATTYX_MAX_IMAGE_PLACEMENTS 64

typedef struct {
    uint32_t image_id;
    int      row;          // viewport-relative row
    int      col;          // column
    uint32_t img_width;    // full image pixel width
    uint32_t img_height;   // full image pixel height
    uint32_t src_x, src_y; // source rect offset in pixels
    uint32_t src_w, src_h; // source rect size (0 = full image)
    uint32_t display_cols; // display width in cells (0 = auto)
    uint32_t display_rows; // display height in cells (0 = auto)
    int32_t  z_index;
    const uint8_t* pixels; // RGBA8 pixel data pointer (valid during seqlock)
} AttyxImagePlacement;

extern AttyxImagePlacement g_image_placements[ATTYX_MAX_IMAGE_PLACEMENTS];
extern volatile int      g_image_placement_count;
extern volatile uint64_t g_image_gen; // bumped when image placements change

// ---------------------------------------------------------------------------
// Overlay system (written by PTY thread inside seqlock, read by renderer)
// ---------------------------------------------------------------------------

#define ATTYX_OVERLAY_MAX_CELLS  2048
#define ATTYX_OVERLAY_MAX_LAYERS 16

typedef struct {
    uint32_t character;
    uint32_t combining[2]; // combining marks (0 = none)
    uint8_t fg_r, fg_g, fg_b;
    uint8_t bg_r, bg_g, bg_b;
    uint8_t bg_alpha;
    uint8_t flags; // bit 0=bold, 1=underline, 3=dim, 4=italic, 5=strikethrough
} AttyxOverlayCell;

typedef struct {
    int visible;
    int col, row;
    int width, height;
    int cell_count;
    int z_order;
} AttyxOverlayDesc;

extern AttyxOverlayDesc  g_overlay_descs[ATTYX_OVERLAY_MAX_LAYERS];
extern AttyxOverlayCell  g_overlay_cells[ATTYX_OVERLAY_MAX_LAYERS][ATTYX_OVERLAY_MAX_CELLS];
extern volatile int      g_overlay_count;
extern volatile uint32_t g_overlay_gen;

// Hit-test a point against visible overlay layers.
// Returns 1 if (col, row) is inside any visible overlay, 0 otherwise.
// Defined inline to avoid Zig 0.15.2 MIR codegen bug when accessing
// C structs from Zig on Linux x86_64 Debug builds.
static inline int attyx_overlay_hit_test(int col, int row) {
    int count = g_overlay_count;
    if (count <= 0) return 0;
    if (count > ATTYX_OVERLAY_MAX_LAYERS) count = ATTYX_OVERLAY_MAX_LAYERS;
    for (int i = 0; i < count; i++) {
        AttyxOverlayDesc d = g_overlay_descs[i];
        if (d.visible && col >= d.col && col < d.col + d.width &&
            row >= d.row && row < d.row + d.height)
            return 1;
    }
    return 0;
}

void attyx_toggle_debug_overlay(void);

extern volatile int g_toggle_anchor_demo;
void attyx_toggle_anchor_demo(void);

extern volatile int g_toggle_ai_demo;
void attyx_toggle_ai_demo(void);

extern volatile int g_toggle_session_switcher;
void attyx_toggle_session_switcher(void);

extern volatile int g_create_session_direct;
void attyx_create_session_direct(void);

// Overlay interaction (PTY thread -> input thread: read-only signal)
extern volatile int g_overlay_has_actions;

// Overlay interaction commands (input thread -> PTY thread via Zig functions)
void attyx_overlay_esc(void);
void attyx_overlay_tab(void);
void attyx_overlay_shift_tab(void);
void attyx_overlay_enter(void);

// Overlay mouse interaction: returns 1 if click/scroll was consumed by an overlay.
int attyx_overlay_click(int col, int row);
int attyx_overlay_scroll(int col, int row, int delta);

// ---------------------------------------------------------------------------
// Popup terminal (written by PTY thread, read by renderer)
// ---------------------------------------------------------------------------

#define ATTYX_POPUP_MAX_CELLS 16384
#define ATTYX_POPUP_MAX 32

typedef struct {
    int active;
    int col, row;               // grid position (top-left of border)
    int width, height;          // total dims including border
    int inner_cols, inner_rows; // terminal grid inside popup
    int cursor_row, cursor_col;
    int cursor_visible;
    int cursor_shape;
} AttyxPopupDesc;

extern AttyxPopupDesc    g_popup_desc;
extern AttyxOverlayCell  g_popup_cells[ATTYX_POPUP_MAX_CELLS];
extern volatile uint32_t g_popup_gen;
extern volatile int      g_popup_active;        // 1 = popup visible, input routed there
extern volatile int      g_popup_trail_active;  // 1 = popup cursor trail animating

#define ATTYX_POPUP_MAX_IMAGE_PLACEMENTS 16
extern AttyxImagePlacement g_popup_image_placements[ATTYX_POPUP_MAX_IMAGE_PLACEMENTS];
extern volatile int        g_popup_image_placement_count;

// ---------------------------------------------------------------------------
// Configurable keybindings (implemented in Zig keybinds.zig)
// ---------------------------------------------------------------------------

// Action constants (must match Action enum in keybinds.zig)
#define ATTYX_ACTION_NONE              0
#define ATTYX_ACTION_COPY              1
#define ATTYX_ACTION_PASTE             2
#define ATTYX_ACTION_SEARCH_TOGGLE     3
#define ATTYX_ACTION_SEARCH_NEXT       4
#define ATTYX_ACTION_SEARCH_PREV       5
#define ATTYX_ACTION_SCROLL_PAGE_UP    6
#define ATTYX_ACTION_SCROLL_PAGE_DOWN  7
#define ATTYX_ACTION_SCROLL_TO_TOP     8
#define ATTYX_ACTION_SCROLL_TO_BOTTOM  9
#define ATTYX_ACTION_CONFIG_RELOAD    10
#define ATTYX_ACTION_DEBUG_TOGGLE     11
#define ATTYX_ACTION_ANCHOR_DEMO      12
#define ATTYX_ACTION_NEW_WINDOW       13
#define ATTYX_ACTION_CLOSE_WINDOW     14
#define ATTYX_ACTION_POPUP_TOGGLE_0   15
#define ATTYX_ACTION_SEND_SEQUENCE    47
#define ATTYX_ACTION_AI_DEMO_TOGGLE   48
#define ATTYX_ACTION_TAB_NEW          49
#define ATTYX_ACTION_TAB_CLOSE        50
#define ATTYX_ACTION_TAB_NEXT         51
#define ATTYX_ACTION_TAB_PREV         52
#define ATTYX_ACTION_SPLIT_VERTICAL   53
#define ATTYX_ACTION_SPLIT_HORIZONTAL 54
#define ATTYX_ACTION_PANE_CLOSE       55
#define ATTYX_ACTION_PANE_FOCUS_UP    56
#define ATTYX_ACTION_PANE_FOCUS_DOWN  57
#define ATTYX_ACTION_PANE_FOCUS_LEFT  58
#define ATTYX_ACTION_PANE_FOCUS_RIGHT 59
#define ATTYX_ACTION_PANE_RESIZE_UP    60
#define ATTYX_ACTION_PANE_RESIZE_DOWN  61
#define ATTYX_ACTION_PANE_RESIZE_LEFT  62
#define ATTYX_ACTION_PANE_RESIZE_RIGHT 63
#define ATTYX_ACTION_TAB_SELECT_1     64
#define ATTYX_ACTION_TAB_SELECT_9     72
#define ATTYX_ACTION_CLEAR_SCREEN     73
#define ATTYX_ACTION_SESSION_SWITCHER 74
#define ATTYX_ACTION_SESSION_CREATE  75
#define ATTYX_ACTION_SESSION_KILL    76

// Returns action ID (0 = no match). For ATTYX_ACTION_SEND_SEQUENCE,
// g_keybind_matched_seq/len are set before returning.
uint8_t attyx_keybind_match(uint16_t key, uint8_t mods, uint32_t codepoint);

// Sequence result (valid after attyx_keybind_match returns SEND_SEQUENCE)
extern const uint8_t* g_keybind_matched_seq;
extern volatile int    g_keybind_matched_seq_len;

// ---------------------------------------------------------------------------
// Native macOS tabs
// ---------------------------------------------------------------------------

extern volatile int g_native_tabs_enabled;    // Zig-owned: 1 = use native window tabs
extern volatile int g_tab_always_show;         // Zig-owned: 1 = show tab bar with 1 tab
extern volatile int g_native_tab_count;        // PTY→main: current tab count
extern volatile int g_native_tab_active;       // PTY→main: current active index

#define ATTYX_NATIVE_TAB_TITLE_MAX 128
extern char g_native_tab_titles[16][ATTYX_NATIVE_TAB_TITLE_MAX]; // Zig-owned
extern volatile int g_native_tab_titles_changed; // Zig-owned: set to 1 when titles updated
extern volatile int g_native_tab_click;          // Zig-owned: main→PTY (-1=none)

// Tab management (called from input thread via keybind dispatch)
void attyx_tab_action(int action);
void attyx_tab_bar_click(int col, int grid_cols);
void attyx_statusbar_tab_click(int col, int grid_cols);

// Split pane management (called from input thread via keybind dispatch)
void attyx_split_action(int action);
void attyx_split_click(int col, int row);
extern volatile int g_split_active; // 1 when active tab has >1 pane

// Split pane drag resize (called from input thread mouse handlers)
void attyx_split_drag_start(int col, int row);
void attyx_split_drag_update(int col, int row);
void attyx_split_drag_end(void);
extern volatile int g_split_drag_active;    // 1 while drag in progress
extern volatile int g_split_drag_direction; // 0=vertical, 1=horizontal

// Input routing (called from input thread when g_popup_active)
void attyx_popup_send_input(const uint8_t* bytes, int len);
void attyx_popup_handle_key(uint16_t key, uint8_t mods, uint8_t event_type, uint32_t codepoint);
void attyx_popup_toggle(int index);

// ---------------------------------------------------------------------------
// Logging bridge (implemented in terminal.zig / main.zig stub)
// ---------------------------------------------------------------------------

// Levels: 0=err, 1=warn, 2=info, 3=debug, 4=trace
void attyx_log(int level, const char* scope, const char* msg);

#define ATTYX_LOG_ERR(scope, fmt, ...)   do { char _lb[1024]; snprintf(_lb, sizeof(_lb), fmt, ##__VA_ARGS__); attyx_log(0, scope, _lb); } while(0)
#define ATTYX_LOG_WARN(scope, fmt, ...)  do { char _lb[1024]; snprintf(_lb, sizeof(_lb), fmt, ##__VA_ARGS__); attyx_log(1, scope, _lb); } while(0)
#define ATTYX_LOG_INFO(scope, fmt, ...)  do { char _lb[1024]; snprintf(_lb, sizeof(_lb), fmt, ##__VA_ARGS__); attyx_log(2, scope, _lb); } while(0)
#define ATTYX_LOG_DEBUG(scope, fmt, ...) do { char _lb[1024]; snprintf(_lb, sizeof(_lb), fmt, ##__VA_ARGS__); attyx_log(3, scope, _lb); } while(0)
#define ATTYX_LOG_TRACE(scope, fmt, ...) do { char _lb[1024]; snprintf(_lb, sizeof(_lb), fmt, ##__VA_ARGS__); attyx_log(4, scope, _lb); } while(0)

#endif
