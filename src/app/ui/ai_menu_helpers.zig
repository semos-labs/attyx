const std = @import("std");
const attyx = @import("attyx");
const overlay_mod = attyx.overlay_mod;
const overlay_ai_menu = attyx.overlay_ai_menu;

const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const input = @import("input.zig");
const publish = @import("publish.zig");
const ai = @import("ai.zig");

const MenuSelection = overlay_ai_menu.MenuSelection;

// ---------------------------------------------------------------------------
// AI menu helpers
// ---------------------------------------------------------------------------

pub fn startAiMenu(ctx: *PtyThreadCtx) void {
    if (ai.g_ai_menu == null) ai.g_ai_menu = overlay_ai_menu.MenuContext.init();
    var menu = &(ai.g_ai_menu.?);
    menu.open();
    terminal.g_ai_prompt_active = 1;
    renderMenuCard(ctx);
}

pub fn renderMenuCard(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    const menu = &(ai.g_ai_menu orelse return);
    const style = ai.contentStyleFromTheme(ctx);
    const result = overlay_ai_menu.layoutMenuCard(mgr.allocator, menu, 48, style) catch return;
    defer mgr.allocator.free(result.cells);

    // Place at bottom-right with margin, same as showAiOverlayCard positioning
    const vp = publish.viewportInfoFromCtx(ctx);
    const anchor = attyx.overlay_anchor.Anchor{ .kind = .viewport_dock, .dock = .bottom_right };
    const placement = attyx.overlay_anchor.placeOverlay(anchor, result.width, result.height, vp, .{});

    // Set content directly — no streaming animation for the menu
    const layer_idx = @intFromEnum(overlay_mod.OverlayId.ai_demo);
    mgr.setContent(.ai_demo, placement.col, placement.row, result.width, result.height, result.cells) catch return;

    var bar = attyx.overlay_action.ActionBar{};
    bar.add(.dismiss, "Cancel");
    mgr.layers[layer_idx].action_bar = bar;
    mgr.layers[layer_idx].anchor = anchor;
    mgr.layers[layer_idx].z_order = 2;

    publish.publishOverlays(ctx);
}

/// Drain menu input and return selected action, or null if no selection yet.
/// Returns null when menu is closed via Esc (and sets g_ai_menu = null).
pub fn consumeMenuInput(ctx: *PtyThreadCtx) ?MenuSelection {
    var menu = &(ai.g_ai_menu orelse return null);

    // Drain cmd ring
    while (true) {
        const w = @atomicLoad(u32, &input.g_ai_prompt_cmd_write, .seq_cst);
        const r = @atomicLoad(u32, &input.g_ai_prompt_cmd_read, .seq_cst);
        if (w == r) break;
        const cmd = input.g_ai_prompt_cmd_ring[r % 16];
        @atomicStore(u32, &input.g_ai_prompt_cmd_read, r +% 1, .seq_cst);
        switch (cmd) {
            7 => { // Esc - cancel
                menu.close();
                ai.g_ai_menu = null;
                terminal.g_ai_prompt_active = 0;
                return null;
            },
            8 => { // Enter - select
                const selection = menu.selection;
                return selection;
            },
            11 => { // Up arrow
                menu.moveUp();
                renderMenuCard(ctx);
            },
            12 => { // Down arrow
                menu.moveDown();
                renderMenuCard(ctx);
            },
            else => {},
        }
    }

    // Drain char ring for number shortcuts
    while (true) {
        const w = @atomicLoad(u32, &input.g_ai_prompt_char_write, .seq_cst);
        const r = @atomicLoad(u32, &input.g_ai_prompt_char_read, .seq_cst);
        if (w == r) break;
        const cp = input.g_ai_prompt_char_ring[r % 32];
        @atomicStore(u32, &input.g_ai_prompt_char_read, r +% 1, .seq_cst);
        switch (cp) {
            '1' => return .rewrite_command,
            '2' => return .explain_command,
            '3' => return .generate_command,
            else => {},
        }
    }

    return null;
}
