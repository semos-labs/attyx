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
    KC_KP_0, KC_KP_1, KC_KP_2, KC_KP_3, KC_KP_4,
    KC_KP_5, KC_KP_6, KC_KP_7, KC_KP_8, KC_KP_9,
    KC_KP_DECIMAL, KC_KP_DIVIDE, KC_KP_MULTIPLY,
    KC_KP_MINUS, KC_KP_PLUS, KC_KP_ENTER, KC_KP_EQUAL,
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
        case kVK_ANSI_Keypad0: return KC_KP_0;
        case kVK_ANSI_Keypad1: return KC_KP_1;
        case kVK_ANSI_Keypad2: return KC_KP_2;
        case kVK_ANSI_Keypad3: return KC_KP_3;
        case kVK_ANSI_Keypad4: return KC_KP_4;
        case kVK_ANSI_Keypad5: return KC_KP_5;
        case kVK_ANSI_Keypad6: return KC_KP_6;
        case kVK_ANSI_Keypad7: return KC_KP_7;
        case kVK_ANSI_Keypad8: return KC_KP_8;
        case kVK_ANSI_Keypad9: return KC_KP_9;
        case kVK_ANSI_KeypadDecimal:  return KC_KP_DECIMAL;
        case kVK_ANSI_KeypadDivide:   return KC_KP_DIVIDE;
        case kVK_ANSI_KeypadMultiply: return KC_KP_MULTIPLY;
        case kVK_ANSI_KeypadMinus:    return KC_KP_MINUS;
        case kVK_ANSI_KeypadPlus:     return KC_KP_PLUS;
        case kVK_ANSI_KeypadEnter:    return KC_KP_ENTER;
        case kVK_ANSI_KeypadEquals:   return KC_KP_EQUAL;
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

// ---------------------------------------------------------------------------
// Keybind dispatch — returns 1 if handled, 0 if the key should pass through
// ---------------------------------------------------------------------------

static int dispatchAction(uint8_t action) {
    if (action >= ATTYX_ACTION_POPUP_TOGGLE_0 &&
        action < ATTYX_ACTION_POPUP_TOGGLE_0 + ATTYX_POPUP_MAX) {
        attyx_popup_toggle(action - ATTYX_ACTION_POPUP_TOGGLE_0);
        return 1;
    }
    if (action >= ATTYX_ACTION_TAB_NEW && action <= ATTYX_ACTION_TAB_PREV) {
        attyx_tab_action(action);
        return 1;
    }
    if (action >= ATTYX_ACTION_SPLIT_VERTICAL && action <= ATTYX_ACTION_PANE_CLOSE) {
        attyx_split_action(action);
        return 1;
    }
    if (action >= ATTYX_ACTION_PANE_FOCUS_UP && action <= ATTYX_ACTION_PANE_RESIZE_RIGHT) {
        if (g_split_active) {
            attyx_split_action(action);
            return 1;
        }
        return 0; // Pass through to terminal when no splits
    }
    switch (action) {
        case ATTYX_ACTION_SEARCH_TOGGLE:
            if (g_search_active) {
                attyx_search_cmd(7); // dismiss
            } else {
                g_search_active = 1;
                g_search_query_len = 0;
                g_search_gen++;
                attyx_mark_all_dirty();
            }
            return 1;
        case ATTYX_ACTION_SEARCH_NEXT:
            if (g_search_active) {
                __sync_fetch_and_add((volatile int*)&g_search_nav_delta, 1);
                attyx_mark_all_dirty();
            }
            return 1;
        case ATTYX_ACTION_SEARCH_PREV:
            if (g_search_active) {
                __sync_fetch_and_add((volatile int*)&g_search_nav_delta, -1);
                attyx_mark_all_dirty();
            }
            return 1;
        case ATTYX_ACTION_SCROLL_PAGE_UP:
            if (g_mouse_tracking || g_alt_screen) return 0;
            attyx_scroll_viewport(g_rows);
            return 1;
        case ATTYX_ACTION_SCROLL_PAGE_DOWN:
            if (g_mouse_tracking || g_alt_screen) return 0;
            attyx_scroll_viewport(-g_rows);
            return 1;
        case ATTYX_ACTION_SCROLL_TO_TOP:
            if (g_mouse_tracking || g_alt_screen) return 0;
            g_viewport_offset = g_scrollback_count;
            attyx_mark_all_dirty();
            return 1;
        case ATTYX_ACTION_SCROLL_TO_BOTTOM:
            if (g_mouse_tracking || g_alt_screen) return 0;
            g_viewport_offset = 0;
            attyx_mark_all_dirty();
            return 1;
        case ATTYX_ACTION_CONFIG_RELOAD:
            attyx_trigger_config_reload();
            return 1;
        case ATTYX_ACTION_DEBUG_TOGGLE:
            attyx_toggle_debug_overlay();
            return 1;
        case ATTYX_ACTION_ANCHOR_DEMO:
            attyx_toggle_anchor_demo();
            return 1;
        case ATTYX_ACTION_AI_DEMO_TOGGLE:
            attyx_toggle_ai_demo();
            return 1;
        case ATTYX_ACTION_NEW_WINDOW:
            attyx_spawn_new_window();
            return 1;
        case ATTYX_ACTION_CLOSE_WINDOW:
            [NSApp.keyWindow close];
            return 1;
        case ATTYX_ACTION_SEND_SEQUENCE:
            if (g_keybind_matched_seq_len > 0 && g_keybind_matched_seq) {
                void (*send_fn)(const uint8_t*, int) =
                    g_popup_active ? attyx_popup_send_input : attyx_send_input;
                send_fn(g_keybind_matched_seq, g_keybind_matched_seq_len);
            }
            return 1;
        default:
            return 0;
    }
}

// Build key + codepoint for keybind matching from an NSEvent.
static void eventToKeyCombo(NSEvent* event, uint16_t* outKey, uint32_t* outCp) {
    uint16_t mapped = mapKeyCode(event.keyCode);
    if (mapped != UINT16_MAX) {
        *outKey = mapped;
        *outCp = 0;
    } else {
        NSString* chars = event.charactersIgnoringModifiers;
        *outKey = KC_CODEPOINT;
        *outCp = (chars.length > 0) ? [chars characterAtIndex:0] : 0;
    }
}

@implementation AttyxView (Keyboard)

// Intercept Ctrl+Tab / Ctrl+Shift+Tab before macOS uses them for focus navigation
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (event.type != NSEventTypeKeyDown) return [super performKeyEquivalent:event];

    NSEventModifierFlags flags = event.modifierFlags;
    BOOL ctrl  = (flags & NSEventModifierFlagControl) != 0;

    if (ctrl && event.keyCode == kVK_Tab) {
        [self keyDown:event];
        return YES;
    }

    return [super performKeyEquivalent:event];
}

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

    // Search bar key routing (before overlay actions, since search bar is an overlay)
    if (g_search_active) {
        unsigned short kc = event.keyCode;
        if (kc == kVK_Escape)                   { attyx_search_cmd(7); return YES; }
        if (kc == kVK_Return)                   { attyx_search_cmd(shift ? 9 : 8); return YES; }
        if (kc == kVK_Delete)                   { attyx_search_cmd(1); return YES; }
        if (kc == kVK_ForwardDelete)            { attyx_search_cmd(2); return YES; }
        if (kc == kVK_LeftArrow && !cmd)        { attyx_search_cmd(3); return YES; }
        if (kc == kVK_RightArrow && !cmd)       { attyx_search_cmd(4); return YES; }
        if (kc == kVK_LeftArrow && cmd)         { attyx_search_cmd(5); return YES; }
        if (kc == kVK_RightArrow && cmd)        { attyx_search_cmd(6); return YES; }
        if (kc == kVK_Home)                     { attyx_search_cmd(5); return YES; }
        if (kc == kVK_End)                      { attyx_search_cmd(6); return YES; }
        if (kc == kVK_UpArrow)                  { attyx_search_cmd(9); return YES; }
        if (kc == kVK_DownArrow)                { attyx_search_cmd(8); return YES; }
        if (ctrl && kc == kVK_ANSI_W)          { attyx_search_cmd(10); return YES; }
    }

    // Overlay interaction keys (contextual, not user-configurable)
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
        if (kc == kVK_Tab && shift && !ctrl) {
            attyx_overlay_shift_tab();
            return YES;
        }
        if (kc == kVK_Return && !ctrl && !shift) {
            attyx_overlay_enter();
            return YES;
        }
    }

    // Configurable keybind match (covers all user-bindable actions:
    // hotkeys, scrollback, popups, sequences, etc.)
    {
        uint16_t matchKey; uint32_t matchCp;
        eventToKeyCombo(event, &matchKey, &matchCp);
        uint8_t mods = buildMods(flags);
        uint8_t action = attyx_keybind_match(matchKey, mods, matchCp);
        if (action != ATTYX_ACTION_NONE && dispatchAction(action))
            return YES;
    }

    // Cmd with no keybind match: forward to system menu (Cmd+Q, Cmd+H, etc.)
    if (cmd) {
        [super keyDown:event];
        return YES;
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
    // When popup is active, route ALL input to popup (except keybinds)
    if (g_popup_active) {
        if ([self handleSpecialKey:event]) return;
        [self interpretKeyEvents:@[event]];
        return;
    }

    [self snapViewportAndClearSelection];

    NSEventModifierFlags flags = event.modifierFlags;
    BOOL cmd = (flags & NSEventModifierFlagCommand) != 0;

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
