#ifndef ATTYX_BRIDGE_H
#define ATTYX_BRIDGE_H

#include <stdint.h>

typedef struct {
    uint8_t character;
    uint8_t fg_r, fg_g, fg_b;
    uint8_t bg_r, bg_g, bg_b;
    uint8_t flags; // bit 0 = bold, bit 1 = underline
} AttyxCell;

// Blocks until the window is closed. Reads cells each frame.
void attyx_run(const AttyxCell* cells, int cols, int rows);

#endif
