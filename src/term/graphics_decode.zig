const std = @import("std");
const graphics_cmd = @import("graphics_cmd.zig");

const stb = @cImport({
    @cInclude("stb_image.h");
});

const zlib = if (@import("builtin").os.tag != .windows) @cImport({
    @cInclude("zlib.h");
}) else struct {};

const jebp = @cImport({
    @cInclude("jebp.h");
});

pub const DecodeError = error{
    InvalidBase64,
    DecompressFailed,
    InvalidPng,
    InvalidDimensions,
    OutOfMemory,
};

/// Decoded image result.
pub const DecodedImage = struct {
    pixels: []u8, // RGBA pixel data
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DecodedImage) void {
        self.allocator.free(self.pixels);
    }
};

/// Decode base64-encoded image payload according to the command parameters.
pub fn decode(
    allocator: std.mem.Allocator,
    payload: []const u8,
    cmd: graphics_cmd.GraphicsCommand,
) DecodeError!DecodedImage {
    // Step 1: Base64 decode
    const raw_data = decodeBase64(allocator, payload) catch return error.InvalidBase64;
    defer allocator.free(raw_data);

    // Step 2: Decompress if needed
    const data = if (cmd.compression == .zlib)
        decompressZlib(allocator, raw_data) catch return error.DecompressFailed
    else
        allocator.dupe(u8, raw_data) catch return error.OutOfMemory;
    defer allocator.free(data);

    // Step 3: Decode based on format.
    // If format is png (f=100), use stb_image which auto-detects PNG/JPEG/GIF/BMP/WebP.
    // For raw formats, first check if the data looks like a compressed image file
    // (some apps omit f=100 when sending JPEG/PNG data).
    return switch (cmd.format) {
        .png => decodePng(allocator, data),
        .rgb24 => if (looksLikeImageFile(data))
            decodePng(allocator, data)
        else
            decodeRgb24(allocator, data, cmd.src_width, cmd.src_height),
        .rgba32 => if (looksLikeImageFile(data))
            decodePng(allocator, data)
        else
            decodeRgba32(allocator, data, cmd.src_width, cmd.src_height),
    };
}

/// Check if data starts with a known image file magic signature.
/// Detects PNG, JPEG, GIF, BMP, WebP so we can auto-detect format even
/// when the sender omits f=100.
fn looksLikeImageFile(data: []const u8) bool {
    if (data.len < 8) return false;
    // PNG: 89 50 4E 47
    if (data[0] == 0x89 and data[1] == 'P' and data[2] == 'N' and data[3] == 'G') return true;
    // JPEG: FF D8 FF
    if (data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF) return true;
    // GIF: "GIF8"
    if (std.mem.startsWith(u8, data, "GIF8")) return true;
    // BMP: "BM"
    if (data[0] == 'B' and data[1] == 'M') return true;
    // WebP: "RIFF" ... "WEBP"
    if (std.mem.startsWith(u8, data, "RIFF") and data.len >= 12 and
        data[8] == 'W' and data[9] == 'E' and data[10] == 'B' and data[11] == 'P') return true;
    return false;
}

fn decodeBase64(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(encoded) catch return error.InvalidCharacter;
    const buf = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(buf);
    decoder.decode(buf, encoded) catch {
        allocator.free(buf);
        return error.InvalidCharacter;
    };
    return buf;
}

fn decompressZlib(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (comptime @import("builtin").os.tag == .windows)
        return error.InvalidCharacter;

    // Start with 4x the input size as initial estimate, grow if needed.
    var out_len: usize = data.len * 4;
    const max_out: usize = 256 * 1024 * 1024; // 256 MB safety limit

    while (out_len <= max_out) {
        const buf = allocator.alloc(u8, out_len) catch return error.OutOfMemory;
        var dest_len: zlib.uLongf = @intCast(out_len);
        const rc = zlib.uncompress(buf.ptr, &dest_len, data.ptr, @intCast(data.len));
        if (rc == zlib.Z_OK) {
            // Shrink to actual size.
            if (dest_len < out_len) {
                const result = allocator.realloc(buf, @intCast(dest_len)) catch {
                    // realloc failed, just return the oversized buffer
                    return buf[0..@intCast(dest_len)];
                };
                return result[0..@intCast(dest_len)];
            }
            return buf;
        } else if (rc == zlib.Z_BUF_ERROR) {
            // Output buffer too small, double and retry.
            allocator.free(buf);
            out_len *= 2;
        } else {
            allocator.free(buf);
            return error.InvalidCharacter;
        }
    }
    return error.InvalidCharacter;
}

/// Decode an image file (PNG, JPEG, GIF, BMP, or WebP).
/// stb_image handles PNG/JPEG/GIF/BMP; jebp handles lossless WebP.
fn decodePng(allocator: std.mem.Allocator, data: []const u8) DecodeError!DecodedImage {
    // Try stb_image first (handles PNG, JPEG, GIF, BMP, TGA, PSD, PNM).
    var w: c_int = 0;
    var h: c_int = 0;
    var channels: c_int = 0;

    const result = stb.stbi_load_from_memory(
        data.ptr,
        @intCast(data.len),
        &w,
        &h,
        &channels,
        4, // force RGBA output
    );
    if (result != null) {
        defer stb.stbi_image_free(result);

        if (w <= 0 or h <= 0) return error.InvalidDimensions;
        const width: u32 = @intCast(w);
        const height: u32 = @intCast(h);
        const byte_len = @as(usize, width) * @as(usize, height) * 4;

        const pixels = allocator.alloc(u8, byte_len) catch return error.OutOfMemory;
        @memcpy(pixels, result[0..byte_len]);

        return .{
            .pixels = pixels,
            .width = width,
            .height = height,
            .allocator = allocator,
        };
    }

    // stb_image failed — try WebP via jebp (supports VP8L lossless WebP).
    return decodeWebp(allocator, data);
}

fn decodeWebp(allocator: std.mem.Allocator, data: []const u8) DecodeError!DecodedImage {
    var image: jebp.jebp_image_t = undefined;
    const err = jebp.jebp_decode(&image, data.len, data.ptr);
    if (err != jebp.JEBP_OK) return error.InvalidPng;
    defer jebp.jebp_free_image(&image);

    const width: u32 = @intCast(image.width);
    const height: u32 = @intCast(image.height);
    if (width == 0 or height == 0) return error.InvalidDimensions;
    const byte_len = @as(usize, width) * @as(usize, height) * 4;

    const pixels = allocator.alloc(u8, byte_len) catch return error.OutOfMemory;
    const src: [*]const u8 = @ptrCast(image.pixels);
    @memcpy(pixels, src[0..byte_len]);

    return .{
        .pixels = pixels,
        .width = width,
        .height = height,
        .allocator = allocator,
    };
}

fn decodeRgb24(
    allocator: std.mem.Allocator,
    data: []const u8,
    width: u32,
    height: u32,
) DecodeError!DecodedImage {
    if (width == 0 or height == 0) return error.InvalidDimensions;
    const expected = @as(usize, width) * @as(usize, height) * 3;
    if (data.len < expected) return error.InvalidDimensions;

    const pixel_count = @as(usize, width) * @as(usize, height);
    const rgba = allocator.alloc(u8, pixel_count * 4) catch return error.OutOfMemory;
    errdefer allocator.free(rgba);

    for (0..pixel_count) |i| {
        rgba[i * 4 + 0] = data[i * 3 + 0];
        rgba[i * 4 + 1] = data[i * 3 + 1];
        rgba[i * 4 + 2] = data[i * 3 + 2];
        rgba[i * 4 + 3] = 255;
    }

    return .{
        .pixels = rgba,
        .width = width,
        .height = height,
        .allocator = allocator,
    };
}

// ===========================================================================
// Tests
// ===========================================================================

test "looksLikeImageFile: PNG signature" {
    const png = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    try std.testing.expect(looksLikeImageFile(&png));
}

test "looksLikeImageFile: JPEG signature" {
    const jpeg = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0 };
    try std.testing.expect(looksLikeImageFile(&jpeg));
}

test "looksLikeImageFile: GIF signature" {
    try std.testing.expect(looksLikeImageFile("GIF89a\x00\x00"));
}

test "looksLikeImageFile: BMP signature" {
    try std.testing.expect(looksLikeImageFile("BM\x00\x00\x00\x00\x00\x00"));
}

test "looksLikeImageFile: WebP signature" {
    try std.testing.expect(looksLikeImageFile("RIFF\x00\x00\x00\x00WEBP"));
}

test "looksLikeImageFile: short data returns false" {
    try std.testing.expect(!looksLikeImageFile("PNG"));
}

test "looksLikeImageFile: random data returns false" {
    try std.testing.expect(!looksLikeImageFile("\x00\x01\x02\x03\x04\x05\x06\x07"));
}

test "decodeRgb24: valid RGB converts to RGBA" {
    const alloc = std.testing.allocator;
    // 2x1 image: pixel(255,0,0), pixel(0,255,0)
    const data = [_]u8{ 255, 0, 0, 0, 255, 0 };
    var img = try decodeRgb24(alloc, &data, 2, 1);
    defer img.deinit();

    try std.testing.expectEqual(@as(u32, 2), img.width);
    try std.testing.expectEqual(@as(u32, 1), img.height);
    // Pixel 0: R=255 G=0 B=0 A=255
    try std.testing.expectEqual(@as(u8, 255), img.pixels[0]);
    try std.testing.expectEqual(@as(u8, 0), img.pixels[1]);
    try std.testing.expectEqual(@as(u8, 0), img.pixels[2]);
    try std.testing.expectEqual(@as(u8, 255), img.pixels[3]);
    // Pixel 1: R=0 G=255 B=0 A=255
    try std.testing.expectEqual(@as(u8, 0), img.pixels[4]);
    try std.testing.expectEqual(@as(u8, 255), img.pixels[5]);
    try std.testing.expectEqual(@as(u8, 255), img.pixels[7]);
}

test "decodeRgb24: zero dims returns error" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidDimensions, decodeRgb24(alloc, "", 0, 0));
    try std.testing.expectError(error.InvalidDimensions, decodeRgb24(alloc, "", 1, 0));
    try std.testing.expectError(error.InvalidDimensions, decodeRgb24(alloc, "", 0, 1));
}

test "decodeRgb24: truncated data returns error" {
    const alloc = std.testing.allocator;
    const data = [_]u8{ 255, 0 }; // need 3 bytes for 1x1
    try std.testing.expectError(error.InvalidDimensions, decodeRgb24(alloc, &data, 1, 1));
}

test "decodeRgba32: valid copy" {
    const alloc = std.testing.allocator;
    const data = [_]u8{ 10, 20, 30, 40, 50, 60, 70, 80 }; // 2x1 RGBA
    var img = try decodeRgba32(alloc, &data, 2, 1);
    defer img.deinit();

    try std.testing.expectEqual(@as(u32, 2), img.width);
    try std.testing.expectEqual(@as(u32, 1), img.height);
    try std.testing.expectEqualSlices(u8, &data, img.pixels);
}

test "decodeRgba32: zero dims returns error" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidDimensions, decodeRgba32(alloc, "", 0, 0));
}

test "decodeRgba32: truncated data returns error" {
    const alloc = std.testing.allocator;
    const data = [_]u8{ 1, 2, 3 }; // need 4 bytes for 1x1
    try std.testing.expectError(error.InvalidDimensions, decodeRgba32(alloc, &data, 1, 1));
}

test "decodeBase64: valid round-trip" {
    const alloc = std.testing.allocator;
    // "Hello" = "SGVsbG8="
    const decoded = try decodeBase64(alloc, "SGVsbG8=");
    defer alloc.free(decoded);
    try std.testing.expectEqualStrings("Hello", decoded);
}

test "decodeBase64: invalid chars returns error" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidCharacter, decodeBase64(alloc, "!!!"));
}

fn decodeRgba32(
    allocator: std.mem.Allocator,
    data: []const u8,
    width: u32,
    height: u32,
) DecodeError!DecodedImage {
    if (width == 0 or height == 0) return error.InvalidDimensions;
    const expected = @as(usize, width) * @as(usize, height) * 4;
    if (data.len < expected) return error.InvalidDimensions;

    const pixels = allocator.dupe(u8, data[0..expected]) catch return error.OutOfMemory;
    return .{
        .pixels = pixels,
        .width = width,
        .height = height,
        .allocator = allocator,
    };
}
