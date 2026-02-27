const content = @import("content.zig");
const ContentBlock = content.ContentBlock;

/// Mock AI response for the streaming demo overlay.
pub const mock_title = "Terminal Grid Resize";

pub const mock_blocks = [_]ContentBlock{
    .{
        .tag = .header,
        .text = "Terminal Grid Resize",
    },
    .{
        .tag = .paragraph,
        .text = "When the terminal window is resized, the grid must be " ++
            "updated to match the new dimensions. This involves " ++
            "reflowing content and notifying the child process.",
    },
    .{
        .tag = .bullet_list,
        .items = &.{
            "Detect resize via SIGWINCH or platform event",
            "Update grid dimensions (rows x cols)",
            "Reflow wrapped lines to new width",
            "Notify PTY with TIOCSWINSZ ioctl",
        },
    },
    .{
        .tag = .code_block,
        .text = "pub fn resize(self: *Grid, rows: u16, cols: u16) !void {\n" ++
            "    self.rows = rows;\n" ++
            "    self.cols = cols;\n" ++
            "    try self.reflow();\n" ++
            "    self.dirty.markAll();\n" ++
            "}",
    },
    .{
        .tag = .paragraph,
        .text = "After resize, the renderer picks up dirty rows " ++
            "on the next frame and repaints only what changed.",
    },
};

test "demo: mock_blocks compile and have expected count" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 5), mock_blocks.len);
    try std.testing.expectEqual(content.BlockTag.header, mock_blocks[0].tag);
    try std.testing.expectEqual(content.BlockTag.code_block, mock_blocks[3].tag);
}
