// Attyx — Modern macOS tab bar
//
// Custom-drawn tab bar in NSTitlebarAccessoryViewController with Safari-style
// visuals: translucent active tab, separators, SF Symbols, drag reorder, tearoff.

#import <Cocoa/Cocoa.h>
#include "bridge.h"
#include "macos_internal.h"

#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

static const CGFloat kBarH       = 28.0;
static const CGFloat kPadH       = 10.0;  // text inset inside tab
static const CGFloat kCloseSize  = 16.0;
static const CGFloat kPlusW      = 36.0;
static const CGFloat kDragThresh = 4.0;
static const CGFloat kTearDist   = 40.0;
static const CGFloat kTearW      = 220.0;
static const CGFloat kTearH      = 38.0;

// ---------------------------------------------------------------------------
// AttyxTabBarView
// ---------------------------------------------------------------------------

@interface AttyxTabBarView : NSView
@property (nonatomic) int tabCount;
@property (nonatomic) int activeTab;
@property (nonatomic, strong) NSMutableArray<NSString*>* titles;
@property (nonatomic) int hoveredTab;
@property (nonatomic) BOOL hoverOnClose;
@property (nonatomic) BOOL sessionsActive;
@property (nonatomic, weak) id tabTarget;
@property (nonatomic) SEL tabClickAction, closeAction, newTabAction, reorderAction, tearoffAction;
@property (nonatomic) SEL sessionDropdownAction;
@end

@implementation AttyxTabBarView {
    NSTrackingArea* _track;
    BOOL _dragOn, _dragGo, _tearoff;
    int  _dragIdx, _dragSlot;
    NSPoint _dragStart;
    CGFloat _dragOffX, _dragX, _dragY;
    NSWindow* _tearWin;
}

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _tabCount = 1; _activeTab = 0; _hoveredTab = -1;
        _titles = [NSMutableArray array];
        _dragIdx = -1; _dragSlot = -1;
    }
    return self;
}

- (BOOL)isFlipped { return NO; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

// --- Layout helpers ---
// Tabs fill the bar edge-to-edge (minus trailing buttons). No gaps, no pills.

static const CGFloat kSessW = 36.0;  // session dropdown button width

- (CGFloat)trailingW {
    return kPlusW + (_sessionsActive ? kSessW : 0);
}

- (CGFloat)tabW {
    return (self.bounds.size.width - [self trailingW]) / MAX(_tabCount, 1);
}

- (NSRect)tabRect:(int)i {
    CGFloat w = [self tabW];
    return NSMakeRect(i * w, 0, w, self.bounds.size.height);
}

- (NSRect)closeRect:(NSRect)r {
    return NSMakeRect(r.origin.x + 8,
                      r.origin.y + (r.size.height - kCloseSize) / 2.0,
                      kCloseSize, kCloseSize);
}

- (NSRect)plusRect {
    CGFloat tabsEnd = _tabCount * [self tabW];
    return NSMakeRect(tabsEnd, 0, kPlusW, self.bounds.size.height);
}

- (NSRect)sessionRect {
    CGFloat tabsEnd = _tabCount * [self tabW];
    return NSMakeRect(tabsEnd + kPlusW, 0, kSessW, self.bounds.size.height);
}

- (BOOL)dark {
    if (@available(macOS 10.14, *)) {
        NSAppearanceName n = [self.effectiveAppearance
            bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
        return [n isEqualToString:NSAppearanceNameDarkAqua];
    }
    return NO;
}

// --- Tab drawing ---

- (void)drawTab:(NSRect)r idx:(int)i active:(BOOL)a hover:(BOOL)h dark:(BOOL)dk {
    // Active tab: lighter. Hover: slightly lighter. Inactive: bar bg (nothing extra).
    if (a) {
        NSColor* bg = dk ? [NSColor colorWithWhite:0.25 alpha:1.0]
                         : [NSColor colorWithWhite:0.82 alpha:1.0];
        [bg setFill]; [NSBezierPath fillRect:r];
    } else if (h && !_dragOn) {
        NSColor* bg = dk ? [NSColor colorWithWhite:0.20 alpha:1.0]
                         : [NSColor colorWithWhite:0.75 alpha:1.0];
        [bg setFill]; [NSBezierPath fillRect:r];
    }

    // Close button — show on active always, on hover for others
    CGFloat textL = (_tabCount > 1) ? kPadH + kCloseSize + 2 : kPadH;
    BOOL showClose = _tabCount > 1 && !_dragOn && (a || h);
    if (showClose) {
        NSRect cr = [self closeRect:r];
        if (h && _hoverOnClose) {
            NSColor* cbg = dk ? [NSColor colorWithWhite:1.0 alpha:0.15]
                              : [NSColor colorWithWhite:0.0 alpha:0.10];
            [cbg setFill];
            [[NSBezierPath bezierPathWithOvalInRect:cr] fill];
        }
        NSColor* xc = dk ? [NSColor colorWithWhite:1.0 alpha:(h && _hoverOnClose ? 0.9 : 0.4)]
                         : [NSColor colorWithWhite:0.0 alpha:(h && _hoverOnClose ? 0.7 : 0.3)];
        [xc setStroke];
        CGFloat m = 5.0;
        NSBezierPath* xp = [NSBezierPath bezierPath];
        [xp setLineWidth:1.4]; [xp setLineCapStyle:NSLineCapStyleRound];
        [xp moveToPoint:NSMakePoint(cr.origin.x + m, cr.origin.y + m)];
        [xp lineToPoint:NSMakePoint(NSMaxX(cr) - m, NSMaxY(cr) - m)];
        [xp moveToPoint:NSMakePoint(NSMaxX(cr) - m, cr.origin.y + m)];
        [xp lineToPoint:NSMakePoint(cr.origin.x + m, NSMaxY(cr) - m)];
        [xp stroke];
    }

    // Title — centered
    NSString* title = (i < (int)_titles.count) ? _titles[i] : @"Tab";
    NSColor* tc = a ? (dk ? [NSColor colorWithWhite:1.0 alpha:0.90]
                          : [NSColor colorWithWhite:0.0 alpha:0.85])
                    : (dk ? [NSColor colorWithWhite:1.0 alpha:0.50]
                          : [NSColor colorWithWhite:0.0 alpha:0.50]);
    NSMutableParagraphStyle* ps = [[NSMutableParagraphStyle alloc] init];
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    ps.alignment = NSTextAlignmentCenter;
    NSDictionary* attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11.5 weight:a ? NSFontWeightMedium : NSFontWeightRegular],
        NSForegroundColorAttributeName: tc,
        NSParagraphStyleAttributeName: ps,
    };
    CGFloat maxW = r.size.width - textL - kPadH;
    if (maxW < 10) return;
    NSSize ts = [title sizeWithAttributes:attrs];
    CGFloat ty = r.origin.y + (r.size.height - ts.height) / 2.0;
    [title drawInRect:NSMakeRect(r.origin.x + textL, ty, maxW, ts.height) withAttributes:attrs];
}

// --- Separator line between tabs ---

- (void)drawSepAt:(CGFloat)x dark:(BOOL)dk {
    NSColor* sc = dk ? [NSColor colorWithWhite:1.0 alpha:0.10]
                     : [NSColor colorWithWhite:0.0 alpha:0.12];
    [sc setFill];
    CGFloat h = self.bounds.size.height * 0.55;
    CGFloat y = (self.bounds.size.height - h) / 2.0;
    [NSBezierPath fillRect:NSMakeRect(x - 0.5, y, 1.0, h)];
}

// --- Main draw ---

- (void)drawRect:(NSRect)dirtyRect {
    BOOL dk = [self dark];
    CGFloat w = [self tabW];

    // Bar background — darker than title bar
    NSColor* barBg = dk ? [NSColor colorWithWhite:0.14 alpha:1.0]
                        : [NSColor colorWithWhite:0.70 alpha:1.0];
    [barBg setFill];
    [NSBezierPath fillRect:self.bounds];

    // Bottom edge line
    NSColor* edgeC = dk ? [NSColor colorWithWhite:0.0 alpha:0.3]
                        : [NSColor colorWithWhite:0.0 alpha:0.10];
    [edgeC setFill];
    [NSBezierPath fillRect:NSMakeRect(0, 0, self.bounds.size.width, 0.5)];

    if (_dragOn && _dragGo) {
        // --- Drag mode ---
        int slot = 0;
        for (int i = 0; i < _tabCount; i++) {
            if (i == _dragIdx) continue;
            if (!_tearoff && slot == _dragSlot) slot++;
            NSRect r = NSMakeRect(slot * w, 0, w, self.bounds.size.height);
            [self drawTab:r idx:i active:(i == _activeTab) hover:NO dark:dk];
            slot++;
        }
        // Separators
        int sep = 0;
        for (int i = 0; i < _tabCount; i++) {
            if (i == _dragIdx) continue;
            if (!_tearoff && sep == _dragSlot) sep++;
            if (sep > 0) [self drawSepAt:sep * w dark:dk];
            sep++;
        }
        if (!_tearoff) {
            // Floating dragged tab
            CGFloat fx = MAX(0, MIN(_dragX - _dragOffX,
                             self.bounds.size.width - kPlusW - w));
            NSRect fr = NSMakeRect(fx, 0, w, self.bounds.size.height);
            [NSGraphicsContext saveGraphicsState];
            NSShadow* sh = [[NSShadow alloc] init];
            sh.shadowOffset = NSMakeSize(0, -1);
            sh.shadowBlurRadius = 10.0;
            sh.shadowColor = [NSColor colorWithWhite:0.0 alpha:dk ? 0.6 : 0.3];
            [sh set];
            [self drawTab:fr idx:_dragIdx active:YES hover:NO dark:dk];
            [NSGraphicsContext restoreGraphicsState];
        }
    } else {
        // --- Normal mode ---
        for (int i = 0; i < _tabCount; i++) {
            [self drawTab:[self tabRect:i] idx:i
                   active:(i == _activeTab) hover:(i == _hoveredTab) dark:dk];
        }
        // Separators between tabs (skip around active/hovered)
        for (int i = 1; i < _tabCount; i++) {
            BOOL skipL = (i - 1 == _activeTab) || (i - 1 == _hoveredTab);
            BOOL skipR = (i == _activeTab) || (i == _hoveredTab);
            if (!skipL && !skipR) [self drawSepAt:i * w dark:dk];
        }
    }

    // "+" button
    {
        NSRect pr = [self plusRect];
        BOOL ph = (_hoveredTab == _tabCount) && !_dragOn;
        if (ph) {
            NSColor* hbg = dk ? [NSColor colorWithWhite:1.0 alpha:0.07]
                              : [NSColor colorWithWhite:0.0 alpha:0.05];
            [hbg setFill]; [NSBezierPath fillRect:pr];
        }
        // Separator before +
        [self drawSepAt:pr.origin.x dark:dk];

        NSImage* pi = [NSImage imageWithSystemSymbolName:@"plus"
                                accessibilityDescription:@"New tab"];
        if (pi) {
            NSColor* pc = dk ? [NSColor colorWithWhite:1.0 alpha:0.45]
                             : [NSColor colorWithWhite:0.0 alpha:0.40];
            NSImageSymbolConfiguration* cfg =
                [NSImageSymbolConfiguration configurationWithPointSize:13
                                                               weight:NSFontWeightMedium
                                                                scale:NSImageSymbolScaleMedium];
            cfg = [cfg configurationByApplyingConfiguration:
                [NSImageSymbolConfiguration configurationWithHierarchicalColor:pc]];
            pi = [pi imageWithSymbolConfiguration:cfg];
            NSSize is = pi.size;
            [pi drawInRect:NSMakeRect(pr.origin.x + (pr.size.width - is.width) / 2.0,
                                      pr.origin.y + (pr.size.height - is.height) / 2.0,
                                      is.width, is.height)];
        } else {
            NSColor* pc = dk ? [NSColor colorWithWhite:1.0 alpha:0.45]
                             : [NSColor colorWithWhite:0.0 alpha:0.40];
            NSDictionary* pa = @{
                NSFontAttributeName: [NSFont systemFontOfSize:16 weight:NSFontWeightRegular],
                NSForegroundColorAttributeName: pc,
            };
            NSSize ps = [@"+" sizeWithAttributes:pa];
            [@"+" drawAtPoint:NSMakePoint(pr.origin.x + (pr.size.width - ps.width) / 2.0,
                                          pr.origin.y + (pr.size.height - ps.height) / 2.0)
               withAttributes:pa];
        }
    }

    // Session dropdown button (only when sessions active)
    if (_sessionsActive) {
        NSRect sr = [self sessionRect];
        BOOL sh = (_hoveredTab == _tabCount + 1) && !_dragOn;
        if (sh) {
            NSColor* hbg = dk ? [NSColor colorWithWhite:1.0 alpha:0.07]
                              : [NSColor colorWithWhite:0.0 alpha:0.05];
            [hbg setFill]; [NSBezierPath fillRect:sr];
        }
        [self drawSepAt:sr.origin.x dark:dk];

        NSImage* si = [NSImage imageWithSystemSymbolName:@"rectangle.stack"
                                accessibilityDescription:@"Sessions"];
        if (si) {
            NSColor* sc = dk ? [NSColor colorWithWhite:1.0 alpha:0.45]
                             : [NSColor colorWithWhite:0.0 alpha:0.40];
            NSImageSymbolConfiguration* scfg =
                [NSImageSymbolConfiguration configurationWithPointSize:11
                                                               weight:NSFontWeightMedium
                                                                scale:NSImageSymbolScaleMedium];
            scfg = [scfg configurationByApplyingConfiguration:
                [NSImageSymbolConfiguration configurationWithHierarchicalColor:sc]];
            si = [si imageWithSymbolConfiguration:scfg];
            NSSize sis = si.size;
            [si drawInRect:NSMakeRect(sr.origin.x + (sr.size.width - sis.width) / 2.0,
                                      sr.origin.y + (sr.size.height - sis.height) / 2.0,
                                      sis.width, sis.height)];
        }
    }
}

// --- Tearoff overlay ---

- (void)showTearoff:(NSPoint)screenPt {
    NSString* title = (_dragIdx < (int)_titles.count) ? _titles[_dragIdx] : @"Tab";
    BOOL dk = [self dark];
    if (!_tearWin) {
        _tearWin = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, kTearW, kTearH)
                      styleMask:NSWindowStyleMaskBorderless
                        backing:NSBackingStoreBuffered defer:NO];
        _tearWin.backgroundColor = [NSColor clearColor];
        _tearWin.opaque = NO; _tearWin.hasShadow = YES;
        _tearWin.level = NSFloatingWindowLevel;
        _tearWin.ignoresMouseEvents = YES;
    }
    NSImage* img = [[NSImage alloc] initWithSize:NSMakeSize(kTearW, kTearH)];
    [img lockFocus];
    NSRect pr = NSMakeRect(0, 0, kTearW, kTearH);
    NSColor* bg = dk ? [NSColor colorWithWhite:0.18 alpha:0.95]
                     : [NSColor colorWithWhite:0.96 alpha:0.95];
    NSBezierPath* pill = [NSBezierPath bezierPathWithRoundedRect:pr xRadius:10 yRadius:10];
    [bg setFill]; [pill fill];
    NSColor* bc = dk ? [NSColor colorWithWhite:1.0 alpha:0.12]
                     : [NSColor colorWithWhite:0.0 alpha:0.10];
    [bc setStroke]; [pill setLineWidth:0.5]; [pill stroke];
    NSColor* tc = dk ? [NSColor colorWithWhite:1.0 alpha:0.90]
                     : [NSColor colorWithWhite:0.0 alpha:0.85];
    NSDictionary* a = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: tc,
    };
    NSSize ts = [title sizeWithAttributes:a];
    CGFloat mw = kTearW - 28;
    [title drawInRect:NSMakeRect((kTearW - MIN(ts.width, mw)) / 2.0,
                                 (kTearH - ts.height) / 2.0,
                                 MIN(ts.width, mw), ts.height) withAttributes:a];
    [img unlockFocus];
    NSImageView* iv = [[NSImageView alloc] initWithFrame:pr];
    iv.image = img;
    _tearWin.contentView = iv;
    [_tearWin setFrame:NSMakeRect(screenPt.x - kTearW / 2.0,
                                   screenPt.y - kTearH / 2.0,
                                   kTearW, kTearH) display:YES];
    if (!_tearWin.visible) [_tearWin orderFront:nil];
}

- (void)hideTearoff { [_tearWin orderOut:nil]; }

// --- Mouse tracking ---

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_track) [self removeTrackingArea:_track];
    _track = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow
               owner:self userInfo:nil];
    [self addTrackingArea:_track];
}

// Hit test returns: 0.._tabCount-1 = tab, _tabCount = plus, _tabCount+1 = session, -1 = none
- (int)hitTab:(NSPoint)p close:(BOOL*)cl {
    if (cl) *cl = NO;
    for (int i = 0; i < _tabCount; i++) {
        NSRect r = [self tabRect:i];
        if (NSPointInRect(p, r)) {
            if (cl && _tabCount > 1) *cl = NSPointInRect(p, [self closeRect:r]);
            return i;
        }
    }
    if (NSPointInRect(p, [self plusRect])) return _tabCount;
    if (_sessionsActive && NSPointInRect(p, [self sessionRect])) return _tabCount + 1;
    return -1;
}

- (void)mouseMoved:(NSEvent*)e {
    if (_dragOn) return;
    NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
    BOOL cl = NO;
    int idx = [self hitTab:p close:&cl];
    if (idx != _hoveredTab || cl != _hoverOnClose) {
        _hoveredTab = idx; _hoverOnClose = cl;
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseExited:(NSEvent*)e {
    if (_dragOn) return;
    _hoveredTab = -1; _hoverOnClose = NO;
    [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent*)e {
    NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
    BOOL cl = NO;
    int idx = [self hitTab:p close:&cl];
    if (idx < 0) return;
    if (idx == _tabCount + 1) {
        // Session dropdown button
        if (_tabTarget && _sessionDropdownAction)
            [_tabTarget performSelector:_sessionDropdownAction withObject:nil];
        return;
    }
    if (idx == _tabCount) {
        if (_tabTarget && _newTabAction)
            [_tabTarget performSelector:_newTabAction withObject:nil];
        return;
    }
    if (cl && _tabCount > 1) {
        if (_tabTarget && _closeAction)
            [_tabTarget performSelector:_closeAction withObject:@(idx)];
        return;
    }
    _dragOn = YES; _dragGo = NO; _tearoff = NO;
    _dragIdx = idx; _dragSlot = idx; _dragStart = p;
    NSRect tr = [self tabRect:idx];
    _dragOffX = p.x - tr.origin.x;
    _dragX = p.x; _dragY = p.y;
}

- (void)mouseDragged:(NSEvent*)e {
    if (!_dragOn) return;
    NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
    if (!_dragGo) {
        CGFloat d2 = (p.x-_dragStart.x)*(p.x-_dragStart.x) + (p.y-_dragStart.y)*(p.y-_dragStart.y);
        if (d2 < kDragThresh * kDragThresh) return;
        _dragGo = YES;
        if (_dragIdx != _activeTab && _tabTarget && _tabClickAction)
            [_tabTarget performSelector:_tabClickAction withObject:@(_dragIdx)];
    }
    _dragX = p.x; _dragY = p.y;
    BOOL wasTear = _tearoff;
    CGFloat bH = self.bounds.size.height;
    _tearoff = (_tabCount > 1) && (p.y > bH + kTearDist || p.y < -kTearDist);
    if (_tearoff) {
        [self showTearoff:[NSEvent mouseLocation]];
        if (!wasTear) _dragSlot = _dragIdx;
    } else {
        if (wasTear) [self hideTearoff];
        CGFloat w = [self tabW];
        int s = (int)((_dragX - _dragOffX + w / 2.0) / w);
        _dragSlot = MAX(0, MIN(s, _tabCount - 1));
    }
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent*)e {
    if (!_dragOn) return;
    NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
    if (!_dragGo) {
        _dragOn = NO; _dragIdx = -1;
        BOOL cl = NO;
        int idx = [self hitTab:p close:&cl];
        if (idx >= 0 && idx < _tabCount && idx != _activeTab && _tabTarget && _tabClickAction)
            [_tabTarget performSelector:_tabClickAction withObject:@(idx)];
        return;
    }
    _dragOn = NO; _dragGo = NO;
    if (_tearoff) {
        _tearoff = NO; [self hideTearoff];
        if (_tabTarget && _tearoffAction)
            [_tabTarget performSelector:_tearoffAction withObject:@(_dragIdx)];
    } else if (_dragSlot != _dragIdx && _tabTarget && _reorderAction) {
        [_tabTarget performSelector:_reorderAction withObject:@((_dragIdx << 8) | _dragSlot)];
    }
    _dragIdx = -1; _dragSlot = -1; _hoveredTab = -1;
    [self setNeedsDisplay:YES];
}

@end

// ---------------------------------------------------------------------------
// AttyxNativeTabManager
// ---------------------------------------------------------------------------

@implementation AttyxNativeTabManager

- (instancetype)initWithWindow:(NSWindow*)window {
    self = [super init];
    if (!self) return nil;
    _window = window;
    _lastSyncedCount = 0; _lastSyncedActive = -1;

    _tabBarView = [[AttyxTabBarView alloc] initWithFrame:NSMakeRect(0, 0, 600, kBarH)];
    _tabBarView.autoresizingMask = NSViewWidthSizable;
    _tabBarView.tabTarget = self;
    _tabBarView.tabClickAction = @selector(handleTabClick:);
    _tabBarView.closeAction = @selector(handleCloseClick:);
    _tabBarView.newTabAction = @selector(handleNewTab);
    _tabBarView.reorderAction = @selector(handleReorder:);
    _tabBarView.tearoffAction = @selector(handleTearoff:);
    _tabBarView.sessionDropdownAction = @selector(handleSessionDropdown);

    _accessoryVC = [[NSTitlebarAccessoryViewController alloc] init];
    _accessoryVC.layoutAttribute = NSLayoutAttributeBottom;
    _accessoryVC.view = _tabBarView;
    _isAttached = NO;
    if ((g_native_tab_count > 1) || g_tab_always_show) {
        [window addTitlebarAccessoryViewController:_accessoryVC];
        _isAttached = YES;
    }
    return self;
}

- (void)handleTabClick:(NSNumber*)i  { g_native_tab_click = [i intValue]; }
- (void)handleCloseClick:(NSNumber*)i { g_native_tab_click = [i intValue]; attyx_dispatch_action(50); }
- (void)handleNewTab { attyx_dispatch_action(49); }
- (void)handleReorder:(NSNumber*)p { g_native_tab_reorder = [p intValue]; }

- (void)handleTearoff:(NSNumber*)i {
    g_native_tab_click = [i intValue];
    attyx_dispatch_action(50);
    attyx_spawn_new_window();
}

- (void)handleSessionDropdown {
    int count = g_session_count;
    int activeIdx = g_active_session_idx;
    if (count <= 0) {
        // No sessions yet — just create one
        attyx_create_session_direct();
        return;
    }

    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Sessions"];

    for (int i = 0; i < count && i < ATTYX_MAX_SESSIONS; i++) {
        NSString* name = [NSString stringWithUTF8String:g_session_names[i]];
        if (!name) name = @"Session";
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:name
                                                      action:@selector(sessionMenuClicked:)
                                               keyEquivalent:@""];
        item.target = self;
        item.tag = (NSInteger)g_session_ids[i];
        if (i == activeIdx) item.state = NSControlStateValueOn;
        [menu addItem:item];
    }

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem* create = [[NSMenuItem alloc] initWithTitle:@"Create Session"
                                                    action:@selector(sessionCreateClicked:)
                                             keyEquivalent:@""];
    create.target = self;
    [menu addItem:create];

    // Show dropdown anchored to the session button
    NSRect sr = [_tabBarView sessionRect];
    NSPoint anchor = NSMakePoint(sr.origin.x, sr.origin.y);
    [menu popUpMenuPositioningItem:nil atLocation:anchor inView:_tabBarView];
}

- (void)sessionMenuClicked:(NSMenuItem*)item {
    g_session_switch_id = (int)item.tag;
}

- (void)sessionCreateClicked:(NSMenuItem*)item {
    attyx_toggle_session_switcher();
}

- (void)sync {
    int cnt = g_native_tab_count, act = g_native_tab_active;
    if (cnt < 1) cnt = 1; if (cnt > 16) cnt = 16;
    if (act < 0) act = 0; if (act >= cnt) act = cnt - 1;

    BOOL show = (cnt > 1) || g_tab_always_show;
    if (show && !_isAttached) {
        [_window addTitlebarAccessoryViewController:_accessoryVC]; _isAttached = YES;
    } else if (!show && _isAttached) {
        [_accessoryVC removeFromParentViewController]; _isAttached = NO;
    }

    BOOL dirty = NO;
    if (cnt != _lastSyncedCount) { _tabBarView.tabCount = cnt; _lastSyncedCount = cnt; dirty = YES; }
    if (act != _lastSyncedActive) { _tabBarView.activeTab = act; _lastSyncedActive = act; dirty = YES; }

    if (__sync_lock_test_and_set((volatile int*)&g_native_tab_titles_changed, 0)) {
        NSMutableArray* t = [NSMutableArray arrayWithCapacity:cnt];
        for (int i = 0; i < cnt; i++) {
            NSString* s = [NSString stringWithUTF8String:g_native_tab_titles[i]];
            [t addObject:s ?: @"Tab"];
        }
        _tabBarView.titles = t; dirty = YES;
    }

    // Sync session dropdown visibility
    BOOL sessNow = (g_sessions_active != 0);
    if (sessNow != _tabBarView.sessionsActive) {
        _tabBarView.sessionsActive = sessNow;
        dirty = YES;
    }

    if (dirty) [_tabBarView setNeedsDisplay:YES];
}

@end
