// Attyx — Linux input handling
// Keyboard, mouse, clipboard, framebuffer-resize, and GLFW error callbacks.

#include "linux_internal.h"

// ---------------------------------------------------------------------------
// Keyboard handling
// ---------------------------------------------------------------------------

static int g_suppress_char = 0;

static void snapViewport(void) {
    if (g_viewport_offset != 0) {
        g_viewport_offset = 0;
        attyx_mark_all_dirty();
    }
    if (g_sel_active) {
        g_sel_active = 0;
        attyx_mark_all_dirty();
    }
}

static void keyCallback(GLFWwindow* w, int key, int scancode, int action, int mods) {
    (void)w; (void)scancode;
    if (action == GLFW_RELEASE) return;
    g_suppress_char = 0;

    // Context menu: Escape dismisses it.
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

    // Ctrl+F toggles search
    if (ctrl && key == GLFW_KEY_F) {
        if (g_search_active) {
            g_search_active = 0;
            g_search_query_len = 0;
            g_search_gen++;
            attyx_mark_all_dirty();
        } else {
            g_search_active = 1;
            g_search_query_len = 0;
            g_search_gen++;
            attyx_mark_all_dirty();
        }
        g_suppress_char = 1;
        return;
    }

    // Ctrl+G / Shift+Ctrl+G — find next/prev (works whenever search is active)
    if (ctrl && key == GLFW_KEY_G && g_search_active) {
        if (shift) {
            __sync_fetch_and_add((volatile int*)&g_search_nav_delta, -1);
        } else {
            __sync_fetch_and_add((volatile int*)&g_search_nav_delta, 1);
        }
        attyx_mark_all_dirty();
        g_suppress_char = 1;
        return;
    }

    // When search bar is open, route keys to search input
    if (g_search_active) {
        if (key == GLFW_KEY_ESCAPE) {
            g_search_active = 0;
            g_search_query_len = 0;
            g_search_gen++;
            attyx_mark_all_dirty();
            g_suppress_char = 1;
            return;
        }
        if (key == GLFW_KEY_ENTER) {
            if (shift) {
                __sync_fetch_and_add((volatile int*)&g_search_nav_delta, -1);
            } else {
                __sync_fetch_and_add((volatile int*)&g_search_nav_delta, 1);
            }
            attyx_mark_all_dirty();
            g_suppress_char = 1;
            return;
        }
        if (key == GLFW_KEY_BACKSPACE) {
            if (g_search_query_len > 0) {
                g_search_query_len--;
                g_search_gen++;
                attyx_mark_all_dirty();
            }
            g_suppress_char = 1;
            return;
        }
        // Swallow other special keys in search mode
        g_suppress_char = 0; // let charCallback handle printable chars
        return;
    }

    // Ctrl+Shift+C/V for copy/paste
    if (ctrl && shift && key == GLFW_KEY_V) {
        const char* text = glfwGetClipboardString(g_window);
        if (text && *text) {
            int len = (int)strlen(text);
            if (g_bracketed_paste) {
                attyx_send_input((const uint8_t*)"\x1b[200~", 6);
                attyx_send_input((const uint8_t*)text, len);
                attyx_send_input((const uint8_t*)"\x1b[201~", 6);
            } else {
                attyx_send_input((const uint8_t*)text, len);
            }
        }
        g_suppress_char = 1;
        return;
    }
    if (ctrl && shift && key == GLFW_KEY_C) {
        doCopy();
        g_suppress_char = 1;
        return;
    }
    if (ctrl && shift && key == GLFW_KEY_R) {
        attyx_trigger_config_reload();
        g_suppress_char = 1;
        return;
    }

    snapViewport();

    // Shift+PageUp/Down/Home/End for scrollback
    if (shift && !g_mouse_tracking && !g_alt_screen) {
        if (key == GLFW_KEY_PAGE_UP)   { attyx_scroll_viewport(g_rows); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_PAGE_DOWN) { attyx_scroll_viewport(-g_rows); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_HOME)      { g_viewport_offset = g_scrollback_count; attyx_mark_all_dirty(); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_END)       { g_viewport_offset = 0; attyx_mark_all_dirty(); g_suppress_char = 1; return; }
    }

    // Arrow keys (DECCKM-aware)
    int appMode = (g_cursor_keys_app != 0);
    switch (key) {
        case GLFW_KEY_UP:    attyx_send_input((const uint8_t*)(appMode ? "\x1bOA" : "\x1b[A"), 3); g_suppress_char = 1; return;
        case GLFW_KEY_DOWN:  attyx_send_input((const uint8_t*)(appMode ? "\x1bOB" : "\x1b[B"), 3); g_suppress_char = 1; return;
        case GLFW_KEY_RIGHT: attyx_send_input((const uint8_t*)(appMode ? "\x1bOC" : "\x1b[C"), 3); g_suppress_char = 1; return;
        case GLFW_KEY_LEFT:  attyx_send_input((const uint8_t*)(appMode ? "\x1bOD" : "\x1b[D"), 3); g_suppress_char = 1; return;
        case GLFW_KEY_ENTER:     attyx_send_input((const uint8_t*)"\r", 1); g_suppress_char = 1; return;
        case GLFW_KEY_BACKSPACE: attyx_send_input((const uint8_t*)"\x7f", 1); g_suppress_char = 1; return;
        case GLFW_KEY_TAB:       attyx_send_input((const uint8_t*)"\t", 1); g_suppress_char = 1; return;
        case GLFW_KEY_ESCAPE:    attyx_send_input((const uint8_t*)"\x1b", 1); g_suppress_char = 1; return;
        case GLFW_KEY_HOME:      attyx_send_input((const uint8_t*)"\x1b[H", 3); g_suppress_char = 1; return;
        case GLFW_KEY_END:       attyx_send_input((const uint8_t*)"\x1b[F", 3); g_suppress_char = 1; return;
        case GLFW_KEY_PAGE_UP:   attyx_send_input((const uint8_t*)"\x1b[5~", 4); g_suppress_char = 1; return;
        case GLFW_KEY_PAGE_DOWN: attyx_send_input((const uint8_t*)"\x1b[6~", 4); g_suppress_char = 1; return;
        case GLFW_KEY_DELETE:    attyx_send_input((const uint8_t*)"\x1b[3~", 4); g_suppress_char = 1; return;
        case GLFW_KEY_INSERT:    attyx_send_input((const uint8_t*)"\x1b[2~", 4); g_suppress_char = 1; return;
        case GLFW_KEY_F1:  attyx_send_input((const uint8_t*)"\x1bOP",   3); g_suppress_char = 1; return;
        case GLFW_KEY_F2:  attyx_send_input((const uint8_t*)"\x1bOQ",   3); g_suppress_char = 1; return;
        case GLFW_KEY_F3:  attyx_send_input((const uint8_t*)"\x1bOR",   3); g_suppress_char = 1; return;
        case GLFW_KEY_F4:  attyx_send_input((const uint8_t*)"\x1bOS",   3); g_suppress_char = 1; return;
        case GLFW_KEY_F5:  attyx_send_input((const uint8_t*)"\x1b[15~", 5); g_suppress_char = 1; return;
        case GLFW_KEY_F6:  attyx_send_input((const uint8_t*)"\x1b[17~", 5); g_suppress_char = 1; return;
        case GLFW_KEY_F7:  attyx_send_input((const uint8_t*)"\x1b[18~", 5); g_suppress_char = 1; return;
        case GLFW_KEY_F8:  attyx_send_input((const uint8_t*)"\x1b[19~", 5); g_suppress_char = 1; return;
        case GLFW_KEY_F9:  attyx_send_input((const uint8_t*)"\x1b[20~", 5); g_suppress_char = 1; return;
        case GLFW_KEY_F10: attyx_send_input((const uint8_t*)"\x1b[21~", 5); g_suppress_char = 1; return;
        case GLFW_KEY_F11: attyx_send_input((const uint8_t*)"\x1b[23~", 5); g_suppress_char = 1; return;
        case GLFW_KEY_F12: attyx_send_input((const uint8_t*)"\x1b[24~", 5); g_suppress_char = 1; return;
        default: break;
    }

    // Ctrl+key → control codes
    if (ctrl && !alt && !shift) {
        if (key >= GLFW_KEY_A && key <= GLFW_KEY_Z) {
            uint8_t b = (uint8_t)(key - GLFW_KEY_A + 1);
            attyx_send_input(&b, 1);
            g_suppress_char = 1;
            return;
        }
        if (key == GLFW_KEY_LEFT_BRACKET)  { attyx_send_input((const uint8_t*)"\x1b", 1); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_RIGHT_BRACKET) { uint8_t b = 0x1d; attyx_send_input(&b, 1); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_BACKSLASH)     { uint8_t b = 0x1c; attyx_send_input(&b, 1); g_suppress_char = 1; return; }
        if (key == GLFW_KEY_SPACE)         { uint8_t b = 0x00; attyx_send_input(&b, 1); g_suppress_char = 1; return; }
        g_suppress_char = 1;
        return;
    }

    // Alt+key → ESC prefix
    if (alt && !ctrl) {
        if (key >= GLFW_KEY_A && key <= GLFW_KEY_Z) {
            uint8_t esc = 0x1b;
            attyx_send_input(&esc, 1);
            uint8_t ch = (uint8_t)('a' + (key - GLFW_KEY_A));
            if (shift) ch = (uint8_t)(ch - 32);
            attyx_send_input(&ch, 1);
            g_suppress_char = 1;
            return;
        }
    }
}

static void charCallback(GLFWwindow* w, unsigned int codepoint) {
    (void)w;
    if (g_suppress_char) { g_suppress_char = 0; return; }

    // When search bar is open, route printable chars into search query
    if (g_search_active) {
        if (codepoint >= 32 && codepoint < 127) {
            if (g_search_query_len < ATTYX_SEARCH_QUERY_MAX - 1) {
                g_search_query[g_search_query_len++] = (char)codepoint;
                g_search_gen++;
                attyx_mark_all_dirty();
            }
        }
        return;
    }

    snapViewport();

    uint8_t buf[4];
    int len = utf8Encode(codepoint, buf);
    if (len > 0) attyx_send_input(buf, len);
}

// ---------------------------------------------------------------------------
// Mouse handling
// ---------------------------------------------------------------------------

static double g_last_click_time = 0;
static int g_last_click_col = -1, g_last_click_row = -1;
static int g_click_count = 0;
static int g_selecting = 0;
static int g_left_down = 0;

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
    float cy = floorf((availH - g_rows * cellH) * 0.5f);
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
    float cy = floorf((availH - g_rows * cellH) * 0.5f);
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

static int mouseModifiers(int mods) {
    int m = 0;
    if (mods & GLFW_MOD_SHIFT)   m |= 4;
    if (mods & GLFW_MOD_ALT)     m |= 8;
    if (mods & GLFW_MOD_CONTROL) m |= 16;
    return m;
}

// Helper: context menu hit-test (returns 1 if pixel (px,py) is inside the menu).
static int ctxMenuHitItem(float px, float py) {
    float gw = g_gc.glyph_w, gh = g_gc.glyph_h;
    float padX = gw * 0.5f, padY = gh * 0.25f;
    float itemH = gh + padY * 2.0f;
    float menuW = padX * 2.0f + 13.0f * gw; // 13 = len("Reload Config")
    return (px >= g_ctx_menu_x && px <= g_ctx_menu_x + menuW &&
            py >= g_ctx_menu_y && py <= g_ctx_menu_y + itemH);
}

static void mouseButtonCallback(GLFWwindow* w, int button, int action, int mods) {
    double mx, my;
    glfwGetCursorPos(w, &mx, &my);

    // Context menu: consume all presses while open, then close.
    if (g_ctx_menu_open && action == GLFW_PRESS) {
        float px = (float)(mx * g_content_scale);
        float py = (float)(my * g_content_scale);
        if (button == GLFW_MOUSE_BUTTON_LEFT && ctxMenuHitItem(px, py))
            attyx_trigger_config_reload();
        g_ctx_menu_open = 0;
        g_ctx_menu_hover = -1;
        g_full_redraw = 1;
        return;
    }

    if (button == GLFW_MOUSE_BUTTON_LEFT) {
        if (action == GLFW_PRESS) {
            if (g_mouse_tracking && g_mouse_sgr) {
                int col, row;
                mouseToCell1(mx, my, &col, &row);
                sendSgrMouse(0 | mouseModifiers(mods), col, row, 1);
                g_left_down = 1;
                return;
            }
            int col, row;
            mouseToCell(mx, my, &col, &row);

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
            float menuW = padX * 2.0f + 13.0f * gw;
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
            float cyp = floorf((avH - g_rows * gh) * 0.5f);
            if (cxp < 0) cxp = 0;
            if (cyp < 0) cyp = 0;
            float offXpx = padLpx + cxp;
            float offYpx = padTpx + cyp;
            if (px + menuW > offXpx + g_cols * gw) px = offXpx + g_cols * gw - menuW;
            if (py + itemH > offYpx + g_rows * gh) py = offYpx + g_rows * gh - itemH;
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
        int col, row;
        mouseToCell(mx, my, &col, &row);
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
        int newHover = ctxMenuHitItem(px, py) ? 0 : -1;
        if (newHover != g_ctx_menu_hover) {
            g_ctx_menu_hover = newHover;
            g_full_redraw = 1;
        }
    }
}

static void scrollCallback(GLFWwindow* w, double xoff, double yoff) {
    (void)xoff;
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
    attyx_scroll_viewport(lines);
    if (g_sel_active) { g_sel_active = 0; attyx_mark_all_dirty(); }
}

// ---------------------------------------------------------------------------
// Copy to clipboard
// ---------------------------------------------------------------------------

void doCopy(void) {
    if (!g_sel_active || !g_window) return;

    int sr = g_sel_start_row, sc = g_sel_start_col;
    int er = g_sel_end_row, ec = g_sel_end_col;
    if (sr > er || (sr == er && sc > ec)) {
        int tr = sr, tc = sc; sr = er; sc = ec; er = tr; ec = tc;
    }

    int cols = g_cols, rows = g_rows;
    if (cols <= 0 || rows <= 0) return;

    uint64_t gen;
    do { gen = g_cell_gen; } while (gen & 1);

    int maxlen = (er - sr + 1) * (cols * 4 + 1) + 1;
    char* buf = (char*)malloc(maxlen);
    if (!buf) return;
    int pos = 0;

    for (int row = sr; row <= er && row < rows; row++) {
        int cStart = (row == sr) ? sc : 0;
        int cEnd = (row == er) ? ec : cols - 1;
        if (cStart >= cols) cStart = cols - 1;
        if (cEnd >= cols) cEnd = cols - 1;

        int lastNonSpace = cStart - 1;
        for (int c = cEnd; c >= cStart; c--) {
            uint32_t ch = g_cells[row * cols + c].character;
            if (ch > 32) { lastNonSpace = c; break; }
        }

        for (int c = cStart; c <= lastNonSpace; c++) {
            uint32_t ch = g_cells[row * cols + c].character;
            if (ch == 0 || ch == ' ') {
                buf[pos++] = ' ';
            } else {
                uint8_t utf8[4];
                int n = utf8Encode(ch, utf8);
                memcpy(buf + pos, utf8, n);
                pos += n;
            }
        }
        if (row < er) buf[pos++] = '\n';
    }

    buf[pos] = '\0';
    if (pos > 0) glfwSetClipboardString(g_window, buf);
    free(buf);
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
// Callback registration — called from attyx_run in platform_linux.c
// ---------------------------------------------------------------------------

// Set the GLFW error callback (must be called before glfwInit).
void linux_set_error_callback(void) {
    glfwSetErrorCallback(errorCallback);
}

// Register all window callbacks (must be called after window creation).
void linux_register_callbacks(GLFWwindow* win) {
    glfwSetFramebufferSizeCallback(win, framebufferSizeCallback);
    glfwSetKeyCallback(win, keyCallback);
    glfwSetCharCallback(win, charCallback);
    glfwSetMouseButtonCallback(win, mouseButtonCallback);
    glfwSetCursorPosCallback(win, cursorPosCallback);
    glfwSetScrollCallback(win, scrollCallback);
}
