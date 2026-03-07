// Attyx — AttyxView IME (NSTextInputClient) and clipboard

#import <Cocoa/Cocoa.h>
#include <string.h>
#include "macos_input_private.h"

@implementation AttyxView (IMEClipboard)

// ---------------------------------------------------------------------------
// NSTextInputClient — IME support
// ---------------------------------------------------------------------------

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    NSString* text = ([string isKindOfClass:[NSAttributedString class]])
        ? [(NSAttributedString*)string string]
        : (NSString*)string;

    g_ime_composing = 0;
    g_ime_preedit_len = 0;
    _markedText.string = @"";
    _markedRange = NSMakeRange(NSNotFound, 0);
    _selectedRange = NSMakeRange(0, 0);
    attyx_mark_all_dirty();

    const char* utf8 = [text UTF8String];
    if (utf8 && strlen(utf8) > 0) {
        if (g_search_active) {
            // Decode UTF-8 and route codepoints to search bar
            const uint8_t* p = (const uint8_t*)utf8;
            const uint8_t* end = p + strlen(utf8);
            while (p < end) {
                uint32_t cp = 0;
                int len = 1;
                if (*p < 0x80) { cp = *p; }
                else if ((*p & 0xE0) == 0xC0 && p+1 < end) { cp = (*p & 0x1F) << 6 | (p[1] & 0x3F); len = 2; }
                else if ((*p & 0xF0) == 0xE0 && p+2 < end) { cp = (*p & 0x0F) << 12 | (p[1] & 0x3F) << 6 | (p[2] & 0x3F); len = 3; }
                else if ((*p & 0xF8) == 0xF0 && p+3 < end) { cp = (*p & 0x07) << 18 | (p[1] & 0x3F) << 12 | (p[2] & 0x3F) << 6 | (p[3] & 0x3F); len = 4; }
                p += len;
                if (cp >= 0x20) attyx_search_insert_char(cp);
            }
        } else if (g_ai_prompt_active) {
            const uint8_t* p = (const uint8_t*)utf8;
            const uint8_t* end = p + strlen(utf8);
            while (p < end) {
                uint32_t cp = 0;
                int len = 1;
                if (*p < 0x80) { cp = *p; }
                else if ((*p & 0xE0) == 0xC0 && p+1 < end) { cp = (*p & 0x1F) << 6 | (p[1] & 0x3F); len = 2; }
                else if ((*p & 0xF0) == 0xE0 && p+2 < end) { cp = (*p & 0x0F) << 12 | (p[1] & 0x3F) << 6 | (p[2] & 0x3F); len = 3; }
                else if ((*p & 0xF8) == 0xF0 && p+3 < end) { cp = (*p & 0x07) << 18 | (p[1] & 0x3F) << 12 | (p[2] & 0x3F) << 6 | (p[3] & 0x3F); len = 4; }
                p += len;
                if (cp >= 0x20) attyx_ai_prompt_insert_char(cp);
            }
        } else if (g_session_picker_active || g_command_palette_active || g_theme_picker_active) {
            const uint8_t* p = (const uint8_t*)utf8;
            const uint8_t* end = p + strlen(utf8);
            while (p < end) {
                uint32_t cp = 0;
                int len = 1;
                if (*p < 0x80) { cp = *p; }
                else if ((*p & 0xE0) == 0xC0 && p+1 < end) { cp = (*p & 0x1F) << 6 | (p[1] & 0x3F); len = 2; }
                else if ((*p & 0xF0) == 0xE0 && p+2 < end) { cp = (*p & 0x0F) << 12 | (p[1] & 0x3F) << 6 | (p[2] & 0x3F); len = 3; }
                else if ((*p & 0xF8) == 0xF0 && p+3 < end) { cp = (*p & 0x07) << 18 | (p[1] & 0x3F) << 12 | (p[2] & 0x3F) << 6 | (p[3] & 0x3F); len = 4; }
                p += len;
                if (cp >= 0x20) attyx_picker_insert_char(cp);
            }
        } else if (g_popup_active) {
            attyx_popup_send_input((const uint8_t*)utf8, (int)strlen(utf8));
        } else {
            attyx_send_input((const uint8_t*)utf8, (int)strlen(utf8));
        }
    }
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
    NSString* text = ([string isKindOfClass:[NSAttributedString class]])
        ? [(NSAttributedString*)string string]
        : (NSString*)string;

    if (text.length == 0) {
        [self unmarkText];
        return;
    }

    _markedText.string = text;
    _markedRange = NSMakeRange(0, text.length);
    _selectedRange = selectedRange;

    const char* utf8 = [text UTF8String];
    int len = utf8 ? (int)strlen(utf8) : 0;
    if (len > ATTYX_IME_MAX_BYTES - 1) len = ATTYX_IME_MAX_BYTES - 1;

    if (!g_ime_composing) {
        g_ime_anchor_row = g_cursor_row;
        g_ime_anchor_col = g_cursor_col;
    }

    memcpy(g_ime_preedit, utf8, len);
    g_ime_preedit[len] = '\0';
    g_ime_preedit_len = len;
    g_ime_cursor_index = (selectedRange.location != NSNotFound) ? (int)selectedRange.location : -1;
    g_ime_composing = 1;
    attyx_mark_all_dirty();
}

- (void)unmarkText {
    _markedText.string = @"";
    _markedRange = NSMakeRange(NSNotFound, 0);
    _selectedRange = NSMakeRange(0, 0);
    g_ime_composing = 0;
    g_ime_preedit_len = 0;
    attyx_mark_all_dirty();
}

- (BOOL)hasMarkedText {
    return (_markedRange.location != NSNotFound && _markedRange.length > 0);
}

- (NSRange)markedRange    { return _markedRange; }
- (NSRange)selectedRange  { return _selectedRange; }

- (NSAttributedString*)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    return nil;
}

- (NSArray<NSAttributedStringKey>*)validAttributesForMarkedText {
    return @[];
}

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    int row = g_ime_composing ? g_ime_anchor_row : g_cursor_row;
    int col = g_ime_composing ? g_ime_anchor_col : g_cursor_col;
    float availW = (float)self.bounds.size.width  - g_padding_left - g_padding_right;
    float availH = (float)self.bounds.size.height - g_padding_top  - g_padding_bottom;
    float cx = floorf((availW - g_cols * g_cell_pt_w) * 0.5f);
    float cy = 0;
    if (cx < 0) cx = 0;
    if (cy < 0) cy = 0;
    float offX = g_padding_left + cx;
    float offY = g_padding_top  + cy;
    NSRect cellRect = NSMakeRect(offX + col * g_cell_pt_w, offY + (row + 1) * g_cell_pt_h, g_cell_pt_w, g_cell_pt_h);
    NSRect screenRect = [self.window convertRectToScreen:[self convertRect:cellRect toView:nil]];
    return screenRect;
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point { return NSNotFound; }

- (void)doCommandBySelector:(SEL)selector {
    // When search, AI prompt, or session picker is active, handled by handleSpecialKey
    if (g_search_active || g_ai_prompt_active || g_session_picker_active || g_command_palette_active || g_theme_picker_active) return;

    if (selector == @selector(insertNewline:)) {
        attyx_send_input((const uint8_t*)"\r", 1);
    } else if (selector == @selector(insertTab:)) {
        attyx_send_input((const uint8_t*)"\t", 1);
    } else if (selector == @selector(cancelOperation:)) {
        attyx_send_input((const uint8_t*)"\x1b", 1);
    } else if (selector == @selector(deleteBackward:)) {
        attyx_send_input((const uint8_t*)"\x7f", 1);
    } else {
        [super doCommandBySelector:selector];
    }
}

// ---------------------------------------------------------------------------
// Clipboard
// ---------------------------------------------------------------------------

- (void)paste:(id)sender {
    NSPasteboard* pb = [NSPasteboard generalPasteboard];
    NSString* text = [pb stringForType:NSPasteboardTypeString];
    if (!text || text.length == 0) return;

    const char* utf8 = [text UTF8String];
    if (!utf8) return;
    int len = (int)strlen(utf8);

    void (*send_fn)(const uint8_t*, int) =
        g_popup_active ? attyx_popup_send_input : attyx_send_input;
    if (g_bracketed_paste) {
        send_fn((const uint8_t*)"\x1b[200~", 6);
        send_fn((const uint8_t*)utf8, len);
        send_fn((const uint8_t*)"\x1b[201~", 6);
    } else {
        send_fn((const uint8_t*)utf8, len);
    }
}

- (void)copy:(id)sender {
    if (!g_sel_active) return;

    int sr = g_sel_start_row, sc = g_sel_start_col;
    int er = g_sel_end_row,   ec = g_sel_end_col;
    if (sr > er || (sr == er && sc > ec)) {
        int tr = sr, tc = sc;
        sr = er; sc = ec;
        er = tr; ec = tc;
    }

    int cols = g_cols;
    int rows = g_rows;
    if (cols <= 0 || rows <= 0) return;

    NSMutableString* result = [NSMutableString string];

    uint64_t gen;
    do { gen = g_cell_gen; } while (gen & 1);

    if (sr < 0) { sr = 0; sc = 0; }
    if (er >= rows) { er = rows - 1; ec = cols - 1; }

    for (int row = sr; row <= er && row < rows; row++) {
        int cStart = (row == sr) ? sc : 0;
        int cEnd   = (row == er) ? ec : cols - 1;
        if (cStart >= cols) cStart = cols - 1;
        if (cEnd >= cols) cEnd = cols - 1;

        int lastNonSpace = cStart - 1;
        for (int c = cEnd; c >= cStart; c--) {
            int idx = row * cols + c;
            uint32_t ch = g_cells[idx].character;
            if (ch > 32) { lastNonSpace = c; break; }
        }

        for (int c = cStart; c <= lastNonSpace; c++) {
            int idx = row * cols + c;
            uint32_t ch = g_cells[idx].character;
            if (ch == 0 || ch == ' ') {
                [result appendString:@" "];
            } else {
                // Build codepoint sequence: base + up to 2 combining marks
                uint32_t cps[3] = { ch, g_cells[idx].combining[0], g_cells[idx].combining[1] };
                unichar utf16[6];
                int utf16Len = 0;
                for (int k = 0; k < 3; k++) {
                    uint32_t cp = cps[k];
                    if (cp == 0) continue;
                    if (cp > 0xFFFF) {
                        uint32_t u = cp - 0x10000;
                        utf16[utf16Len++] = (unichar)(0xD800 + (u >> 10));
                        utf16[utf16Len++] = (unichar)(0xDC00 + (u & 0x3FF));
                    } else {
                        utf16[utf16Len++] = (unichar)cp;
                    }
                }
                [result appendString:[NSString stringWithCharacters:utf16 length:utf16Len]];
            }
        }

        if (row < er && !g_row_wrapped[row]) [result appendString:@"\n"];
    }

    if (result.length > 0) {
        NSPasteboard* pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setString:result forType:NSPasteboardTypeString];
    }
}

// ---------------------------------------------------------------------------
// Drag and Drop — file path insertion
// ---------------------------------------------------------------------------

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    (void)sender;
    return NSDragOperationCopy;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSPasteboard* pb = [sender draggingPasteboard];
    NSArray<NSURL*>* urls = [pb readObjectsForClasses:@[[NSURL class]]
                                              options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (!urls || urls.count == 0) return NO;

    NSMutableString* result = [NSMutableString string];
    for (NSUInteger i = 0; i < urls.count; i++) {
        if (i > 0) [result appendString:@" "];
        // Shell-escape: wrap in single quotes, replace ' with '\''
        NSString* escaped = [urls[i].path stringByReplacingOccurrencesOfString:@"'"
                                                                   withString:@"'\\''"];
        [result appendFormat:@"'%@'", escaped];
    }

    const char* utf8 = [result UTF8String];
    if (!utf8) return NO;
    int len = (int)strlen(utf8);

    void (*send_fn)(const uint8_t*, int) =
        g_popup_active ? attyx_popup_send_input : attyx_send_input;
    if (g_bracketed_paste) {
        send_fn((const uint8_t*)"\x1b[200~", 6);
        send_fn((const uint8_t*)utf8, len);
        send_fn((const uint8_t*)"\x1b[201~", 6);
    } else {
        send_fn((const uint8_t*)utf8, len);
    }
    return YES;
}

@end

// ---------------------------------------------------------------------------
// Programmatic clipboard copy (callable from any thread)
// ---------------------------------------------------------------------------

void attyx_clipboard_copy(const char* text, int len) {
    if (!text || len <= 0) return;
    NSString* str = [[NSString alloc] initWithBytes:text length:len encoding:NSUTF8StringEncoding];
    if (!str) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSPasteboard* pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setString:str forType:NSPasteboardTypeString];
    });
}
