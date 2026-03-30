/// Layout codec — serialize/deserialize tab+split structure for the layout blob.
/// Compact binary format stored on the daemon and restored on session switch.
///
/// The base body intentionally stays compatible with the legacy v1 layout
/// reader. Newer metadata is stored in an optional trailer appended after the
/// legacy body so older binaries can still read the structural layout and raw
/// tab titles without understanding explicit-vs-hint semantics.
const std = @import("std");

pub const max_tabs = 16;
pub const max_nodes_per_tab = 15;
pub const title_flag_explicit: u8 = 0x01;
const title_trailer_magic = "ttl2";
const title_trailer_version: u8 = 1;
const title_trailer_header_len: usize = title_trailer_magic.len + 2;

pub const NodeTag = enum(u8) { leaf = 0, branch = 1 };
pub const SplitDirection = enum(u8) { vertical = 0, horizontal = 1 };

pub const LayoutNode = struct {
    tag: NodeTag,
    // Leaf fields
    pane_id: u32 = 0,
    // Branch fields
    direction: SplitDirection = .vertical,
    ratio_x100: u16 = 50,
    child_left: u8 = 0,
    child_right: u8 = 0,
};

pub const max_title_len = 128;

pub const TabLayout = struct {
    node_count: u8 = 0,
    root_idx: u8 = 0,
    focused_idx: u8 = 0,
    title_len: u8 = 0,
    title_flags: u8 = 0,
    title: [max_title_len]u8 = undefined,
    nodes: [max_nodes_per_tab]LayoutNode = undefined,

    pub fn getTitle(self: *const TabLayout) ?[]const u8 {
        if (self.title_len == 0) return null;
        return self.title[0..self.title_len];
    }

    pub fn isExplicitTitle(self: *const TabLayout) bool {
        return (self.title_flags & title_flag_explicit) != 0;
    }
};

const empty_tab_layout = TabLayout{
    .title = undefined,
    .nodes = undefined,
};

pub const LayoutInfo = struct {
    tab_count: u8 = 0,
    active_tab: u8 = 0,
    focused_pane_id: u32 = 0,
    tabs: [max_tabs]TabLayout = [_]TabLayout{empty_tab_layout} ** max_tabs,
};

fn hasTitleTrailer(info: *const LayoutInfo) bool {
    for (0..info.tab_count) |ti| {
        if (info.tabs[ti].title_flags != 0) return true;
    }
    return false;
}

/// Serialize a LayoutInfo into a binary blob. Returns number of bytes written.
pub fn serialize(info: *const LayoutInfo, buf: []u8) !u16 {
    var pos: usize = 0;

    // Header: tab_count(u8), active_tab(u8), focused_pane_id(u32)
    if (buf.len < 6) return error.BufferTooSmall;
    buf[pos] = info.tab_count;
    pos += 1;
    buf[pos] = info.active_tab;
    pos += 1;
    std.mem.writeInt(u32, buf[pos..][0..4], info.focused_pane_id, .little);
    pos += 4;

    // Per tab
    for (0..info.tab_count) |ti| {
        const tab = &info.tabs[ti];
        // Legacy-compatible tab header:
        // node_count(u8), root_idx(u8), focused_idx(u8), title_len(u8), title(...)
        if (pos + 4 > buf.len) return error.BufferTooSmall;
        buf[pos] = tab.node_count;
        pos += 1;
        buf[pos] = tab.root_idx;
        pos += 1;
        buf[pos] = tab.focused_idx;
        pos += 1;
        buf[pos] = tab.title_len;
        pos += 1;
        if (tab.title_len > 0) {
            if (pos + tab.title_len > buf.len) return error.BufferTooSmall;
            @memcpy(buf[pos..][0..tab.title_len], tab.title[0..tab.title_len]);
            pos += tab.title_len;
        }

        // Per node
        for (0..tab.node_count) |ni| {
            const node = &tab.nodes[ni];
            if (pos + 1 > buf.len) return error.BufferTooSmall;
            buf[pos] = @intFromEnum(node.tag);
            pos += 1;
            switch (node.tag) {
                .leaf => {
                    if (pos + 4 > buf.len) return error.BufferTooSmall;
                    std.mem.writeInt(u32, buf[pos..][0..4], node.pane_id, .little);
                    pos += 4;
                },
                .branch => {
                    if (pos + 5 > buf.len) return error.BufferTooSmall;
                    buf[pos] = @intFromEnum(node.direction);
                    pos += 1;
                    std.mem.writeInt(u16, buf[pos..][0..2], node.ratio_x100, .little);
                    pos += 2;
                    buf[pos] = node.child_left;
                    pos += 1;
                    buf[pos] = node.child_right;
                    pos += 1;
                },
            }
        }
    }

    if (hasTitleTrailer(info)) {
        if (pos + title_trailer_header_len + info.tab_count > buf.len) return error.BufferTooSmall;
        @memcpy(buf[pos..][0..title_trailer_magic.len], title_trailer_magic);
        pos += title_trailer_magic.len;
        buf[pos] = title_trailer_version;
        pos += 1;
        buf[pos] = info.tab_count;
        pos += 1;
        for (0..info.tab_count) |ti| {
            buf[pos] = info.tabs[ti].title_flags;
            pos += 1;
        }
    }

    return @intCast(pos);
}

/// Deserialize a binary blob into a LayoutInfo.
pub fn deserialize(data: []const u8) !LayoutInfo {
    var info = LayoutInfo{};
    if (data.len < 6) return error.DataTooShort;

    var pos: usize = 0;
    info.tab_count = data[pos];
    pos += 1;
    info.active_tab = data[pos];
    pos += 1;
    info.focused_pane_id = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;

    if (info.tab_count > max_tabs) return error.TooManyTabs;

    for (0..info.tab_count) |ti| {
        if (pos + 4 > data.len) return error.DataTooShort;
        var tab = &info.tabs[ti];
        tab.node_count = data[pos];
        pos += 1;
        tab.root_idx = data[pos];
        pos += 1;
        tab.focused_idx = data[pos];
        pos += 1;
        tab.title_len = data[pos];
        pos += 1;
        tab.title_flags = 0;
        if (tab.title_len > max_title_len) return error.TitleTooLong;
        if (tab.title_len > 0) {
            if (pos + tab.title_len > data.len) return error.DataTooShort;
            @memcpy(tab.title[0..tab.title_len], data[pos..][0..tab.title_len]);
            pos += tab.title_len;
        }

        if (tab.node_count > max_nodes_per_tab) return error.TooManyNodes;

        for (0..tab.node_count) |ni| {
            if (pos + 1 > data.len) return error.DataTooShort;
            const tag_raw = data[pos];
            pos += 1;
            const tag: NodeTag = std.meta.intToEnum(NodeTag, tag_raw) catch return error.InvalidTag;
            tab.nodes[ni].tag = tag;
            switch (tag) {
                .leaf => {
                    if (pos + 4 > data.len) return error.DataTooShort;
                    tab.nodes[ni].pane_id = std.mem.readInt(u32, data[pos..][0..4], .little);
                    pos += 4;
                },
                .branch => {
                    if (pos + 5 > data.len) return error.DataTooShort;
                    tab.nodes[ni].direction = std.meta.intToEnum(SplitDirection, data[pos]) catch return error.InvalidDirection;
                    pos += 1;
                    tab.nodes[ni].ratio_x100 = std.mem.readInt(u16, data[pos..][0..2], .little);
                    pos += 2;
                    tab.nodes[ni].child_left = data[pos];
                    pos += 1;
                    tab.nodes[ni].child_right = data[pos];
                    pos += 1;
                },
            }
        }
    }

    if (pos == data.len) return info;
    if (data.len - pos < title_trailer_magic.len) return info;
    if (!std.mem.eql(u8, data[pos .. pos + title_trailer_magic.len], title_trailer_magic))
        return info;
    if (data.len - pos < title_trailer_header_len) return error.InvalidExtension;
    pos += title_trailer_magic.len;
    if (data[pos] != title_trailer_version) return error.UnsupportedExtensionVersion;
    pos += 1;
    if (data[pos] != info.tab_count) return error.InvalidExtension;
    pos += 1;
    if (data.len - pos != info.tab_count) return error.InvalidExtension;
    for (0..info.tab_count) |ti| {
        info.tabs[ti].title_flags = data[pos];
        pos += 1;
    }

    return info;
}

// ---------------------------------------------------------------------------
// Pane ID helpers — used by session revive to remap old→new IDs.
// ---------------------------------------------------------------------------

/// Collect all leaf pane IDs from a LayoutInfo. Returns the count.
pub fn collectLeafPaneIds(info: *const LayoutInfo, out: []u32) u32 {
    var count: u32 = 0;
    for (0..info.tab_count) |ti| {
        const tab = &info.tabs[ti];
        for (0..tab.node_count) |ni| {
            if (tab.nodes[ni].tag == .leaf) {
                if (count < out.len) {
                    out[count] = tab.nodes[ni].pane_id;
                    count += 1;
                }
            }
        }
    }
    return count;
}

/// Replace old pane IDs with new ones in all leaf nodes and focused_pane_id.
pub fn remapPaneIds(info: *LayoutInfo, old_ids: []const u32, new_ids: []const u32) void {
    for (0..info.tab_count) |ti| {
        const tab = &info.tabs[ti];
        for (0..tab.node_count) |ni| {
            if (tab.nodes[ni].tag == .leaf) {
                for (0..old_ids.len) |k| {
                    if (tab.nodes[ni].pane_id == old_ids[k]) {
                        tab.nodes[ni].pane_id = new_ids[k];
                        break;
                    }
                }
            }
        }
    }
    // Remap focused_pane_id
    for (0..old_ids.len) |k| {
        if (info.focused_pane_id == old_ids[k]) {
            info.focused_pane_id = new_ids[k];
            break;
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "round-trip single tab single pane" {
    var info = LayoutInfo{};
    info.tab_count = 1;
    info.active_tab = 0;
    info.focused_pane_id = 42;
    info.tabs[0].node_count = 1;
    info.tabs[0].root_idx = 0;
    info.tabs[0].focused_idx = 0;
    info.tabs[0].nodes[0] = .{ .tag = .leaf, .pane_id = 42 };

    var buf: [256]u8 = undefined;
    const len = try serialize(&info, &buf);
    const decoded = try deserialize(buf[0..len]);

    try std.testing.expectEqual(@as(u8, 1), decoded.tab_count);
    try std.testing.expectEqual(@as(u8, 0), decoded.active_tab);
    try std.testing.expectEqual(@as(u32, 42), decoded.focused_pane_id);
    try std.testing.expectEqual(@as(u8, 1), decoded.tabs[0].node_count);
    try std.testing.expectEqual(NodeTag.leaf, decoded.tabs[0].nodes[0].tag);
    try std.testing.expectEqual(@as(u32, 42), decoded.tabs[0].nodes[0].pane_id);
}

test "round-trip split layout" {
    var info = LayoutInfo{};
    info.tab_count = 1;
    info.active_tab = 0;
    info.focused_pane_id = 2;
    info.tabs[0].node_count = 3;
    info.tabs[0].root_idx = 0;
    info.tabs[0].focused_idx = 2;
    // Branch: vertical split at 60%
    info.tabs[0].nodes[0] = .{
        .tag = .branch,
        .direction = .vertical,
        .ratio_x100 = 60,
        .child_left = 1,
        .child_right = 2,
    };
    info.tabs[0].nodes[1] = .{ .tag = .leaf, .pane_id = 1 };
    info.tabs[0].nodes[2] = .{ .tag = .leaf, .pane_id = 2 };

    var buf: [256]u8 = undefined;
    const len = try serialize(&info, &buf);
    const decoded = try deserialize(buf[0..len]);

    try std.testing.expectEqual(@as(u8, 3), decoded.tabs[0].node_count);
    const root = decoded.tabs[0].nodes[0];
    try std.testing.expectEqual(NodeTag.branch, root.tag);
    try std.testing.expectEqual(SplitDirection.vertical, root.direction);
    try std.testing.expectEqual(@as(u16, 60), root.ratio_x100);
    try std.testing.expectEqual(@as(u8, 1), root.child_left);
    try std.testing.expectEqual(@as(u8, 2), root.child_right);
    try std.testing.expectEqual(@as(u32, 1), decoded.tabs[0].nodes[1].pane_id);
    try std.testing.expectEqual(@as(u32, 2), decoded.tabs[0].nodes[2].pane_id);
}

test "round-trip multi-tab" {
    var info = LayoutInfo{};
    info.tab_count = 2;
    info.active_tab = 1;
    info.focused_pane_id = 10;

    // Tab 0: single pane
    info.tabs[0].node_count = 1;
    info.tabs[0].root_idx = 0;
    info.tabs[0].focused_idx = 0;
    info.tabs[0].nodes[0] = .{ .tag = .leaf, .pane_id = 5 };

    // Tab 1: single pane
    info.tabs[1].node_count = 1;
    info.tabs[1].root_idx = 0;
    info.tabs[1].focused_idx = 0;
    info.tabs[1].nodes[0] = .{ .tag = .leaf, .pane_id = 10 };

    var buf: [256]u8 = undefined;
    const len = try serialize(&info, &buf);
    const decoded = try deserialize(buf[0..len]);

    try std.testing.expectEqual(@as(u8, 2), decoded.tab_count);
    try std.testing.expectEqual(@as(u8, 1), decoded.active_tab);
    try std.testing.expectEqual(@as(u32, 5), decoded.tabs[0].nodes[0].pane_id);
    try std.testing.expectEqual(@as(u32, 10), decoded.tabs[1].nodes[0].pane_id);
}

test "empty layout" {
    var info = LayoutInfo{};
    info.tab_count = 0;

    var buf: [256]u8 = undefined;
    const len = try serialize(&info, &buf);
    const decoded = try deserialize(buf[0..len]);

    try std.testing.expectEqual(@as(u8, 0), decoded.tab_count);
}

test "partially initialized layout info keeps title fields empty" {
    var info = LayoutInfo{};
    info.tab_count = 1;
    info.active_tab = 0;
    info.focused_pane_id = 42;
    info.tabs[0].node_count = 1;
    info.tabs[0].root_idx = 0;
    info.tabs[0].focused_idx = 0;
    info.tabs[0].nodes[0] = .{ .tag = .leaf, .pane_id = 42 };

    var buf: [256]u8 = undefined;
    const len = try serialize(&info, &buf);
    try std.testing.expectEqual(@as(u16, 15), len);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], title_trailer_magic) == null);

    const decoded = try deserialize(buf[0..len]);
    try std.testing.expectEqual(@as(u8, 0), decoded.tabs[0].title_len);
    try std.testing.expect(decoded.tabs[0].getTitle() == null);
    try std.testing.expect(!decoded.tabs[0].isExplicitTitle());
}

test "error on too short data" {
    const data = [_]u8{ 1, 0 }; // only 2 bytes, need at least 6
    try std.testing.expectError(error.DataTooShort, deserialize(&data));
}

test "round-trip with tab titles" {
    var info = LayoutInfo{};
    info.tab_count = 2;
    info.active_tab = 0;
    info.focused_pane_id = 1;

    // Tab 0 with title "vim"
    info.tabs[0].node_count = 1;
    info.tabs[0].root_idx = 0;
    info.tabs[0].focused_idx = 0;
    info.tabs[0].nodes[0] = .{ .tag = .leaf, .pane_id = 1 };
    @memcpy(info.tabs[0].title[0..3], "vim");
    info.tabs[0].title_len = 3;
    info.tabs[0].title_flags = title_flag_explicit;

    // Tab 1 with no title
    info.tabs[1].node_count = 1;
    info.tabs[1].root_idx = 0;
    info.tabs[1].focused_idx = 0;
    info.tabs[1].nodes[0] = .{ .tag = .leaf, .pane_id = 2 };
    info.tabs[1].title_len = 0;

    var buf: [256]u8 = undefined;
    const len = try serialize(&info, &buf);
    const decoded = try deserialize(buf[0..len]);

    try std.testing.expectEqual(@as(u8, 2), decoded.tab_count);
    try std.testing.expectEqual(@as(u8, 3), decoded.tabs[0].title_len);
    try std.testing.expectEqualStrings("vim", decoded.tabs[0].getTitle().?);
    try std.testing.expect(decoded.tabs[0].isExplicitTitle());
    try std.testing.expectEqual(@as(u8, 0), decoded.tabs[1].title_len);
    try std.testing.expect(decoded.tabs[1].getTitle() == null);
}

test "legacy layout keeps raw tab titles as hints" {
    const data = [_]u8{
        0x01, // tab_count
        0x00, // active_tab
        0x2A, 0x00, 0x00, 0x00, // focused_pane_id
        0x01, // node_count
        0x00, // root_idx
        0x00, // focused_idx
        0x04, // title_len
        'c',
        'o',
        'd',
        'e',
        0x00, // node tag = leaf
        0x2A, 0x00, 0x00, 0x00, // pane_id
    };

    const decoded = try deserialize(&data);
    try std.testing.expectEqual(@as(u8, 1), decoded.tab_count);
    try std.testing.expectEqualStrings("code", decoded.tabs[0].getTitle().?);
    try std.testing.expect(!decoded.tabs[0].isExplicitTitle());
}

test "new layout stays readable as a legacy body without the trailer" {
    var info = LayoutInfo{};
    info.tab_count = 1;
    info.active_tab = 0;
    info.focused_pane_id = 42;
    info.tabs[0].node_count = 1;
    info.tabs[0].root_idx = 0;
    info.tabs[0].focused_idx = 0;
    info.tabs[0].nodes[0] = .{ .tag = .leaf, .pane_id = 42 };
    @memcpy(info.tabs[0].title[0..4], "code");
    info.tabs[0].title_len = 4;
    info.tabs[0].title_flags = title_flag_explicit;

    var buf: [256]u8 = undefined;
    const len = try serialize(&info, &buf);
    const legacy_body_len = len - (title_trailer_header_len + info.tab_count);
    const expected_legacy_body = [_]u8{
        0x01, // tab_count
        0x00, // active_tab
        0x2A, 0x00, 0x00, 0x00, // focused_pane_id
        0x01, // node_count
        0x00, // root_idx
        0x00, // focused_idx
        0x04, // title_len
        'c',
        'o',
        'd',
        'e',
        0x00, // node tag = leaf
        0x2A, 0x00, 0x00, 0x00, // pane_id
    };
    try std.testing.expectEqualSlices(u8, &expected_legacy_body, buf[0..legacy_body_len]);
    const legacy_view = try deserialize(buf[0..legacy_body_len]);

    try std.testing.expectEqual(@as(u8, 1), legacy_view.tab_count);
    try std.testing.expectEqualStrings("code", legacy_view.tabs[0].getTitle().?);
    try std.testing.expect(!legacy_view.tabs[0].isExplicitTitle());

    const decoded = try deserialize(buf[0..len]);
    try std.testing.expect(decoded.tabs[0].isExplicitTitle());
}

test "unknown trailing bytes are ignored" {
    const data = [_]u8{
        0x01, // tab_count
        0x00, // active_tab
        0x2A, 0x00, 0x00, 0x00, // focused_pane_id
        0x01, // node_count
        0x00, // root_idx
        0x00, // focused_idx
        0x04, // title_len
        'c',
        'o',
        'd',
        'e',
        0x00, // node tag = leaf
        0x2A, 0x00, 0x00, 0x00, // pane_id
        'b',  'a',  'd',  '!',
    };

    const decoded = try deserialize(&data);
    try std.testing.expectEqual(@as(u8, 1), decoded.tab_count);
    try std.testing.expectEqualStrings("code", decoded.tabs[0].getTitle().?);
    try std.testing.expect(!decoded.tabs[0].isExplicitTitle());
}

test "truncated title trailer is rejected once magic matches" {
    const data = [_]u8{
        0x01, // tab_count
        0x00, // active_tab
        0x2A, 0x00, 0x00, 0x00, // focused_pane_id
        0x01, // node_count
        0x00, // root_idx
        0x00, // focused_idx
        0x04, // title_len
        'c',
        'o',
        'd',
        'e',
        0x00, // node tag = leaf
        0x2A, 0x00, 0x00, 0x00, // pane_id
        't',  't',  'l',  '2',
    };

    try std.testing.expectError(error.InvalidExtension, deserialize(&data));
}

test "collectLeafPaneIds: collects all leaves" {
    var info = LayoutInfo{};
    info.tab_count = 1;
    info.focused_pane_id = 2;
    info.tabs[0].node_count = 3;
    info.tabs[0].root_idx = 0;
    info.tabs[0].nodes[0] = .{ .tag = .branch, .direction = .vertical, .ratio_x100 = 50, .child_left = 1, .child_right = 2 };
    info.tabs[0].nodes[1] = .{ .tag = .leaf, .pane_id = 10 };
    info.tabs[0].nodes[2] = .{ .tag = .leaf, .pane_id = 20 };

    var ids: [16]u32 = undefined;
    const count = collectLeafPaneIds(&info, &ids);
    try std.testing.expectEqual(@as(u32, 2), count);
    try std.testing.expectEqual(@as(u32, 10), ids[0]);
    try std.testing.expectEqual(@as(u32, 20), ids[1]);
}

test "remapPaneIds: remaps leaves and focused" {
    var info = LayoutInfo{};
    info.tab_count = 1;
    info.focused_pane_id = 10;
    info.tabs[0].node_count = 2;
    info.tabs[0].nodes[0] = .{ .tag = .leaf, .pane_id = 10 };
    info.tabs[0].nodes[1] = .{ .tag = .leaf, .pane_id = 20 };

    const old = [_]u32{ 10, 20 };
    const new = [_]u32{ 100, 200 };
    remapPaneIds(&info, &old, &new);

    try std.testing.expectEqual(@as(u32, 100), info.tabs[0].nodes[0].pane_id);
    try std.testing.expectEqual(@as(u32, 200), info.tabs[0].nodes[1].pane_id);
    try std.testing.expectEqual(@as(u32, 100), info.focused_pane_id);
}
