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
    char buf[32];
    int len = snprintf(buf, sizeof(buf), "\x1b[<%d;%d;%d%c",
                       button, col, row, press ? 'M' : 'm');
    attyx_send_input((const uint8_t *)buf, len);
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

@implementation AttyxView

- (instancetype)initWithFrame:(NSRect)frameRect device:(id<MTLDevice>)device {
    self = [super initWithFrame:frameRect device:device];
    if (self) {
        _markedText = [[NSMutableString alloc] init];
        _markedRange = NSMakeRange(NSNotFound, 0);
        _selectedRange = NSMakeRange(0, 0);
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
    if (g_mouse_tracking && g_mouse_sgr) {
        int col, row;
        mouseCell(event, self, &col, &row);
        int btn = 0 | mouseModifiers(event.modifierFlags);
        sendSgrMouse(btn, col, row, YES);
        _leftDown = YES;
        _lastMouseCol = col;
        _lastMouseRow = row;
        return;
    }
    int col, row;
    mouseCell0(event, self, &col, &row);

    // Tab bar click: consume if click is on the tab bar row
    if (row == 0 && g_tab_bar_visible) {
        attyx_tab_bar_click(col, g_cols);
        return;
    }

    // Overlay click: consume if hit
    if (g_overlay_has_actions && attyx_overlay_click(col, row)) return;

    // Split pane click: focus the clicked pane + start drag resize
    if (g_split_active) {
        attyx_split_drag_start(col, row);
        _splitDragging = YES;
        attyx_split_click(col, row);
    }

    if (event.modifierFlags & NSEventModifierFlagCommand) {
        int cols = g_cols, rows_n = g_rows;
        if (g_cells && col >= 0 && col < cols && row >= 0 && row < rows_n) {
            uint32_t lid = g_cells[row * cols + col].link_id;
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
            if (detectUrlAtCell(row, col, cols, &dStart, &dEnd, dUrl, DETECTED_URL_MAX, &dLen) && dLen > 0) {
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

    // Show native context menu
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    [menu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Reload Config" action:@selector(reloadConfig:) keyEquivalent:@""];
    [NSMenu popUpContextMenu:menu withEvent:event forView:self];
}

- (void)reloadConfig:(id)sender {
    attyx_trigger_config_reload();
}

- (void)rightMouseUp:(NSEvent *)event {
    _rightDown = NO;
    if (!g_mouse_tracking || !g_mouse_sgr) return;
    int col, row;
    mouseCell(event, self, &col, &row);
    int btn = 2 | mouseModifiers(event.modifierFlags);
    sendSgrMouse(btn, col, row, NO);
}

- (void)otherMouseDown:(NSEvent *)event {
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
    _middleDown = NO;
    if (!g_mouse_tracking || !g_mouse_sgr) return;
    int col, row;
    mouseCell(event, self, &col, &row);
    int btn = 1 | mouseModifiers(event.modifierFlags);
    sendSgrMouse(btn, col, row, NO);
}

- (void)mouseDragged:(NSEvent *)event {
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
    int tracking = g_mouse_tracking;
    if (tracking == 3 && g_mouse_sgr) {
        int col, row;
        mouseCell(event, self, &col, &row);
        if (col == _lastMouseCol && row == _lastMouseRow) return;
        int btn = 35 | mouseModifiers(event.modifierFlags);
        sendSgrMouse(btn, col, row, YES);
        _lastMouseCol = col;
        _lastMouseRow = row;
        return;
    }

    if (!tracking) {
        int col, row;
        mouseCell0(event, self, &col, &row);
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
}

- (void)scrollWheel:(NSEvent *)event {
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
    if (g_sel_active) {
        g_sel_active = 0;
        attyx_mark_all_dirty();
    }
}

@end
