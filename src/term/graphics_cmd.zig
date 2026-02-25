const std = @import("std");

/// Kitty graphics protocol action type.
pub const GraphicsAction = enum(u8) {
    transmit_and_display = 0, // default (no 'a=' or a=T)
    transmit = 't',
    display = 'p',
    delete = 'd',
    query = 'q',
    frame = 'f',
    animate = 'a',
    compose = 'c',
};

/// Transmission medium for image data.
pub const TransmitMedium = enum(u8) {
    direct = 0, // default (no 't=' or t=d)
    file = 'f',
    temp_file = 't',
    shared_memory = 's',
};

/// Image pixel format.
pub const ImageFormat = enum(u8) {
    rgba32 = 32, // default
    rgb24 = 24,
    png = 100,
};

/// Compression scheme for the payload.
pub const Compression = enum(u8) {
    none = 0, // default
    zlib = 'z',
};

/// Target for delete operations.
pub const DeleteTarget = enum(u8) {
    all = 'a', // delete all placements on visible screen
    by_id = 'i', // delete image with specified id
    by_id_placement = 0, // delete specific placement of image (default)
    by_cursor = 'c', // delete all at cursor position
    by_cell = 'p', // delete all intersecting cell at (x, y)
    by_column = 'x', // delete all intersecting column
    by_row = 'y', // delete all intersecting row
    by_z = 'z', // delete all at z-index
    // Uppercase variants delete data + placements.
    all_data = 'A',
    by_id_data = 'I',
    by_cursor_data = 'C',
    by_cell_data = 'P',
    by_column_data = 'X',
    by_row_data = 'Y',
    by_z_data = 'Z',
};

/// Parsed Kitty graphics command with all protocol keys.
///
/// The raw APC payload has the form: `key=value,key=value,...;base64data`
/// This struct captures all recognized keys. Unrecognized keys are ignored.
pub const GraphicsCommand = struct {
    // Action
    action: GraphicsAction = .transmit_and_display,

    // Transmission
    medium: TransmitMedium = .direct,
    format: ImageFormat = .rgba32,
    compression: Compression = .none,
    more_chunks: bool = false, // m=1 means more chunks follow

    // Quiet mode: 0 = respond, 1 = suppress OK, 2 = suppress all
    quiet: u8 = 0,

    // Image identification
    image_id: u32 = 0, // i=
    image_number: u32 = 0, // I=
    placement_id: u32 = 0, // p=

    // Source image dimensions (for raw pixel data)
    src_width: u32 = 0, // s=
    src_height: u32 = 0, // v=

    // Display dimensions (in cells or pixels depending on context)
    display_width: u32 = 0, // w=
    display_height: u32 = 0, // h=

    // Source rectangle offset
    src_x: u32 = 0, // x=
    src_y: u32 = 0, // y=

    // Cell offset within the cell
    cell_x_off: u32 = 0, // X=
    cell_y_off: u32 = 0, // Y=

    // Display columns/rows
    display_cols: u32 = 0, // c=
    display_rows: u32 = 0, // r=

    // Z-index for layering
    z_index: i32 = 0, // z=

    // Cursor policy: 0 = move cursor, 1 = don't move
    cursor_policy: u8 = 0, // C=

    // Virtual placement flag
    virtual: bool = false, // U=1

    // Delete target
    delete_target: DeleteTarget = .by_id_placement, // d=

    // Offset to base64 payload within the raw command string.
    // Set by parse(); 0 means no payload.
    payload_offset: u16 = 0,
    payload_len: u16 = 0,

    /// Parse a raw APC graphics payload (after the 'G' prefix).
    /// Format: `key=value,key=value,...;base64data`
    pub fn parse(raw: []const u8) GraphicsCommand {
        var cmd = GraphicsCommand{};

        // Split control data from payload at the first ';'.
        var control_end: usize = raw.len;
        for (raw, 0..) |ch, i| {
            if (ch == ';') {
                control_end = i;
                if (i + 1 < raw.len) {
                    cmd.payload_offset = @intCast(i + 1);
                    cmd.payload_len = @intCast(raw.len - (i + 1));
                }
                break;
            }
        }

        const control = raw[0..control_end];

        // Parse comma-separated key=value pairs.
        var iter = std.mem.splitScalar(u8, control, ',');
        while (iter.next()) |pair| {
            if (pair.len < 2) continue;
            // Find '=' separator.
            const eq_pos = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (eq_pos == 0 or eq_pos + 1 >= pair.len) continue;
            const key = pair[0..eq_pos];
            const value = pair[eq_pos + 1 ..];

            if (key.len != 1) continue;
            applyKey(&cmd, key[0], value);
        }

        return cmd;
    }

    fn applyKey(cmd: *GraphicsCommand, key: u8, value: []const u8) void {
        switch (key) {
            'a' => cmd.action = parseAction(value),
            't' => cmd.medium = parseMedium(value),
            'f' => cmd.format = parseFormat(value),
            'o' => cmd.compression = parseCompression(value),
            'm' => cmd.more_chunks = parseU32(value) == 1,
            'q' => cmd.quiet = @intCast(@min(parseU32(value), 2)),
            'i' => cmd.image_id = parseU32(value),
            'I' => cmd.image_number = parseU32(value),
            'p' => cmd.placement_id = parseU32(value),
            's' => cmd.src_width = parseU32(value),
            'v' => cmd.src_height = parseU32(value),
            'w' => cmd.display_width = parseU32(value),
            'h' => cmd.display_height = parseU32(value),
            'x' => cmd.src_x = parseU32(value),
            'y' => cmd.src_y = parseU32(value),
            'X' => cmd.cell_x_off = parseU32(value),
            'Y' => cmd.cell_y_off = parseU32(value),
            'c' => cmd.display_cols = parseU32(value),
            'r' => cmd.display_rows = parseU32(value),
            'z' => cmd.z_index = parseI32(value),
            'C' => cmd.cursor_policy = @intCast(@min(parseU32(value), 1)),
            'U' => cmd.virtual = parseU32(value) == 1,
            'd' => cmd.delete_target = parseDeleteTarget(value),
            else => {},
        }
    }

    fn parseAction(value: []const u8) GraphicsAction {
        if (value.len != 1) return .transmit_and_display;
        return switch (value[0]) {
            'T' => .transmit_and_display,
            't' => .transmit,
            'p' => .display,
            'd' => .delete,
            'q' => .query,
            'f' => .frame,
            'a' => .animate,
            'c' => .compose,
            else => .transmit_and_display,
        };
    }

    fn parseMedium(value: []const u8) TransmitMedium {
        if (value.len != 1) return .direct;
        return switch (value[0]) {
            'd' => .direct,
            'f' => .file,
            't' => .temp_file,
            's' => .shared_memory,
            else => .direct,
        };
    }

    fn parseFormat(value: []const u8) ImageFormat {
        const n = parseU32(value);
        return switch (n) {
            24 => .rgb24,
            32 => .rgba32,
            100 => .png,
            else => .rgba32,
        };
    }

    fn parseCompression(value: []const u8) Compression {
        if (value.len != 1) return .none;
        return switch (value[0]) {
            'z' => .zlib,
            else => .none,
        };
    }

    fn parseDeleteTarget(value: []const u8) DeleteTarget {
        if (value.len != 1) return .by_id_placement;
        return switch (value[0]) {
            'a' => .all,
            'i' => .by_id,
            'c' => .by_cursor,
            'p' => .by_cell,
            'x' => .by_column,
            'y' => .by_row,
            'z' => .by_z,
            'A' => .all_data,
            'I' => .by_id_data,
            'C' => .by_cursor_data,
            'P' => .by_cell_data,
            'X' => .by_column_data,
            'Y' => .by_row_data,
            'Z' => .by_z_data,
            else => .by_id_placement,
        };
    }

    fn parseU32(value: []const u8) u32 {
        return std.fmt.parseInt(u32, value, 10) catch 0;
    }

    fn parseI32(value: []const u8) i32 {
        return std.fmt.parseInt(i32, value, 10) catch 0;
    }
};
