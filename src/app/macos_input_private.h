#ifndef ATTYX_MACOS_INPUT_PRIVATE_H
#define ATTYX_MACOS_INPUT_PRIVATE_H

#include "macos_internal.h"

@interface AttyxView () {
    int _lastMouseCol;
    int _lastMouseRow;
    BOOL _leftDown;
    BOOL _rightDown;
    BOOL _middleDown;
    CGFloat _scrollAccum;
    BOOL _selecting;
    BOOL _splitDragging;
    BOOL _sidebarDragging;
    int _clickCount;
    NSMutableString* _markedText;
    NSRange _markedRange;
    NSRange _selectedRange;
}
@end

#endif // ATTYX_MACOS_INPUT_PRIVATE_H
