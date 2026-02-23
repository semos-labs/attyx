// Attyx — AttyxView keyboard handling

#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#include "macos_internal.h"

@implementation AttyxView (Keyboard)

- (void)keyUp:(NSEvent *)event {}

- (void)snapViewportAndClearSelection {
    if (g_viewport_offset != 0) {
        g_viewport_offset = 0;
        attyx_mark_all_dirty();
    }
    if (g_sel_active) {
        g_sel_active = 0;
        attyx_mark_all_dirty();
    }
}

- (BOOL)handleSpecialKey:(NSEvent *)event {
    NSEventModifierFlags flags = event.modifierFlags;
    BOOL ctrl  = (flags & NSEventModifierFlagControl) != 0;
    BOOL alt   = (flags & NSEventModifierFlagOption) != 0;
    BOOL cmd   = (flags & NSEventModifierFlagCommand) != 0;
    BOOL shift = (flags & NSEventModifierFlagShift) != 0;

    if (cmd) {
        [super keyDown:event];
        return YES;
    }

    if (shift && !g_mouse_tracking && !g_alt_screen) {
        unsigned short kc = event.keyCode;
        if (kc == kVK_PageUp)   { attyx_scroll_viewport(g_rows); return YES; }
        if (kc == kVK_PageDown) { attyx_scroll_viewport(-g_rows); return YES; }
        if (kc == kVK_Home)     { g_viewport_offset = g_scrollback_count; attyx_mark_all_dirty(); return YES; }
        if (kc == kVK_End)      { g_viewport_offset = 0; attyx_mark_all_dirty(); return YES; }
    }

    unsigned short kc = event.keyCode;

    BOOL appMode = (g_cursor_keys_app != 0);
    const char* appUp    = "\x1bOA";
    const char* appDown  = "\x1bOB";
    const char* appRight = "\x1bOC";
    const char* appLeft  = "\x1bOD";
    const char* csiUp    = "\x1b[A";
    const char* csiDown  = "\x1b[B";
    const char* csiRight = "\x1b[C";
    const char* csiLeft  = "\x1b[D";

    switch (kc) {
        case kVK_UpArrow:    { const char* s = appMode ? appUp : csiUp;       attyx_send_input((const uint8_t*)s, 3); return YES; }
        case kVK_DownArrow:  { const char* s = appMode ? appDown : csiDown;   attyx_send_input((const uint8_t*)s, 3); return YES; }
        case kVK_RightArrow: { const char* s = appMode ? appRight : csiRight; attyx_send_input((const uint8_t*)s, 3); return YES; }
        case kVK_LeftArrow:  { const char* s = appMode ? appLeft : csiLeft;   attyx_send_input((const uint8_t*)s, 3); return YES; }
        case kVK_Return:        attyx_send_input((const uint8_t*)"\r", 1); return YES;
        case kVK_Delete:        attyx_send_input((const uint8_t*)"\x7f", 1); return YES;
        case kVK_Tab:           attyx_send_input((const uint8_t*)"\t", 1); return YES;
        case kVK_Escape:        attyx_send_input((const uint8_t*)"\x1b", 1); return YES;
        case kVK_Home:          attyx_send_input((const uint8_t*)"\x1b[H", 3); return YES;
        case kVK_End:           attyx_send_input((const uint8_t*)"\x1b[F", 3); return YES;
        case kVK_PageUp:        attyx_send_input((const uint8_t*)"\x1b[5~", 4); return YES;
        case kVK_PageDown:      attyx_send_input((const uint8_t*)"\x1b[6~", 4); return YES;
        case kVK_ForwardDelete: attyx_send_input((const uint8_t*)"\x1b[3~", 4); return YES;
        case kVK_Help:          attyx_send_input((const uint8_t*)"\x1b[2~", 4); return YES;
        case kVK_F1:  attyx_send_input((const uint8_t*)"\x1bOP",   3); return YES;
        case kVK_F2:  attyx_send_input((const uint8_t*)"\x1bOQ",   3); return YES;
        case kVK_F3:  attyx_send_input((const uint8_t*)"\x1bOR",   3); return YES;
        case kVK_F4:  attyx_send_input((const uint8_t*)"\x1bOS",   3); return YES;
        case kVK_F5:  attyx_send_input((const uint8_t*)"\x1b[15~", 5); return YES;
        case kVK_F6:  attyx_send_input((const uint8_t*)"\x1b[17~", 5); return YES;
        case kVK_F7:  attyx_send_input((const uint8_t*)"\x1b[18~", 5); return YES;
        case kVK_F8:  attyx_send_input((const uint8_t*)"\x1b[19~", 5); return YES;
        case kVK_F9:  attyx_send_input((const uint8_t*)"\x1b[20~", 5); return YES;
        case kVK_F10: attyx_send_input((const uint8_t*)"\x1b[21~", 5); return YES;
        case kVK_F11: attyx_send_input((const uint8_t*)"\x1b[23~", 5); return YES;
        case kVK_F12: attyx_send_input((const uint8_t*)"\x1b[24~", 5); return YES;
        default: break;
    }

    // Ctrl+Shift+R → reload config (intercept before generic Ctrl handling)
    if (ctrl && shift && kc == 0x0F /* kVK_ANSI_R */) {
        attyx_trigger_config_reload();
        return YES;
    }

    if (ctrl) {
        NSString* chars = event.charactersIgnoringModifiers;
        if (chars.length == 1) {
            unichar ch = [chars characterAtIndex:0];
            if (ch >= 'a' && ch <= 'z') { uint8_t b = (uint8_t)(ch - 'a' + 1); attyx_send_input(&b, 1); return YES; }
            if (ch >= 'A' && ch <= 'Z') { uint8_t b = (uint8_t)(ch - 'A' + 1); attyx_send_input(&b, 1); return YES; }
            if (ch == '[')  { attyx_send_input((const uint8_t*)"\x1b", 1); return YES; }
            if (ch == ']')  { uint8_t b = 0x1d; attyx_send_input(&b, 1); return YES; }
            if (ch == '\\') { uint8_t b = 0x1c; attyx_send_input(&b, 1); return YES; }
            if (ch == '^' || ch == '6') { uint8_t b = 0x1e; attyx_send_input(&b, 1); return YES; }
            if (ch == '_' || ch == '-') { uint8_t b = 0x1f; attyx_send_input(&b, 1); return YES; }
            if (ch == '@' || ch == ' ' || ch == '2') { uint8_t b = 0x00; attyx_send_input(&b, 1); return YES; }
        }
        return YES;
    }

    if (alt) {
        NSString* chars = event.charactersIgnoringModifiers;
        if (chars.length > 0) {
            const char* utf8 = [chars UTF8String];
            if (utf8) {
                uint8_t esc = 0x1b;
                attyx_send_input(&esc, 1);
                attyx_send_input((const uint8_t*)utf8, (int)strlen(utf8));
                return YES;
            }
        }
    }

    return NO;
}

- (void)keyDown:(NSEvent *)event {
    NSEventModifierFlags flags = event.modifierFlags;
    BOOL cmd   = (flags & NSEventModifierFlagCommand) != 0;
    BOOL shift = (flags & NSEventModifierFlagShift) != 0;
    unsigned short kc = event.keyCode;

    if (cmd && kc == 3 /* kVK_F */) {
        if (g_nativeSearchBar) [g_nativeSearchBar toggle];
        return;
    }

    if (cmd && kc == 5 /* kVK_G */ && g_search_active) {
        if (shift) {
            __sync_fetch_and_add((volatile int*)&g_search_nav_delta, -1);
        } else {
            __sync_fetch_and_add((volatile int*)&g_search_nav_delta, 1);
        }
        attyx_mark_all_dirty();
        return;
    }

    [self snapViewportAndClearSelection];

    if ([self hasMarkedText]) {
        if (cmd) {
            [super keyDown:event];
            return;
        }
        [self interpretKeyEvents:@[event]];
        return;
    }

    if ([self handleSpecialKey:event]) return;

    [self interpretKeyEvents:@[event]];
}

@end
