const std = @import("std");
const GraphicsStore = @import("../../term/graphics_store.zig").GraphicsStore;
const ImageData = @import("../../term/graphics_store.zig").ImageData;
const Placement = @import("../../term/graphics_store.zig").Placement;

// ===========================================================================
// GraphicsStore tests
// ===========================================================================

fn makeTestImage(alloc: std.mem.Allocator, id: u32) !ImageData {
    const pixels = try alloc.alloc(u8, 16); // 2x2 RGBA
    @memset(pixels, 0xFF);
    return .{ .id = id, .width = 2, .height = 2, .pixels = pixels };
}

test "graphics_store: put and get image" {
    const alloc = std.testing.allocator;
    var store = GraphicsStore.init(alloc);
    defer store.deinit();

    const img = try makeTestImage(alloc, 1);
    try store.putImage(img);

    const got = store.getImage(1);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(got.?.width, 2);
    try std.testing.expectEqual(got.?.height, 2);
}

test "graphics_store: remove image" {
    const alloc = std.testing.allocator;
    var store = GraphicsStore.init(alloc);
    defer store.deinit();

    const img = try makeTestImage(alloc, 1);
    try store.putImage(img);
    store.removeImage(1);

    try std.testing.expect(store.getImage(1) == null);
}

test "graphics_store: replace image with same id" {
    const alloc = std.testing.allocator;
    var store = GraphicsStore.init(alloc);
    defer store.deinit();

    const img1 = try makeTestImage(alloc, 1);
    try store.putImage(img1);

    // Create a different-sized image with same id.
    const pixels2 = try alloc.alloc(u8, 36); // 3x3 RGBA
    @memset(pixels2, 0xAA);
    const img2 = ImageData{ .id = 1, .width = 3, .height = 3, .pixels = pixels2 };
    try store.putImage(img2);

    const got = store.getImage(1);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(got.?.width, 3);
}

test "graphics_store: add and delete placement" {
    const alloc = std.testing.allocator;
    var store = GraphicsStore.init(alloc);
    defer store.deinit();

    const img = try makeTestImage(alloc, 1);
    try store.putImage(img);

    try store.addPlacement(.{ .image_id = 1, .placement_id = 10, .row = 0, .col = 0 });
    try std.testing.expectEqual(store.placements.items.len, 1);

    store.deletePlacement(1, 10);
    try std.testing.expectEqual(store.placements.items.len, 0);
}

test "graphics_store: delete placements by image id" {
    const alloc = std.testing.allocator;
    var store = GraphicsStore.init(alloc);
    defer store.deinit();

    const img = try makeTestImage(alloc, 1);
    try store.putImage(img);

    try store.addPlacement(.{ .image_id = 1, .placement_id = 1, .row = 0, .col = 0 });
    try store.addPlacement(.{ .image_id = 1, .placement_id = 2, .row = 1, .col = 0 });
    try std.testing.expectEqual(store.placements.items.len, 2);

    store.deletePlacementsByImageId(1);
    try std.testing.expectEqual(store.placements.items.len, 0);
}

test "graphics_store: scroll placements" {
    const alloc = std.testing.allocator;
    var store = GraphicsStore.init(alloc);
    defer store.deinit();

    const img = try makeTestImage(alloc, 1);
    try store.putImage(img);

    try store.addPlacement(.{ .image_id = 1, .row = 5, .col = 0 });
    try store.addPlacement(.{ .image_id = 1, .row = 10, .col = 0 });

    store.scrollPlacements(3);

    try std.testing.expectEqual(store.placements.items.len, 2);
    try std.testing.expectEqual(store.placements.items[0].row, 2);
    try std.testing.expectEqual(store.placements.items[1].row, 7);
}

test "graphics_store: scroll removes off-screen placements" {
    const alloc = std.testing.allocator;
    var store = GraphicsStore.init(alloc);
    defer store.deinit();

    const img = try makeTestImage(alloc, 1);
    try store.putImage(img);

    try store.addPlacement(.{ .image_id = 1, .row = 2, .col = 0 });
    // Scroll enough to push it way off-screen.
    store.scrollPlacements(200);

    try std.testing.expectEqual(store.placements.items.len, 0);
}

test "graphics_store: chunk reassembly" {
    const alloc = std.testing.allocator;
    var store = GraphicsStore.init(alloc);
    defer store.deinit();

    try store.appendChunk("AAAA");
    try store.appendChunk("BBBB");
    try store.appendChunk("CCCC");

    const data = store.finalizeChunks();
    try std.testing.expectEqualStrings("AAAABBBBCCCC", data);

    store.resetChunks();
    try std.testing.expectEqual(store.chunk_buf.items.len, 0);
}

test "graphics_store: assign id auto-increments" {
    const alloc = std.testing.allocator;
    var store = GraphicsStore.init(alloc);
    defer store.deinit();

    const id1 = store.assignId(0);
    const id2 = store.assignId(0);
    try std.testing.expect(id1 != id2);

    // Explicit ID is returned as-is.
    const id3 = store.assignId(42);
    try std.testing.expectEqual(id3, 42);
}

test "graphics_store: visible placements filter" {
    const alloc = std.testing.allocator;
    var store = GraphicsStore.init(alloc);
    defer store.deinit();

    const img = try makeTestImage(alloc, 1);
    try store.putImage(img);

    try store.addPlacement(.{ .image_id = 1, .row = 0, .col = 0 });
    try store.addPlacement(.{ .image_id = 1, .row = 5, .col = 0 });
    try store.addPlacement(.{ .image_id = 1, .row = -1, .col = 0 }); // off-screen

    var buf: [10]Placement = undefined;
    const visible = store.visiblePlacements(24, &buf);
    try std.testing.expectEqual(visible.len, 2);
}
