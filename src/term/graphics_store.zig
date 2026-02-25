const std = @import("std");

/// Stored image data (RGBA pixels).
pub const ImageData = struct {
    id: u32,
    width: u32,
    height: u32,
    pixels: []u8, // RGBA, owned by allocator
    ref_count: u32 = 0, // number of active placements

    pub fn deinit(self: *ImageData, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    pub fn byteSize(self: ImageData) usize {
        return self.pixels.len;
    }
};

/// An image placement on the terminal grid.
pub const Placement = struct {
    image_id: u32,
    placement_id: u32 = 0,
    row: i32 = 0,
    col: i32 = 0,
    src_x: u32 = 0,
    src_y: u32 = 0,
    src_width: u32 = 0,
    src_height: u32 = 0,
    display_cols: u32 = 0,
    display_rows: u32 = 0,
    z_index: i32 = 0,
    virtual: bool = false,
};

/// Maximum total image storage in bytes (320 MB).
const max_total_bytes: usize = 320 * 1024 * 1024;
/// Maximum active placements.
const max_placements: usize = 256;

/// Storage for images and their placements.
pub const GraphicsStore = struct {
    allocator: std.mem.Allocator,
    images: std.AutoHashMap(u32, ImageData),
    placements: std.ArrayListUnmanaged(Placement) = .{},
    total_bytes: usize = 0,
    next_id: u32 = 1,

    // Chunk reassembly state.
    chunk_buf: std.ArrayListUnmanaged(u8) = .{},
    chunk_image_id: u32 = 0,
    /// Command from the first chunk (carries dimensions, format, etc.).
    chunk_cmd: ?@import("graphics_cmd.zig").GraphicsCommand = null,

    pub fn init(allocator: std.mem.Allocator) GraphicsStore {
        return .{
            .allocator = allocator,
            .images = std.AutoHashMap(u32, ImageData).init(allocator),
        };
    }

    pub fn deinit(self: *GraphicsStore) void {
        var it = self.images.valueIterator();
        while (it.next()) |img| {
            self.allocator.free(img.pixels);
        }
        self.images.deinit();
        self.placements.deinit(self.allocator);
        self.chunk_buf.deinit(self.allocator);
    }

    /// Assign an image ID if none was provided (id == 0).
    pub fn assignId(self: *GraphicsStore, requested_id: u32) u32 {
        if (requested_id != 0) return requested_id;
        const id = self.next_id;
        self.next_id +|= 1;
        return id;
    }

    /// Store an image. If an image with the same ID exists, it is replaced.
    pub fn putImage(self: *GraphicsStore, image: ImageData) !void {
        while (self.total_bytes + image.byteSize() > max_total_bytes) {
            if (!self.evictOldest()) break;
        }

        if (self.images.fetchRemove(image.id)) |old| {
            self.total_bytes -= old.value.byteSize();
            var old_img = old.value;
            old_img.deinit(self.allocator);
        }

        try self.images.put(image.id, image);
        self.total_bytes += image.byteSize();
    }

    pub fn getImage(self: *const GraphicsStore, id: u32) ?*const ImageData {
        return self.images.getPtr(id);
    }

    /// Remove an image and all its placements.
    pub fn removeImage(self: *GraphicsStore, id: u32) void {
        self.deletePlacementsByImageId(id);
        if (self.images.fetchRemove(id)) |old| {
            self.total_bytes -= old.value.byteSize();
            var old_img = old.value;
            old_img.deinit(self.allocator);
        }
    }

    /// Add a placement. Enforces max placement limit.
    pub fn addPlacement(self: *GraphicsStore, placement: Placement) !void {
        if (self.images.getPtr(placement.image_id)) |img| {
            img.ref_count += 1;
        }
        if (self.placements.items.len >= max_placements) {
            const removed = self.placements.orderedRemove(0);
            self.decrementRef(removed.image_id);
        }
        try self.placements.append(self.allocator, placement);
    }

    /// Delete all placements for a given image ID.
    pub fn deletePlacementsByImageId(self: *GraphicsStore, image_id: u32) void {
        var i: usize = 0;
        while (i < self.placements.items.len) {
            if (self.placements.items[i].image_id == image_id) {
                _ = self.placements.orderedRemove(i);
                self.decrementRef(image_id);
            } else {
                i += 1;
            }
        }
    }

    /// Delete a specific placement by image_id and placement_id.
    pub fn deletePlacement(self: *GraphicsStore, image_id: u32, placement_id: u32) void {
        var i: usize = 0;
        while (i < self.placements.items.len) {
            const p = self.placements.items[i];
            if (p.image_id == image_id and p.placement_id == placement_id) {
                _ = self.placements.orderedRemove(i);
                self.decrementRef(image_id);
            } else {
                i += 1;
            }
        }
    }

    /// Delete all placements visible on screen.
    pub fn deleteAllVisible(self: *GraphicsStore, screen_rows: usize) void {
        var i: usize = 0;
        while (i < self.placements.items.len) {
            const p = self.placements.items[i];
            if (p.row >= 0 and @as(usize, @intCast(p.row)) < screen_rows) {
                _ = self.placements.orderedRemove(i);
                self.decrementRef(p.image_id);
            } else {
                i += 1;
            }
        }
    }

    /// Adjust placement row positions when the screen scrolls.
    pub fn scrollPlacements(self: *GraphicsStore, lines: i32) void {
        var i: usize = 0;
        while (i < self.placements.items.len) {
            self.placements.items[i].row -= lines;
            if (self.placements.items[i].row < -100) {
                const removed = self.placements.orderedRemove(i);
                self.decrementRef(removed.image_id);
            } else {
                i += 1;
            }
        }
    }

    /// Return placements visible within the given screen row range.
    pub fn visiblePlacements(
        self: *const GraphicsStore,
        screen_rows: usize,
        buf: []Placement,
    ) []Placement {
        var count: usize = 0;
        for (self.placements.items) |p| {
            if (count >= buf.len) break;
            if (p.row >= 0 and @as(usize, @intCast(p.row)) < screen_rows) {
                buf[count] = p;
                count += 1;
            }
        }
        return buf[0..count];
    }

    // -- Chunk reassembly --------------------------------------------------

    pub fn appendChunk(self: *GraphicsStore, data: []const u8) !void {
        try self.chunk_buf.appendSlice(self.allocator, data);
    }

    pub fn finalizeChunks(self: *GraphicsStore) []const u8 {
        return self.chunk_buf.items;
    }

    pub fn resetChunks(self: *GraphicsStore) void {
        self.chunk_buf.clearRetainingCapacity();
        self.chunk_image_id = 0;
        self.chunk_cmd = null;
    }

    // -- Internal ----------------------------------------------------------

    fn decrementRef(self: *GraphicsStore, image_id: u32) void {
        if (self.images.getPtr(image_id)) |img| {
            if (img.ref_count > 0) img.ref_count -= 1;
        }
    }

    fn evictOldest(self: *GraphicsStore) bool {
        var oldest_id: ?u32 = null;
        var it = self.images.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.ref_count == 0) {
                oldest_id = entry.key_ptr.*;
                break;
            }
        }
        if (oldest_id) |id| {
            self.removeImage(id);
            return true;
        }
        return false;
    }
};
