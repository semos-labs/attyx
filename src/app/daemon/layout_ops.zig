// Attyx — pure layout-tree operations
//
// Side-effect-free helpers that manipulate a serialized LayoutInfo / TabLayout
// (the daemon's authoritative view of a session's tab/split tree). No PTYs, no
// sockets — just tree surgery, so they're trivially testable. The session/
// client-coupled ctl handlers live in handler_ctl_layout.zig.

const std = @import("std");
const layout_codec = @import("../layout_codec.zig");

const TabLayout = layout_codec.TabLayout;
const LayoutInfo = layout_codec.LayoutInfo;
const LayoutNode = layout_codec.LayoutNode;

/// Append a leaf (single-pane) tab. Returns false if the tab table is full.
pub fn appendLeafTab(info: *LayoutInfo, pane_id: u32) bool {
    if (info.tab_count >= layout_codec.max_tabs) return false;
    const idx = info.tab_count;
    var t = &info.tabs[idx];
    t.node_count = 1;
    t.root_idx = 0;
    t.focused_idx = 0;
    t.title_len = 0;
    t.title_flags = 0;
    t.nodes[0] = .{ .tag = .leaf, .pane_id = pane_id };
    info.tab_count += 1;
    return true;
}

/// pane_id of a tab's focused node, or its first leaf, or 0.
pub fn tabFocusedPane(tab: *const TabLayout) u32 {
    if (tab.focused_idx < tab.node_count and tab.nodes[tab.focused_idx].tag == .leaf) {
        return tab.nodes[tab.focused_idx].pane_id;
    }
    for (0..tab.node_count) |ni| {
        if (tab.nodes[ni].tag == .leaf) return tab.nodes[ni].pane_id;
    }
    return 0;
}

/// Index of the tab's focused node if it's a leaf, else its first leaf node.
pub fn focusedLeafIdx(tab: *const TabLayout) u8 {
    if (tab.focused_idx < tab.node_count and tab.nodes[tab.focused_idx].tag == .leaf) {
        return tab.focused_idx;
    }
    for (0..tab.node_count) |i| {
        if (tab.nodes[i].tag == .leaf) return @intCast(i);
    }
    return 0;
}

/// Node index of the leaf holding `pane_id`, or null.
pub fn findLeafInTab(tab: *const TabLayout, pane_id: u32) ?usize {
    for (0..tab.node_count) |i| {
        if (tab.nodes[i].tag == .leaf and tab.nodes[i].pane_id == pane_id) return i;
    }
    return null;
}

pub fn countLeaves(tab: *const TabLayout) usize {
    var n: usize = 0;
    for (0..tab.node_count) |i| {
        if (tab.nodes[i].tag == .leaf) n += 1;
    }
    return n;
}

/// Leaf pane_ids of a tab in node order. Returns the count.
pub fn collectLeafPanes(tab: *const TabLayout, out: *[layout_codec.max_nodes_per_tab]u32) usize {
    var n: usize = 0;
    for (0..tab.node_count) |i| {
        if (tab.nodes[i].tag == .leaf) {
            out[n] = tab.nodes[i].pane_id;
            n += 1;
        }
    }
    return n;
}

/// Cycle the pane assignments among a tab's leaves by one position (the pane in
/// each leaf slot moves to the next slot, wrapping). The tree shape and focused
/// slot stay put; only which pane sits where changes.
pub fn rotateLeaves(tab: *TabLayout) void {
    var leaf_idx: [layout_codec.max_nodes_per_tab]usize = undefined;
    var n: usize = 0;
    for (0..tab.node_count) |i| {
        if (tab.nodes[i].tag == .leaf) {
            leaf_idx[n] = i;
            n += 1;
        }
    }
    if (n < 2) return;
    const last = tab.nodes[leaf_idx[n - 1]].pane_id;
    var k: usize = n - 1;
    while (k > 0) : (k -= 1) {
        tab.nodes[leaf_idx[k]].pane_id = tab.nodes[leaf_idx[k - 1]].pane_id;
    }
    tab.nodes[leaf_idx[0]].pane_id = last;
}

/// Remove tab `idx`, shifting the rest down and keeping active_tab/focus sane.
pub fn removeTab(info: *LayoutInfo, idx: usize) void {
    var k = idx;
    while (k + 1 < info.tab_count) : (k += 1) info.tabs[k] = info.tabs[k + 1];
    info.tab_count -= 1;
    if (info.tab_count == 0) {
        info.active_tab = 0;
        info.focused_pane_id = 0;
        return;
    }
    if (info.active_tab > idx) info.active_tab -= 1;
    if (info.active_tab >= info.tab_count) info.active_tab = info.tab_count - 1;
    info.focused_pane_id = tabFocusedPane(&info.tabs[info.active_tab]);
}

/// Swap the active tab with its left (right=false) or right (right=true)
/// neighbor, following it with active_tab. Returns false if already at the edge.
pub fn moveTab(info: *LayoutInfo, right: bool) bool {
    const a = info.active_tab;
    if (right) {
        if (a + 1 >= info.tab_count) return false;
        const tmp = info.tabs[a];
        info.tabs[a] = info.tabs[a + 1];
        info.tabs[a + 1] = tmp;
        info.active_tab = a + 1;
    } else {
        if (a == 0) return false;
        const tmp = info.tabs[a];
        info.tabs[a] = info.tabs[a - 1];
        info.tabs[a - 1] = tmp;
        info.active_tab = a - 1;
    }
    return true;
}

/// Set a tab's explicit title.
pub fn setTabTitle(tab: *TabLayout, name: []const u8) void {
    const n: u8 = @intCast(@min(name.len, layout_codec.max_title_len));
    @memcpy(tab.title[0..n], name[0..n]);
    tab.title_len = n;
    tab.title_flags |= layout_codec.title_flag_explicit;
}

/// Remove leaf `ni` from a multi-pane tab: promote its sibling into the parent
/// branch's slot, then compact the node array. Returns the surviving focus pane.
pub fn removeLeafPromote(tab: *TabLayout, ni: usize) u32 {
    var pi: ?usize = null;
    var ni_is_left = false;
    for (0..tab.node_count) |k| {
        if (tab.nodes[k].tag != .branch) continue;
        if (tab.nodes[k].child_left == ni) {
            pi = k;
            ni_is_left = true;
            break;
        }
        if (tab.nodes[k].child_right == ni) {
            pi = k;
            ni_is_left = false;
            break;
        }
    }
    const p = pi orelse return tabFocusedPane(tab); // shouldn't happen (countLeaves > 1)
    const si = if (ni_is_left) tab.nodes[p].child_right else tab.nodes[p].child_left;
    const focus_pane = firstLeafPane(tab, si);
    tab.nodes[p] = tab.nodes[si]; // promote sibling into the parent slot
    compactTab(tab, focus_pane);
    return focus_pane;
}

/// pane_id of the leftmost leaf under node `idx`.
pub fn firstLeafPane(tab: *const TabLayout, idx: u8) u32 {
    var cur = idx;
    var guard: usize = 0;
    while (tab.nodes[cur].tag == .branch and guard < layout_codec.max_nodes_per_tab) : (guard += 1) {
        cur = tab.nodes[cur].child_left;
    }
    return tab.nodes[cur].pane_id;
}

/// Rebuild the tab's node array via DFS from the root so it's compact (no
/// orphaned nodes), remapping child indices. Sets focused_idx to the leaf
/// holding `focus_pane`, else the first leaf.
pub fn compactTab(tab: *TabLayout, focus_pane: u32) void {
    var out: [layout_codec.max_nodes_per_tab]LayoutNode = undefined;
    var count: u8 = 0;
    const new_root = dfsCopy(tab, tab.root_idx, &out, &count);
    tab.nodes = out;
    tab.node_count = count;
    tab.root_idx = new_root;
    tab.focused_idx = 0;
    for (0..count) |i| {
        if (out[i].tag == .leaf and out[i].pane_id == focus_pane) {
            tab.focused_idx = @intCast(i);
            return;
        }
    }
    for (0..count) |i| {
        if (out[i].tag == .leaf) {
            tab.focused_idx = @intCast(i);
            return;
        }
    }
}

/// DFS-copy the subtree rooted at `old_idx` into `out`, assigning contiguous
/// indices. Returns the new index of `old_idx`.
fn dfsCopy(
    tab: *const TabLayout,
    old_idx: u8,
    out: *[layout_codec.max_nodes_per_tab]LayoutNode,
    count: *u8,
) u8 {
    const my_idx = count.*;
    out[my_idx] = tab.nodes[old_idx];
    count.* += 1;
    if (tab.nodes[old_idx].tag == .branch) {
        const l = dfsCopy(tab, tab.nodes[old_idx].child_left, out, count);
        const r = dfsCopy(tab, tab.nodes[old_idx].child_right, out, count);
        out[my_idx].child_left = l;
        out[my_idx].child_right = r;
    }
    return my_idx;
}

test "removeLeafPromote collapses parent branch and compacts orphans" {
    // root(0) = vsplit[ leaf p1 (1), hsplit(2)[ leaf p2 (3), leaf p3 (4) ] ]
    var tab = TabLayout{};
    tab.nodes[0] = .{ .tag = .branch, .direction = .vertical, .child_left = 1, .child_right = 2 };
    tab.nodes[1] = .{ .tag = .leaf, .pane_id = 1 };
    tab.nodes[2] = .{ .tag = .branch, .direction = .horizontal, .child_left = 3, .child_right = 4 };
    tab.nodes[3] = .{ .tag = .leaf, .pane_id = 2 };
    tab.nodes[4] = .{ .tag = .leaf, .pane_id = 3 };
    tab.node_count = 5;
    tab.root_idx = 0;
    tab.focused_idx = 4;

    const focus = removeLeafPromote(&tab, 4);

    try std.testing.expectEqual(@as(u32, 2), focus);
    try std.testing.expectEqual(@as(u8, 3), tab.node_count);

    var leaves: usize = 0;
    var seen1 = false;
    var seen2 = false;
    var seen3 = false;
    for (0..tab.node_count) |i| {
        if (tab.nodes[i].tag == .leaf) {
            leaves += 1;
            switch (tab.nodes[i].pane_id) {
                1 => seen1 = true,
                2 => seen2 = true,
                3 => seen3 = true,
                else => {},
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 2), leaves);
    try std.testing.expect(seen1 and seen2 and !seen3);
    try std.testing.expect(tab.nodes[tab.focused_idx].tag == .leaf);
    try std.testing.expectEqual(@as(u32, 2), tab.nodes[tab.focused_idx].pane_id);
}

test "rotateLeaves cycles pane assignments" {
    var tab = TabLayout{};
    tab.nodes[0] = .{ .tag = .branch, .direction = .vertical, .child_left = 1, .child_right = 2 };
    tab.nodes[1] = .{ .tag = .leaf, .pane_id = 10 };
    tab.nodes[2] = .{ .tag = .branch, .direction = .horizontal, .child_left = 3, .child_right = 4 };
    tab.nodes[3] = .{ .tag = .leaf, .pane_id = 20 };
    tab.nodes[4] = .{ .tag = .leaf, .pane_id = 30 };
    tab.node_count = 5;
    rotateLeaves(&tab);
    // leaves in node order were [10,20,30] → rotate → [30,10,20]
    try std.testing.expectEqual(@as(u32, 30), tab.nodes[1].pane_id);
    try std.testing.expectEqual(@as(u32, 10), tab.nodes[3].pane_id);
    try std.testing.expectEqual(@as(u32, 20), tab.nodes[4].pane_id);
}
