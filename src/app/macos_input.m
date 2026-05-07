// Attyx — macOS input handling (AttyxView: keyboard, mouse, IME, clipboard)

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <Carbon/Carbon.h>
#include <string.h>
#include "macos_internal.h"
#include "macos_input_private.h"

// ---------------------------------------------------------------------------
// Mouse helpers
// ---------------------------------------------------------------------------

static inline int clampInt(int val, int lo, int hi) {
    if (val < lo) return lo;
    if (val > hi) return hi;
    return val;
}

static void mouseCell(NSEvent *event, NSView *view, int *outCol, int *outRow) {
    NSPoint loc = [view convertPoint:event.locationInWindow fromView:nil];
    loc.y = view.bounds.size.height - loc.y;
    float availW = (float)view.bounds.size.width  - g_padding_left - g_padding_right;
    float availH = (float)view.bounds.size.height - g_padding_top  - g_padding_bottom;
    float cx = floorf((availW - g_cols * g_cell_pt_w) * 0.5f);
    float cy = 0;
    if (cx < 0) cx = 0;
    if (cy < 0) cy = 0;
    float offX = g_padding_left + cx;
    float offY = g_padding_top  + cy;
    int col = (int)((loc.x - offX) / g_cell_pt_w) + 1;
    int row = (int)((loc.y - offY) / g_cell_pt_h) + 1;
    *outCol = clampInt(col, 1, g_cols);
    *outRow = clampInt(row, 1, g_rows);
}

static void mouseCell0(NSEvent *event, NSView *view, int *outCol, int *outRow) {
    NSPoint loc = [view convertPoint:event.locationInWindow fromView:nil];
    loc.y = view.bounds.size.height - loc.y;
    float availW = (float)view.bounds.size.width  - g_padding_left - g_padding_right;
    float availH = (float)view.bounds.size.height - g_padding_top  - g_padding_bottom;
    float cx = floorf((availW - g_cols * g_cell_pt_w) * 0.5f);
    float cy = 0;
    if (cx < 0) cx = 0;
    if (cy < 0) cy = 0;
    float offX = g_padding_left + cx;
    float offY = g_padding_top  + cy;
    int col = (int)((loc.x - offX) / g_cell_pt_w);
    int row = (int)((loc.y - offY) / g_cell_pt_h);
    *outCol = clampInt(col, 0, g_cols - 1);
    *outRow = clampInt(row, 0, g_rows - 1);
}

static int mouseModifiers(NSEventModifierFlags flags) {
    int m = 0;
    if (flags & NSEventModifierFlagShift)   m |= 4;
    if (flags & NSEventModifierFlagOption)  m |= 8;
    if (flags & NSEventModifierFlagControl) m |= 16;
    return m;
}

static void sendSgrMouse(int button, int col, int row, BOOL press) {
    // Convert from screen-grid 1-based coords to focused-pane 1-based coords:
    //   - subtract g_grid_top_offset for tab bar / statusbar rows
    //   - subtract g_pane_rect_row/col for the pane's offset within the split
    // Without this, mouse-aware apps (opencode, vim, …) running in any pane
    // other than the top-left one receive coords past their visible area
    // and their own selection / click handling breaks.
    row -= g_grid_top_offset + g_pane_rect_row;
    col -= g_pane_rect_col;
    if (row < 1) row = 1;
    if (col < 1) col = 1;
    if (g_pane_rect_cols > 0 && col > g_pane_rect_cols) col = g_pane_rect_cols;
    if (g_pane_rect_rows > 0 && row > g_pane_rect_rows) row = g_pane_rect_rows;
    char buf[32];
    int len = snprintf(buf, sizeof(buf), "\x1b[<%d;%d;%d%c",
                       button, col, row, press ? 'M' : 'm');
    attyx_send_input((const uint8_t *)buf, len);
}

static void sendSgrMousePopup(int button, int col, int row, BOOL press) {
    char buf[32];
    int len = snprintf(buf, sizeof(buf), "\x1b[<%d;%d;%d%c",
                       button, col, row, press ? 'M' : 'm');
    attyx_popup_send_input((const uint8_t *)buf, len);
}

// Test if grid-space (col, row) is inside the popup bounds.
// If inside, writes popup-local 1-based coordinates to outCol/outRow.
static BOOL popupHitTest(int col, int row, int *outCol, int *outRow) {
    AttyxPopupDesc d = g_popup_desc;
    if (!d.active) return NO;
    // Popup is rendered at offY which includes g_grid_top_offset, so the
    // visual row is shifted down. mouseCell0 returns raw grid coords
    // (row 0 = top of window), so we must account for that shift.
    int vis_row = d.row + g_grid_top_offset;
    if (col < d.col || col >= d.col + d.width) return NO;
    if (row < vis_row || row >= vis_row + d.height) return NO;
    // Convert to inner terminal coordinates (1-based for SGR protocol)
    int inner_col = col - d.col - d.content_col_off + 1;
    int inner_row = row - vis_row - d.content_row_off + 1;
    if (inner_col < 1) inner_col = 1;
    if (inner_row < 1) inner_row = 1;
    if (inner_col > d.inner_cols) inner_col = d.inner_cols;
    if (inner_row > d.inner_rows) inner_row = d.inner_rows;
    *outCol = inner_col;
    *outRow = inner_row;
    return YES;
}

// ---------------------------------------------------------------------------
// Split separator hit-test (~20px grab zone around separator lines)
// mouseX: raw mouse X in view points.  offX/cellW: grid origin and cell width.
// Returns: 0 = miss, 1 = vertical (left-right resize), 2 = horizontal (up-down)
// ---------------------------------------------------------------------------

static int separatorHitTest(int col, int row, float mouseX, float offX, float cellW) {
    int srow = row - g_grid_top_offset;
    int scols = g_cols;
    if (!g_cells || srow < 0 || srow >= g_rows) return 0;
    const float halfHit = 10.0f; // 10pt each side ≈ 20px on Retina
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
            BOOL hasVert = NO;
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

static void mouseXOffset(NSEvent *event, NSView *view, float *outMouseX, float *outOffX) {
    NSPoint loc = [view convertPoint:event.locationInWindow fromView:nil];
    *outMouseX = (float)loc.x;
    float availW = (float)view.bounds.size.width - g_padding_left - g_padding_right;
    float cx = floorf((availW - g_cols * g_cell_pt_w) * 0.5f);
    if (cx < 0) cx = 0;
    *outOffX = g_padding_left + cx;
}

// ---------------------------------------------------------------------------
// URL detection helpers
// ---------------------------------------------------------------------------

static BOOL isUrlChar(uint32_t ch) {
    if (ch <= 32 || ch == 127) return NO;
    if (ch == '<' || ch == '>' || ch == '"' || ch == '`') return NO;
    if (ch == '{' || ch == '}') return NO;
    return YES;
}

static BOOL isTrailingPunct(uint32_t ch) {
    return (ch == '.' || ch == ',' || ch == ';' || ch == ':' ||
            ch == '!' || ch == '?' || ch == '\'' || ch == '"' ||
            ch == ')' || ch == ']' || ch == '>');
}

static BOOL detectUrlAtCell(int row, int col, int cols,
                            int *outStart, int *outEnd,
                            char *outUrl, int urlBufSize, int *outUrlLen) {
    if (!g_cells || cols <= 0) return NO;
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
                return YES;
            }

            haystack = found + 1;
        }
    }
    return NO;
}

// ---------------------------------------------------------------------------
// Word boundary helpers for double-click selection
// ---------------------------------------------------------------------------

static BOOL isWordChar(uint32_t ch) {
    if (ch == 0 || ch == ' ') return NO;
    if (ch == '_' || ch == '-') return YES;
    if (ch > 127) return YES;
    if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')) return YES;
    return NO;
}

static void findWordBounds(int row, int col, int cols, int *outStart, int *outEnd) {
    if (!g_cells || cols <= 0) { *outStart = col; *outEnd = col; return; }
    int base = row * cols;
    uint32_t ch = g_cells[base + col].character;
    BOOL target = isWordChar(ch);

    int start = col;
    while (start > 0 && isWordChar(g_cells[base + start - 1].character) == target)
        start--;

    int end = col;
    while (end < cols - 1 && isWordChar(g_cells[base + end + 1].character) == target)
        end++;

    *outStart = start;
    *outEnd = end;
}

// ---------------------------------------------------------------------------
// AttyxView
// ---------------------------------------------------------------------------

@implementation AttyxView {
    int _ctxMenuCol;
    int _ctxMenuRow;
}

- (instancetype)initWithFrame:(NSRect)frameRect device:(id<MTLDevice>)device {
    self = [super initWithFrame:frameRect device:device];
    if (self) {
        _markedText = [[NSMutableString alloc] init];
        _markedRange = NSMakeRange(NSNotFound, 0);
        _selectedRange = NSMakeRange(0, 0);
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    }
    return self;
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder  { return YES; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas)
        [self removeTrackingArea:area];
    NSTrackingArea *ta = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:(NSTrackingMouseMoved |
                      NSTrackingMouseEnteredAndExited |
                      NSTrackingActiveInKeyWindow |
                      NSTrackingInVisibleRect)
               owner:self
            userInfo:nil];
    [self addTrackingArea:ta];
}

- (void)mouseDown:(NSEvent *)event {
    // Popup mouse routing: all clicks go to popup when active
    if (g_popup_active) {
        int col, row;
        mouseCell0(event, self, &col, &row);
        int pc, pr;
        if (popupHitTest(col, row, &pc, &pr)) {
            if (g_popup_mouse_tracking && g_popup_mouse_sgr) {
                int btn = 0 | mouseModifiers(event.modifierFlags);
                sendSgrMousePopup(btn, pc, pr, YES);
                _leftDown = YES;
                _lastMouseCol = pc;
                _lastMouseRow = pr;
            }
        }
        return; // eat all clicks when popup is open
    }

    // Mouse click exits copy mode
    if (g_copy_mode) {
        attyx_copy_mode_exit(0);
    }

    // Split separator click: intercept before mouse tracking so drag resize
    // works even when the focused pane has mouse tracking enabled (e.g. vim).
    if (g_split_active) {
        int sc, sr;
        mouseCell0(event, self, &sc, &sr);
        float mx, ox;
        mouseXOffset(event, self, &mx, &ox);
        if (separatorHitTest(sc, sr, mx, ox, g_cell_pt_w)) {
            attyx_split_drag_start(sc, sr);
            _splitDragging = YES;
            return;
        }
    }

    // Cmd-click on a link bypasses mouse reporting so TUIs (Claude Code,
    // vim, etc.) don't swallow the click before we can open the URL.
    // Falls through to the normal mouse-reporting / selection path when
    // there's no link at the clicked cell.
    if (event.modifierFlags & NSEventModifierFlagCommand) {
        int cc, cr;
        mouseCell0(event, self, &cc, &cr);
        cr -= g_grid_top_offset;
        if (cr >= 0) {
            int cols = g_cols, rows_n = g_rows;
            if (g_cells && cc >= 0 && cc < cols && cr < rows_n) {
                uint32_t lid = g_cells[cr * cols + cc].link_id;
                if (lid != 0) {
                    char uri_buf[2048];
                    int uri_len = attyx_get_link_uri(lid, uri_buf, sizeof(uri_buf));
                    if (uri_len > 0) {
                        NSString* urlStr = [[NSString alloc] initWithBytes:uri_buf
                                                                   length:uri_len
                                                                 encoding:NSUTF8StringEncoding];
                        if (urlStr) {
                            NSURL* url = [NSURL URLWithString:urlStr];
                            if (url) [[NSWorkspace sharedWorkspace] openURL:url];
                        }
                    }
                    return;
                }
                int dStart, dEnd;
                char dUrl[DETECTED_URL_MAX];
                int dLen = 0;
                if (detectUrlAtCell(cr, cc, cols, &dStart, &dEnd, dUrl, DETECTED_URL_MAX, &dLen) && dLen > 0) {
                    NSString* urlStr = [[NSString alloc] initWithBytes:dUrl
                                                               length:dLen
                                                             encoding:NSUTF8StringEncoding];
                    if (urlStr) {
                        NSURL* url = [NSURL URLWithString:urlStr];
                        if (url) [[NSWorkspace sharedWorkspace] openURL:url];
                    }
                    return;
                }
            }
        }
    }

    int col, row;
    mouseCell0(event, self, &col, &row);

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

    // Let pane switching win over app mouse tracking so OpenCode and other
    // mouse-aware apps do not trap clicks meant to focus another split.
    if (g_split_active && g_pane_rect_rows > 0) {
        int content_row = row - g_grid_top_offset;
        int pr = g_pane_rect_row, pc = g_pane_rect_col;
        int pe = pr + g_pane_rect_rows, pce = pc + g_pane_rect_cols;
        if (content_row >= 0 &&
            (content_row < pr || content_row >= pe || col < pc || col >= pce)) {
            attyx_split_click(col, row);
            return;
        }
    }

    if (g_mouse_tracking && g_mouse_sgr) {
        int track_col, track_row;
        mouseCell(event, self, &track_col, &track_row);
        int btn = 0 | mouseModifiers(event.modifierFlags);
        sendSgrMouse(btn, track_col, track_row, YES);
        _leftDown = YES;
        _lastMouseCol = track_col;
        _lastMouseRow = track_row;
        return;
    }

    // Split pane click: focus the clicked pane + start drag resize
    if (g_split_active) {
        attyx_split_drag_start(col, row);
        _splitDragging = YES;
        attyx_split_click(col, row);
    }

    // Adjust row to content space for selection and cell access.
    // Tab bar, statusbar, overlay, and split all use grid-space row above.
    row -= g_grid_top_offset;
    if (row < 0) row = 0;

    // Clamp to focused pane bounds when splits are active
    if (g_split_active && g_pane_rect_rows > 0) {
        int pr = g_pane_rect_row, pc = g_pane_rect_col;
        int pe = pr + g_pane_rect_rows, pce = pc + g_pane_rect_cols;
        if (row < pr) row = pr;
        if (row >= pe) row = pe - 1;
        if (col < pc) col = pc;
        if (col >= pce) col = pce - 1;
    }

    // Cmd-click link handling runs earlier (before mouse-reporting) so it
    // works inside TUIs. By this point we know no link was at the click.

    // Shift-click extends existing selection
    if ((event.modifierFlags & NSEventModifierFlagShift) && g_sel_active) {
        g_sel_end_row = row;
        g_sel_end_col = col;
        _selecting = YES;
        attyx_mark_all_dirty();
        return;
    }

    _clickCount = (int)event.clickCount;

    if (_clickCount >= 3) {
        g_sel_start_row = row; g_sel_start_col = 0;
        g_sel_end_row = row;   g_sel_end_col = g_cols - 1;
        g_sel_active = 1;
        _selecting = YES;
    } else if (_clickCount == 2) {
        int wStart, wEnd;
        findWordBounds(row, col, g_cols, &wStart, &wEnd);
        g_sel_start_row = row; g_sel_start_col = wStart;
        g_sel_end_row = row;   g_sel_end_col = wEnd;
        g_sel_active = 1;
        _selecting = YES;
    } else {
        g_sel_start_row = row; g_sel_start_col = col;
        g_sel_end_row = row;   g_sel_end_col = col;
        g_sel_active = 0;
        _selecting = YES;
    }
    attyx_mark_all_dirty();
}

- (void)mouseUp:(NSEvent *)event {
    if (g_popup_active) {
        _leftDown = NO;
        if (g_popup_mouse_tracking && g_popup_mouse_sgr) {
            int col, row;
            mouseCell0(event, self, &col, &row);
            int pc, pr;
            if (popupHitTest(col, row, &pc, &pr)) {
                int btn = 0 | mouseModifiers(event.modifierFlags);
                sendSgrMousePopup(btn, pc, pr, NO);
            }
        }
        return;
    }
    _leftDown = NO;
    if (_splitDragging) {
        if (g_split_drag_active) attyx_split_drag_end();
        _splitDragging = NO;
        [[NSCursor IBeamCursor] set];
    }
    if (g_mouse_tracking && g_mouse_sgr) {
        int col, row;
        mouseCell(event, self, &col, &row);
        int btn = 0 | mouseModifiers(event.modifierFlags);
        sendSgrMouse(btn, col, row, NO);
        return;
    }
    if (_selecting) {
        _selecting = NO;
        if (g_sel_start_row != g_sel_end_row || g_sel_start_col != g_sel_end_col)
            g_sel_active = 1;
        else
            g_sel_active = 0;
    }
}

- (void)rightMouseDown:(NSEvent *)event {
    if (g_popup_active) {
        if (g_popup_mouse_tracking && g_popup_mouse_sgr) {
            int col, row;
            mouseCell0(event, self, &col, &row);
            int pc, pr;
            if (popupHitTest(col, row, &pc, &pr)) {
                int btn = 2 | mouseModifiers(event.modifierFlags);
                sendSgrMousePopup(btn, pc, pr, YES);
            }
        }
        return;
    }
    if (g_mouse_tracking && g_mouse_sgr) {
        int col, row;
        mouseCell(event, self, &col, &row);
        int btn = 2 | mouseModifiers(event.modifierFlags);
        sendSgrMouse(btn, col, row, YES);
        _rightDown = YES;
        _lastMouseCol = col;
        _lastMouseRow = row;
        return;
    }

    // Compute grid cell for pane-aware context menu actions
    int ctxCol, ctxRow;
    mouseCell(event, self, &ctxCol, &ctxRow);
    _ctxMenuCol = ctxCol;
    _ctxMenuRow = ctxRow;

    // Show native context menu
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    [menu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];

    // Split actions (target the right-clicked pane)
    [menu addItemWithTitle:@"Split Vertical" action:@selector(ctxSplitVertical:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Split Horizontal" action:@selector(ctxSplitHorizontal:) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];

    // Rotate (works on all panes regardless of click target)
    [menu addItemWithTitle:@"Rotate Panes" action:@selector(ctxRotate:) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];

    // Close pane (targets the right-clicked pane)
    [menu addItemWithTitle:@"Close Pane" action:@selector(ctxClosePane:) keyEquivalent:@""];

    [NSMenu popUpContextMenu:menu withEvent:event forView:self];
}

- (void)ctxSplitVertical:(id)sender   { attyx_context_menu_action(53, _ctxMenuCol, _ctxMenuRow); }
- (void)ctxSplitHorizontal:(id)sender { attyx_context_menu_action(54, _ctxMenuCol, _ctxMenuRow); }
- (void)ctxRotate:(id)sender          { attyx_dispatch_action(78); }
- (void)ctxClosePane:(id)sender       { attyx_context_menu_action(55, _ctxMenuCol, _ctxMenuRow); }

- (void)reloadConfig:(id)sender {
    attyx_trigger_config_reload();
}

- (void)rightMouseUp:(NSEvent *)event {
    if (g_popup_active) {
        _rightDown = NO;
        if (g_popup_mouse_tracking && g_popup_mouse_sgr) {
            int col, row;
            mouseCell0(event, self, &col, &row);
            int pc, pr;
            if (popupHitTest(col, row, &pc, &pr)) {
                int btn = 2 | mouseModifiers(event.modifierFlags);
                sendSgrMousePopup(btn, pc, pr, NO);
            }
        }
        return;
    }
    _rightDown = NO;
    if (!g_mouse_tracking || !g_mouse_sgr) return;
    int col, row;
    mouseCell(event, self, &col, &row);
    int btn = 2 | mouseModifiers(event.modifierFlags);
    sendSgrMouse(btn, col, row, NO);
}

- (void)otherMouseDown:(NSEvent *)event {
    if (g_popup_active) {
        if (g_popup_mouse_tracking && g_popup_mouse_sgr) {
            int col, row;
            mouseCell0(event, self, &col, &row);
            int pc, pr;
            if (popupHitTest(col, row, &pc, &pr)) {
                int btn = 1 | mouseModifiers(event.modifierFlags);
                sendSgrMousePopup(btn, pc, pr, YES);
            }
        }
        return;
    }
    if (!g_mouse_tracking || !g_mouse_sgr) return;
    int col, row;
    mouseCell(event, self, &col, &row);
    int btn = 1 | mouseModifiers(event.modifierFlags);
    sendSgrMouse(btn, col, row, YES);
    _middleDown = YES;
    _lastMouseCol = col;
    _lastMouseRow = row;
}

- (void)otherMouseUp:(NSEvent *)event {
    if (g_popup_active) {
        _middleDown = NO;
        if (g_popup_mouse_tracking && g_popup_mouse_sgr) {
            int col, row;
            mouseCell0(event, self, &col, &row);
            int pc, pr;
            if (popupHitTest(col, row, &pc, &pr)) {
                int btn = 1 | mouseModifiers(event.modifierFlags);
                sendSgrMousePopup(btn, pc, pr, NO);
            }
        }
        return;
    }
    _middleDown = NO;
    if (!g_mouse_tracking || !g_mouse_sgr) return;
    int col, row;
    mouseCell(event, self, &col, &row);
    int btn = 1 | mouseModifiers(event.modifierFlags);
    sendSgrMouse(btn, col, row, NO);
}

- (void)mouseDragged:(NSEvent *)event {
    if (g_popup_active) {
        if (g_popup_mouse_tracking && g_popup_mouse_sgr && g_popup_mouse_tracking >= 2) {
            int col, row;
            mouseCell0(event, self, &col, &row);
            int pc, pr;
            if (popupHitTest(col, row, &pc, &pr)) {
                if (pc != _lastMouseCol || pr != _lastMouseRow) {
                    int btn = 32 | mouseModifiers(event.modifierFlags);
                    sendSgrMousePopup(btn, pc, pr, YES);
                    _lastMouseCol = pc;
                    _lastMouseRow = pr;
                }
            }
        }
        return;
    }
    if (_splitDragging && g_split_drag_active) {
        int col, row;
        mouseCell0(event, self, &col, &row);
        attyx_split_drag_update(col, row);
        if (g_split_drag_direction == 0)
            [[NSCursor resizeLeftRightCursor] set];
        else
            [[NSCursor resizeUpDownCursor] set];
        return;
    }
    if (g_mouse_tracking && g_mouse_sgr) {
        int tracking = g_mouse_tracking;
        if (tracking < 2) return;
        int col, row;
        mouseCell(event, self, &col, &row);
        if (col == _lastMouseCol && row == _lastMouseRow) return;
        int btn = 32 | mouseModifiers(event.modifierFlags);
        sendSgrMouse(btn, col, row, YES);
        _lastMouseCol = col;
        _lastMouseRow = row;
        return;
    }
    if (_selecting) {
        // Auto-scroll when dragging past top/bottom edge
        if (!g_alt_screen) {
            NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
            loc.y = self.bounds.size.height - loc.y;
            float availH = (float)self.bounds.size.height - g_padding_top - g_padding_bottom;
            float cy = 0;
            if (cy < 0) cy = 0;
            float offY = g_padding_top + cy;
            int rawRow = (int)((loc.y - offY) / g_cell_pt_h);
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
        mouseCell0(event, self, &col, &row);
        row -= g_grid_top_offset;
        if (row < 0) row = 0;

        // Clamp to focused pane bounds when splits are active
        if (g_split_active && g_pane_rect_rows > 0) {
            int pr = g_pane_rect_row, pc = g_pane_rect_col;
            int pe = pr + g_pane_rect_rows, pce = pc + g_pane_rect_cols;
            if (row < pr) row = pr;
            if (row >= pe) row = pe - 1;
            if (col < pc) col = pc;
            if (col >= pce) col = pce - 1;
        }

        if (col == g_sel_end_col && row == g_sel_end_row) return;

        if (_clickCount >= 3) {
            g_sel_end_row = row;
            g_sel_end_col = (row >= g_sel_start_row) ? g_cols - 1 : 0;
            if (row < g_sel_start_row) g_sel_start_col = g_cols - 1;
            else g_sel_start_col = 0;
        } else if (_clickCount == 2) {
            int wStart, wEnd;
            findWordBounds(row, col, g_cols, &wStart, &wEnd);
            if (row > g_sel_start_row || (row == g_sel_start_row && col >= g_sel_start_col)) {
                g_sel_end_row = row;
                g_sel_end_col = wEnd;
            } else {
                g_sel_end_row = row;
                g_sel_end_col = wStart;
            }
        } else {
            g_sel_end_row = row;
            g_sel_end_col = col;
        }
        g_sel_active = 1;
        attyx_mark_all_dirty();
    }
}

- (void)rightMouseDragged:(NSEvent *)event {
    if (g_popup_active) {
        if (g_popup_mouse_tracking >= 2 && g_popup_mouse_sgr) {
            int col, row;
            mouseCell0(event, self, &col, &row);
            int pc, pr;
            if (popupHitTest(col, row, &pc, &pr)) {
                if (pc != _lastMouseCol || pr != _lastMouseRow) {
                    int btn = (32 | 2) | mouseModifiers(event.modifierFlags);
                    sendSgrMousePopup(btn, pc, pr, YES);
                    _lastMouseCol = pc;
                    _lastMouseRow = pr;
                }
            }
        }
        return;
    }
    int tracking = g_mouse_tracking;
    if (!tracking || !g_mouse_sgr) return;
    if (tracking < 2) return;
    int col, row;
    mouseCell(event, self, &col, &row);
    if (col == _lastMouseCol && row == _lastMouseRow) return;
    int btn = (32 | 2) | mouseModifiers(event.modifierFlags);
    sendSgrMouse(btn, col, row, YES);
    _lastMouseCol = col;
    _lastMouseRow = row;
}

- (void)otherMouseDragged:(NSEvent *)event {
    if (g_popup_active) {
        if (g_popup_mouse_tracking >= 2 && g_popup_mouse_sgr) {
            int col, row;
            mouseCell0(event, self, &col, &row);
            int pc, pr;
            if (popupHitTest(col, row, &pc, &pr)) {
                if (pc != _lastMouseCol || pr != _lastMouseRow) {
                    int btn = (32 | 1) | mouseModifiers(event.modifierFlags);
                    sendSgrMousePopup(btn, pc, pr, YES);
                    _lastMouseCol = pc;
                    _lastMouseRow = pr;
                }
            }
        }
        return;
    }
    int tracking = g_mouse_tracking;
    if (!tracking || !g_mouse_sgr) return;
    if (tracking < 2) return;
    int col, row;
    mouseCell(event, self, &col, &row);
    if (col == _lastMouseCol && row == _lastMouseRow) return;
    int btn = (32 | 1) | mouseModifiers(event.modifierFlags);
    sendSgrMouse(btn, col, row, YES);
    _lastMouseCol = col;
    _lastMouseRow = row;
}

- (void)mouseMoved:(NSEvent *)event {
    if (g_popup_active) {
        if (g_popup_mouse_tracking == 3 && g_popup_mouse_sgr) {
            int col, row;
            mouseCell0(event, self, &col, &row);
            int pc, pr;
            if (popupHitTest(col, row, &pc, &pr)) {
                if (pc != _lastMouseCol || pr != _lastMouseRow) {
                    int btn = 35 | mouseModifiers(event.modifierFlags);
                    sendSgrMousePopup(btn, pc, pr, YES);
                    _lastMouseCol = pc;
                    _lastMouseRow = pr;
                }
            }
        }
        return;
    }
    // Split separator hover: always check before mouse tracking so the
    // resize cursor appears even when the focused pane tracks the mouse.
    if (g_split_active && !g_split_drag_active) {
        static BOOL wasOnSeparator = NO;
        int hcol, hrow;
        mouseCell0(event, self, &hcol, &hrow);
        float mx, ox;
        mouseXOffset(event, self, &mx, &ox);
        int hit = separatorHitTest(hcol, hrow, mx, ox, g_cell_pt_w);
        if (hit == 1) {
            [[NSCursor resizeLeftRightCursor] set];
            wasOnSeparator = YES;
            return;
        } else if (hit == 2) {
            [[NSCursor resizeUpDownCursor] set];
            wasOnSeparator = YES;
            return;
        }
        if (wasOnSeparator) {
            wasOnSeparator = NO;
            [[NSCursor IBeamCursor] set];
        }
    }

    int tracking = g_mouse_tracking;

    // Run hover-link detection unconditionally so OSC 8 hyperlinks still
    // show the hand cursor and hover underline even when a TUI has mouse
    // motion reporting enabled.
    {
        int col, row;
        mouseCell0(event, self, &col, &row);

        row -= g_grid_top_offset;
        if (row < 0) row = 0;
        int cols = g_cols, rows_n = g_rows;

        uint32_t lid = 0;
        if (g_cells && col >= 0 && col < cols && row >= 0 && row < rows_n) {
            lid = g_cells[row * cols + col].link_id;
        }

        int detStart = -1, detEnd = -1;
        char detUrlBuf[DETECTED_URL_MAX];
        int detUrlLen = 0;
        BOOL hasDetected = NO;
        if (lid == 0 && g_cells && col >= 0 && col < cols && row >= 0 && row < rows_n) {
            hasDetected = detectUrlAtCell(row, col, cols,
                                          &detStart, &detEnd,
                                          detUrlBuf, DETECTED_URL_MAX, &detUrlLen);
        }

        BOOL isLink = (lid != 0 || hasDetected);
        int prevOscRow = g_hover_row;
        int prevDetRow = g_detected_url_row;
        int prevDetStart = g_detected_url_start_col;
        int prevDetEnd = g_detected_url_end_col;
        uint32_t prevLid = g_hover_link_id;

        BOOL oscChanged = (lid != prevLid);
        BOOL detChanged = NO;
        if (hasDetected) {
            detChanged = (row != prevDetRow || detStart != prevDetStart || detEnd != prevDetEnd);
        } else if (g_detected_url_len > 0) {
            detChanged = YES;
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

            if (isLink) {
                [[NSCursor pointingHandCursor] set];
            } else {
                [[NSCursor IBeamCursor] set];
            }

            if (prevOscRow >= 0 && prevOscRow < 256)
                __sync_fetch_and_or((volatile uint64_t*)&g_dirty[prevOscRow >> 6], (uint64_t)1 << (prevOscRow & 63));
            if (prevDetRow >= 0 && prevDetRow < 256)
                __sync_fetch_and_or((volatile uint64_t*)&g_dirty[prevDetRow >> 6], (uint64_t)1 << (prevDetRow & 63));
            if (row >= 0 && row < 256 && isLink)
                __sync_fetch_and_or((volatile uint64_t*)&g_dirty[row >> 6], (uint64_t)1 << (row & 63));
        }
    }

    // Forward SGR motion reports to the app when any-motion tracking is on.
    if (tracking == 3 && g_mouse_sgr) {
        int col, row;
        mouseCell(event, self, &col, &row);
        if (col == _lastMouseCol && row == _lastMouseRow) return;
        int btn = 35 | mouseModifiers(event.modifierFlags);
        sendSgrMouse(btn, col, row, YES);
        _lastMouseCol = col;
        _lastMouseRow = row;
    }
}

- (void)scrollWheel:(NSEvent *)event {
    if (g_popup_active) {
        if (g_popup_mouse_tracking && g_popup_mouse_sgr) {
            CGFloat dy = event.scrollingDeltaY;
            if (event.hasPreciseScrollingDeltas) dy /= 3.0;
            if (dy == 0) return;
            int col, row;
            mouseCell0(event, self, &col, &row);
            int pc, pr;
            if (popupHitTest(col, row, &pc, &pr)) {
                int btn = (dy > 0 ? 64 : 65) | mouseModifiers(event.modifierFlags);
                sendSgrMousePopup(btn, pc, pr, YES);
            }
        }
        return;
    }
    if (g_mouse_tracking && g_mouse_sgr) {
        CGFloat dy = event.scrollingDeltaY;
        if (event.hasPreciseScrollingDeltas) dy /= 3.0;
        if (dy == 0) return;
        int col, row;
        mouseCell(event, self, &col, &row);
        int btn = (dy > 0 ? 64 : 65) | mouseModifiers(event.modifierFlags);
        sendSgrMouse(btn, col, row, YES);
        return;
    }

    if (g_alt_screen) return;

    CGFloat dy = event.scrollingDeltaY;

    // Overlay scroll: check before viewport scrollback
    if (g_overlay_has_actions) {
        int col0, row0;
        mouseCell0(event, self, &col0, &row0);
        int lines;
        if (event.hasPreciseScrollingDeltas) {
            _scrollAccum += dy;
            CGFloat threshold = g_cell_pt_h > 0 ? g_cell_pt_h : 16.0;
            lines = (int)(_scrollAccum / threshold);
            if (lines == 0) return;
            _scrollAccum -= lines * threshold;
        } else {
            lines = (int)dy;
            if (lines == 0) lines = (dy > 0) ? 1 : -1;
        }
        if (attyx_overlay_scroll(col0, row0, lines)) return;
        // Not on overlay — fall through to viewport scroll
        attyx_scroll_viewport(lines);
    } else if (event.hasPreciseScrollingDeltas) {
        _scrollAccum += dy;
        CGFloat threshold = g_cell_pt_h > 0 ? g_cell_pt_h : 16.0;
        int lines = (int)(_scrollAccum / threshold);
        if (lines == 0) return;
        _scrollAccum -= lines * threshold;
        attyx_scroll_viewport(lines);
    } else {
        int lines = (int)dy;
        if (lines == 0) lines = (dy > 0) ? 1 : -1;
        attyx_scroll_viewport(lines);
    }
}

@end
