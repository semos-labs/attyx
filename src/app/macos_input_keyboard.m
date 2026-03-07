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

    // AI edit prompt key routing
    if (g_ai_prompt_active) {
        unsigned short kc = event.keyCode;
        if (kc == kVK_Escape)                   { attyx_ai_prompt_cmd(7); return YES; }
        if (kc == kVK_Return)                   { attyx_ai_prompt_cmd(8); return YES; }
        if (kc == kVK_Delete)                   { attyx_ai_prompt_cmd(1); return YES; }
        if (kc == kVK_ForwardDelete)            { attyx_ai_prompt_cmd(2); return YES; }
        if (kc == kVK_LeftArrow)                { attyx_ai_prompt_cmd(3); return YES; }
        if (kc == kVK_RightArrow)               { attyx_ai_prompt_cmd(4); return YES; }
        if (kc == kVK_Home)                     { attyx_ai_prompt_cmd(5); return YES; }
        if (kc == kVK_End)                      { attyx_ai_prompt_cmd(6); return YES; }
    }

    // Session picker / command palette key routing
    if (g_session_picker_active || g_command_palette_active) {
        unsigned short kc = event.keyCode;
        if (kc == kVK_Escape)              { attyx_picker_cmd(7); return YES; }
        if (kc == kVK_Return)              { attyx_picker_cmd(8); return YES; }
        if (kc == kVK_Delete)              { attyx_picker_cmd(1); return YES; }
        if (kc == kVK_ForwardDelete)       { attyx_picker_cmd(1); return YES; }
        if (kc == kVK_UpArrow)             { attyx_picker_cmd(9); return YES; }
        if (kc == kVK_DownArrow)           { attyx_picker_cmd(10); return YES; }
        if (ctrl && kc == kVK_ANSI_R)      { attyx_picker_cmd(11); return YES; }
        if (ctrl && kc == kVK_ANSI_X)      { attyx_picker_cmd(12); return YES; }
        if (ctrl && kc == kVK_ANSI_U)      { attyx_picker_cmd(13); return YES; }
        if (ctrl && kc == kVK_ANSI_D)      { attyx_picker_cmd(14); return YES; }
        if (ctrl && kc == kVK_ANSI_W)      { attyx_picker_cmd(15); return YES; }
        if (ctrl && kc == kVK_ANSI_C)      { attyx_picker_cmd(7); return YES; }
        // Printable chars fall through to IME handler
        return NO;
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

    // Copy/visual mode: intercept all keys when active
    if (g_copy_mode) {
        uint16_t vmKey; uint32_t vmCp;
        eventToKeyCombo(event, &vmKey, &vmCp);
        uint8_t vmMods = buildMods(flags);
        if (attyx_copy_mode_key(vmKey, vmMods, vmCp)) return YES;
    }

    // Configurable keybind match (covers all user-bindable actions:
    // hotkeys, scrollback, popups, sequences, etc.)
    {
        uint16_t matchKey; uint32_t matchCp;
        eventToKeyCombo(event, &matchKey, &matchCp);
        uint8_t mods = buildMods(flags);
        uint8_t action = attyx_keybind_match(matchKey, mods, matchCp);
        if (action != ATTYX_ACTION_NONE && attyx_dispatch_action(action))
            return YES;
    }

    // Alt+Arrow: send word movement sequences (ESC b / ESC f)
    if ((flags & NSEventModifierFlagOption) && !cmd && !ctrl) {
        uint16_t mapped = mapKeyCode(event.keyCode);
        if (mapped == KC_LEFT || mapped == KC_RIGHT) {
            const uint8_t *seq = (mapped == KC_LEFT)
                ? (const uint8_t *)"\x1b" "b" : (const uint8_t *)"\x1b" "f";
            void (*send_fn)(const uint8_t*, int) =
                g_popup_active ? attyx_popup_send_input : attyx_send_input;
            send_fn(seq, 2);
            return YES;
        }
    }

    // Cmd+Arrow: remap to Home/End for standard terminal line-navigation
    if (cmd) {
        uint16_t mapped = mapKeyCode(event.keyCode);
        if (mapped == KC_LEFT || mapped == KC_RIGHT) {
            uint16_t remapped = (mapped == KC_LEFT) ? KC_HOME : KC_END;
            uint8_t et = event.isARepeat ? 2 : 1;
            void (*handle_key_fn)(uint16_t, uint8_t, uint8_t, uint32_t) =
                g_popup_active ? attyx_popup_handle_key : attyx_handle_key;
            handle_key_fn(remapped, 0, et, 0);
            return YES;
        }
        // Forward remaining Cmd keys to system menu (Cmd+Q, Cmd+H, etc.)
        [super keyDown:event];
        return YES;
    }

    unsigned short kc = event.keyCode;
    uint16_t mapped = mapKeyCode(kc);
    uint8_t mods = buildMods(flags);
    uint8_t et = event.isARepeat ? 2 : 1;

    // Route special keys to popup or main terminal
    void (*handle_key_fn)(uint16_t, uint8_t, uint8_t, uint32_t) =
        g_popup_active ? attyx_popup_handle_key : attyx_handle_key;

    // Special keys handled by the encoder
    if (mapped != UINT16_MAX) {
        handle_key_fn(mapped, mods, et, 0);
        return YES;
    }

    // Ctrl+key or Alt+key with a character
    if (ctrl || (flags & NSEventModifierFlagOption)) {
        NSString* chars = event.charactersIgnoringModifiers;
        if (chars.length > 0) {
            uint32_t cp = [chars characterAtIndex:0];
            handle_key_fn(KC_CODEPOINT, mods, et, cp);
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

    NSEventModifierFlags flags = event.modifierFlags;
    BOOL cmd = (flags & NSEventModifierFlagCommand) != 0;

    if ([self hasMarkedText]) {
        [self snapViewportAndClearSelection];
        if (cmd) {
            [super keyDown:event];
            return;
        }
        [self interpretKeyEvents:@[event]];
        return;
    }

    // Handle special keys (keybinds, overlays, search) BEFORE clearing
    // selection — the AI edit keybind needs to see g_sel_active.
    if ([self handleSpecialKey:event]) return;

    // In copy mode, suppress all remaining input (no IME, no PTY)
    if (g_copy_mode) return;

    [self snapViewportAndClearSelection];

    // Repeat bypass: send repeated character keys directly to the encoder,
    // skipping interpretKeyEvents (which would trigger the accent picker).
    if (event.isARepeat) {
        NSString* chars = event.characters;
        if (chars.length > 0) {
            uint32_t cp = [chars characterAtIndex:0];
            uint8_t mods = buildMods(event.modifierFlags);
            void (*handle_key_fn)(uint16_t, uint8_t, uint8_t, uint32_t) =
                g_popup_active ? attyx_popup_handle_key : attyx_handle_key;
            handle_key_fn(KC_CODEPOINT, mods, 2, cp);
            return;
        }
    }

    [self interpretKeyEvents:@[event]];
}

@end
