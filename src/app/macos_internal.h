#ifndef ATTYX_MACOS_INTERNAL_H
#define ATTYX_MACOS_INTERNAL_H

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <CoreText/CoreText.h>

#include "bridge.h"

// ---------------------------------------------------------------------------
// Shared state (written by Zig PTY thread, read by renderer on main thread)
// ---------------------------------------------------------------------------

extern AttyxCell* g_cells;
extern int g_cols;
extern int g_rows;
extern volatile uint64_t g_cell_gen;
extern volatile int g_cursor_row;
extern volatile int g_cursor_col;
extern volatile int g_should_quit;

// Mode flags
extern volatile int g_bracketed_paste;
extern volatile int g_cursor_keys_app;

// Mouse mode flags
extern volatile int g_mouse_tracking;
extern volatile int g_mouse_sgr;

// Hyperlink hover state
extern volatile uint32_t g_hover_link_id;
extern volatile int g_hover_row;

// Regex-detected URL hover state
#define DETECTED_URL_MAX 2048
extern char g_detected_url[DETECTED_URL_MAX];
extern volatile int g_detected_url_len;
extern volatile int g_detected_url_row;
extern volatile int g_detected_url_start_col;
extern volatile int g_detected_url_end_col;

// Row-level dirty bitset
extern volatile uint64_t g_dirty[4];

// Pending resize
extern volatile int g_pending_resize_rows;
extern volatile int g_pending_resize_cols;

// Cell dimensions in points (set once at glyph cache creation)
extern CGFloat g_cell_pt_w;
extern CGFloat g_cell_pt_h;

// ---------------------------------------------------------------------------
// Vertex layout (matches shader struct)
// ---------------------------------------------------------------------------

typedef struct __attribute__((packed)) {
    float px, py;
    float u, v;
    float r, g, b, a;
} Vertex;

// ---------------------------------------------------------------------------
// GlyphCache
// ---------------------------------------------------------------------------

#define GLYPH_CACHE_CAP  4096
// Bit 30 of the slot value flags a 2-cell-wide glyph (advance > 1.3×cell).
// Bit 31 is reserved for the "not found" sentinel (-1 = all bits set).
// Bit 29 flags a color emoji glyph stored in color_texture (BGRA8), not texture (R8).
#define GLYPH_WIDE_BIT   (1 << 30)
#define GLYPH_COLOR_BIT  (1 << 29)

typedef struct {
    uint32_t codepoint;
    int slot;
} GlyphEntry;

typedef struct {
    id<MTLTexture> texture;        // R8Unorm  — grayscale glyphs
    id<MTLTexture> color_texture;  // BGRA8Unorm — color emoji
    CTFontRef      font;
    float          glyph_w;
    float          glyph_h;
    float          scale;
    CGFloat        descent;
    float          baseline_y;
    float          x_offset;
    int            atlas_cols;
    int            atlas_w;
    int            atlas_h;
    int            next_slot;
    int            max_slots;
    id<MTLDevice>  device;

    GlyphEntry     map[GLYPH_CACHE_CAP];
} GlyphCache;

// ---------------------------------------------------------------------------
// GlyphCache functions (macos_glyph.m)
// ---------------------------------------------------------------------------

GlyphCache createGlyphCache(id<MTLDevice> device, CGFloat scale);
int  glyphCacheLookup(GlyphCache* gc, uint32_t cp);
int  glyphCacheRasterize(GlyphCache* gc, uint32_t cp);
int  renderBoxDraw(CGContextRef ctx, uint32_t cp, int gw, int gh, float scale);

// ---------------------------------------------------------------------------
// Emit helpers (macos_renderer.m — used by renderer and search bar)
// ---------------------------------------------------------------------------

int emitRect(Vertex* v, int i, float x, float y, float w, float h,
             float r, float g, float b, float a);
int emitGlyph(Vertex* v, int i, GlyphCache* gc, uint32_t cp,
              float x, float y, float gw, float gh,
              float r, float g, float b);
int emitString(Vertex* v, int i, GlyphCache* gc,
               const char* str, int len, float x, float y,
               float gw, float gh, float r, float g, float b);

// ---------------------------------------------------------------------------
// Dirty helpers (macos_renderer.m)
// ---------------------------------------------------------------------------

static inline int dirtyBitTest(const uint64_t dirty[4], int row) {
    if (row < 0 || row >= 256) return 0;
    return (dirty[row >> 6] >> (row & 63)) & 1;
}

static inline int dirtyAny(const uint64_t dirty[4]) {
    return (dirty[0] | dirty[1] | dirty[2] | dirty[3]) != 0;
}

// ---------------------------------------------------------------------------
// AttyxRenderer interface (macos_renderer.m)
// ---------------------------------------------------------------------------

@interface AttyxRenderer : NSObject <MTKViewDelegate>
- (instancetype)initWithDevice:(id<MTLDevice>)device
                          view:(MTKView*)view
                    glyphCache:(GlyphCache)glyphCache;
@end

// ---------------------------------------------------------------------------
// AttyxView interface (macos_input.m)
// ---------------------------------------------------------------------------

@interface AttyxView : MTKView <NSTextInputClient>
- (instancetype)initWithFrame:(NSRect)frameRect device:(id<MTLDevice>)device;
@end

// ---------------------------------------------------------------------------
// Search bar (macos_search.m) — interface exposed so callers can message it
// ---------------------------------------------------------------------------

@interface AttyxSearchBar : NSVisualEffectView <NSTextFieldDelegate>
@property (strong) NSView      *inputBox;
@property (strong) NSTextField *inputField;
@property (strong) NSTextField *countLabel;
@property (strong) NSButton    *prevButton;
@property (strong) NSButton    *nextButton;
@property (strong) NSButton    *closeButton;
@property (weak)   NSView      *termView;
- (instancetype)initForTermView:(NSView*)parent;
- (void)show;
- (void)dismiss;
- (void)toggle;
- (void)syncCountLabel;
@end

extern AttyxSearchBar* g_nativeSearchBar;
void syncSearchBarCount(void);

// ---------------------------------------------------------------------------
// Metal shader source (platform_macos.m)
// ---------------------------------------------------------------------------

extern NSString* const kShaderSource;

#endif // ATTYX_MACOS_INTERNAL_H
