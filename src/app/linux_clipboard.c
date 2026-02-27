// Attyx — Linux clipboard helpers
// GLFW-first clipboard with popen() fallback to wl-copy/wl-paste or xclip.

#include "linux_internal.h"

#ifdef __linux__

// ---------------------------------------------------------------------------
// Backend detection (lazy-cached)
// ---------------------------------------------------------------------------

enum ClipBackend {
    CB_UNKNOWN = 0,
    CB_WAYLAND,
    CB_X11,
    CB_NONE,
};

static enum ClipBackend g_clip_backend = CB_UNKNOWN;

static int commandExists(const char* name) {
    char buf[256];
    snprintf(buf, sizeof(buf), "which %s >/dev/null 2>&1", name);
    return system(buf) == 0;
}

static enum ClipBackend detectBackend(void) {
    if (g_clip_backend != CB_UNKNOWN) return g_clip_backend;

    // Check Wayland first
    const char* wl = getenv("WAYLAND_DISPLAY");
    if (wl && wl[0]) {
        if (commandExists("wl-copy") && commandExists("wl-paste")) {
            ATTYX_LOG_DEBUG("clipboard", "detected Wayland backend (wl-copy/wl-paste)");
            g_clip_backend = CB_WAYLAND;
            return g_clip_backend;
        }
    }

    // Check X11
    const char* display = getenv("DISPLAY");
    const char* session = getenv("XDG_SESSION_TYPE");
    int isX11 = (display && display[0]) ||
                (session && strcmp(session, "x11") == 0);
    if (isX11) {
        if (commandExists("xclip")) {
            ATTYX_LOG_DEBUG("clipboard", "detected X11 backend (xclip)");
            g_clip_backend = CB_X11;
            return g_clip_backend;
        }
    }

    ATTYX_LOG_WARN("clipboard", "no fallback clipboard tool found (install wl-copy or xclip)");
    g_clip_backend = CB_NONE;
    return g_clip_backend;
}

// ---------------------------------------------------------------------------
// Copy
// ---------------------------------------------------------------------------

void clipboardCopy(const char* text) {
    if (!text || !text[0]) return;

    // Try GLFW first
    if (g_window) {
        glfwSetClipboardString(g_window, text);
        // Verify it took (GLFW may fail silently on Wayland)
        const char* check = glfwGetClipboardString(g_window);
        if (check && check[0]) {
            ATTYX_LOG_DEBUG("clipboard", "copy via GLFW (%d bytes)", (int)strlen(text));
            return;
        }
        ATTYX_LOG_DEBUG("clipboard", "GLFW clipboard set failed, trying fallback");
    }

    // Fallback via popen
    enum ClipBackend backend = detectBackend();
    const char* cmd = NULL;
    switch (backend) {
        case CB_WAYLAND: cmd = "wl-copy"; break;
        case CB_X11:     cmd = "xclip -selection clipboard"; break;
        default:
            ATTYX_LOG_WARN("clipboard", "copy failed: no clipboard backend available");
            return;
    }

    FILE* fp = popen(cmd, "w");
    if (!fp) {
        ATTYX_LOG_ERR("clipboard", "copy: popen('%s') failed", cmd);
        return;
    }
    fwrite(text, 1, strlen(text), fp);
    int rc = pclose(fp);
    if (rc != 0) {
        ATTYX_LOG_WARN("clipboard", "copy: '%s' exited with %d", cmd, rc);
    } else {
        ATTYX_LOG_DEBUG("clipboard", "copy via %s (%d bytes)",
                        backend == CB_WAYLAND ? "wl-copy" : "xclip",
                        (int)strlen(text));
    }
}

// ---------------------------------------------------------------------------
// Paste
// ---------------------------------------------------------------------------

#define PASTE_BUF_SIZE (64 * 1024)
static char g_paste_buf[PASTE_BUF_SIZE];

const char* clipboardPaste(void) {
    // Try GLFW first
    if (g_window) {
        const char* text = glfwGetClipboardString(g_window);
        if (text && text[0]) {
            ATTYX_LOG_DEBUG("clipboard", "paste via GLFW (%d bytes)", (int)strlen(text));
            return text;
        }
        ATTYX_LOG_DEBUG("clipboard", "GLFW clipboard get returned empty, trying fallback");
    }

    // Fallback via popen
    enum ClipBackend backend = detectBackend();
    const char* cmd = NULL;
    switch (backend) {
        case CB_WAYLAND: cmd = "wl-paste --no-newline 2>/dev/null"; break;
        case CB_X11:     cmd = "xclip -selection clipboard -o 2>/dev/null"; break;
        default:
            ATTYX_LOG_WARN("clipboard", "paste failed: no clipboard backend available");
            return NULL;
    }

    FILE* fp = popen(cmd, "r");
    if (!fp) {
        ATTYX_LOG_ERR("clipboard", "paste: popen('%s') failed", cmd);
        return NULL;
    }

    size_t total = 0;
    while (total < PASTE_BUF_SIZE - 1) {
        size_t n = fread(g_paste_buf + total, 1, PASTE_BUF_SIZE - 1 - total, fp);
        if (n == 0) break;
        total += n;
    }
    g_paste_buf[total] = '\0';
    pclose(fp);

    if (total == 0) {
        ATTYX_LOG_DEBUG("clipboard", "paste: fallback returned empty");
        return NULL;
    }

    ATTYX_LOG_DEBUG("clipboard", "paste via %s (%d bytes)",
                    backend == CB_WAYLAND ? "wl-paste" : "xclip",
                    (int)total);
    return g_paste_buf;
}

// ---------------------------------------------------------------------------
// Programmatic clipboard copy (callable from any thread)
// ---------------------------------------------------------------------------

void attyx_clipboard_copy(const char* text, int len) {
    if (!text || len <= 0) return;
    char* buf = (char*)malloc(len + 1);
    if (!buf) return;
    memcpy(buf, text, len);
    buf[len] = '\0';
    clipboardCopy(buf);
    free(buf);
}

#endif // __linux__
