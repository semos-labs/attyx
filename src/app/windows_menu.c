// Attyx — Windows system menu bar (File, Edit, View, Window)
//
// Creates a Win32 menu bar matching the macOS NSMenu structure.
// Menu items dispatch actions via attyx_dispatch_action() using the same
// action IDs as keybinds.zig.

#ifdef _WIN32

#include "windows_internal.h"

// ---------------------------------------------------------------------------
// Menu command IDs — WM_COMMAND wParam values
// ---------------------------------------------------------------------------
// We use a base offset so they don't collide with system commands.
// The low byte carries the action ID from keybinds.zig.

#define MENU_BASE           0x1000
#define MENU_ACTION(id)     (MENU_BASE + (id))

// Special commands (not keybind actions)
#define MENU_COPY           0x2001
#define MENU_PASTE          0x2002
#define MENU_MINIMIZE       0x2003
#define MENU_ZOOM           0x2004
#define MENU_OPEN_CONFIG    MENU_ACTION(89)
#define MENU_RELOAD_CONFIG  MENU_ACTION(10)

// ---------------------------------------------------------------------------
// Accelerator key text from keybind table
// ---------------------------------------------------------------------------

// Build a human-readable accelerator string (e.g. "Ctrl+Shift+T") for a
// given action ID by querying the runtime keybind table. Returns the length
// written into `buf`, 0 if no keybind is bound.
static int menuAccelText(uint8_t action_id, char* buf, int buf_size) {
    uint16_t key = 0;
    uint8_t  mods = 0;
    uint32_t cp = 0;
    if (!attyx_keybind_for_action(action_id, &key, &mods, &cp))
        return 0;

    int pos = 0;

    // Modifier prefixes — Windows convention: Ctrl+Shift+Alt+Key
    if (mods & 4) { // MOD_CTRL
        const char* s = "Ctrl+";
        int l = 5;
        if (pos + l < buf_size) { memcpy(buf + pos, s, l); pos += l; }
    }
    if (mods & 1) { // MOD_SHIFT
        const char* s = "Shift+";
        int l = 6;
        if (pos + l < buf_size) { memcpy(buf + pos, s, l); pos += l; }
    }
    if (mods & 2) { // MOD_ALT
        const char* s = "Alt+";
        int l = 4;
        if (pos + l < buf_size) { memcpy(buf + pos, s, l); pos += l; }
    }
    if (mods & 8) { // MOD_SUPER (Win key — show as Win+)
        const char* s = "Win+";
        int l = 4;
        if (pos + l < buf_size) { memcpy(buf + pos, s, l); pos += l; }
    }

    // Key name — special keys by enum, otherwise codepoint
    enum { KC_UP=0, KC_DOWN, KC_LEFT, KC_RIGHT, KC_HOME, KC_END,
           KC_PAGE_UP, KC_PAGE_DOWN, KC_INSERT, KC_DELETE,
           KC_BACKSPACE, KC_ENTER, KC_TAB, KC_ESCAPE, KC_F1 };

    const char* key_name = NULL;
    switch (key) {
        case KC_UP:        key_name = "Up"; break;
        case KC_DOWN:      key_name = "Down"; break;
        case KC_LEFT:      key_name = "Left"; break;
        case KC_RIGHT:     key_name = "Right"; break;
        case KC_HOME:      key_name = "Home"; break;
        case KC_END:       key_name = "End"; break;
        case KC_PAGE_UP:   key_name = "PgUp"; break;
        case KC_PAGE_DOWN: key_name = "PgDn"; break;
        case KC_INSERT:    key_name = "Ins"; break;
        case KC_DELETE:    key_name = "Del"; break;
        case KC_BACKSPACE: key_name = "Bksp"; break;
        case KC_ENTER:     key_name = "Enter"; break;
        case KC_TAB:       key_name = "Tab"; break;
        case KC_ESCAPE:    key_name = "Esc"; break;
        default:
            // F1–F12
            if (key >= KC_F1 && key <= KC_F1 + 11) {
                int n = pos;
                n += snprintf(buf + n, buf_size - n, "F%d", key - KC_F1 + 1);
                return (n < buf_size) ? n : 0;
            }
            // Printable codepoint
            if (cp >= 0x20 && cp < 0x7f) {
                char ch = (char)cp;
                if (ch >= 'a' && ch <= 'z') ch -= 32; // uppercase
                if (pos < buf_size - 1) {
                    buf[pos++] = ch;
                    return pos;
                }
            }
            return 0;
    }

    if (key_name) {
        int l = (int)strlen(key_name);
        if (pos + l < buf_size) {
            memcpy(buf + pos, key_name, l);
            pos += l;
        }
    }
    return pos;
}

// Append a menu item with action ID and auto-generated accelerator text.
static void appendActionItem(HMENU menu, const char* label, uint8_t action_id) {
    char text[128];
    char accel[64];
    int accel_len = menuAccelText(action_id, accel, sizeof(accel));

    if (accel_len > 0) {
        accel[accel_len] = '\0';
        snprintf(text, sizeof(text), "%s\t%s", label, accel);
    } else {
        snprintf(text, sizeof(text), "%s", label);
    }

    AppendMenuA(menu, MF_STRING, MENU_ACTION(action_id), text);
}

// ---------------------------------------------------------------------------
// Public: build and install the menu bar
// ---------------------------------------------------------------------------

HMENU windows_menu_create(void) {
    HMENU menubar = CreateMenu();

    // -- File --
    HMENU file_menu = CreatePopupMenu();
    appendActionItem(file_menu, "New Tab",              49);
    AppendMenuA(file_menu, MF_SEPARATOR, 0, NULL);
    appendActionItem(file_menu, "Next Tab",             51);
    appendActionItem(file_menu, "Previous Tab",         52);
    AppendMenuA(file_menu, MF_SEPARATOR, 0, NULL);
    appendActionItem(file_menu, "Split Vertical",       53);
    appendActionItem(file_menu, "Split Horizontal",     54);
    AppendMenuA(file_menu, MF_SEPARATOR, 0, NULL);
    appendActionItem(file_menu, "Close Tab",            50);
    appendActionItem(file_menu, "Close Pane",           55);
    AppendMenuA(file_menu, MF_SEPARATOR, 0, NULL);
    appendActionItem(file_menu, "Close All Tabs",       92);
    AppendMenuA(file_menu, MF_SEPARATOR, 0, NULL);
    appendActionItem(file_menu, "Close Window",         14);
    AppendMenuA(menubar, MF_POPUP, (UINT_PTR)file_menu, "File");

    // -- Edit --
    HMENU edit_menu = CreatePopupMenu();
    AppendMenuA(edit_menu, MF_STRING, MENU_COPY,  "Copy\tCtrl+Shift+C");
    AppendMenuA(edit_menu, MF_STRING, MENU_PASTE, "Paste\tCtrl+Shift+V");
    AppendMenuA(edit_menu, MF_SEPARATOR, 0, NULL);
    appendActionItem(edit_menu, "Find...",              3);
    appendActionItem(edit_menu, "Find Next",            4);
    appendActionItem(edit_menu, "Find Previous",        5);
    AppendMenuA(edit_menu, MF_SEPARATOR, 0, NULL);
    appendActionItem(edit_menu, "Clear Screen",         73);
    AppendMenuA(menubar, MF_POPUP, (UINT_PTR)edit_menu, "Edit");

    // -- View --
    HMENU view_menu = CreatePopupMenu();
    appendActionItem(view_menu, "Bigger",               85);
    appendActionItem(view_menu, "Smaller",              86);
    appendActionItem(view_menu, "Reset Font Size",      87);
    AppendMenuA(view_menu, MF_SEPARATOR, 0, NULL);
    appendActionItem(view_menu, "Command Palette",      77);
    AppendMenuA(menubar, MF_POPUP, (UINT_PTR)view_menu, "View");

    // -- Settings --
    HMENU settings_menu = CreatePopupMenu();
    appendActionItem(settings_menu, "Open Config...",   89);
    appendActionItem(settings_menu, "Reload Config",    10);
    AppendMenuA(menubar, MF_POPUP, (UINT_PTR)settings_menu, "Settings");

    // -- Window --
    HMENU window_menu = CreatePopupMenu();
    AppendMenuA(window_menu, MF_STRING, MENU_MINIMIZE, "Minimize");
    AppendMenuA(window_menu, MF_STRING, MENU_ZOOM,     "Maximize");
    AppendMenuA(menubar, MF_POPUP, (UINT_PTR)window_menu, "Window");

    return menubar;
}

// ---------------------------------------------------------------------------
// Public: handle WM_COMMAND from menu clicks
// ---------------------------------------------------------------------------

int windows_menu_handle_command(WPARAM wParam) {
    WORD cmd = LOWORD(wParam);

    // Action-based menu items (MENU_BASE + action_id)
    if (cmd >= MENU_BASE && cmd < MENU_BASE + 256) {
        uint8_t action_id = (uint8_t)(cmd - MENU_BASE);
        attyx_dispatch_action(action_id);
        return 1;
    }

    // Special commands
    switch (cmd) {
    case MENU_COPY:
        attyx_platform_copy();
        return 1;
    case MENU_PASTE:
        attyx_platform_paste();
        return 1;
    case MENU_MINIMIZE:
        ShowWindow(g_hwnd, SW_MINIMIZE);
        return 1;
    case MENU_ZOOM:
        ShowWindow(g_hwnd, IsZoomed(g_hwnd) ? SW_RESTORE : SW_MAXIMIZE);
        return 1;
    }

    return 0;
}

#endif // _WIN32
