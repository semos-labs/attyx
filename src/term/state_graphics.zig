const std = @import("std");
const TerminalState = @import("state.zig").TerminalState;
const graphics_cmd = @import("graphics_cmd.zig");
const graphics_decode = @import("graphics_decode.zig");
const graphics_store = @import("graphics_store.zig");

const GraphicsCommand = graphics_cmd.GraphicsCommand;
const GraphicsStore = graphics_store.GraphicsStore;
const ImageData = graphics_store.ImageData;
const Placement = graphics_store.Placement;

// Metal renderer now supports image textures. Enable protocol responses so
// applications detect graphics support via query (a=q) responses.
const responses_enabled = true;

// Debug logging to file (temporary)
fn dbgLog(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    const file = std.posix.open("/tmp/attyx_gfx_debug.log", .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644) catch return;
    defer std.posix.close(file);
    _ = std.posix.write(file, msg) catch {};
}

/// Handle a parsed graphics command dispatched by the parser.
pub fn handleGraphicsCommand(self: *TerminalState, raw: []const u8) void {
    const cmd = GraphicsCommand.parse(raw);

    dbgLog("[attyx:gfx] action={d} id={d} more={} fmt={d} payload_len={d} cursor=({d},{d})", .{
        @intFromEnum(cmd.action), cmd.image_id, cmd.more_chunks,
        @intFromEnum(cmd.format), cmd.payload_len,
        self.cursor.row, self.cursor.col,
    });

    switch (cmd.action) {
        .query => handleQuery(self, cmd, raw),
        .transmit_and_display => handleTransmitAndDisplay(self, cmd, raw),
        .transmit => handleTransmit(self, cmd, raw),
        .display => handleDisplay(self, cmd),
        .delete => handleDelete(self, cmd),
        else => {},
    }
}

fn handleQuery(self: *TerminalState, cmd: GraphicsCommand, raw: []const u8) void {
    const store = self.graphics_store orelse return;
    const id = store.assignId(cmd.image_id);

    if (!responses_enabled) return;

    const payload = getPayload(cmd, raw) orelse {
        respondOk(self, cmd, id);
        return;
    };

    const alloc = self.grid.allocator;
    var decoded = graphics_decode.decode(alloc, payload, cmd) catch |err| {
        respondDecodeError(self, cmd, id, err);
        return;
    };
    decoded.deinit();

    respondOk(self, cmd, id);
}

fn handleTransmitAndDisplay(self: *TerminalState, cmd: GraphicsCommand, raw: []const u8) void {
    const store = self.graphics_store orelse {
        dbgLog("[attyx:gfx] T+D: no graphics_store!", .{});
        return;
    };
    const alloc = self.grid.allocator;

    const effective_cmd = store.chunk_cmd orelse cmd;
    const id = store.assignId(effective_cmd.image_id);

    // Intermediate chunk — accumulate data, never respond.
    if (cmd.more_chunks) {
        dbgLog("[attyx:gfx] T+D: chunk accumulate, id={d}, chunk_buf_len={d}", .{ id, store.chunk_buf.items.len });
        startOrContinueChunk(store, cmd, id, raw);
        return;
    }

    // Final chunk or single transmission.
    const payload = finalizePayload(store, cmd, raw) orelse {
        dbgLog("[attyx:gfx] T+D: no payload!", .{});
        if (responses_enabled) respondError(self, effective_cmd, "EINVAL:no payload");
        return;
    };

    dbgLog("[attyx:gfx] T+D: decoding, payload_len={d}, format={d}", .{ payload.len, @intFromEnum(effective_cmd.format) });

    var decoded = graphics_decode.decode(alloc, payload, effective_cmd) catch |err| {
        dbgLog("[attyx:gfx] T+D: decode FAILED: {s}", .{@errorName(err)});
        store.resetChunks();
        if (responses_enabled) respondDecodeError(self, effective_cmd, id, err);
        return;
    };

    store.resetChunks();

    dbgLog("[attyx:gfx] T+D: decoded OK, {d}x{d}, {d} bytes", .{ decoded.width, decoded.height, decoded.pixels.len });

    const image = ImageData{
        .id = id,
        .width = decoded.width,
        .height = decoded.height,
        .pixels = decoded.pixels,
    };
    store.putImage(image) catch {
        decoded.deinit();
        dbgLog("[attyx:gfx] T+D: putImage FAILED (OOM)", .{});
        if (responses_enabled) respondError(self, effective_cmd, "ENOMEM:store");
        return;
    };

    const placement = Placement{
        .image_id = id,
        .placement_id = effective_cmd.placement_id,
        .row = @intCast(self.cursor.row),
        .col = @intCast(self.cursor.col),
        .src_x = effective_cmd.src_x,
        .src_y = effective_cmd.src_y,
        .src_width = effective_cmd.display_width,
        .src_height = effective_cmd.display_height,
        .display_cols = effective_cmd.display_cols,
        .display_rows = effective_cmd.display_rows,
        .z_index = effective_cmd.z_index,
        .virtual = effective_cmd.virtual,
    };

    store.addPlacement(placement) catch {
        dbgLog("[attyx:gfx] T+D: addPlacement FAILED (OOM)", .{});
        if (responses_enabled) respondError(self, effective_cmd, "ENOMEM:placement");
        return;
    };

    dbgLog("[attyx:gfx] T+D: SUCCESS id={d} at ({d},{d}) cols={d} rows={d} total_placements={d}", .{
        id, self.cursor.row, self.cursor.col,
        effective_cmd.display_cols, effective_cmd.display_rows,
        store.placements.items.len,
    });

    if (responses_enabled) respondOk(self, effective_cmd, id);
}

fn handleTransmit(self: *TerminalState, cmd: GraphicsCommand, raw: []const u8) void {
    const store = self.graphics_store orelse return;
    const alloc = self.grid.allocator;

    const effective_cmd = store.chunk_cmd orelse cmd;
    const id = store.assignId(effective_cmd.image_id);

    // Intermediate chunk — accumulate data, never respond.
    if (cmd.more_chunks) {
        startOrContinueChunk(store, cmd, id, raw);
        return;
    }

    const payload = finalizePayload(store, cmd, raw) orelse {
        if (responses_enabled) respondError(self, effective_cmd, "EINVAL:no payload");
        return;
    };

    var decoded = graphics_decode.decode(alloc, payload, effective_cmd) catch |err| {
        store.resetChunks();
        if (responses_enabled) respondDecodeError(self, effective_cmd, id, err);
        return;
    };

    store.resetChunks();

    const image = ImageData{
        .id = id,
        .width = decoded.width,
        .height = decoded.height,
        .pixels = decoded.pixels,
    };

    store.putImage(image) catch {
        decoded.deinit();
        if (responses_enabled) respondError(self, effective_cmd, "ENOMEM:store");
        return;
    };

    if (responses_enabled) respondOk(self, effective_cmd, id);
}

fn handleDisplay(self: *TerminalState, cmd: GraphicsCommand) void {
    const store = self.graphics_store orelse return;

    if (cmd.image_id == 0) return;
    if (store.getImage(cmd.image_id) == null) return;

    const placement = Placement{
        .image_id = cmd.image_id,
        .placement_id = cmd.placement_id,
        .row = @intCast(self.cursor.row),
        .col = @intCast(self.cursor.col),
        .src_x = cmd.src_x,
        .src_y = cmd.src_y,
        .src_width = cmd.display_width,
        .src_height = cmd.display_height,
        .display_cols = cmd.display_cols,
        .display_rows = cmd.display_rows,
        .z_index = cmd.z_index,
        .virtual = cmd.virtual,
    };

    store.addPlacement(placement) catch return;
}

fn handleDelete(self: *TerminalState, cmd: GraphicsCommand) void {
    const store = self.graphics_store orelse return;

    switch (cmd.delete_target) {
        .all => store.deleteAllVisible(self.grid.rows),
        .all_data => store.deleteAllVisible(self.grid.rows),
        .by_id => store.deletePlacementsByImageId(cmd.image_id),
        .by_id_data => store.removeImage(cmd.image_id),
        .by_id_placement => {
            if (cmd.placement_id != 0) {
                store.deletePlacement(cmd.image_id, cmd.placement_id);
            } else {
                store.deletePlacementsByImageId(cmd.image_id);
            }
        },
        else => {},
    }
}

// -- Chunked transmission helpers ------------------------------------------

fn startOrContinueChunk(store: *GraphicsStore, cmd: GraphicsCommand, id: u32, raw: []const u8) void {
    if (store.chunk_image_id == 0) {
        store.chunk_image_id = id;
        store.chunk_cmd = cmd;
    }
    if (getPayload(cmd, raw)) |payload| {
        store.appendChunk(payload) catch {};
    }
}

fn finalizePayload(store: *GraphicsStore, cmd: GraphicsCommand, raw: []const u8) ?[]const u8 {
    if (store.chunk_buf.items.len > 0) {
        if (getPayload(cmd, raw)) |p| {
            store.appendChunk(p) catch {};
        }
        return store.finalizeChunks();
    }
    return getPayload(cmd, raw);
}

// -- Response helpers ------------------------------------------------------

fn getPayload(cmd: GraphicsCommand, raw: []const u8) ?[]const u8 {
    if (cmd.payload_len == 0) return null;
    const start = cmd.payload_offset;
    const end = start + cmd.payload_len;
    if (end > raw.len) return null;
    return raw[start..end];
}

fn respondOk(self: *TerminalState, cmd: GraphicsCommand, id: u32) void {
    if (cmd.quiet >= 1) return;
    respondFmt(self, id, "OK");
}

fn respondError(self: *TerminalState, cmd: GraphicsCommand, msg: []const u8) void {
    if (cmd.quiet >= 2) return;
    respondFmt(self, if (cmd.image_id != 0) cmd.image_id else 0, msg);
}

fn respondDecodeError(self: *TerminalState, cmd: GraphicsCommand, id: u32, err: graphics_decode.DecodeError) void {
    if (cmd.quiet >= 2) return;
    const msg = switch (err) {
        error.InvalidBase64 => "EINVAL:invalid base64",
        error.DecompressFailed => "EINVAL:decompress failed",
        error.InvalidPng => "EINVAL:invalid PNG",
        error.InvalidDimensions => "EINVAL:invalid dimensions",
        error.OutOfMemory => "ENOMEM:out of memory",
    };
    respondFmt(self, id, msg);
}

fn respondFmt(self: *TerminalState, id: u32, msg: []const u8) void {
    var buf: [256]u8 = undefined;
    const resp = std.fmt.bufPrint(&buf, "\x1b_Gi={d};{s}\x1b\\", .{ id, msg }) catch return;
    self.appendResponse(resp);
}
