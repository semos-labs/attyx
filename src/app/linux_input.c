// Attyx — Linux input handling
// Keyboard, mouse, clipboard, framebuffer-resize, and GLFW error callbacks.

#include "linux_internal.h"

// ---------------------------------------------------------------------------
// Keyboard handling
// ---------------------------------------------------------------------------

// KeyCode enum values (must match src/term/key_encode.zig KeyCode)
enum {
    KC_UP = 0, KC_DOWN, KC_LEFT, KC_RIGHT,
    KC_HOME, KC_END, KC_PAGE_UP, KC_PAGE_DOWN,
    KC_INSERT, KC_DELETE,
    KC_BACKSPACE, KC_ENTER, KC_TAB, KC_ESCAPE,
    KC_F1, KC_F2, KC_F3, KC_F4, KC_F5, KC_F6,
    KC_F7, KC_F8, KC_F9, KC_F10, KC_F11, KC_F12,
    KC_KP_0, KC_KP_1, KC_KP_2, KC_KP_3, KC_KP_4,
    KC_KP_5, KC_KP_6, KC_KP_7, KC_KP_8, KC_KP_9,
    KC_KP_DECIMAL, KC_KP_DIVIDE, KC_KP_MULTIPLY,
    KC_KP_MINUS, KC_KP_PLUS, KC_KP_ENTER, KC_KP_EQUAL,
    KC_CODEPOINT,
};

static int g_suppress_char = 0;

static void snapViewport(void) {
    // Don't snap/clear when in copy mode — selection is keyboard-driven
    if (g_copy_mode) return;
    if (g_viewport_offset != 0) {
        g_viewport_offset = 0;
        attyx_mark_all_dirty();
    }
    if (g_sel_active) {
        g_sel_active = 0;
        attyx_mark_all_dirty();
    }
}

static uint16_t mapGlfwKey(int key) {
    switch (key) {
        case GLFW_KEY_UP:        return KC_UP;
        case GLFW_KEY_DOWN:      return KC_DOWN;
        case GLFW_KEY_RIGHT:     return KC_RIGHT;
        case GLFW_KEY_LEFT:      return KC_LEFT;
        case GLFW_KEY_HOME:      return KC_HOME;
        case GLFW_KEY_END:       return KC_END;
        case GLFW_KEY_PAGE_UP:   return KC_PAGE_UP;
        case GLFW_KEY_PAGE_DOWN: return KC_PAGE_DOWN;
        case GLFW_KEY_INSERT:    return KC_INSERT;
        case GLFW_KEY_DELETE:    return KC_DELETE;
        case GLFW_KEY_BACKSPACE: return KC_BACKSPACE;
        case GLFW_KEY_ENTER:     return KC_ENTER;
        case GLFW_KEY_TAB:       return KC_TAB;
        case GLFW_KEY_ESCAPE:    return KC_ESCAPE;
        case GLFW_KEY_F1:        return KC_F1;
        case GLFW_KEY_F2:        return KC_F2;
        case GLFW_KEY_F3:        return KC_F3;
        case GLFW_KEY_F4:        return KC_F4;
        case GLFW_KEY_F5:        return KC_F5;
        case GLFW_KEY_F6:        return KC_F6;
        case GLFW_KEY_F7:        return KC_F7;
        case GLFW_KEY_F8:        return KC_F8;
        case GLFW_KEY_F9:        return KC_F9;
        case GLFW_KEY_F10:       return KC_F10;
        case GLFW_KEY_F11:       return KC_F11;
        case GLFW_KEY_F12:       return KC_F12;
        case GLFW_KEY_KP_0:        return KC_KP_0;
        case GLFW_KEY_KP_1:        return KC_KP_1;
        case GLFW_KEY_KP_2:        return KC_KP_2;
        case GLFW_KEY_KP_3:        return KC_KP_3;
        case GLFW_KEY_KP_4:        return KC_KP_4;
        case GLFW_KEY_KP_5:        return KC_KP_5;
        case GLFW_KEY_KP_6:        return KC_KP_6;
        case GLFW_KEY_KP_7:        return KC_KP_7;
        case GLFW_KEY_KP_8:        return KC_KP_8;
        case GLFW_KEY_KP_9:        return KC_KP_9;
        case GLFW_KEY_KP_DECIMAL:  return KC_KP_DECIMAL;
        case GLFW_KEY_KP_DIVIDE:   return KC_KP_DIVIDE;
        case GLFW_KEY_KP_MULTIPLY: return KC_KP_MULTIPLY;
        case GLFW_KEY_KP_SUBTRACT: return KC_KP_MINUS;
        case GLFW_KEY_KP_ADD:      return KC_KP_PLUS;
        case GLFW_KEY_KP_ENTER:    return KC_KP_ENTER;
        case GLFW_KEY_KP_EQUAL:    return KC_KP_EQUAL;
        default:                 return UINT16_MAX;
    }
}

static uint8_t buildGlfwMods(int mods) {
    uint8_t m = 0;
    if (mods & GLFW_MOD_SHIFT)   m |= 1;
    if (mods & GLFW_MOD_ALT)     m |= 2;
    if (mods & GLFW_MOD_CONTROL) m |= 4;
    if (mods & GLFW_MOD_SUPER)   m |= 8;
    return m;
}

static uint8_t glfwActionToEventType(int action) {
    switch (action) {
        case GLFW_PRESS:   return 1;
        case GLFW_REPEAT:  return 2;
        case GLFW_RELEASE: return 3;
        default:           return 1;
    }
}

// ---------------------------------------------------------------------------
// Platform clipboard operations (called from Zig dispatch)
// ---------------------------------------------------------------------------

void attyx_platform_paste(void) {
    const char* text = clipboardPaste();
    if (!text || !*text) {
        ATTYX_LOG_DEBUG("clipboard", "paste: clipboard is empty");
        return;
    }
    int len = (int)strlen(text);
    void (*send_fn)(const uint8_t*, int) =
        g_popup_active ? attyx_popup_send_input : attyx_send_input;
    if (g_bracketed_paste) {
        send_fn((const uint8_t*)"\x1b[200~", 6);
        send_fn((const uint8_t*)text, len);
        send_fn((const uint8_t*)"\x1b[201~", 6);
    } else {
        send_fn((const uint8_t*)text, len);
    }
    ATTYX_LOG_DEBUG("clipboard", "paste: sent %d bytes to PTY", len);
}

// Build key + codepoint for keybind matching from a GLFW key event.
static void glfwToKeyCombo(int key, int mods, uint16_t* outKey, uint32_t* outCp) {
    uint16_t mapped = mapGlfwKey(key);
    if (mapped != UINT16_MAX) {
        *outKey = mapped;
        *outCp = 0;
    } else if (key >= GLFW_KEY_A && key <= GLFW_KEY_Z) {
        *outKey = KC_CODEPOINT;
        uint32_t cp = 'a' + (key - GLFW_KEY_A);
        if (mods & GLFW_MOD_SHIFT) cp -= 32;
        *outCp = cp;
    } else if (key >= GLFW_KEY_0 && key <= GLFW_KEY_9) {
        *outKey = KC_CODEPOINT;
        *outCp = '0' + (key - GLFW_KEY_0);
    } else {
        *outKey = KC_CODEPOINT;
        *outCp = 0;
    }
}

// Remap numpad keys to navigation when NumLock is off (standard PC behavior).
// GLFW always reports GLFW_KEY_KP_* regardless of numlock state, so we fix it here.
static int remapNumpadIfNoNumlock(int key, int mods) {
    if (mods & GLFW_MOD_NUM_LOCK) return key;
    switch (key) {
        case GLFW_KEY_KP_0:       return GLFW_KEY_INSERT;
        case GLFW_KEY_KP_1:       return GLFW_KEY_END;
        case GLFW_KEY_KP_2:       return GLFW_KEY_DOWN;
        case GLFW_KEY_KP_3:       return GLFW_KEY_PAGE_DOWN;
        case GLFW_KEY_KP_4:       return GLFW_KEY_LEFT;
        case GLFW_KEY_KP_5:       return -1; // no function
        case GLFW_KEY_KP_6:       return GLFW_KEY_RIGHT;
        case GLFW_KEY_KP_7:       return GLFW_KEY_HOME;
        case GLFW_KEY_KP_8:       return GLFW_KEY_UP;
        case GLFW_KEY_KP_9:       return GLFW_KEY_PAGE_UP;
        case GLFW_KEY_KP_DECIMAL: return GLFW_KEY_DELETE;
        default:                  return key;
    }
}

static void keyCallback(GLFWwindow* w, int key, int scancode, int action, int mods) {
    (void)w; (void)scancode;

    // Remap numpad digit keys to navigation when NumLock is off
    key = remapNumpadIfNoNumlock(key, mods);
    if (key < 0) return; // KP_5 with no numlock has no function

    // Handle key releases for kitty protocol
    if (action == GLFW_RELEASE) {
        if (g_kitty_kbd_flags & 2) {
            uint16_t mapped = mapGlfwKey(key);
            uint8_t m = buildGlfwMods(mods);
            void (*key_fn)(uint16_t, uint8_t, uint8_t, uint32_t) =
                g_popup_active ? attyx_popup_handle_key : attyx_handle_key;
            if (mapped != UINT16_MAX) {
                key_fn(mapped, m, 3, 0);
            } else if (key >= GLFW_KEY_A && key <= GLFW_KEY_Z) {
                uint32_t cp = 'a' + (key - GLFW_KEY_A);
                key_fn(KC_CODEPOINT, m, 3, cp);
            }
        }
        return;
    }

    g_suppress_char = 0;

    // Context menu: Escape dismisses it (contextual, not configurable).
    if (g_ctx_menu_open && key == GLFW_KEY_ESCAPE) {
        g_ctx_menu_open = 0;
        g_ctx_menu_hover = -1;
        g_full_redraw = 1;
        g_suppress_char = 1;
        return;
    }

    int ctrl  = (mods & GLFW_MOD_CONTROL) != 0;
    int alt   = (mods & GLFW_MOD_ALT) != 0;
    int shift = (mods & GLFW_MOD_SHIFT) != 0;

    // Overlay interaction keys (contextual, not user-configurable)
    if (g_overlay_has_actions && action != GLFW_RELEASE) {
        if (key == GLFW_KEY_ESCAPE) {
            attyx_overlay_esc();
            g_suppress_char = 1;
            return;
        }
        if (key == GLFW_KEY_TAB && !ctrl && !shift && !alt) {
            attyx_overlay_tab();
            g_suppress_char = 1;
            return;
        }
        if (key == GLFW_KEY_TAB && shift && !ctrl && !alt) {
            attyx_overlay_shift_tab();
            g_suppress_char = 1;
            return;
        }
        if (key == GLFW_KEY_ENTER && !ctrl && !shift && !alt) {
            attyx_overlay_enter();
            g_suppress_char = 1;
            return;
        }
    }

    // Copy/visual mode: intercept all keys when active
    if (g_copy_mode && action != GLFW_RELEASE) {
        uint16_t vmKey; uint32_t vmCp;
        glfwToKeyCombo(key, mods, &vmKey, &vmCp);
        uint8_t vmMods = buildGlfwMods(mods);
        if (attyx_copy_mode_key(vmKey, vmMods, vmCp)) {
            g_suppress_char = 1;
            return;
        }
    }

    // Configurable keybind match (covers search, scroll, copy/paste, popups, etc.)
    {
        uint16_t matchKey; uint32_t matchCp;
        glfwToKeyCombo(key, mods, &matchKey, &matchCp);
        uint8_t m = buildGlfwMods(mods);
        uint8_t act = attyx_keybind_match(matchKey, m, matchCp);
        if (act != ATTYX_ACTION_NONE && attyx_dispatch_action(act)) {
            g_suppress_char = 1;
            return;
        }
    }

    // Any input past this point goes to the PTY — snap viewport to bottom
    // so the user sees what they're typing. (Keybinds like scroll_page_up
    // already returned above, so they won't trigger this.)
    snapViewport();

    // Shift+Enter / Alt+Enter: legacy fallback only.
    // When Kitty keyboard protocol is active, the encoder reports modifiers
    // properly, so apps like Claude Code can distinguish them natively.
    if (!g_kitty_kbd_flags && key == GLFW_KEY_ENTER) {
        if (shift && !alt && !ctrl && !(mods & GLFW_MOD_SUPER)) {
            const uint8_t nl = '\n';
            void (*send_fn)(const uint8_t*, int) =
                g_popup_active ? attyx_popup_send_input : attyx_send_input;
            send_fn(&nl, 1);
            g_suppress_char = 1;
            return;
        }
        if (alt && !ctrl && !shift && !(mods & GLFW_MOD_SUPER)) {
            const uint8_t seq[2] = { 0x1b, '\r' };
            void (*send_fn)(const uint8_t*, int) =
                g_popup_active ? attyx_popup_send_input : attyx_send_input;
            send_fn(seq, 2);
            g_suppress_char = 1;
            return;
        }
    }

    // Alt+Arrow: send word movement sequences (ESC b / ESC f) in legacy mode.
    // When Kitty protocol is active, let the encoder send proper CSI with
    // modifier bits so apps get the real Alt+Arrow info.
    if (!g_kitty_kbd_flags && alt && !ctrl && !(mods & GLFW_MOD_SUPER)) {
        if (key == GLFW_KEY_LEFT || key == GLFW_KEY_RIGHT) {
            const uint8_t *seq = (key == GLFW_KEY_LEFT)
                ? (const uint8_t *)"\x1b" "b" : (const uint8_t *)"\x1b" "f";
            void (*send_fn)(const uint8_t*, int) =
                g_popup_active ? attyx_popup_send_input : attyx_send_input;
            send_fn(seq, 2);
            g_suppress_char = 1;
            return;
        }
    }

    // When search bar is open, route keys to search commands
    if (g_search_active) {
        if (key == GLFW_KEY_ESCAPE)       { attyx_search_cmd(7); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_ENTER)        { attyx_search_cmd(shift ? 9 : 8); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_BACKSPACE)    { attyx_search_cmd(1); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_DELETE)       { attyx_search_cmd(2); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_LEFT)         { attyx_search_cmd(3); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_RIGHT)        { attyx_search_cmd(4); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_HOME)         { attyx_search_cmd(5); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_END)          { attyx_search_cmd(6); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_UP)           { attyx_search_cmd(9); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_DOWN)         { attyx_search_cmd(8); g_suppress_char = 1; return; }
        if (ctrl && key == GLFW_KEY_W)   { attyx_search_cmd(10); g_suppress_char = 1; return; }
        g_suppress_char = 0;
        return;
    }

    // AI edit prompt key routing
    if (g_ai_prompt_active) {
        if (key == GLFW_KEY_ESCAPE)       { attyx_ai_prompt_cmd(7); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_ENTER)        { attyx_ai_prompt_cmd(8); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_BACKSPACE)    { attyx_ai_prompt_cmd(1); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_DELETE)       { attyx_ai_prompt_cmd(2); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_LEFT)         { attyx_ai_prompt_cmd(3); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_RIGHT)        { attyx_ai_prompt_cmd(4); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_HOME)         { attyx_ai_prompt_cmd(5); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_END)          { attyx_ai_prompt_cmd(6); g_suppress_char = 1; return; }
        g_suppress_char = 0;
        return;
    }

    // Session picker / command palette key routing
    if (g_session_picker_active || g_command_palette_active || g_theme_picker_active) {
        if (key == GLFW_KEY_ESCAPE)       { attyx_picker_cmd(7); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_ENTER)        { attyx_picker_cmd(8); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_BACKSPACE)    { attyx_picker_cmd(1); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_DELETE)       { attyx_picker_cmd(1); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_UP)           { attyx_picker_cmd(9); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_DOWN)         { attyx_picker_cmd(10); g_suppress_char = 1; return; }
        if (ctrl && key == GLFW_KEY_R)    { attyx_picker_cmd(11); g_suppress_char = 1; return; }
        if (ctrl && key == GLFW_KEY_X)    { attyx_picker_cmd(12); g_suppress_char = 1; return; }
        if (ctrl && key == GLFW_KEY_U)    { attyx_picker_cmd(13); g_suppress_char = 1; return; }
        if (ctrl && key == GLFW_KEY_D)    { attyx_picker_cmd(14); g_suppress_char = 1; return; }
        if (ctrl && key == GLFW_KEY_W)    { attyx_picker_cmd(15); g_suppress_char = 1; return; }
        if (ctrl && key == GLFW_KEY_C)    { attyx_picker_cmd(7); g_suppress_char = 1; return; }
        g_suppress_char = 0;
        return;
    }

    // When popup is active, route ALL input to popup
    if (g_popup_active && action != GLFW_RELEASE) {
        uint16_t mapped = mapGlfwKey(key);
        uint8_t m = buildGlfwMods(mods);
        uint8_t et = glfwActionToEventType(action);
        if (mapped != UINT16_MAX) {
            attyx_popup_handle_key(mapped, m, et, 0);
        } else if (key >= GLFW_KEY_A && key <= GLFW_KEY_Z) {
            uint32_t cp = 'a' + (key - GLFW_KEY_A);
            if (shift) cp -= 32;
            attyx_popup_handle_key(KC_CODEPOINT, m, et, cp);
        }
        g_suppress_char = 1;
        return;
    }

    // Modifier-only keys must not clear selection or snap viewport.
    // Without this, pressing Shift (part of Ctrl+Shift+C) clears the
    // selection before the full chord arrives.
    if (key == GLFW_KEY_LEFT_SHIFT   || key == GLFW_KEY_RIGHT_SHIFT   ||
        key == GLFW_KEY_LEFT_CONTROL || key == GLFW_KEY_RIGHT_CONTROL ||
        key == GLFW_KEY_LEFT_ALT     || key == GLFW_KEY_RIGHT_ALT     ||
        key == GLFW_KEY_LEFT_SUPER   || key == GLFW_KEY_RIGHT_SUPER)
        return;

    snapViewport();

    // Map special keys through the encoder
    uint16_t mapped = mapGlfwKey(key);
    uint8_t m = buildGlfwMods(mods);
    uint8_t et = glfwActionToEventType(action);

    if (mapped != UINT16_MAX) {
        attyx_handle_key(mapped, m, et, 0);
        g_suppress_char = 1;
        return;
    }

    // Ctrl+key or Alt+key with a letter
    if ((ctrl || alt) && key >= GLFW_KEY_A && key <= GLFW_KEY_Z) {
        uint32_t cp = 'a' + (key - GLFW_KEY_A);
        if (shift) cp -= 32;
        attyx_handle_key(KC_CODEPOINT, m, et, cp);
        g_suppress_char = 1;
        return;
    }

    // Ctrl+punctuation
    if (ctrl && !alt && !shift) {
        uint32_t cp = 0;
        switch (key) {
            case GLFW_KEY_LEFT_BRACKET:  cp = '['; break;
            case GLFW_KEY_RIGHT_BRACKET: cp = ']'; break;
            case GLFW_KEY_BACKSLASH:     cp = '\\'; break;
            case GLFW_KEY_SPACE:         cp = ' '; break;
            default: g_suppress_char = 1; return;
        }
        attyx_handle_key(KC_CODEPOINT, m, et, cp);
        g_suppress_char = 1;
        return;
    }
}

static void charCallback(GLFWwindow* w, unsigned int codepoint) {
    (void)w;
    if (g_suppress_char) { g_suppress_char = 0; return; }
    if (g_copy_mode) return;

    // When search bar is open, route chars to search overlay
    if (g_search_active) {
        if (codepoint >= 0x20) attyx_search_insert_char(codepoint);
        return;
    }

    // When AI prompt is open, route chars to prompt
    if (g_ai_prompt_active) {
        if (codepoint >= 0x20) attyx_ai_prompt_insert_char(codepoint);
        return;
    }

    // When session picker or command palette is open, route chars to picker
    if (g_session_picker_active || g_command_palette_active || g_theme_picker_active) {
        if (codepoint >= 0x20) attyx_picker_insert_char(codepoint);
        return;
    }

    // When popup is active, route chars to popup
    if (g_popup_active) {
        attyx_popup_handle_key(KC_CODEPOINT, 0, 1, codepoint);
        return;
    }

    snapViewport();

    // Send through encoder for kitty protocol support
    attyx_handle_key(KC_CODEPOINT, 0, 1, codepoint);
}

// ---------------------------------------------------------------------------
// Mouse handling
// ---------------------------------------------------------------------------

static double g_last_click_time = 0;
static int g_last_click_col = -1, g_last_click_row = -1;
static int g_click_count = 0;
static int g_selecting = 0;
static int g_left_down = 0;
static int g_split_dragging = 0;

static inline int clampInt(int val, int lo, int hi) {
    if (val < lo) return lo;
    if (val > hi) return hi;
    return val;
}

void mouseToCell(double mx, double my, int* outCol, int* outRow) {
    float cellW = g_cell_px_w / g_content_scale;
    float cellH = g_cell_px_h / g_content_scale;
    int win_w, win_h;
    glfwGetWindowSize(g_window, &win_w, &win_h);
    float availW = (float)win_w - g_padding_left - g_padding_right;
    float availH = (float)win_h - g_padding_top  - g_padding_bottom;
    float cx = floorf((availW - g_cols * cellW) * 0.5f);
    float cy = 0;
    if (cx < 0) cx = 0;
    if (cy < 0) cy = 0;
    float offX = g_padding_left + cx;
    float offY = g_padding_top  + cy;
    *outCol = clampInt((int)((mx - offX) / cellW), 0, g_cols - 1);
    *outRow = clampInt((int)((my - offY) / cellH), 0, g_rows - 1);
}

void mouseToCell1(double mx, double my, int* outCol, int* outRow) {
    float cellW = g_cell_px_w / g_content_scale;
    float cellH = g_cell_px_h / g_content_scale;
    int win_w, win_h;
    glfwGetWindowSize(g_window, &win_w, &win_h);
    float availW = (float)win_w - g_padding_left - g_padding_right;
    float availH = (float)win_h - g_padding_top  - g_padding_bottom;
    float cx = floorf((availW - g_cols * cellW) * 0.5f);
    float cy = 0;
    if (cx < 0) cx = 0;
    if (cy < 0) cy = 0;
    float offX = g_padding_left + cx;
    float offY = g_padding_top  + cy;
    *outCol = clampInt((int)((mx - offX) / cellW) + 1, 1, g_cols);
    *outRow = clampInt((int)((my - offY) / cellH) + 1, 1, g_rows);
}

static void sendSgrMouse(int button, int col, int row, int press) {
    char buf[32];
    int len = snprintf(buf, sizeof(buf), "\x1b[<%d;%d;%d%c",
                       button, col, row, press ? 'M' : 'm');
    attyx_send_input((const uint8_t*)buf, len);
}

static void sendSgrMousePopup(int button, int col, int row, int press) {
    char buf[32];
    int len = snprintf(buf, sizeof(buf), "\x1b[<%d;%d;%d%c",
                       button, col, row, press ? 'M' : 'm');
    attyx_popup_send_input((const uint8_t*)buf, len);
}

// Test if grid-space (col, row) is inside the popup bounds.
// If inside, writes popup-local 1-based coordinates to outCol/outRow.
static int popupHitTest(int col, int row, int *outCol, int *outRow) {
    AttyxPopupDesc d = g_popup_desc;
    if (!d.active) return 0;
    // Popup is rendered at offY which includes g_grid_top_offset, so the
    // visual row is shifted down. mouseToCell returns raw grid coords
    // (row 0 = top of window), so we must account for that shift.
    int vis_row = d.row + g_grid_top_offset;
    if (col < d.col || col >= d.col + d.width) return 0;
    if (row < vis_row || row >= vis_row + d.height) return 0;
    int inner_col = col - d.col - d.content_col_off + 1;
    int inner_row = row - vis_row - d.content_row_off + 1;
    if (inner_col < 1) inner_col = 1;
    if (inner_row < 1) inner_row = 1;
    if (inner_col > d.inner_cols) inner_col = d.inner_cols;
    if (inner_row > d.inner_rows) inner_row = d.inner_rows;
    *outCol = inner_col;
    *outRow = inner_row;
    return 1;
}

static int mouseModifiers(int mods) {
    int m = 0;
    if (mods & GLFW_MOD_SHIFT)   m |= 4;
    if (mods & GLFW_MOD_ALT)     m |= 8;
    if (mods & GLFW_MOD_CONTROL) m |= 16;
    return m;
}

// Helper: context menu hit-test.
// Returns item index (CTX_MENU_ITEM_*) or -1 if outside the menu.
static int ctxMenuHitItem(float px, float py) {
    float gw = g_gc.glyph_w, gh = g_gc.glyph_h;
    float padX = gw * 0.5f, padY = gh * 0.25f;
    float itemH = gh + padY * 2.0f;
    float sepH  = padY * 2.0f;
    float menuW = padX * 2.0f + 13.0f * gw; // 13 = len("Reload Config")
    float menuH = itemH * 3.0f + sepH;       // Copy, Paste, sep, Reload Config

    if (px < g_ctx_menu_x || px > g_ctx_menu_x + menuW ||
        py < g_ctx_menu_y || py > g_ctx_menu_y + menuH)
        return -1;

    float relY = py - g_ctx_menu_y;
    if (relY < itemH)              return CTX_MENU_ITEM_COPY;
    if (relY < itemH * 2.0f)      return CTX_MENU_ITEM_PASTE;
    if (relY < itemH * 2.0f + sepH) return CTX_MENU_ITEM_SEPARATOR;
    return CTX_MENU_ITEM_RELOAD_CONFIG;
}

// Split separator hit-test (~20px grab zone around separator lines).
// mouseX: raw mouse X in screen coords.  offX/cellW: grid origin and cell width.
// Returns: 0 = miss, 1 = vertical (left-right resize), 2 = horizontal (up-down)
static int separatorHitTest(int col, int row, float mouseX, float offX, float cellW) {
    int srow = row - g_grid_top_offset;
    int scols = g_cols;
    if (!g_cells || srow < 0 || srow >= g_rows) return 0;
    const float halfHit = 10.0f;
    for (int dc = -1; dc <= 1; dc++) {
        int c = col + dc;
        if (c < 0 || c >= scols) continue;
        uint32_t ch = g_cells[srow * scols + c].character;
        int type = 0;
        if (ch == 0x2502) { type = 1; }
        else if (ch == 0x2500) { type = 2; }
        else if (ch == 0x253C || ch == 0x251C || ch == 0x2524 ||
                 ch == 0x252C || ch == 0x2534 || ch == 0x250C ||
                 ch == 0x2510 || ch == 0x2514 || ch == 0x2518) {
            int hasVert = 0;
            if (srow > 0) {
                uint32_t nc = g_cells[(srow-1) * scols + c].character;
                hasVert = (nc == 0x2502 || nc == 0x253C || nc == 0x251C ||
                           nc == 0x2524 || nc == 0x252C || nc == 0x2534);
            }
            type = hasVert ? 1 : 2;
        }
        if (type == 0) continue;
        float sepCenterX = offX + (c + 0.5f) * cellW;
        if (fabsf(mouseX - sepCenterX) <= halfHit) return type;
    }
    return 0;
}

static void mouseXOffset(double mx, float *outOffX, float *outCellW) {
    float cellW = g_cell_px_w / g_content_scale;
    int win_w, win_h;
    glfwGetWindowSize(g_window, &win_w, &win_h);
    float availW = (float)win_w - g_padding_left - g_padding_right;
    float cx = floorf((availW - g_cols * cellW) * 0.5f);
    if (cx < 0) cx = 0;
    *outOffX = g_padding_left + cx;
    *outCellW = cellW;
}

static void mouseButtonCallback(GLFWwindow* w, int button, int action, int mods) {
    double mx, my;
    glfwGetCursorPos(w, &mx, &my);

    // Popup mouse routing: all clicks go to popup when active
    if (g_popup_active) {
        int col, row;
        mouseToCell(mx, my, &col, &row);
        int pc, pr;
        if (button == GLFW_MOUSE_BUTTON_LEFT) {
            if (action == GLFW_PRESS) {
                if (popupHitTest(col, row, &pc, &pr) && g_popup_mouse_tracking && g_popup_mouse_sgr) {
                    int btn = 0 | mouseModifiers(mods);
                    sendSgrMousePopup(btn, pc, pr, 1);
                    g_left_down = 1;
                    g_last_motion_col = pc;
                    g_last_motion_row = pr;
                }
            } else {
                g_left_down = 0;
                if (popupHitTest(col, row, &pc, &pr) && g_popup_mouse_tracking && g_popup_mouse_sgr) {
                    int btn = 0 | mouseModifiers(mods);
                    sendSgrMousePopup(btn, pc, pr, 0);
                }
            }
        } else if (button == GLFW_MOUSE_BUTTON_RIGHT) {
            if (popupHitTest(col, row, &pc, &pr) && g_popup_mouse_tracking && g_popup_mouse_sgr)
                sendSgrMousePopup(2 | mouseModifiers(mods), pc, pr, action == GLFW_PRESS);
        } else if (button == GLFW_MOUSE_BUTTON_MIDDLE) {
            if (popupHitTest(col, row, &pc, &pr) && g_popup_mouse_tracking && g_popup_mouse_sgr)
                sendSgrMousePopup(1 | mouseModifiers(mods), pc, pr, action == GLFW_PRESS);
        }
        return;
    }

    // Context menu: consume all presses while open, then close.
    if (g_ctx_menu_open && action == GLFW_PRESS) {
        float px = (float)(mx * g_content_scale);
        float py = (float)(my * g_content_scale);
        if (button == GLFW_MOUSE_BUTTON_LEFT) {
            int item = ctxMenuHitItem(px, py);
            switch (item) {
                case CTX_MENU_ITEM_COPY:          attyx_platform_copy(); break;
                case CTX_MENU_ITEM_PASTE:         attyx_platform_paste(); break;
                case CTX_MENU_ITEM_RELOAD_CONFIG: attyx_trigger_config_reload(); break;
                default: break;
            }
        }
        g_ctx_menu_open = 0;
        g_ctx_menu_hover = -1;
        g_full_redraw = 1;
        return;
    }

    if (button == GLFW_MOUSE_BUTTON_LEFT) {
        if (action == GLFW_PRESS) {
            // Mouse click exits copy mode
            if (g_copy_mode) {
                attyx_copy_mode_exit(0);
            }

            // Split separator click: intercept before mouse tracking so drag
            // resize works even when focused pane tracks the mouse (e.g. vim).
            if (g_split_active) {
                int sc, sr;
                mouseToCell(mx, my, &sc, &sr);
                float ox, cw;
                mouseXOffset(mx, &ox, &cw);
                if (separatorHitTest(sc, sr, (float)mx, ox, cw)) {
                    attyx_split_drag_start(sc, sr);
                    g_split_dragging = 1;
                    return;
                }
            }

            if (g_mouse_tracking && g_mouse_sgr) {
                int col, row;
                mouseToCell1(mx, my, &col, &row);
                sendSgrMouse(0 | mouseModifiers(mods), col, row, 1);
                g_left_down = 1;
                return;
            }
            int col, row;
            mouseToCell(mx, my, &col, &row);

            // Tab bar click: consume if click is on the tab bar row
            if (row == 0 && g_tab_bar_visible) {
                attyx_tab_bar_click(col, g_cols);
                return;
            }

            // Statusbar tab click: check if click is on the statusbar row
            if (g_statusbar_visible) {
                int sb_row = (g_statusbar_position == 0) ? 0 : (g_rows - 1);
                if (row == sb_row) {
                    attyx_statusbar_tab_click(col, g_cols);
                    return;
                }
            }

            // Overlay click: consume if hit
            if (g_overlay_has_actions && attyx_overlay_click(col, row)) return;

            // Split pane click: focus the clicked pane + start drag resize
            if (g_split_active) {
                attyx_split_drag_start(col, row);
                g_split_dragging = 1;
                attyx_split_click(col, row);
            }

            // Adjust row to content space for selection and cell access.
            // Tab bar, statusbar, overlay, and split all use grid-space row above.
            row -= g_grid_top_offset;
            if (row < 0) row = 0;

            // Ctrl+click opens hyperlink
            if (mods & GLFW_MOD_CONTROL) {
                int cols = g_cols, nrows = g_rows;
                if (g_cells && col >= 0 && col < cols && row >= 0 && row < nrows) {
                    // OSC 8 link takes priority
                    uint32_t lid = g_cells[row * cols + col].link_id;
                    if (lid != 0) {
                        char uri_buf[2048];
                        int uri_len = attyx_get_link_uri(lid, uri_buf, sizeof(uri_buf));
                        if (uri_len > 0) {
                            char cmd[2200];
                            snprintf(cmd, sizeof(cmd), "xdg-open '%s' &", uri_buf);
                            (void)system(cmd);
                        }
                        g_left_down = 1;
                        return;
                    }

                    // Fallback: regex-detected URL
                    int dStart, dEnd;
                    char dUrl[DETECTED_URL_MAX];
                    int dLen = 0;
                    if (detectUrlAtCell(row, col, cols, &dStart, &dEnd, dUrl, DETECTED_URL_MAX, &dLen) && dLen > 0) {
                        char cmd[2200];
                        snprintf(cmd, sizeof(cmd), "xdg-open '%s' &", dUrl);
                        (void)system(cmd);
                        g_left_down = 1;
                        return;
                    }
                }
            }

            // Shift-click extends existing selection
            if ((mods & GLFW_MOD_SHIFT) && g_sel_active) {
                g_sel_end_row = row;
                g_sel_end_col = col;
                g_selecting = 1;
                g_left_down = 1;
                attyx_mark_all_dirty();
                return;
            }

            double now = glfwGetTime();
            if (now - g_last_click_time < 0.35 && col == g_last_click_col && row == g_last_click_row)
                g_click_count++;
            else
                g_click_count = 1;
            g_last_click_time = now;
            g_last_click_col = col;
            g_last_click_row = row;

            if (g_click_count >= 3) {
                g_sel_start_row = row; g_sel_start_col = 0;
                g_sel_end_row = row;   g_sel_end_col = g_cols - 1;
                g_sel_active = 1;
            } else if (g_click_count == 2) {
                int wS, wE;
                findWordBounds(row, col, g_cols, &wS, &wE);
                g_sel_start_row = row; g_sel_start_col = wS;
                g_sel_end_row = row;   g_sel_end_col = wE;
                g_sel_active = 1;
            } else {
                g_sel_start_row = row; g_sel_start_col = col;
                g_sel_end_row = row;   g_sel_end_col = col;
                g_sel_active = 0;
            }
            g_selecting = 1;
            g_left_down = 1;
            attyx_mark_all_dirty();
        } else {
            g_left_down = 0;
            if (g_split_dragging) {
                if (g_split_drag_active) attyx_split_drag_end();
                g_split_dragging = 0;
            }
            if (g_mouse_tracking && g_mouse_sgr) {
                int col, row;
                mouseToCell1(mx, my, &col, &row);
                sendSgrMouse(0 | mouseModifiers(mods), col, row, 0);
                return;
            }
            if (g_selecting) {
                g_selecting = 0;
                if (g_sel_start_row != g_sel_end_row || g_sel_start_col != g_sel_end_col)
                    g_sel_active = 1;
                else if (g_click_count < 2)
                    g_sel_active = 0;
            }
        }
    } else if (button == GLFW_MOUSE_BUTTON_RIGHT) {
        if (action == GLFW_PRESS && !g_mouse_tracking) {
            // Compute menu position in vertex/framebuffer pixel coords, clamped to centered grid area.
            float gw = g_gc.glyph_w, gh = g_gc.glyph_h;
            float padX = gw * 0.5f, padY = gh * 0.25f;
            float itemH = gh + padY * 2.0f;
            float sepH  = padY * 2.0f;
            float menuW = padX * 2.0f + 13.0f * gw;
            float menuH = itemH * 3.0f + sepH;  // Copy, Paste, sep, Reload Config
            float px = (float)(mx * g_content_scale);
            float py = (float)(my * g_content_scale);
            int fb_w2, fb_h2;
            glfwGetFramebufferSize(w, &fb_w2, &fb_h2);
            float padLpx = g_padding_left   * g_content_scale;
            float padRpx = g_padding_right  * g_content_scale;
            float padTpx = g_padding_top    * g_content_scale;
            float padBpx = g_padding_bottom * g_content_scale;
            float avW = (float)fb_w2 - padLpx - padRpx;
            float avH = (float)fb_h2 - padTpx - padBpx;
            float cxp = floorf((avW - g_cols * gw) * 0.5f);
            float cyp = 0;
            if (cxp < 0) cxp = 0;
            if (cyp < 0) cyp = 0;
            float offXpx = padLpx + cxp;
            float offYpx = padTpx + cyp;
            if (px + menuW > offXpx + g_cols * gw) px = offXpx + g_cols * gw - menuW;
            if (py + menuH > offYpx + g_rows * gh) py = offYpx + g_rows * gh - menuH;
            if (px < offXpx) px = offXpx;
            if (py < offYpx) py = offYpx;
            g_ctx_menu_x = px;
            g_ctx_menu_y = py;
            g_ctx_menu_open = 1;
            g_ctx_menu_hover = -1;
            g_full_redraw = 1;
            return;
        }
        if (!g_mouse_tracking || !g_mouse_sgr) return;
        int col, row;
        mouseToCell1(mx, my, &col, &row);
        sendSgrMouse((2 | mouseModifiers(mods)), col, row, action == GLFW_PRESS);
    } else if (button == GLFW_MOUSE_BUTTON_MIDDLE) {
        if (!g_mouse_tracking || !g_mouse_sgr) return;
        int col, row;
        mouseToCell1(mx, my, &col, &row);
        sendSgrMouse((1 | mouseModifiers(mods)), col, row, action == GLFW_PRESS);
    }
}

static int g_last_motion_col = -1, g_last_motion_row = -1;

static void cursorPosCallback(GLFWwindow* w, double mx, double my) {
    (void)w;
    // Popup mouse routing: drag and move
    if (g_popup_active) {
        if (g_popup_mouse_tracking && g_popup_mouse_sgr) {
            int col, row;
            mouseToCell(mx, my, &col, &row);
            int pc, pr;
            if (popupHitTest(col, row, &pc, &pr)) {
                if (g_left_down && g_popup_mouse_tracking >= 2) {
                    if (pc != g_last_motion_col || pr != g_last_motion_row) {
                        sendSgrMousePopup(32, pc, pr, 1);
                        g_last_motion_col = pc;
                        g_last_motion_row = pr;
                    }
                } else if (!g_left_down && g_popup_mouse_tracking == 3) {
                    if (pc != g_last_motion_col || pr != g_last_motion_row) {
                        sendSgrMousePopup(35, pc, pr, 1);
                        g_last_motion_col = pc;
                        g_last_motion_row = pr;
                    }
                }
            }
        }
        return;
    }
    if (g_split_dragging && g_split_drag_active) {
        int col, row;
        mouseToCell(mx, my, &col, &row);
        attyx_split_drag_update(col, row);
        return;
    }

    // Split separator hover: check before mouse tracking so the resize
    // cursor appears even when the focused pane tracks the mouse.
    if (g_split_active && !g_split_drag_active) {
        static int wasOnSep = 0;
        int scol, srow;
        mouseToCell(mx, my, &scol, &srow);
        float ox, cw;
        mouseXOffset(mx, &ox, &cw);
        int hit = separatorHitTest(scol, srow, (float)mx, ox, cw);
        if (hit == 1) {
            glfwSetCursor(w, glfwCreateStandardCursor(GLFW_HRESIZE_CURSOR));
            wasOnSep = 1;
            return;
        } else if (hit == 2) {
            glfwSetCursor(w, glfwCreateStandardCursor(GLFW_VRESIZE_CURSOR));
            wasOnSep = 1;
            return;
        }
        if (wasOnSep) {
            wasOnSep = 0;
            glfwSetCursor(w, glfwCreateStandardCursor(GLFW_IBEAM_CURSOR));
        }
    }

    if (g_left_down && g_mouse_tracking && g_mouse_sgr) {
        if (g_mouse_tracking < 2) return;
        int col, row;
        mouseToCell1(mx, my, &col, &row);
        if (col == g_last_motion_col && row == g_last_motion_row) return;
        sendSgrMouse(32, col, row, 1);
        g_last_motion_col = col;
        g_last_motion_row = row;
        return;
    }
    if (!g_left_down && g_mouse_tracking == 3 && g_mouse_sgr) {
        int col, row;
        mouseToCell1(mx, my, &col, &row);
        if (col == g_last_motion_col && row == g_last_motion_row) return;
        sendSgrMouse(35, col, row, 1);
        g_last_motion_col = col;
        g_last_motion_row = row;
        return;
    }
    if (g_selecting && g_left_down) {
        // Auto-scroll when dragging past top/bottom edge
        if (!g_alt_screen) {
            float cellH = g_cell_px_h / g_content_scale;
            int win_w, win_h;
            glfwGetWindowSize(g_window, &win_w, &win_h);
            float availH = (float)win_h - g_padding_top - g_padding_bottom;
            float cyp = 0;
            if (cyp < 0) cyp = 0;
            float offY = g_padding_top + cyp;
            int rawRow = (int)((my - offY) / cellH);
            if (rawRow < 0 && g_scrollback_count > 0) {
                attyx_scroll_viewport(1);
                g_sel_start_row++;
            }
            if (rawRow >= g_rows && g_viewport_offset > 0) {
                attyx_scroll_viewport(-1);
                g_sel_start_row--;
            }
        }

        int col, row;
        mouseToCell(mx, my, &col, &row);
        row -= g_grid_top_offset;
        if (row < 0) row = 0;
        if (col == g_sel_end_col && row == g_sel_end_row) return;

        if (g_click_count >= 3) {
            g_sel_end_row = row;
            g_sel_end_col = (row >= g_sel_start_row) ? g_cols - 1 : 0;
            if (row < g_sel_start_row) g_sel_start_col = g_cols - 1;
            else g_sel_start_col = 0;
        } else if (g_click_count == 2) {
            int wS, wE;
            findWordBounds(row, col, g_cols, &wS, &wE);
            g_sel_end_row = row;
            if (row > g_sel_start_row || (row == g_sel_start_row && col >= g_sel_start_col))
                g_sel_end_col = wE;
            else
                g_sel_end_col = wS;
        } else {
            g_sel_end_row = row;
            g_sel_end_col = col;
        }
        g_sel_active = 1;
        attyx_mark_all_dirty();
        return;
    }

    // Hyperlink hover detection (when mouse mode is off)
    if (!g_mouse_tracking && !g_left_down) {
        int col, row;
        mouseToCell(mx, my, &col, &row);
        row -= g_grid_top_offset;
        if (row < 0) row = 0;
        int cols = g_cols, nrows = g_rows;

        // OSC 8 link check
        uint32_t lid = 0;
        if (g_cells && col >= 0 && col < cols && row >= 0 && row < nrows)
            lid = g_cells[row * cols + col].link_id;

        // Regex URL detection fallback
        int detStart = -1, detEnd = -1;
        char detUrlBuf[DETECTED_URL_MAX];
        int detUrlLen = 0;
        int hasDetected = 0;
        if (lid == 0 && g_cells && col >= 0 && col < cols && row >= 0 && row < nrows) {
            hasDetected = detectUrlAtCell(row, col, cols,
                                          &detStart, &detEnd,
                                          detUrlBuf, DETECTED_URL_MAX, &detUrlLen);
        }

        int isLink = (lid != 0 || hasDetected);
        int prevOscRow = g_hover_row;
        int prevDetRow = g_detected_url_row;
        uint32_t prevLid = g_hover_link_id;

        int oscChanged = (lid != prevLid);
        int detChanged = 0;
        if (hasDetected) {
            detChanged = (row != prevDetRow || detStart != g_detected_url_start_col || detEnd != g_detected_url_end_col);
        } else if (g_detected_url_len > 0) {
            detChanged = 1;
        }

        if (oscChanged || detChanged) {
            g_hover_link_id = lid;
            g_hover_row = (lid != 0) ? row : -1;

            if (hasDetected) {
                memcpy(g_detected_url, detUrlBuf, detUrlLen + 1);
                g_detected_url_len = detUrlLen;
                g_detected_url_row = row;
                g_detected_url_start_col = detStart;
                g_detected_url_end_col = detEnd;
            } else {
                g_detected_url_len = 0;
                g_detected_url_row = -1;
            }

            if (isLink)
                glfwSetCursor(w, glfwCreateStandardCursor(GLFW_HAND_CURSOR));
            else
                glfwSetCursor(w, glfwCreateStandardCursor(GLFW_IBEAM_CURSOR));

            if (prevOscRow >= 0 && prevOscRow < 256)
                __sync_fetch_and_or((volatile uint64_t*)&g_dirty[prevOscRow >> 6], (uint64_t)1 << (prevOscRow & 63));
            if (prevDetRow >= 0 && prevDetRow < 256)
                __sync_fetch_and_or((volatile uint64_t*)&g_dirty[prevDetRow >> 6], (uint64_t)1 << (prevDetRow & 63));
            if (row >= 0 && row < 256 && isLink)
                __sync_fetch_and_or((volatile uint64_t*)&g_dirty[row >> 6], (uint64_t)1 << (row & 63));
        }
    }

    // Context menu hover tracking.
    if (g_ctx_menu_open) {
        float px = (float)(mx * g_content_scale);
        float py = (float)(my * g_content_scale);
        int newHover = ctxMenuHitItem(px, py);
        // Don't highlight the separator
        if (newHover == CTX_MENU_ITEM_SEPARATOR) newHover = -1;
        if (newHover != g_ctx_menu_hover) {
            g_ctx_menu_hover = newHover;
            g_full_redraw = 1;
        }
    }
}

static void scrollCallback(GLFWwindow* w, double xoff, double yoff) {
    (void)xoff;
    if (g_popup_active) {
        if (g_popup_mouse_tracking && g_popup_mouse_sgr && yoff != 0) {
            double mx, my;
            glfwGetCursorPos(w, &mx, &my);
            int col, row;
            mouseToCell(mx, my, &col, &row);
            int pc, pr;
            if (popupHitTest(col, row, &pc, &pr)) {
                int btn = (yoff > 0 ? 64 : 65);
                sendSgrMousePopup(btn, pc, pr, 1);
            }
        }
        return;
    }
    if (g_mouse_tracking && g_mouse_sgr) {
        if (yoff == 0) return;
        double mx, my;
        glfwGetCursorPos(w, &mx, &my);
        int col, row;
        mouseToCell1(mx, my, &col, &row);
        int btn = (yoff > 0 ? 64 : 65);
        sendSgrMouse(btn, col, row, 1);
        return;
    }
    if (g_alt_screen) return;
    int lines = (int)yoff;
    if (lines == 0) lines = (yoff > 0) ? 1 : -1;
    // Overlay scroll: consume if hit
    if (g_overlay_has_actions) {
        double mx, my;
        glfwGetCursorPos(w, &mx, &my);
        int col, row;
        mouseToCell(mx, my, &col, &row);
        if (attyx_overlay_scroll(col, row, lines)) return;
    }
    attyx_scroll_viewport(lines);
}

// ---------------------------------------------------------------------------
// Copy to clipboard
// ---------------------------------------------------------------------------

void attyx_platform_copy(void) {
    attyx_copy_selection();
}

// ---------------------------------------------------------------------------
// Framebuffer resize callback
// ---------------------------------------------------------------------------

static void framebufferSizeCallback(GLFWwindow* w, int width, int height) {
    (void)w;
    if (g_cell_px_w <= 0 || g_cell_px_h <= 0) return;
    float padPxW = (float)(g_padding_left + g_padding_right) * g_content_scale;
    float padPxH = (float)(g_padding_top  + g_padding_bottom) * g_content_scale;
    int new_cols = (int)((width  - padPxW) / g_cell_px_w + 0.01f);
    int new_rows = (int)((height - padPxH) / g_cell_px_h + 0.01f);
    if (new_cols < 1) new_cols = 1;
    if (new_rows < 1) new_rows = 1;
    if (new_cols > ATTYX_MAX_COLS) new_cols = ATTYX_MAX_COLS;
    if (new_rows > ATTYX_MAX_ROWS) new_rows = ATTYX_MAX_ROWS;
    g_pending_resize_rows = new_rows;
    g_pending_resize_cols = new_cols;
    g_full_redraw = 1;
}

// ---------------------------------------------------------------------------
// GLFW error callback
// ---------------------------------------------------------------------------

static void errorCallback(int error, const char* description) {
    ATTYX_LOG_ERR("input", "GLFW error %d: %s", error, description);
}

// ---------------------------------------------------------------------------
// Drag and Drop — file path insertion
// ---------------------------------------------------------------------------

static void dropCallback(GLFWwindow* w, int count, const char** paths) {
    (void)w;
    if (count <= 0 || !paths) return;

    // Compute buffer size: each char could be ' (becomes 4 chars), plus quotes and spaces
    int totalMax = 0;
    for (int i = 0; i < count; i++)
        totalMax += (int)strlen(paths[i]) * 4 + 3; // worst case + surrounding quotes + space

    char* buf = (char*)malloc(totalMax);
    if (!buf) return;
    int pos = 0;

    for (int i = 0; i < count; i++) {
        if (i > 0) buf[pos++] = ' ';
        // Shell-escape: wrap in single quotes, replace ' with '\''
        buf[pos++] = '\'';
        for (const char* p = paths[i]; *p; p++) {
            if (*p == '\'') {
                buf[pos++] = '\'';
                buf[pos++] = '\\';
                buf[pos++] = '\'';
                buf[pos++] = '\'';
            } else {
                buf[pos++] = *p;
            }
        }
        buf[pos++] = '\'';
    }
    buf[pos] = '\0';

    void (*send_fn)(const uint8_t*, int) =
        g_popup_active ? attyx_popup_send_input : attyx_send_input;
    if (g_bracketed_paste) {
        send_fn((const uint8_t*)"\x1b[200~", 6);
        send_fn((const uint8_t*)buf, pos);
        send_fn((const uint8_t*)"\x1b[201~", 6);
    } else {
        send_fn((const uint8_t*)buf, pos);
    }
    free(buf);
}

// ---------------------------------------------------------------------------
// Callback registration — called from attyx_run in platform_linux.c
// ---------------------------------------------------------------------------

// Set the GLFW error callback (must be called before glfwInit).
void linux_set_error_callback(void) {
    glfwSetErrorCallback(errorCallback);
}

// Register all window callbacks (must be called after window creation).
void linux_register_callbacks(GLFWwindow* win) {
    // Enable lock-key modifier bits so we get GLFW_MOD_NUM_LOCK in key callbacks.
    glfwSetInputMode(win, GLFW_LOCK_KEY_MODS, GLFW_TRUE);
    glfwSetFramebufferSizeCallback(win, framebufferSizeCallback);
    glfwSetKeyCallback(win, keyCallback);
    glfwSetCharCallback(win, charCallback);
    glfwSetMouseButtonCallback(win, mouseButtonCallback);
    glfwSetCursorPosCallback(win, cursorPosCallback);
    glfwSetScrollCallback(win, scrollCallback);
    glfwSetDropCallback(win, dropCallback);
}
