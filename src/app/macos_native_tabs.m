// Attyx — Native macOS tab manager
// Uses NSWindow tab grouping (addTabbedWindow:ordered:) for native tab bar.

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#include "bridge.h"
#include "macos_internal.h"

// ---------------------------------------------------------------------------
// C-owned globals (declared extern in bridge.h)
// ---------------------------------------------------------------------------

char g_native_tab_titles[16][ATTYX_NATIVE_TAB_TITLE_MAX];
volatile int g_native_tab_click = -1;

// Interface declared in macos_internal.h

@implementation AttyxNativeTabManager

- (instancetype)initWithDevice:(id<MTLDevice>)device
                      renderer:(AttyxRenderer*)renderer
                    glyphCache:(GlyphCache)gc {
    self = [super init];
    if (self) {
        _tabWindows = [NSMutableArray array];
        _pendingClose = [NSMutableSet set];
        _device = device;
        _sharedRenderer = renderer;
        _glyphCache = gc;
        // Per-PID tabbing identifier prevents cross-process tab merging
        _tabbingId = [NSString stringWithFormat:@"com.attyx.tabs.%d", getpid()];
    }
    return self;
}

- (NSWindow*)createTabWindowWithSize:(NSSize)size {
    NSRect frame = NSMakeRect(200, 200, size.width, size.height);
    NSUInteger mask = NSWindowStyleMaskTitled
                    | NSWindowStyleMaskClosable
                    | NSWindowStyleMaskMiniaturizable
                    | NSWindowStyleMaskResizable;

    NSWindow* win = [[NSWindow alloc] initWithContentRect:frame
                                                styleMask:mask
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    [win setTitle:@"Attyx"];
    [win setDelegate:self];
    [win setAcceptsMouseMovedEvents:YES];
    [win setTabbingIdentifier:_tabbingId];

    if (g_tab_always_show) {
        [win setTabbingMode:NSWindowTabbingModePreferred];
    } else {
        [win setTabbingMode:NSWindowTabbingModeAutomatic];
    }

    CGFloat scaleFactor = [NSScreen mainScreen].backingScaleFactor;

    // Create an MTKView sharing the same Metal device
    AttyxView* termView = [[AttyxView alloc] initWithFrame:frame device:_device];
    termView.layer.contentsScale = scaleFactor;
    termView.layerContentsPlacement = NSViewLayerContentsPlacementTopLeft;
    ((CAMetalLayer*)termView.layer).presentsWithTransaction = YES;
    termView.preferredFramesPerSecond = 60;

    float _opac = g_background_opacity;
    if (_opac >= 1.0f) {
        termView.clearColor = MTLClearColorMake(0.118, 0.118, 0.141, 1.0);
    } else {
        termView.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
    }

    // The shared renderer is only the delegate for the active tab's MTKView.
    // Inactive tab views are paused. We set delegate for the first window only;
    // sync will manage delegate assignment on tab switch.

    BOOL transparent = (g_background_opacity < 1.0f);
    BOOL blurEnabled = transparent && (g_background_blur > 0);

    if (transparent) {
        [win setOpaque:NO];
        [win setBackgroundColor:[NSColor clearColor]];
        ((CAMetalLayer*)termView.layer).opaque = NO;
    }

    if (blurEnabled) {
        NSVisualEffectView* blurView = [[NSVisualEffectView alloc] initWithFrame:frame];
        blurView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        blurView.material     = NSVisualEffectMaterialUnderWindowBackground;
        blurView.state        = NSVisualEffectStateActive;
        blurView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        termView.frame = blurView.bounds;
        termView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [blurView addSubview:termView];
        [win setContentView:blurView];
        [win makeFirstResponder:termView];
    } else {
        [win setContentView:termView];
        [win makeFirstResponder:termView];
    }

    [_tabWindows addObject:win];
    return win;
}

/// Find the MTKView inside a window (either direct contentView or subview of blur view).
- (MTKView*)findTermViewInWindow:(NSWindow*)win {
    NSView* content = [win contentView];
    if ([content isKindOfClass:[MTKView class]]) {
        return (MTKView*)content;
    }
    for (NSView* sub in [content subviews]) {
        if ([sub isKindOfClass:[MTKView class]]) {
            return (MTKView*)sub;
        }
    }
    return nil;
}

/// Poll-based sync: called from drawFrameImpl at 60fps.
/// Processes tab operations and title updates.
- (void)sync {
    // Process pending tab operation
    int op = __sync_lock_test_and_set((volatile int*)&g_native_tab_op, 0);
    if (op != 0) {
        switch (op) {
            case 1: // new tab
                [self handleNewTab];
                break;
            case 2: // close tab
                [self handleCloseTab];
                break;
            case 3: // switch tab
                [self handleSwitchTab];
                break;
            default:
                break;
        }
    }

    // Update titles if changed
    if (__sync_lock_test_and_set((volatile int*)&g_native_tab_titles_changed, 0)) {
        [self updateTitles];
    }

    // Update tabbingMode based on always_show
    if (_tabWindows.count > 0) {
        NSWindowTabbingMode mode = g_tab_always_show
            ? NSWindowTabbingModePreferred
            : NSWindowTabbingModeAutomatic;
        for (NSWindow* w in _tabWindows) {
            if ([w tabbingMode] != mode) {
                [w setTabbingMode:mode];
            }
        }
    }
}

- (void)handleNewTab {
    if (_tabWindows.count == 0) return;
    NSWindow* primary = _tabWindows[0];
    NSSize size = [[primary contentView] frame].size;
    NSWindow* newWin = [self createTabWindowWithSize:size];

    // Set the renderer delegate on the new window's MTKView
    MTKView* newView = [self findTermViewInWindow:newWin];
    if (newView) {
        newView.delegate = _sharedRenderer;
        // Pause all other tab views
        for (NSWindow* w in _tabWindows) {
            if (w == newWin) continue;
            MTKView* v = [self findTermViewInWindow:w];
            if (v) {
                v.delegate = nil;
                v.paused = YES;
            }
        }
        newView.paused = NO;
    }

    [primary addTabbedWindow:newWin ordered:NSWindowAbove];
    [newWin makeKeyAndOrderFront:nil];

    ATTYX_LOG_INFO("native_tabs", "created tab window %d", (int)_tabWindows.count);
}

- (void)handleCloseTab {
    int target = g_native_tab_target;
    if (target < 0 || target >= (int)_tabWindows.count) return;

    NSWindow* win = _tabWindows[target];

    // Mark as approved for close. When performClose: triggers
    // windowShouldClose:, we'll return YES for this window.
    [_pendingClose addObject:win];

    // Schedule performClose: on the next run loop iteration.
    // We are inside drawFrameImpl: (the MTKView delegate callback);
    // closing a window here would corrupt the autorelease pool.
    // performClose: goes through AppKit's normal window lifecycle:
    //   performClose: → windowShouldClose: (YES) → windowWillClose: → dealloc
    // This lets AppKit manage the tab group teardown correctly.
    dispatch_async(dispatch_get_main_queue(), ^{
        [win performClose:nil];
    });

    ATTYX_LOG_INFO("native_tabs", "scheduled close for tab %d", target);
}

- (void)handleSwitchTab {
    int target = g_native_tab_active;
    if (target < 0 || target >= (int)_tabWindows.count) return;
    [self activateWindowAtIndex:target];
}

- (void)activateWindowAtIndex:(int)index {
    // Pause all views, activate the target
    for (int i = 0; i < (int)_tabWindows.count; i++) {
        MTKView* v = [self findTermViewInWindow:_tabWindows[i]];
        if (!v) continue;
        if (i == index) {
            v.delegate = _sharedRenderer;
            v.paused = NO;
        } else {
            v.delegate = nil;
            v.paused = YES;
        }
    }
    [_tabWindows[index] makeKeyAndOrderFront:nil];
}

- (void)updateTitles {
    int count = g_native_tab_count;
    if (count > 16) count = 16;
    for (int i = 0; i < count && i < (int)_tabWindows.count; i++) {
        NSString* title = [NSString stringWithUTF8String:g_native_tab_titles[i]];
        if (title) {
            [_tabWindows[i] setTitle:title];
        }
    }
}

// ---------------------------------------------------------------------------
// NSWindowDelegate
// ---------------------------------------------------------------------------

- (void)windowDidBecomeKey:(NSNotification*)notification {
    NSWindow* win = [notification object];
    NSUInteger idx = [_tabWindows indexOfObject:win];
    if (idx == NSNotFound) return;

    // Signal to PTY thread that user clicked this native tab
    g_native_tab_click = (int)idx;

    // Switch renderer to this window's MTKView
    [self activateWindowAtIndex:(int)idx];
}

- (BOOL)windowShouldClose:(NSWindow*)sender {
    NSUInteger idx = [_tabWindows indexOfObject:sender];
    if (idx == NSNotFound) return YES;

    // If this is the last tab, quit the app
    if (_tabWindows.count <= 1) {
        attyx_request_quit();
        return YES;
    }

    // PTY thread has approved this close (via handleCloseTab → pendingClose).
    // Allow AppKit to close the window through its normal lifecycle.
    if ([_pendingClose containsObject:sender]) {
        [_pendingClose removeObject:sender];
        return YES;
    }

    // User-initiated close (Cmd+W, click): signal PTY thread to clean up.
    // PTY thread will process the close, then signal back via g_native_tab_op=2,
    // which triggers handleCloseTab → pendingClose → performClose:.
    g_native_tab_click = (int)idx;
    attyx_tab_action(ATTYX_ACTION_TAB_CLOSE);
    return NO;
}

/// Called by AppKit after the window is approved for close.
/// Disconnect the MTKView and remove from our tracking array.
- (void)windowWillClose:(NSNotification*)notification {
    NSWindow* win = [notification object];
    NSUInteger idx = [_tabWindows indexOfObject:win];
    if (idx == NSNotFound) return;

    // Disconnect the MTKView from the shared renderer
    MTKView* v = [self findTermViewInWindow:win];
    if (v) {
        v.delegate = nil;
        v.paused = YES;
    }

    [_tabWindows removeObjectAtIndex:idx];

    ATTYX_LOG_INFO("native_tabs", "window %d closed, now %d windows",
                   (int)idx, (int)_tabWindows.count);
}

@end
