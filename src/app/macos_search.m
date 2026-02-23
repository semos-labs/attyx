// Attyx — macOS native search bar (Cocoa)

#import <Cocoa/Cocoa.h>
#include <string.h>
#include "macos_internal.h"

@implementation AttyxSearchBar

- (instancetype)initForTermView:(NSView*)parent {
    self = [super initWithFrame:NSZeroRect];
    if (!self) return nil;

    _termView = parent;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.material = NSVisualEffectMaterialMenu;
    self.state = NSVisualEffectStateActive;
    self.wantsLayer = YES;
    self.layer.cornerRadius = 0;

    _inputBox = [[NSView alloc] initWithFrame:NSZeroRect];
    _inputBox.translatesAutoresizingMaskIntoConstraints = NO;
    _inputBox.wantsLayer = YES;
    _inputBox.layer.cornerRadius = 6;
    _inputBox.layer.backgroundColor = [[NSColor colorWithWhite:0.12 alpha:1.0] CGColor];
    [self addSubview:_inputBox];

    _inputField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _inputField.translatesAutoresizingMaskIntoConstraints = NO;
    _inputField.placeholderString = @"Find";
    _inputField.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
    _inputField.bordered = NO;
    _inputField.focusRingType = NSFocusRingTypeNone;
    _inputField.drawsBackground = NO;
    _inputField.textColor = [NSColor whiteColor];
    _inputField.cell.scrollable = YES;
    _inputField.cell.wraps = NO;
    _inputField.delegate = self;
    [_inputBox addSubview:_inputField];

    [NSLayoutConstraint activateConstraints:@[
        [_inputField.leadingAnchor constraintEqualToAnchor:_inputBox.leadingAnchor constant:8],
        [_inputField.trailingAnchor constraintEqualToAnchor:_inputBox.trailingAnchor constant:-8],
        [_inputField.centerYAnchor constraintEqualToAnchor:_inputBox.centerYAnchor],
    ]];

    _countLabel = [NSTextField labelWithString:@""];
    _countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _countLabel.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    _countLabel.textColor = [NSColor secondaryLabelColor];
    _countLabel.alignment = NSTextAlignmentRight;
    [_countLabel setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self addSubview:_countLabel];

    NSImageSymbolConfiguration* symCfg = [NSImageSymbolConfiguration
        configurationWithPointSize:12 weight:NSFontWeightMedium];
    NSImage* upImg   = [[NSImage imageWithSystemSymbolName:@"chevron.up"
                          accessibilityDescription:@"Previous"]
                         imageWithSymbolConfiguration:symCfg];
    NSImage* downImg = [[NSImage imageWithSystemSymbolName:@"chevron.down"
                          accessibilityDescription:@"Next"]
                         imageWithSymbolConfiguration:symCfg];
    NSImage* xImg    = [[NSImage imageWithSystemSymbolName:@"xmark"
                          accessibilityDescription:@"Close"]
                         imageWithSymbolConfiguration:symCfg];

    _prevButton  = [NSButton buttonWithImage:upImg   target:self action:@selector(goPrev:)];
    _nextButton  = [NSButton buttonWithImage:downImg target:self action:@selector(goNext:)];
    _closeButton = [NSButton buttonWithImage:xImg    target:self action:@selector(dismiss)];
    for (NSButton* b in @[_prevButton, _nextButton, _closeButton]) {
        b.translatesAutoresizingMaskIntoConstraints = NO;
        b.bordered = NO;
        b.bezelStyle = NSBezelStyleInline;
        b.contentTintColor = [NSColor secondaryLabelColor];
        [b setContentHuggingPriority:NSLayoutPriorityRequired
                      forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self addSubview:b];
    }
    _prevButton.toolTip  = @"Previous Match (\u21e7\u2318G)";
    _nextButton.toolTip  = @"Next Match (\u2318G)";
    _closeButton.toolTip = @"Close (Esc)";

    NSDictionary *views = NSDictionaryOfVariableBindings(_inputBox, _countLabel, _prevButton, _nextButton, _closeButton);
    [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:
        @"H:|-8-[_inputBox]-6-[_countLabel(>=44)]-4-[_prevButton(26)]-1-[_nextButton(26)]-6-[_closeButton(26)]-6-|"
        options:0 metrics:nil views:views]];

    for (NSView* sub in @[_inputBox, _countLabel, _prevButton, _nextButton, _closeButton]) {
        [NSLayoutConstraint activateConstraints:@[
            [sub.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
    }

    [_inputBox.heightAnchor constraintEqualToConstant:26].active = YES;

    return self;
}

- (void)show {
    if (self.superview) {
        [self.window makeFirstResponder:_inputField];
        return;
    }
    NSView* parent = _termView;
    if (!parent) return;

    [parent addSubview:self];
    [NSLayoutConstraint activateConstraints:@[
        [self.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor],
        [self.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor],
        [self.topAnchor constraintEqualToAnchor:parent.topAnchor],
        [self.heightAnchor constraintEqualToConstant:36],
    ]];

    g_search_active = 1;
    g_search_query_len = 0;
    g_search_gen++;
    [_inputField setStringValue:@""];
    _countLabel.stringValue = @"";
    [self.window makeFirstResponder:_inputField];
    attyx_mark_all_dirty();
}

- (void)dismiss {
    if (!self.superview) return;
    g_search_active = 0;
    g_search_query_len = 0;
    g_search_gen++;
    attyx_mark_all_dirty();

    NSView* parent = _termView;
    [self removeFromSuperview];
    if (parent) [parent.window makeFirstResponder:parent];
}

- (void)toggle {
    if (self.superview) [self dismiss];
    else [self show];
}

- (void)goNext:(id)sender {
    __sync_fetch_and_add((volatile int*)&g_search_nav_delta, 1);
    attyx_mark_all_dirty();
}

- (void)goPrev:(id)sender {
    __sync_fetch_and_add((volatile int*)&g_search_nav_delta, -1);
    attyx_mark_all_dirty();
}

- (void)syncCountLabel {
    if (!self.superview) return;
    int total = g_search_total;
    int cur   = g_search_current;
    if (total > 0) {
        _countLabel.stringValue = [NSString stringWithFormat:@"%d/%d", cur + 1, total];
        _countLabel.textColor = [NSColor secondaryLabelColor];
    } else if (g_search_query_len > 0) {
        _countLabel.stringValue = @"-/0";
        _countLabel.textColor = [NSColor systemRedColor];
    } else {
        _countLabel.stringValue = @"";
    }
}

- (void)controlTextDidChange:(NSNotification *)n {
    const char* utf8 = [_inputField.stringValue UTF8String];
    int len = (int)strlen(utf8);
    if (len > ATTYX_SEARCH_QUERY_MAX - 1) len = ATTYX_SEARCH_QUERY_MAX - 1;
    memcpy(g_search_query, utf8, len);
    g_search_query_len = len;
    g_search_gen++;
    attyx_mark_all_dirty();
}

- (BOOL)control:(NSControl*)ctl textView:(NSTextView*)tv doCommandBySelector:(SEL)sel {
    if (sel == @selector(insertNewline:))    { [self goNext:nil]; return YES; }
    if (sel == @selector(cancelOperation:))  { [self dismiss]; return YES; }
    return NO;
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags f = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    unsigned short kc = event.keyCode;
    BOOL cmd   = (f & NSEventModifierFlagCommand) != 0;
    BOOL shift = (f & NSEventModifierFlagShift) != 0;

    if (cmd && kc == 3 /* F */) { [self dismiss]; return YES; }
    if (cmd && kc == 5 /* G */) {
        if (shift) [self goPrev:nil]; else [self goNext:nil];
        return YES;
    }
    return [super performKeyEquivalent:event];
}

@end

void syncSearchBarCount(void) {
    if (g_nativeSearchBar) [g_nativeSearchBar syncCountLabel];
}
