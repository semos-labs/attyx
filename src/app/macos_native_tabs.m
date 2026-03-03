// Attyx — Custom-drawn native-style macOS tab bar
//
// Renders a tab bar in NSTitlebarAccessoryViewController that visually matches
// macOS native window tabs: pill-shaped tabs, close button on hover, "+" button.
// NO additional NSWindows. All tab state lives in the internal TabManager.

#import <Cocoa/Cocoa.h>
#include "bridge.h"
#include "macos_internal.h"

// Globals are Zig-owned (terminal.zig) — declared extern in bridge.h.

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

static const CGFloat kTabBarHeight = 30.0;
static const CGFloat kTabHeight    = 24.0;
static const CGFloat kTabMinWidth  = 80.0;
static const CGFloat kTabMaxWidth  = 180.0;
static const CGFloat kTabSpacing   = 2.0;
static const CGFloat kTabRadius    = 6.0;
static const CGFloat kTabPadH      = 10.0;  // horizontal padding inside tab
static const CGFloat kCloseSize    = 14.0;
static const CGFloat kBarPadLeft   = 8.0;
static const CGFloat kBarPadRight  = 8.0;
static const CGFloat kPlusWidth    = 28.0;

// ---------------------------------------------------------------------------
// AttyxTabBarView — custom-drawn tab bar
// ---------------------------------------------------------------------------

@interface AttyxTabBarView : NSView
@property (nonatomic) int tabCount;
@property (nonatomic) int activeTab;
@property (nonatomic, strong) NSMutableArray<NSString*>* titles;
@property (nonatomic) int hoveredTab;
@property (nonatomic) BOOL hoverOnClose;
@property (nonatomic, weak) id tabTarget;
@property (nonatomic) SEL tabClickAction;
@property (nonatomic) SEL closeAction;
@property (nonatomic) SEL newTabAction;
@end

@implementation AttyxTabBarView {
    NSTrackingArea* _trackingArea;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _tabCount = 1;
        _activeTab = 0;
        _hoveredTab = -1;
        _titles = [NSMutableArray array];
    }
    return self;
}

- (BOOL)isFlipped { return NO; }

// --- Layout ---

- (CGFloat)tabWidthForCount:(int)count {
    CGFloat available = self.bounds.size.width - kBarPadLeft - kBarPadRight - kPlusWidth;
    CGFloat w = (available - (count - 1) * kTabSpacing) / count;
    return MIN(kTabMaxWidth, MAX(kTabMinWidth, w));
}

- (NSRect)tabRectForIndex:(int)i {
    CGFloat w = [self tabWidthForCount:_tabCount];
    CGFloat x = kBarPadLeft + i * (w + kTabSpacing);
    CGFloat y = (self.bounds.size.height - kTabHeight) / 2.0;
    return NSMakeRect(x, y, w, kTabHeight);
}

- (NSRect)closeRectForTab:(NSRect)r {
    CGFloat cx = r.origin.x + 8;
    CGFloat cy = r.origin.y + (r.size.height - kCloseSize) / 2.0;
    return NSMakeRect(cx, cy, kCloseSize, kCloseSize);
}

- (NSRect)plusRect {
    CGFloat w = [self tabWidthForCount:_tabCount];
    CGFloat x = kBarPadLeft + _tabCount * (w + kTabSpacing) + 4;
    CGFloat y = (self.bounds.size.height - kTabHeight) / 2.0;
    return NSMakeRect(x, y, kPlusWidth, kTabHeight);
}

// --- Drawing ---

- (BOOL)isDarkMode {
    if (@available(macOS 10.14, *)) {
        NSAppearanceName name = [self.effectiveAppearance
            bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
        return [name isEqualToString:NSAppearanceNameDarkAqua];
    }
    return NO;
}

- (void)drawRect:(NSRect)dirtyRect {
    BOOL dark = [self isDarkMode];

    for (int i = 0; i < _tabCount; i++) {
        NSRect r = [self tabRectForIndex:i];
        BOOL active = (i == _activeTab);
        BOOL hovered = (i == _hoveredTab);

        // Tab background
        NSColor* bg;
        if (active) {
            bg = dark ? [NSColor colorWithWhite:0.28 alpha:1.0]
                      : [NSColor colorWithWhite:0.90 alpha:1.0];
        } else if (hovered) {
            bg = dark ? [NSColor colorWithWhite:0.22 alpha:1.0]
                      : [NSColor colorWithWhite:0.82 alpha:1.0];
        } else {
            bg = dark ? [NSColor colorWithWhite:0.18 alpha:1.0]
                      : [NSColor colorWithWhite:0.77 alpha:1.0];
        }

        NSBezierPath* pill = [NSBezierPath bezierPathWithRoundedRect:r
                                                             xRadius:kTabRadius
                                                             yRadius:kTabRadius];
        [bg setFill];
        [pill fill];

        // Close button (only when hovered on this tab and count > 1)
        CGFloat textLeft = kTabPadH;
        if (hovered && _tabCount > 1) {
            NSRect cr = [self closeRectForTab:r];
            textLeft = kTabPadH + kCloseSize + 4;

            if (_hoverOnClose) {
                NSColor* closeBg = dark ? [NSColor colorWithWhite:0.45 alpha:0.5]
                                        : [NSColor colorWithWhite:0.55 alpha:0.4];
                NSBezierPath* circle = [NSBezierPath bezierPathWithOvalInRect:cr];
                [closeBg setFill];
                [circle fill];
            }

            // Draw X
            NSColor* xColor = dark ? [NSColor colorWithWhite:0.8 alpha:1.0]
                                   : [NSColor colorWithWhite:0.3 alpha:1.0];
            [xColor setStroke];
            CGFloat inset = 4.0;
            NSBezierPath* xPath = [NSBezierPath bezierPath];
            [xPath setLineWidth:1.2];
            [xPath moveToPoint:NSMakePoint(cr.origin.x + inset, cr.origin.y + inset)];
            [xPath lineToPoint:NSMakePoint(NSMaxX(cr) - inset, NSMaxY(cr) - inset)];
            [xPath moveToPoint:NSMakePoint(NSMaxX(cr) - inset, cr.origin.y + inset)];
            [xPath lineToPoint:NSMakePoint(cr.origin.x + inset, NSMaxY(cr) - inset)];
            [xPath stroke];
        }

        // Tab title
        NSString* title = (i < (int)_titles.count) ? _titles[i] : @"Tab";
        NSColor* textColor;
        if (active) {
            textColor = dark ? [NSColor colorWithWhite:0.95 alpha:1.0]
                             : [NSColor colorWithWhite:0.1 alpha:1.0];
        } else {
            textColor = dark ? [NSColor colorWithWhite:0.55 alpha:1.0]
                             : [NSColor colorWithWhite:0.35 alpha:1.0];
        }

        NSDictionary* attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:12.0 weight:active ? NSFontWeightMedium : NSFontWeightRegular],
            NSForegroundColorAttributeName: textColor,
        };
        NSSize textSize = [title sizeWithAttributes:attrs];
        CGFloat textMaxW = r.size.width - textLeft - kTabPadH;
        CGFloat tx = r.origin.x + textLeft + (textMaxW - MIN(textSize.width, textMaxW)) / 2.0;
        CGFloat ty = r.origin.y + (r.size.height - textSize.height) / 2.0;
        NSRect textRect = NSMakeRect(tx, ty, MIN(textSize.width, textMaxW), textSize.height);
        [title drawInRect:textRect withAttributes:attrs];
    }

    // "+" button
    {
        NSRect pr = [self plusRect];
        BOOL plusHovered = (_hoveredTab == _tabCount);
        NSColor* pbg = plusHovered
            ? (dark ? [NSColor colorWithWhite:0.25 alpha:1.0] : [NSColor colorWithWhite:0.82 alpha:1.0])
            : [NSColor clearColor];
        NSBezierPath* pp = [NSBezierPath bezierPathWithRoundedRect:pr xRadius:kTabRadius yRadius:kTabRadius];
        [pbg setFill];
        [pp fill];

        NSColor* plusColor = dark ? [NSColor colorWithWhite:0.6 alpha:1.0]
                                  : [NSColor colorWithWhite:0.4 alpha:1.0];
        NSDictionary* pa = @{
            NSFontAttributeName: [NSFont systemFontOfSize:16.0 weight:NSFontWeightLight],
            NSForegroundColorAttributeName: plusColor,
        };
        NSSize ps = [@"+" sizeWithAttributes:pa];
        CGFloat px = pr.origin.x + (pr.size.width - ps.width) / 2.0;
        CGFloat py = pr.origin.y + (pr.size.height - ps.height) / 2.0;
        [@"+" drawAtPoint:NSMakePoint(px, py) withAttributes:pa];
    }
}

// --- Mouse tracking ---

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea) [self removeTrackingArea:_trackingArea];
    _trackingArea = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow
               owner:self
            userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (int)tabIndexAtPoint:(NSPoint)p closeHit:(BOOL*)isClose {
    if (isClose) *isClose = NO;
    for (int i = 0; i < _tabCount; i++) {
        NSRect r = [self tabRectForIndex:i];
        if (NSPointInRect(p, r)) {
            if (isClose && _tabCount > 1) {
                NSRect cr = [self closeRectForTab:r];
                *isClose = NSPointInRect(p, cr);
            }
            return i;
        }
    }
    if (NSPointInRect(p, [self plusRect])) return _tabCount; // "+" sentinel
    return -1;
}

- (void)mouseMoved:(NSEvent*)event {
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    BOOL onClose = NO;
    int idx = [self tabIndexAtPoint:p closeHit:&onClose];
    if (idx != _hoveredTab || onClose != _hoverOnClose) {
        _hoveredTab = idx;
        _hoverOnClose = onClose;
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseExited:(NSEvent*)event {
    _hoveredTab = -1;
    _hoverOnClose = NO;
    [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent*)event {
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    BOOL onClose = NO;
    int idx = [self tabIndexAtPoint:p closeHit:&onClose];
    if (idx < 0) return;

    if (idx == _tabCount) {
        // "+" button
        if (_tabTarget && _newTabAction) {
            [_tabTarget performSelector:_newTabAction withObject:nil];
        }
    } else if (onClose && _tabCount > 1) {
        // Close button
        if (_tabTarget && _closeAction) {
            [_tabTarget performSelector:_closeAction withObject:@(idx)];
        }
    } else {
        // Tab click
        if (idx != _activeTab && _tabTarget && _tabClickAction) {
            [_tabTarget performSelector:_tabClickAction withObject:@(idx)];
        }
    }
}

@end

// ---------------------------------------------------------------------------
// AttyxNativeTabManager
// ---------------------------------------------------------------------------

@implementation AttyxNativeTabManager

- (instancetype)initWithWindow:(NSWindow*)window {
    self = [super init];
    if (self) {
        _window = window;
        _lastSyncedCount = 0;
        _lastSyncedActive = -1;

        _tabBarView = [[AttyxTabBarView alloc] initWithFrame:NSMakeRect(0, 0, 600, kTabBarHeight)];
        _tabBarView.autoresizingMask = NSViewWidthSizable;
        _tabBarView.tabTarget = self;
        _tabBarView.tabClickAction = @selector(handleTabClick:);
        _tabBarView.closeAction = @selector(handleCloseClick:);
        _tabBarView.newTabAction = @selector(handleNewTab);

        _accessoryVC = [[NSTitlebarAccessoryViewController alloc] init];
        _accessoryVC.layoutAttribute = NSLayoutAttributeBottom;
        _accessoryVC.view = _tabBarView;
        _isAttached = NO;

        // Only attach if needed (count > 1 or always_show)
        if ((g_native_tab_count > 1) || g_tab_always_show) {
            [window addTitlebarAccessoryViewController:_accessoryVC];
            _isAttached = YES;
        }
    }
    return self;
}

- (void)handleTabClick:(NSNumber*)index {
    g_native_tab_click = [index intValue];
}

- (void)handleCloseClick:(NSNumber*)index {
    g_native_tab_click = [index intValue];
    attyx_tab_action(ATTYX_ACTION_TAB_CLOSE);
}

- (void)handleNewTab {
    attyx_tab_action(ATTYX_ACTION_TAB_NEW);
}

- (void)sync {
    int wantCount = g_native_tab_count;
    int wantActive = g_native_tab_active;
    if (wantCount < 1) wantCount = 1;
    if (wantCount > 16) wantCount = 16;
    if (wantActive < 0) wantActive = 0;
    if (wantActive >= wantCount) wantActive = wantCount - 1;

    BOOL shouldShow = (wantCount > 1) || g_tab_always_show;
    if (shouldShow && !_isAttached) {
        [_window addTitlebarAccessoryViewController:_accessoryVC];
        _isAttached = YES;
    } else if (!shouldShow && _isAttached) {
        [_accessoryVC removeFromParentViewController];
        _isAttached = NO;
    }

    BOOL needsRedraw = NO;

    if (wantCount != _lastSyncedCount) {
        _tabBarView.tabCount = wantCount;
        _lastSyncedCount = wantCount;
        needsRedraw = YES;
    }

    if (wantActive != _lastSyncedActive) {
        _tabBarView.activeTab = wantActive;
        _lastSyncedActive = wantActive;
        needsRedraw = YES;
    }

    if (__sync_lock_test_and_set((volatile int*)&g_native_tab_titles_changed, 0)) {
        NSMutableArray* titles = [NSMutableArray arrayWithCapacity:wantCount];
        for (int i = 0; i < wantCount; i++) {
            NSString* t = [NSString stringWithUTF8String:g_native_tab_titles[i]];
            [titles addObject:t ?: @"Tab"];
        }
        _tabBarView.titles = titles;
        needsRedraw = YES;
    }

    if (needsRedraw) {
        [_tabBarView setNeedsDisplay:YES];
    }
}

@end
