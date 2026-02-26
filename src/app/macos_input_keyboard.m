// Attyx — AttyxView keyboard handling

#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#include "macos_internal.h"

// KeyCode enum values (must match src/term/key_encode.zig KeyCode)
enum {
    KC_UP = 0, KC_DOWN, KC_LEFT, KC_RIGHT,
    KC_HOME, KC_END, KC_PAGE_UP, KC_PAGE_DOWN,
    KC_INSERT, KC_DELETE,
    KC_BACKSPACE, KC_ENTER, KC_TAB, KC_ESCAPE,
    KC_F1, KC_F2, KC_F3, KC_F4, KC_F5, KC_F6,
    KC_F7, KC_F8, KC_F9, KC_F10, KC_F11, KC_F12,
    KC_CODEPOINT,
};

static uint16_t mapKeyCode(unsigned short kc) {
    switch (kc) {
        case kVK_UpArrow:      return KC_UP;
        case kVK_DownArrow:    return KC_DOWN;
        case kVK_RightArrow:   return KC_RIGHT;
        case kVK_LeftArrow:    return KC_LEFT;
        case kVK_Home:         return KC_HOME;
        case kVK_End:          return KC_END;
        case kVK_PageUp:       return KC_PAGE_UP;
        case kVK_PageDown:     return KC_PAGE_DOWN;
        case kVK_Help:         return KC_INSERT;
        case kVK_ForwardDelete:return KC_DELETE;
        case kVK_Delete:       return KC_BACKSPACE;
        case kVK_Return:       return KC_ENTER;
        case kVK_Tab:          return KC_TAB;
        case kVK_Escape:       return KC_ESCAPE;
        case kVK_F1:           return KC_F1;
        case kVK_F2:           return KC_F2;
        case kVK_F3:           return KC_F3;
        case kVK_F4:           return KC_F4;
        case kVK_F5:           return KC_F5;
        case kVK_F6:           return KC_F6;
        case kVK_F7:           return KC_F7;
        case kVK_F8:           return KC_F8;
        case kVK_F9:           return KC_F9;
        case kVK_F10:          return KC_F10;
        case kVK_F11:          return KC_F11;
        case kVK_F12:          return KC_F12;
        default:               return UINT16_MAX;
    }
}

static uint8_t buildMods(NSEventModifierFlags flags) {
    uint8_t m = 0;
    if (flags & NSEventModifierFlagShift)   m |= 1;
    if (flags & NSEventModifierFlagOption)  m |= 2;
    if (flags & NSEventModifierFlagControl) m |= 4;
    if (flags & NSEventModifierFlagCommand) m |= 8;
    return m;
}

// Map lowercase letter ('a'-'z') to macOS virtual keycode
static unsigned short letterToVK(char letter) {
    // macOS virtual keycodes for A-Z (not alphabetical!)
    static const unsigned short vk_map[26] = {
        0x00, // A
        0x0B, // B
        0x08, // C
        0x02, // D
        0x0E, // E
        0x03, // F
        0x05, // G
        0x04, // H
        0x22, // I
        0x26, // J
        0x28, // K
        0x25, // L
        0x2E, // M
        0x2D, // N
        0x1F, // O
        0x23, // P
        0x0C, // Q
        0x0F, // R
        0x01, // S
        0x11, // T
        0x20, // U
        0x09, // V
        0x0D, // W
        0x07, // X
        0x10, // Y
        0x06, // Z
    };
    if (letter >= 'a' && letter <= 'z') return vk_map[letter - 'a'];
    return UINT16_MAX;
}

@implementation AttyxView (Keyboard)

- (void)keyUp:(NSEvent *)event {
    // Only send key release when kitty event_types flag is active (bit 1)
    if (!(g_kitty_kbd_flags & 2)) return;

    unsigned short kc = event.keyCode;
    uint16_t mapped = mapKeyCode(kc);
    uint8_t mods = buildMods(event.modifierFlags);

    void (*handle_key_fn)(uint16_t, uint8_t, uint8_t, uint32_t) =
        g_popup_active ? attyx_popup_handle_key : attyx_handle_key;

    if (mapped != UINT16_MAX) {
        handle_key_fn(mapped, mods, 3, 0);
    } else {
        NSString* chars = event.charactersIgnoringModifiers;
        if (chars.length > 0) {
            uint32_t cp = [chars characterAtIndex:0];
            handle_key_fn(KC_CODEPOINT, mods, 3, cp);
        }
    }
}

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
    BOOL shift = (flags & NSEventModifierFlagShift) != 0;
    BOOL cmd   = (flags & NSEventModifierFlagCommand) != 0;

    if (cmd) {
        [super keyDown:event];
        return YES;
    }

    // Overlay interaction keys (only when overlay has actions)
    if (g_overlay_has_actions) {
        unsigned short kc = event.keyCode;
        if (kc == kVK_Escape) {
            attyx_overlay_esc();
            return YES;
        }
        if (kc == kVK_Tab && !ctrl && !shift) {
            attyx_overlay_tab();
            return YES;
        }
        if (kc == kVK_Return && !ctrl && !shift) {
            attyx_overlay_enter();
            return YES;
        }
    }

    // Shift+PageUp/Down/Home/End for scrollback navigation (UI-level, not sent to PTY)
    if (shift && !g_mouse_tracking && !g_alt_screen) {
        unsigned short kc = event.keyCode;
        if (kc == kVK_PageUp)   { attyx_scroll_viewport(g_rows); return YES; }
        if (kc == kVK_PageDown) { attyx_scroll_viewport(-g_rows); return YES; }
        if (kc == kVK_Home)     { g_viewport_offset = g_scrollback_count; attyx_mark_all_dirty(); return YES; }
        if (kc == kVK_End)      { g_viewport_offset = 0; attyx_mark_all_dirty(); return YES; }
    }

    // Ctrl+Shift+R → reload config (intercept before generic key handling)
    if (ctrl && shift && event.keyCode == 0x0F /* kVK_ANSI_R */) {
        attyx_trigger_config_reload();
        return YES;
    }

    // Ctrl+Shift+D → toggle debug overlay
    if (ctrl && shift && event.keyCode == 0x02 /* kVK_ANSI_D */) {
        attyx_toggle_debug_overlay();
        return YES;
    }

    // Ctrl+Shift+A → toggle anchor demo overlay
    if (ctrl && shift && event.keyCode == 0x00 /* kVK_ANSI_A */) {
        attyx_toggle_anchor_demo();
        return YES;
    }

    // Popup hotkeys (Ctrl+Shift+<letter>)
    if (ctrl && shift) {
        for (int i = 0; i < g_popup_hotkey_count; i++) {
            char letter = g_popup_hotkey_letters[i];
            unsigned short vk = letterToVK(letter);
            if (vk != UINT16_MAX && event.keyCode == vk) {
                attyx_popup_toggle(i);
                return YES;
            }
        }
    }

    unsigned short kc = event.keyCode;
    uint16_t mapped = mapKeyCode(kc);
    uint8_t mods = buildMods(flags);

    // Route special keys to popup or main terminal
    void (*handle_key_fn)(uint16_t, uint8_t, uint8_t, uint32_t) =
        g_popup_active ? attyx_popup_handle_key : attyx_handle_key;

    // Special keys handled by the encoder
    if (mapped != UINT16_MAX) {
        handle_key_fn(mapped, mods, 1, 0);
        return YES;
    }

    // Ctrl+key or Alt+key with a character
    if (ctrl || (flags & NSEventModifierFlagOption)) {
        NSString* chars = event.charactersIgnoringModifiers;
        if (chars.length > 0) {
            uint32_t cp = [chars characterAtIndex:0];
            handle_key_fn(KC_CODEPOINT, mods, 1, cp);
            return YES;
        }
        if (ctrl) return YES;
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

    // When popup is active, route ALL input to popup (except Cmd and popup hotkeys)
    if (g_popup_active) {
        if ([self handleSpecialKey:event]) return;  // hotkeys checked first
        // Route text input to popup
        [self interpretKeyEvents:@[event]];
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
