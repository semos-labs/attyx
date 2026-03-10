// Attyx — IPC command queue (lockfree ring buffer)
//
// The IPC listener thread enqueues commands; the PTY thread dequeues them.
// Same atomic ring buffer pattern as src/app/ui/input.zig.

const std = @import("std");
const posix = std.posix;

pub const max_payload = 4096;
pub const max_queued = 8;

pub const IpcCommand = struct {
    msg_type: u8,
    payload: [max_payload]u8,
    payload_len: u16,
    response_fd: posix.fd_t,
    done: i32 = 0, // set to 1 by handler when response has been written
};

var ring: [max_queued]IpcCommand = undefined;
var write_idx: u32 = 0;
var read_idx: u32 = 0;

/// Enqueue a command from the IPC listener thread.
/// Returns false if the ring is full (command dropped).
pub fn enqueue(cmd: IpcCommand) bool {
    const w = @atomicLoad(u32, &write_idx, .seq_cst);
    const r = @atomicLoad(u32, &read_idx, .seq_cst);
    if (w -% r >= max_queued) return false; // full
    ring[w % max_queued] = cmd;
    @atomicStore(u32, &write_idx, w +% 1, .seq_cst);
    return true;
}

/// Dequeue a command from the PTY thread.
/// Returns null if the ring is empty.
pub fn dequeue() ?*IpcCommand {
    const r = @atomicLoad(u32, &read_idx, .seq_cst);
    const w = @atomicLoad(u32, &write_idx, .seq_cst);
    if (r == w) return null; // empty
    const cmd = &ring[r % max_queued];
    return cmd;
}

/// Mark the current front element as consumed. Call after processing dequeue() result.
pub fn advance() void {
    const r = @atomicLoad(u32, &read_idx, .seq_cst);
    @atomicStore(u32, &read_idx, r +% 1, .seq_cst);
}

/// Returns how many commands are pending.
pub fn pending() u32 {
    const w = @atomicLoad(u32, &write_idx, .seq_cst);
    const r = @atomicLoad(u32, &read_idx, .seq_cst);
    return w -% r;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "enqueue and dequeue" {
    // Reset state
    write_idx = 0;
    read_idx = 0;

    var cmd = IpcCommand{
        .msg_type = 0x20,
        .payload = undefined,
        .payload_len = 5,
        .response_fd = -1,
    };
    @memcpy(cmd.payload[0..5], "hello");

    try std.testing.expect(enqueue(cmd));
    try std.testing.expectEqual(@as(u32, 1), pending());

    const got = dequeue().?;
    try std.testing.expectEqual(@as(u8, 0x20), got.msg_type);
    try std.testing.expectEqual(@as(u16, 5), got.payload_len);
    try std.testing.expectEqualStrings("hello", got.payload[0..5]);
    advance();

    try std.testing.expectEqual(@as(u32, 0), pending());
    try std.testing.expect(dequeue() == null);
}

test "ring full" {
    write_idx = 0;
    read_idx = 0;

    const cmd = IpcCommand{
        .msg_type = 0x20,
        .payload = undefined,
        .payload_len = 0,
        .response_fd = -1,
    };

    // Fill ring
    for (0..max_queued) |_| {
        try std.testing.expect(enqueue(cmd));
    }
    // Should reject when full
    try std.testing.expect(!enqueue(cmd));
    try std.testing.expectEqual(@as(u32, max_queued), pending());
}
