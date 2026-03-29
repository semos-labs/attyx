// block.zig — Block model for xyron command output.
//
// Mirrors xyron's Block structure. Each command produces a Block tracked
// by block_id. Attyx uses evt_block_started/finished events to manage
// the lifecycle and renders bordered "cards" in the terminal.

const std = @import("std");

pub const max_blocks = 32;
pub const max_input_len = 256;
pub const max_cwd_len = 256;

pub const BlockStatus = enum {
    running,
    success,
    failed,
    interrupted,

    pub fn fromExitCode(code: u8) BlockStatus {
        if (code == 0) return .success;
        if (code == 130) return .interrupted;
        return .failed;
    }
};

pub const Block = struct {
    block_id: u64 = 0,
    group_id: u64 = 0,
    raw_input: [max_input_len]u8 = undefined,
    input_len: u8 = 0,
    cwd: [max_cwd_len]u8 = undefined,
    cwd_len: u8 = 0,
    status: BlockStatus = .running,
    exit_code: u8 = 0,
    start_ms: i64 = 0,
    duration_ms: i64 = 0,
    is_background: bool = false,
    /// Engine row where this block's output starts (set on block_started)
    output_start_row: usize = 0,
    /// Engine row where output ends (set on block_finished)
    output_end_row: usize = 0,

    pub fn inputText(self: *const Block) []const u8 {
        return self.raw_input[0..self.input_len];
    }

    pub fn cwdText(self: *const Block) []const u8 {
        return self.cwd[0..self.cwd_len];
    }
};

/// Ring buffer of recent command blocks.
pub const BlockList = struct {
    items: [max_blocks]Block = undefined,
    count: usize = 0,
    head: usize = 0,

    /// Start a new block from evt_block_started.
    pub fn start(
        self: *BlockList,
        block_id: u64,
        group_id: u64,
        raw_input: []const u8,
        cwd_str: []const u8,
        is_background: bool,
        start_row: usize,
    ) *Block {
        const idx = (self.head + self.count) % max_blocks;
        if (self.count == max_blocks) {
            self.head = (self.head + 1) % max_blocks;
        } else {
            self.count += 1;
        }

        const b = &self.items[idx];
        b.* = .{};
        b.block_id = block_id;
        b.group_id = group_id;
        b.status = .running;
        b.output_start_row = start_row;
        b.is_background = is_background;

        const ilen: u8 = @intCast(@min(raw_input.len, max_input_len));
        @memcpy(b.raw_input[0..ilen], raw_input[0..ilen]);
        b.input_len = ilen;

        const clen: u8 = @intCast(@min(cwd_str.len, max_cwd_len));
        @memcpy(b.cwd[0..clen], cwd_str[0..clen]);
        b.cwd_len = clen;

        return b;
    }

    /// Finish a block from evt_block_finished.
    pub fn finish(self: *BlockList, block_id: u64, exit_code: u8, duration_ms: i64, end_row: usize) void {
        if (self.findById(block_id)) |b| {
            b.exit_code = exit_code;
            b.duration_ms = duration_ms;
            b.status = BlockStatus.fromExitCode(exit_code);
            b.output_end_row = end_row;
        }
    }

    /// Find a block by ID.
    pub fn findById(self: *BlockList, block_id: u64) ?*Block {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.head + i) % max_blocks;
            if (self.items[idx].block_id == block_id) return &self.items[idx];
        }
        return null;
    }

    /// Find the active (running) block, if any.
    pub fn activeBlock(self: *BlockList) ?*Block {
        if (self.count == 0) return null;
        const idx = (self.head + self.count - 1) % max_blocks;
        const b = &self.items[idx];
        if (b.status == .running) return b;
        return null;
    }

    /// Iterate over all blocks (oldest first).
    pub fn iter(self: *const BlockList) Iterator {
        return .{ .list = self, .idx = 0 };
    }

    pub const Iterator = struct {
        list: *const BlockList,
        idx: usize,

        pub fn next(self: *Iterator) ?*const Block {
            if (self.idx >= self.list.count) return null;
            const ring_idx = (self.list.head + self.idx) % max_blocks;
            self.idx += 1;
            return &self.list.items[ring_idx];
        }
    };
};
