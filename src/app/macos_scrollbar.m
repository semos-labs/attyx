// Attyx — macOS native scrollbar (NSScroller, legacy style)

#import <Cocoa/Cocoa.h>
#include "bridge.h"

// Forward declaration
void attyx_scroll_viewport(int delta);

// ---------------------------------------------------------------------------
// Scrollbar target (handles thumb drag / page clicks)
// ---------------------------------------------------------------------------

@interface AttyxScrollTarget : NSObject
@end

static NSScroller*         s_scroller = nil;
static AttyxScrollTarget*  s_target   = nil;

@implementation AttyxScrollTarget

- (void)scrollAction:(NSScroller*)sender {
    int sb = g_scrollback_count;
    int rows = g_rows;
    if (sb <= 0) return;

    switch (sender.hitPart) {
        case NSScrollerKnob:
        case NSScrollerKnobSlot: {
            double val = sender.doubleValue;
            int targetPos = (int)((1.0 - val) * sb + 0.5);
            if (targetPos < 0) targetPos = 0;
            if (targetPos > sb) targetPos = sb;
            int delta = targetPos - g_viewport_offset;
            if (delta != 0) attyx_scroll_viewport(delta);
            break;
        }
        case NSScrollerDecrementPage:
            attyx_scroll_viewport(rows);
            break;
        case NSScrollerIncrementPage:
            attyx_scroll_viewport(-rows);
            break;
        default:
            break;
    }
}

@end

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

void attyx_scrollbar_init(NSView* parent) {
    if (s_scroller) return;

    s_target = [[AttyxScrollTarget alloc] init];

    CGFloat scrollerWidth = [NSScroller scrollerWidthForControlSize:NSControlSizeRegular
                                                     scrollerStyle:NSScrollerStyleLegacy];
    NSRect frame = NSMakeRect(
        parent.bounds.size.width - scrollerWidth, 0,
        scrollerWidth, parent.bounds.size.height
    );
    s_scroller = [[NSScroller alloc] initWithFrame:frame];
    s_scroller.scrollerStyle = NSScrollerStyleLegacy;
    s_scroller.autoresizingMask = NSViewHeightSizable | NSViewMinXMargin;
    s_scroller.target = s_target;
    s_scroller.action = @selector(scrollAction:);
    s_scroller.enabled = YES;
    s_scroller.hidden = YES;

    [parent addSubview:s_scroller];
}

// Cache to avoid redundant updates
static int s_prev_sb   = -1;
static int s_prev_vp   = -1;
static int s_prev_rows = -1;

void attyx_scrollbar_update(void) {
    if (!s_scroller) return;

    if (!g_window_scrollbar) {
        if (!s_scroller.hidden) s_scroller.hidden = YES;
        return;
    }

    int sb = g_scrollback_count;
    int vp = g_viewport_offset;
    int rows = g_rows;

    if (sb <= 0 || g_alt_screen) {
        if (!s_scroller.hidden) s_scroller.hidden = YES;
        s_prev_sb = sb;
        s_prev_vp = vp;
        s_prev_rows = rows;
        return;
    }

    if (sb == s_prev_sb && vp == s_prev_vp && rows == s_prev_rows)
        return;

    if (s_scroller.hidden) s_scroller.hidden = NO;

    double proportion = (double)rows / (double)(sb + rows);
    double value = (sb > 0) ? (double)(sb - vp) / (double)sb : 1.0;

    s_scroller.knobProportion = proportion;
    s_scroller.doubleValue = value;

    s_prev_sb   = sb;
    s_prev_vp   = vp;
    s_prev_rows = rows;
}
