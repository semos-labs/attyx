const grid_mod = @import("grid.zig");
const actions_mod = @import("actions.zig");

const TerminalState = @import("state.zig").TerminalState;
const Cell = grid_mod.Cell;

pub fn eraseInDisplay(self: *TerminalState, mode: actions_mod.EraseMode) void {
    const cols = self.ring.cols;
    const rows = self.ring.screen_rows;
    switch (mode) {
        .to_end => {
            // Clear from cursor to end of screen
            // Clear rest of current row
            const row_cells = self.ring.getScreenRowMut(self.cursor.row);
            @memset(row_cells[self.cursor.col..], Cell{});
            self.ring.setScreenWrapped(self.cursor.row, false);
            // Clear all rows below
            for (self.cursor.row + 1..rows) |r| {
                self.ring.clearScreenRow(r);
            }
            self.dirty.markRange(self.cursor.row, rows - 1);
        },
        .to_start => {
            // Clear from start of screen to cursor
            for (0..self.cursor.row) |r| {
                self.ring.clearScreenRow(r);
            }
            // Clear current row up to and including cursor
            const row_cells = self.ring.getScreenRowMut(self.cursor.row);
            @memset(row_cells[0 .. self.cursor.col + 1], Cell{});
            self.dirty.markRange(0, self.cursor.row);
        },
        .all => {
            if (!self.alt_active) {
                // Save visible content to scrollback by advancing the screen.
                var last_content_row: usize = 0;
                var has_content = false;
                {
                    var r: usize = rows;
                    while (r > 0) {
                        r -= 1;
                        const row_cells = self.ring.getScreenRow(r);
                        for (0..cols) |c| {
                            if (!grid_mod.isDefaultCell(row_cells[c])) {
                                last_content_row = r;
                                has_content = true;
                                break;
                            }
                        }
                        if (has_content) break;
                    }
                }
                if (has_content) {
                    // Advance screen N times to push content rows into scrollback.
                    for (0..last_content_row + 1) |_| {
                        _ = self.ring.advanceScreen();
                    }
                }
            }
            // Clear all screen rows
            for (0..rows) |r| {
                self.ring.clearScreenRow(r);
            }
            self.dirty.markAll(rows);
        },
        .scrollback => {
            // CSI 3 J — Erase Saved Lines: clear scrollback buffer.
            if (!self.alt_active) {
                self.ring.clearScrollback();
                self.viewport_offset = 0;
            }
            self.dirty.markAll(rows);
        },
    }
}

pub fn eraseInLine(self: *TerminalState, mode: actions_mod.EraseMode) void {
    const row_cells = self.ring.getScreenRowMut(self.cursor.row);
    switch (mode) {
        .to_end => {
            @memset(row_cells[self.cursor.col..], Cell{});
            self.ring.setScreenWrapped(self.cursor.row, false);
        },
        .to_start => {
            @memset(row_cells[0 .. self.cursor.col + 1], Cell{});
        },
        .all => {
            @memset(row_cells, Cell{});
            self.ring.setScreenWrapped(self.cursor.row, false);
        },
        .scrollback => {},
    }
}
