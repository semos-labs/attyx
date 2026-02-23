const grid_mod = @import("grid.zig");
const actions_mod = @import("actions.zig");

const TerminalState = @import("state.zig").TerminalState;
const Cell = grid_mod.Cell;

pub fn eraseInDisplay(self: *TerminalState, mode: actions_mod.EraseMode) void {
    const cols = self.grid.cols;
    switch (mode) {
        .to_end => {
            const start = self.cursor.row * cols + self.cursor.col;
            @memset(self.grid.cells[start..], Cell{});
            for (self.cursor.row..self.grid.rows) |r| {
                self.grid.row_wrapped[r] = false;
            }
            self.dirty.markRange(self.cursor.row, self.grid.rows - 1);
        },
        .to_start => {
            const end = self.cursor.row * cols + self.cursor.col + 1;
            @memset(self.grid.cells[0..end], Cell{});
            for (0..self.cursor.row + 1) |r| {
                self.grid.row_wrapped[r] = false;
            }
            self.dirty.markRange(0, self.cursor.row);
        },
        .all => {
            if (!self.alt_active) {
                // If the screen has visible content, save it to
                // scrollback and pin the cursor to the bottom so
                // the shell's next prompt lands there (e.g. `clear`).
                var last_content_row: usize = 0;
                var has_content = false;
                {
                    var r: usize = self.grid.rows;
                    while (r > 0) {
                        r -= 1;
                        const base = r * cols;
                        for (0..cols) |c| {
                            if (!grid_mod.isDefaultCell(self.grid.cells[base + c])) {
                                last_content_row = r;
                                has_content = true;
                                break;
                            }
                        }
                        if (has_content) break;
                    }
                }
                if (has_content) {
                    for (0..last_content_row + 1) |r| {
                        const start = r * cols;
                        self.scrollback.pushLine(self.grid.cells[start .. start + cols]);
                    }
                    self.cursor.row = self.grid.rows - 1;
                }
            }
            @memset(self.grid.cells, Cell{});
            @memset(self.grid.row_wrapped[0..self.grid.rows], false);
            self.dirty.markAll(self.grid.rows);
        },
    }
}

pub fn eraseInLine(self: *TerminalState, mode: actions_mod.EraseMode) void {
    const cols = self.grid.cols;
    const row_start = self.cursor.row * cols;
    switch (mode) {
        .to_end => {
            @memset(self.grid.cells[row_start + self.cursor.col .. row_start + cols], Cell{});
            self.grid.row_wrapped[self.cursor.row] = false;
        },
        .to_start => {
            @memset(self.grid.cells[row_start .. row_start + self.cursor.col + 1], Cell{});
        },
        .all => {
            self.grid.clearRow(self.cursor.row);
        },
    }
}
