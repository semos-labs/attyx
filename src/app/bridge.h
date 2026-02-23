#ifndef ATTYX_BRIDGE_H
#define ATTYX_BRIDGE_H

#include <stdint.h>

#define ATTYX_MAX_ROWS 256
#define ATTYX_MAX_COLS 512

typedef struct {
    uint32_t character;
    uint8_t fg_r, fg_g, fg_b;
    uint8_t bg_r, bg_g, bg_b;
    uint8_t flags; // bit 0 = bold, bit 1 = underline
} AttyxCell;

// Blocks until the window is closed. Reads cells each frame (live).
void attyx_run(AttyxCell* cells, int cols, int rows);

// Update cursor position (called from PTY thread).
void attyx_set_cursor(int row, int col);

// Signal the window to close (called from PTY thread on child exit).
void attyx_request_quit(void);

// Check if the window has been closed (polled by PTY thread).
int attyx_should_quit(void);

// Send keyboard input to the PTY (called from main/Cocoa thread).
// Implemented in Zig (ui2.zig).
void attyx_send_input(const uint8_t* bytes, int len);

// Update terminal mode flags (called from PTY thread after engine.feed).
void attyx_set_mode_flags(int bracketed_paste, int cursor_keys_app);

// Update mouse mode flags (called from PTY thread after engine.feed).
// tracking: 0=off, 1=x10, 2=button_event, 3=any_event
// sgr: 1 if SGR 1006 encoding is enabled
void attyx_set_mouse_mode(int tracking, int sgr);

// Mark rows dirty (atomic OR). Called from PTY thread; renderer reads + clears.
// dirty is a 4-element uint64_t array (256-row bitset).
void attyx_set_dirty(const uint64_t dirty[4]);

// Update the active grid dimensions (called from PTY thread after resize).
void attyx_set_grid_size(int cols, int rows);

// Check for a pending resize request from the renderer (window resize).
// Returns 1 if a resize is pending (writing new dimensions into out_rows/out_cols),
// 0 otherwise. Called from PTY thread.
int attyx_check_resize(int* out_rows, int* out_cols);

// Seqlock for cell buffer: PTY thread calls begin/end around cell updates.
// Renderer checks the generation to detect torn reads.
void attyx_begin_cell_update(void);
void attyx_end_cell_update(void);

#endif
