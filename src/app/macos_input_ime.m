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
        if (g_popup_active) {
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

    if (g_bracketed_paste) {
        attyx_send_input((const uint8_t*)"\x1b[200~", 6);
        attyx_send_input((const uint8_t*)utf8, len);
        attyx_send_input((const uint8_t*)"\x1b[201~", 6);
    } else {
        attyx_send_input((const uint8_t*)utf8, len);
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
                unichar u = (unichar)ch;
                if (ch > 0xFFFF) {
                    uint32_t cp = ch - 0x10000;
                    unichar hi = (unichar)(0xD800 + (cp >> 10));
                    unichar lo = (unichar)(0xDC00 + (cp & 0x3FF));
                    unichar pair[2] = {hi, lo};
                    [result appendString:[NSString stringWithCharacters:pair length:2]];
                } else {
                    [result appendString:[NSString stringWithCharacters:&u length:1]];
                }
            }
        }

        if (row < er) [result appendString:@"\n"];
    }

    if (result.length > 0) {
        NSPasteboard* pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setString:result forType:NSPasteboardTypeString];
    }
}

@end
