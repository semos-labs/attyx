// Attyx — macOS platform layer (Cocoa + Metal + Core Text)
// This file contains: globals, bridge functions, shader source, AppDelegate, entry point.
// Rendering:   macos_renderer.m
// Glyph cache: macos_glyph.m
// Input:       macos_input.m
// Search bar:  macos_search.m

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CABase.h>
#import <UserNotifications/UserNotifications.h>

#include "bridge.h"
#include "macos_internal.h"

// Auto-updater (macos_updater.m)
extern void attyx_updater_init(void);
extern void attyx_updater_check(void);
extern BOOL attyx_updater_available(void);

// ---------------------------------------------------------------------------
// Shared state definitions
// ---------------------------------------------------------------------------

AttyxCell* g_cells = NULL;
int g_cols = 0;
int g_rows = 0;
volatile uint64_t g_cell_gen = 0;
volatile int g_cursor_row = 0;
volatile int g_cursor_col = 0;
volatile int g_should_quit = 0;

volatile int g_bracketed_paste = 0;
volatile int g_cursor_keys_app = 0;

volatile int g_mouse_tracking = 0;
volatile int g_mouse_sgr = 0;

volatile int g_viewport_offset = 0;
volatile int g_scrollback_count = 0;
volatile int g_alt_screen = 0;

volatile int g_sel_start_row = -1, g_sel_start_col = -1;
volatile int g_sel_end_row = -1, g_sel_end_col = -1;
volatile int g_sel_active = 0;

volatile uint8_t g_row_wrapped[ATTYX_MAX_ROWS] = {0};

volatile int g_cursor_shape   = 0;
volatile int g_cursor_visible = 1;
volatile int g_cursor_trail   = 0;
volatile int g_font_ligatures = 1;

char         g_title_buf[ATTYX_TITLE_MAX];
volatile int g_title_len     = 0;
volatile int g_title_changed = 0;

volatile int  g_ime_composing    = 0;
volatile int  g_ime_cursor_index = -1;
volatile int  g_ime_anchor_row   = 0;
volatile int  g_ime_anchor_col   = 0;
char          g_ime_preedit[ATTYX_IME_MAX_BYTES];
volatile int  g_ime_preedit_len  = 0;

char         g_font_family[ATTYX_FONT_FAMILY_MAX];
volatile int g_font_family_len = 0;
volatile int g_font_size       = 14;
volatile int g_default_font_size = 14;
volatile int g_cell_width      = 0;
volatile int g_cell_height     = 0;
char         g_font_fallback[ATTYX_FONT_FALLBACK_MAX][ATTYX_FONT_FAMILY_MAX];
volatile int g_font_fallback_count = 0;

char          g_search_query[ATTYX_SEARCH_QUERY_MAX];
volatile int  g_search_query_len  = 0;
volatile int  g_search_active     = 0;
volatile int  g_search_gen        = 0;
volatile int  g_search_nav_delta  = 0;
volatile int  g_search_total      = 0;
volatile int  g_search_current    = 0;
AttyxSearchVis g_search_vis[ATTYX_SEARCH_VIS_MAX];
volatile int  g_search_vis_count  = 0;
volatile int  g_search_cur_vis_row = -1;
volatile int  g_search_cur_vis_cs  = 0;
volatile int  g_search_cur_vis_ce  = 0;

volatile uint32_t g_hover_link_id = 0;
volatile int g_hover_row = -1;

AttyxImagePlacement g_image_placements[ATTYX_MAX_IMAGE_PLACEMENTS];
volatile int      g_image_placement_count = 0;
volatile uint64_t g_image_gen = 0;

AttyxImagePlacement g_popup_image_placements[ATTYX_POPUP_MAX_IMAGE_PLACEMENTS];
volatile int        g_popup_image_placement_count = 0;

char g_detected_url[DETECTED_URL_MAX];
volatile int g_detected_url_len = 0;
volatile int g_detected_url_row = -1;
volatile int g_detected_url_start_col = 0;
volatile int g_detected_url_end_col = 0;

volatile uint64_t g_dirty[4] = {0,0,0,0};

volatile int g_pending_resize_rows = 0;
volatile int g_pending_resize_cols = 0;

CGFloat g_cell_pt_w = 0;
CGFloat g_cell_pt_h = 0;

volatile float g_cell_w_pts = 0;
volatile float g_cell_h_pts = 0;

// Overlay system
AttyxOverlayDesc  g_overlay_descs[ATTYX_OVERLAY_MAX_LAYERS];
AttyxOverlayCell  g_overlay_cells[ATTYX_OVERLAY_MAX_LAYERS][ATTYX_OVERLAY_MAX_CELLS];
volatile int      g_overlay_count = 0;
volatile uint32_t g_overlay_gen   = 0;

// Popup terminal
AttyxPopupDesc    g_popup_desc;
AttyxOverlayCell  g_popup_cells[ATTYX_POPUP_MAX_CELLS];
volatile uint32_t g_popup_gen    = 0;

// ---------------------------------------------------------------------------
// Bridge function implementations
// ---------------------------------------------------------------------------

void attyx_set_cursor(int row, int col) {
    g_cursor_row = row;
    g_cursor_col = col;
}

void attyx_request_quit(void) {
    g_should_quit = 1;  // Signal PTY thread immediately to prevent use-after-close race
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp terminate:nil];
    });
}

int attyx_should_quit(void) {
    return g_should_quit;
}

void attyx_set_mode_flags(int bracketed_paste, int cursor_keys_app) {
    g_bracketed_paste = bracketed_paste;
    g_cursor_keys_app = cursor_keys_app;
}

void attyx_set_mouse_mode(int tracking, int sgr) {
    g_mouse_tracking = tracking;
    g_mouse_sgr = sgr;
}

void attyx_mark_all_dirty(void) {
    for (int i = 0; i < 4; i++)
        __sync_fetch_and_or((volatile uint64_t*)&g_dirty[i], ~(uint64_t)0);
}

void attyx_scroll_viewport(int delta) {
    int cur = g_viewport_offset;
    int sb = g_scrollback_count;
    int nv = cur + delta;
    if (nv < 0) nv = 0;
    if (nv > sb) nv = sb;
    g_viewport_offset = nv;
    // Dirty bits are set by the PTY thread after it updates the cell buffer
    // for the new viewport offset.  Setting them here would cause the renderer
    // to draw stale cells (old viewport content), producing artifacts.
}

void attyx_set_dirty(const uint64_t dirty[4]) {
    for (int i = 0; i < 4; i++)
        __sync_fetch_and_or((volatile uint64_t*)&g_dirty[i], dirty[i]);
}

void attyx_set_grid_size(int cols, int rows) {
    g_cols = cols;
    g_rows = rows;
}

void attyx_begin_cell_update(void) {
    __sync_fetch_and_add(&g_cell_gen, 1);
}

void attyx_end_cell_update(void) {
    __sync_fetch_and_add(&g_cell_gen, 1);
}

int attyx_check_resize(int* out_rows, int* out_cols) {
    int pr = g_pending_resize_rows;
    int pc = g_pending_resize_cols;
    if (pr <= 0 || pc <= 0) return 0;
    if (pr == g_rows && pc == g_cols) return 0;
    *out_rows = pr;
    *out_cols = pc;
    g_pending_resize_rows = 0;
    g_pending_resize_cols = 0;
    return 1;
}

// ---------------------------------------------------------------------------
// Metal shader source
// ---------------------------------------------------------------------------

NSString* const kShaderSource =
@"#include <metal_stdlib>\n"
 "using namespace metal;\n"
 "\n"
 "struct Vertex {\n"
 "    packed_float2 position;\n"
 "    packed_float2 texcoord;\n"
 "    packed_float4 color;\n"
 "};\n"
 "\n"
 "struct VertexOut {\n"
 "    float4 position [[position]];\n"
 "    float2 texcoord;\n"
 "    float4 color;\n"
 "};\n"
 "\n"
 "vertex VertexOut vert_main(\n"
 "    const device Vertex* vertices [[buffer(0)]],\n"
 "    constant float2& viewport [[buffer(1)]],\n"
 "    uint vid [[vertex_id]])\n"
 "{\n"
 "    VertexOut out;\n"
 "    float2 pos = vertices[vid].position / viewport * 2.0 - 1.0;\n"
 "    pos.y = -pos.y;\n"
 "    out.position = float4(pos, 0.0, 1.0);\n"
 "    out.texcoord = vertices[vid].texcoord;\n"
 "    out.color = vertices[vid].color;\n"
 "    return out;\n"
 "}\n"
 "\n"
 "fragment float4 frag_solid(VertexOut in [[stage_in]]) {\n"
 "    return in.color;\n"
 "}\n"
 "\n"
 "fragment float4 frag_text(\n"
 "    VertexOut in [[stage_in]],\n"
 "    texture2d<float> tex [[texture(0)]])\n"
 "{\n"
 "    constexpr sampler s(filter::nearest);\n"
 "    float a = tex.sample(s, in.texcoord).r;\n"
 "    return float4(in.color.rgb, in.color.a * a);\n"
 "}\n"
 "\n"
 "fragment float4 frag_color_text(\n"
 "    VertexOut in [[stage_in]],\n"
 "    texture2d<float> tex [[texture(0)]])\n"
 "{\n"
 "    constexpr sampler s(filter::nearest);\n"
 "    float4 c = tex.sample(s, in.texcoord);\n"
 "    // Premultiplied BGRA; Metal auto-swizzles BGRA8Unorm to RGBA. Scale by vertex alpha.\n"
 "    return float4(c.rgb * in.color.a, c.a * in.color.a);\n"
 "}\n"
 "\n"
 "fragment float4 frag_image(\n"
 "    VertexOut in [[stage_in]],\n"
 "    texture2d<float> tex [[texture(0)]])\n"
 "{\n"
 "    constexpr sampler s(filter::linear);\n"
 "    float4 c = tex.sample(s, in.texcoord);\n"
 "    return float4(c.rgb, c.a * in.color.a);\n"
 "}\n";

// ---------------------------------------------------------------------------
// Platform close window (called from Zig dispatch)
// ---------------------------------------------------------------------------

void attyx_platform_close_window(void) {
    [NSApp.keyWindow close];
}

// ---------------------------------------------------------------------------
// Desktop notifications (OSC 9 / OSC 777)
// ---------------------------------------------------------------------------

void attyx_platform_notify(const char* title, const char* body) {
    if (!body || body[0] == '\0') return;

    NSString* nsTitle = title && title[0]
        ? [NSString stringWithUTF8String:title]
        : @"Attyx";
    NSString* nsBody = [NSString stringWithUTF8String:body];

    // Only notify when the app is not focused (avoid spamming the user)
    if ([NSApp isActive]) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        UNUserNotificationCenter* center = [UNUserNotificationCenter currentNotificationCenter];

        // Request permission on first use (no-op if already granted/denied)
        [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                              completionHandler:^(BOOL granted, NSError* _Nullable error) {
            (void)error;
            if (!granted) return;

            UNMutableNotificationContent* content = [[UNMutableNotificationContent alloc] init];
            content.title = nsTitle;
            content.body = nsBody;
            content.sound = [UNNotificationSound defaultSound];

            NSString* identifier = [[NSUUID UUID] UUIDString];
            UNNotificationRequest* request =
                [UNNotificationRequest requestWithIdentifier:identifier
                                                     content:content
                                                     trigger:nil]; // deliver immediately

            [center addNotificationRequest:request withCompletionHandler:^(NSError* _Nullable err) {
                if (err) {
                    ATTYX_LOG_WARN("notify", "notification failed: %s",
                                   err.localizedDescription.UTF8String);
                }
            }];
        }];
    });
}

// ---------------------------------------------------------------------------
// Spawn new window (new instance via NSWorkspace)
// ---------------------------------------------------------------------------

void attyx_spawn_new_window(void) {
    NSURL* bundleURL = [[NSBundle mainBundle] bundleURL];
    // If running from a .app bundle, use NSWorkspace to launch a new instance
    // grouped under the same app identity (same dock icon, Cmd+` switching).
    if ([[bundleURL pathExtension] isEqualToString:@"app"]) {
        NSWorkspaceOpenConfiguration* config = [NSWorkspaceOpenConfiguration configuration];
        config.createsNewApplicationInstance = YES;
        [[NSWorkspace sharedWorkspace] openApplicationAtURL:bundleURL
                                              configuration:config
                                          completionHandler:nil];
    } else {
        // Fallback for running the raw binary outside a bundle (dev builds).
        NSString* path = NSProcessInfo.processInfo.arguments[0];
        const char* cpath = [path fileSystemRepresentation];
        pid_t pid = fork();
        if (pid == 0) {
            char* argv[] = { (char*)cpath, NULL };
            execv(cpath, argv);
            _exit(1);
        }
    }
}

// ---------------------------------------------------------------------------
// App Delegate
// ---------------------------------------------------------------------------

@interface AttyxAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (nonatomic, strong) NSWindow* window;
@property (nonatomic, strong) AttyxRenderer* renderer;
@property (nonatomic, strong) AttyxNativeTabManager* nativeTabMgr;
@end

@implementation AttyxAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    // Disable accent picker so holding a key sends repeats instead
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"ApplePressAndHoldEnabled"];

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        NSLog(@"Metal is not supported on this machine");
        [NSApp terminate:nil];
        return;
    }

    CGFloat scaleFactor = [NSScreen mainScreen].backingScaleFactor;
    GlyphCache gc = createGlyphCache(device, scaleFactor);

    g_cell_pt_w = gc.glyph_w / gc.scale;
    g_cell_pt_h = gc.glyph_h / gc.scale;
    g_cell_w_pts = (float)g_cell_pt_w;
    g_cell_h_pts = (float)g_cell_pt_h;

    CGFloat winW = g_cols * g_cell_pt_w + g_padding_left + g_padding_right;
    CGFloat winH = g_rows * g_cell_pt_h + g_padding_top  + g_padding_bottom;

    NSRect frame = NSMakeRect(200, 200, winW, winH);
    NSUInteger mask = NSWindowStyleMaskTitled
                    | NSWindowStyleMaskClosable
                    | NSWindowStyleMaskMiniaturizable
                    | NSWindowStyleMaskResizable;
    if (!g_window_decorations) {
        mask |= NSWindowStyleMaskFullSizeContentView;
    }

    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:mask
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    [_window setTitle:@"Attyx"];
    [_window setDelegate:self];
    [_window setAcceptsMouseMovedEvents:YES];

    if (!g_window_decorations) {
        [_window setTitlebarAppearsTransparent:YES];
        [_window setTitleVisibility:NSWindowTitleHidden];
        [[_window standardWindowButton:NSWindowCloseButton] setHidden:YES];
        [[_window standardWindowButton:NSWindowMiniaturizeButton] setHidden:YES];
        [[_window standardWindowButton:NSWindowZoomButton] setHidden:YES];
    }

    AttyxView* termView = [[AttyxView alloc] initWithFrame:frame device:device];
    termView.layer.contentsScale = scaleFactor;
    termView.layerContentsPlacement = NSViewLayerContentsPlacementTopLeft;
    CAMetalLayer* metalLayer = (CAMetalLayer*)termView.layer;
    metalLayer.presentsWithTransaction = YES;
    metalLayer.maximumDrawableCount = 2;
    float _opac = g_background_opacity;
    if (_opac >= 1.0f) {
        termView.clearColor = MTLClearColorMake(0.118, 0.118, 0.141, 1.0);
    } else {
        termView.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
    }
    termView.preferredFramesPerSecond = 60;

    _renderer = [[AttyxRenderer alloc] initWithDevice:device
                                                 view:termView
                                           glyphCache:gc];
    termView.delegate = _renderer;

    BOOL transparent = (g_background_opacity < 1.0f);
    BOOL blurEnabled = transparent && (g_background_blur > 0);

    if (transparent) {
        [_window setOpaque:NO];
        [_window setBackgroundColor:[NSColor clearColor]];
        ((CAMetalLayer*)termView.layer).opaque = NO;
    }

    if (blurEnabled) {
        NSVisualEffectView* blurView = [[NSVisualEffectView alloc] initWithFrame:frame];
        blurView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        blurView.material     = NSVisualEffectMaterialDark;
        blurView.state        = NSVisualEffectStateActive;
        blurView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        termView.frame = blurView.bounds;  // origin must be (0,0) in parent coords
        termView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [blurView addSubview:termView];
        [_window setContentView:blurView];
        [_window makeFirstResponder:termView];
    } else {
        [_window setContentView:termView];
        [_window makeFirstResponder:termView];
    }
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    if (g_icon_png_len > 0) {
        NSData* iconData = [NSData dataWithBytesNoCopy:(void*)g_icon_png
                                               length:(NSUInteger)g_icon_png_len
                                         freeWhenDone:NO];
        NSImage* raw = [[NSImage alloc] initWithData:iconData];
        if (raw) {
            // macOS icon convention: ~10% padding on each side so the icon
            // content doesn't appear oversized relative to other dock icons.
            const CGFloat canvas  = 512.0;
            const CGFloat padding = canvas * 0.10;
            const CGFloat inner   = canvas - padding * 2.0;
            NSImage* icon = [[NSImage alloc] initWithSize:NSMakeSize(canvas, canvas)];
            [icon lockFocus];
            [raw drawInRect:NSMakeRect(padding, padding, inner, inner)
                   fromRect:NSZeroRect
                  operation:NSCompositingOperationSourceOver
                   fraction:1.0];
            [icon unlockFocus];
            [NSApp setApplicationIconImage:icon];
        }
    }

    // Native macOS tabs: titlebar accessory (no extra windows).
    if (g_native_tabs_enabled) {
        _nativeTabMgr = [[AttyxNativeTabManager alloc] initWithWindow:_window];
        // Tab bar lives in the titlebar — needs visible title bar.
        if (!g_window_decorations) {
            NSUInteger wmask = [_window styleMask];
            wmask &= ~NSWindowStyleMaskFullSizeContentView;
            [_window setStyleMask:wmask];
            [_window setTitlebarAppearsTransparent:NO];
            [_window setTitleVisibility:NSWindowTitleVisible];
            [[_window standardWindowButton:NSWindowCloseButton] setHidden:NO];
            [[_window standardWindowButton:NSWindowMiniaturizeButton] setHidden:NO];
            [[_window standardWindowButton:NSWindowZoomButton] setHidden:NO];
        }
    }

    // Auto-updater (skipped for Homebrew installs)
    attyx_updater_init();
}

- (NSSize)windowWillResize:(NSWindow*)sender toSize:(NSSize)frameSize {
    (void)sender;
    return frameSize;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    return YES;
}

- (void)applicationWillTerminate:(NSNotification*)notification {
    g_should_quit = 1;
}

- (void)reloadConfig:(id)sender {
    (void)sender;
    attyx_trigger_config_reload();
}

- (void)spawnNewWindow:(id)sender {
    (void)sender;
    attyx_spawn_new_window();
}

- (void)checkForUpdates:(id)sender {
    (void)sender;
    attyx_updater_check();
}

- (void)showAbout:(id)sender {
    (void)sender;
    NSString* version = @"unknown";
    if (g_app_version_len > 0) {
        version = [[NSString alloc] initWithBytes:(const void*)g_app_version
                                           length:(NSUInteger)g_app_version_len
                                         encoding:NSUTF8StringEncoding];
    }
    NSMutableDictionary* opts = [NSMutableDictionary dictionary];
    opts[@"ApplicationVersion"] = version;
    opts[@"Version"] = @"";
    if (g_icon_png_len > 0) {
        NSData* iconData = [NSData dataWithBytesNoCopy:(void*)g_icon_png
                                                length:(NSUInteger)g_icon_png_len
                                          freeWhenDone:NO];
        NSImage* icon = [[NSImage alloc] initWithData:iconData];
        if (icon) opts[@"ApplicationIcon"] = icon;
    }
    [NSApp orderFrontStandardAboutPanelWithOptions:opts];
}

- (void)closeTabOrWindow:(id)sender {
    (void)sender;
    attyx_dispatch_action(50);
}

// Generic action dispatch from menu items (action ID stored in tag)
- (void)dispatchMenuAction:(NSMenuItem*)sender {
    attyx_dispatch_action((uint8_t)sender.tag);
}

- (BOOL)validateMenuItem:(NSMenuItem*)item {
    if ([item action] == @selector(checkForUpdates:)) {
        return attyx_updater_available();
    }
    return YES;
}

@end

// ---------------------------------------------------------------------------
// Hot-reload: apply window property changes (opacity, blur, decorations, padding)
// Called from render thread when g_needs_window_update is set.
// ---------------------------------------------------------------------------

void attyx_apply_window_update(void) {
    AttyxAppDelegate* del = (AttyxAppDelegate*)[NSApp delegate];
    NSWindow* window = del.window;
    AttyxRenderer* renderer = del.renderer;
    if (!window || !renderer) return;

    // Find the MTKView (termView) — either direct contentView or subview of blur view
    MTKView* termView = nil;
    NSView* content = [window contentView];
    if ([content isKindOfClass:[MTKView class]]) {
        termView = (MTKView*)content;
    } else {
        // Content is blur view; termView is its first MTKView subview
        for (NSView* sub in [content subviews]) {
            if ([sub isKindOfClass:[MTKView class]]) {
                termView = (MTKView*)sub;
                break;
            }
        }
    }
    if (!termView) return;

    static BOOL was_transparent = NO;
    static BOOL had_blur = NO;
    static BOOL had_decorations = YES;
    static BOOL first_call = YES;

    if (first_call) {
        was_transparent = (g_background_opacity < 1.0f);
        had_blur = was_transparent && (g_background_blur > 0);
        had_decorations = (g_window_decorations != 0);
        first_call = NO;
    }

    BOOL now_transparent = (g_background_opacity < 1.0f);
    BOOL now_blur = now_transparent && (g_background_blur > 0);
    BOOL now_decorations = (g_window_decorations != 0);

    // --- Opacity ---
    if (now_transparent != was_transparent) {
        if (now_transparent) {
            [window setOpaque:NO];
            [window setBackgroundColor:[NSColor clearColor]];
            ((CAMetalLayer*)termView.layer).opaque = NO;
            termView.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
        } else {
            [window setOpaque:YES];
            [window setBackgroundColor:[NSColor windowBackgroundColor]];
            ((CAMetalLayer*)termView.layer).opaque = YES;
            termView.clearColor = MTLClearColorMake(0.118, 0.118, 0.141, 1.0);
        }
        // Force the window server to rebuild the backing store for the new opacity state.
        // invalidateShadow alone isn't enough — toggling hasShadow forces a full
        // teardown and rebuild of the compositing surface.
        BOOL shadow = [window hasShadow];
        [window setHasShadow:NO];
        [window setHasShadow:shadow];
        was_transparent = now_transparent;
    }

    // --- Blur ---
    if (now_blur != had_blur) {
        if (now_blur) {
            NSVisualEffectView* blurView = [[NSVisualEffectView alloc]
                initWithFrame:[window.contentView bounds]];
            blurView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
            blurView.material     = NSVisualEffectMaterialDark;
            blurView.state        = NSVisualEffectStateActive;
            blurView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

            [termView removeFromSuperview];
            termView.frame = blurView.bounds;
            termView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [blurView addSubview:termView];
            [window setContentView:blurView];
            [window makeFirstResponder:termView];
        } else {
            [termView removeFromSuperview];
            termView.frame = [window.contentView bounds];
            [window setContentView:termView];
            [window makeFirstResponder:termView];
        }
        had_blur = now_blur;
    }

    // --- Decorations ---
    // Native tabs require a visible title bar; skip decoration changes.
    if (now_decorations != had_decorations && !g_native_tabs_enabled) {
        NSUInteger mask = [window styleMask];
        if (!now_decorations) {
            mask |= NSWindowStyleMaskFullSizeContentView;
            [window setStyleMask:mask];
            [window setTitlebarAppearsTransparent:YES];
            [window setTitleVisibility:NSWindowTitleHidden];
            [[window standardWindowButton:NSWindowCloseButton] setHidden:YES];
            [[window standardWindowButton:NSWindowMiniaturizeButton] setHidden:YES];
            [[window standardWindowButton:NSWindowZoomButton] setHidden:YES];
        } else {
            mask &= ~NSWindowStyleMaskFullSizeContentView;
            [window setStyleMask:mask];
            [window setTitlebarAppearsTransparent:NO];
            [window setTitleVisibility:NSWindowTitleVisible];
            [[window standardWindowButton:NSWindowCloseButton] setHidden:NO];
            [[window standardWindowButton:NSWindowMiniaturizeButton] setHidden:NO];
            [[window standardWindowButton:NSWindowZoomButton] setHidden:NO];
        }
        // setStyleMask: can reset the displayed title — re-apply from bridge.
        int tlen = g_title_len;
        if (tlen > 0 && tlen < ATTYX_TITLE_MAX) {
            NSString* title = [[NSString alloc] initWithBytes:g_title_buf
                                                       length:tlen
                                                     encoding:NSUTF8StringEncoding];
            if (title) [window setTitle:title];
        }
        had_decorations = now_decorations;
    }

    // --- Padding (always trigger resize recalculation) ---
    [renderer mtkView:termView drawableSizeWillChange:termView.drawableSize];
}

// ---------------------------------------------------------------------------
// C entry point called from Zig
// ---------------------------------------------------------------------------

void attyx_run(AttyxCell* cells, int cols, int rows) {
    g_cells = cells;
    g_cols  = cols;
    g_rows  = rows;

    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        // Delegate is created first so it can be set as the menu item target.
        AttyxAppDelegate* delegate = [[AttyxAppDelegate alloc] init];
        [app setDelegate:delegate];

        NSMenu* menuBar = [[NSMenu alloc] init];
        NSMenuItem* appMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:appMenuItem];
        NSMenu* appMenu = [[NSMenu alloc] initWithTitle:@"Attyx"];
        NSMenuItem* aboutItem = [[NSMenuItem alloc] initWithTitle:@"About Attyx"
                                                          action:@selector(showAbout:)
                                                   keyEquivalent:@""];
        [aboutItem setTarget:delegate];
        [appMenu addItem:aboutItem];
        [appMenu addItem:[NSMenuItem separatorItem]];
        NSMenuItem* reloadItem = [[NSMenuItem alloc] initWithTitle:@"Reload Config"
                                                            action:@selector(reloadConfig:)
                                                     keyEquivalent:@""];
        [reloadItem setTarget:delegate];
        [appMenu addItem:reloadItem];

        NSMenuItem* updateItem = [[NSMenuItem alloc] initWithTitle:@"Check for Updates..."
                                                            action:@selector(checkForUpdates:)
                                                     keyEquivalent:@""];
        [updateItem setTarget:delegate];
        [appMenu addItem:updateItem];

        [appMenu addItem:[NSMenuItem separatorItem]];
        [appMenu addItemWithTitle:@"Quit Attyx"
                           action:@selector(terminate:)
                    keyEquivalent:@"q"];
        [appMenuItem setSubmenu:appMenu];

        // Helper to create a menu item that dispatches a keybind action by tag
        NSMenuItem* (^actionItem)(NSString*, uint8_t, NSString*, NSEventModifierFlags) =
            ^NSMenuItem*(NSString* title, uint8_t actionId, NSString* key, NSEventModifierFlags mods) {
                NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title
                                                              action:@selector(dispatchMenuAction:)
                                                       keyEquivalent:key];
                item.tag = actionId;
                item.target = delegate;
                item.keyEquivalentModifierMask = mods;
                return item;
            };

        // -- Edit menu --
        NSMenuItem* editMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:editMenuItem];
        NSMenu* editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
        [editMenu addItemWithTitle:@"Copy"   action:@selector(copy:)  keyEquivalent:@"c"];
        [editMenu addItemWithTitle:@"Paste"  action:@selector(paste:) keyEquivalent:@"v"];
        [editMenu addItem:[NSMenuItem separatorItem]];
        [editMenu addItem:actionItem(@"Find…", 3, @"f", NSEventModifierFlagCommand)];
        [editMenu addItem:actionItem(@"Find Next", 4, @"g", NSEventModifierFlagCommand)];
        [editMenu addItem:actionItem(@"Find Previous", 5, @"g",
            NSEventModifierFlagCommand | NSEventModifierFlagShift)];
        [editMenu addItem:[NSMenuItem separatorItem]];
        [editMenu addItem:actionItem(@"Clear Screen", 73, @"k", NSEventModifierFlagCommand)];
        [editMenuItem setSubmenu:editMenu];

        // -- View menu --
        NSMenuItem* viewMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:viewMenuItem];
        NSMenu* viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
        [viewMenu addItem:actionItem(@"Bigger", 85, @"=", NSEventModifierFlagCommand)];
        [viewMenu addItem:actionItem(@"Smaller", 86, @"-", NSEventModifierFlagCommand)];
        [viewMenu addItem:actionItem(@"Reset Font Size", 87, @"0", NSEventModifierFlagCommand)];
        [viewMenu addItem:[NSMenuItem separatorItem]];
        [viewMenu addItem:actionItem(@"Command Palette", 77, @"p",
            NSEventModifierFlagCommand | NSEventModifierFlagShift)];
        [viewMenuItem setSubmenu:viewMenu];

        // -- Shell menu --
        NSMenuItem* shellMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:shellMenuItem];
        NSMenu* shellMenu = [[NSMenu alloc] initWithTitle:@"Shell"];
        [shellMenu addItem:actionItem(@"New Tab", 49, @"t", NSEventModifierFlagCommand)];
        [shellMenu addItem:actionItem(@"Close Tab", 50, @"w", NSEventModifierFlagCommand)];
        [shellMenu addItem:[NSMenuItem separatorItem]];
        [shellMenu addItem:actionItem(@"Next Tab", 51, @"\t",
            NSEventModifierFlagControl)];
        [shellMenu addItem:actionItem(@"Previous Tab", 52, @"\t",
            NSEventModifierFlagControl | NSEventModifierFlagShift)];
        [shellMenu addItem:[NSMenuItem separatorItem]];
        [shellMenu addItem:actionItem(@"Split Vertically", 53, @"d", NSEventModifierFlagCommand)];
        [shellMenu addItem:actionItem(@"Split Horizontally", 54, @"d",
            NSEventModifierFlagCommand | NSEventModifierFlagShift)];
        [shellMenuItem setSubmenu:shellMenu];

        // -- Window menu --
        NSMenuItem* windowMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:windowMenuItem];
        NSMenu* windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
        [windowMenu addItemWithTitle:@"New Window"
                              action:@selector(spawnNewWindow:)
                       keyEquivalent:@"n"];
        [windowMenu addItem:[NSMenuItem separatorItem]];
        [windowMenu addItemWithTitle:@"Minimize Window"
                              action:@selector(performMiniaturize:)
                       keyEquivalent:@"m"];
        [windowMenu addItemWithTitle:@"Zoom"
                              action:@selector(performZoom:)
                       keyEquivalent:@""];
        [windowMenuItem setSubmenu:windowMenu];
        [app setWindowsMenu:windowMenu];

        [app setMainMenu:menuBar];
        [app run];
    }
}
