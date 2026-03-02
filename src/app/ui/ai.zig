const std = @import("std");
const attyx = @import("attyx");
const logging = @import("../../logging/log.zig");

const overlay_mod = attyx.overlay_mod;
const overlay_anchor = attyx.overlay_anchor;
const overlay_content = attyx.overlay_content;
const overlay_streaming = attyx.overlay_streaming;
const overlay_demo = attyx.overlay_demo;
const overlay_context = attyx.overlay_context;
const overlay_context_extract = attyx.overlay_context_extract;
const overlay_context_ui = attyx.overlay_context_ui;
const overlay_ai_config = attyx.overlay_ai_config;
const overlay_ai_auth = attyx.overlay_ai_auth;
const overlay_ai_stream = attyx.overlay_ai_stream;
const overlay_ai_content = attyx.overlay_ai_content;
const overlay_ai_error = attyx.overlay_ai_error;
const overlay_ai_edit = attyx.overlay_ai_edit;
const update_check = attyx.overlay_update_check;
const OverlayManager = overlay_mod.OverlayManager;

const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const c = terminal.c;
const input = @import("input.zig");
const publish = @import("publish.zig");
const ai_edit = @import("ai_edit_helpers.zig");

/// Re-export edit helper functions for callers that import ai.zig.
pub const renderEditPromptCard = ai_edit.renderEditPromptCard;
pub const consumeAiPromptInput = ai_edit.consumeAiPromptInput;
pub const handleEditAcceptAction = ai_edit.handleEditAcceptAction;
pub const handleEditInsertAction = ai_edit.handleEditInsertAction;
pub const handleEditDoneResponse = ai_edit.handleEditDoneResponse;
pub const handleNormalDoneResponse = ai_edit.handleNormalDoneResponse;
pub const handleEditRejectAction = ai_edit.handleEditRejectAction;
pub const handleRetryAction = ai_edit.handleRetryAction;
pub const cancelAi = ai_edit.cancelAi;

// AI demo streaming state (persists across PTY loop iterations).
pub var g_streaming: ?overlay_streaming.StreamingOverlay = null;

// Context bundle captured when the AI demo is started.
pub var g_context_bundle: ?overlay_context.ContextBundle = null;

// AI backend integration state
pub var g_token_store: ?overlay_ai_auth.TokenStore = null;
pub var g_auth_thread: ?overlay_ai_auth.AuthThread = null;
pub var g_sse_thread: ?overlay_ai_stream.SseThread = null;
pub var g_ai_accumulator: ?overlay_ai_content.AiContentAccumulator = null;
pub var g_ai_request_body: ?[]u8 = null;
const g_ai_base_url: []const u8 = overlay_ai_config.base_url;

// AI edit state machine
pub var g_ai_edit: ?overlay_ai_edit.EditContext = null;

// Update notification state
pub var g_update_checker: ?update_check.UpdateChecker = null;

pub fn captureAiContext(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    const eng = publish.ctxEngine(ctx);

    if (g_context_bundle) |*old| old.deinit();
    g_context_bundle = null;

    const sel_active_raw: i32 = @bitCast(c.g_sel_active);
    const sel_start_row_raw: i32 = @bitCast(c.g_sel_start_row);
    const sel_start_col_raw: i32 = @bitCast(c.g_sel_start_col);
    const sel_end_row_raw: i32 = @bitCast(c.g_sel_end_row);
    const sel_end_col_raw: i32 = @bitCast(c.g_sel_end_col);
    const sel_bounds: ?overlay_context_extract.SelBounds = if (sel_active_raw != 0)
        .{
            .start_row = if (sel_start_row_raw >= 0) @intCast(@as(u32, @bitCast(sel_start_row_raw))) else 0,
            .start_col = if (sel_start_col_raw >= 0) @intCast(@as(u32, @bitCast(sel_start_col_raw))) else 0,
            .end_row = if (sel_end_row_raw >= 0) @intCast(@as(u32, @bitCast(sel_end_row_raw))) else 0,
            .end_col = if (sel_end_col_raw >= 0) @intCast(@as(u32, @bitCast(sel_end_col_raw))) else 0,
        }
    else
        null;

    const title_len_raw: i32 = @bitCast(c.g_title_len);
    const title_len: usize = if (title_len_raw > 0) @intCast(@as(u32, @bitCast(title_len_raw))) else 0;
    const title_ptr: ?[*]const u8 = if (title_len > 0) @ptrCast(&c.g_title_buf) else null;

    g_context_bundle = overlay_context.captureContext(
        mgr.allocator,
        &eng.state.grid,
        &eng.state.scrollback,
        eng.state.cursor.row,
        title_ptr,
        title_len,
        sel_bounds,
        80,
        eng.state.alt_active,
    ) catch null;
}

pub fn showAiOverlayCard(ctx: *PtyThreadCtx, cells: []overlay_mod.OverlayCell, width: u16, height: u16, bar: attyx.overlay_action.ActionBar) void {
    const mgr = ctx.overlay_mgr orelse return;
    const vp = publish.viewportInfoFromCtx(ctx);
    const anchor = overlay_anchor.Anchor{ .kind = .viewport_dock, .dock = .bottom_right };
    const placement = overlay_anchor.placeOverlay(anchor, width, height, vp, .{});

    const margin: u16 = 1;
    const bottom_row: u16 = if (vp.grid_rows > margin + 1) vp.grid_rows - 1 - margin else vp.grid_rows -| 1;
    const max_vis: u16 = if (vp.grid_rows > margin * 2) vp.grid_rows - margin * 2 else 3;

    if (g_streaming == null) {
        g_streaming = overlay_streaming.StreamingOverlay{ .allocator = mgr.allocator };
    }
    var so = &(g_streaming.?);
    so.start(cells, width, height, placement.col, bottom_row, max_vis, std.time.nanoTimestamp());

    mgr.layers[@intFromEnum(overlay_mod.OverlayId.ai_demo)].action_bar = bar;
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.ai_demo)].anchor = anchor;
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.ai_demo)].z_order = 2;

    publishAiStreamingFrame(ctx);
}

fn spawnSseStream(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    const bundle = &(g_context_bundle orelse return);
    const store = &(g_token_store orelse return);
    const token = store.access_token orelse return;

    // Serialize request body
    if (g_ai_request_body) |old| mgr.allocator.free(old);
    g_ai_request_body = overlay_ai_config.serializeRequest(mgr.allocator, bundle) catch null;
    const body = g_ai_request_body orelse return;

    // Build URL — edit mode uses non-streaming endpoint
    var url_buf: [512]u8 = undefined;
    const endpoint = if (bundle.invocation == .edit_selection) "/v1/ai/execute" else "/v1/ai/execute/stream";
    const url = std.fmt.bufPrint(&url_buf, "{s}{s}", .{ g_ai_base_url, endpoint }) catch return;

    // Initialize SSE thread
    if (g_sse_thread == null) g_sse_thread = overlay_ai_stream.SseThread.init();
    var sse = &(g_sse_thread.?);

    // Initialize accumulator
    if (g_ai_accumulator == null) {
        g_ai_accumulator = overlay_ai_content.AiContentAccumulator.init(mgr.allocator);
    } else {
        g_ai_accumulator.?.reset();
    }

    // Show connecting card
    const connecting_result = overlay_ai_error.layoutConnectingCard(mgr.allocator, 48) catch return;
    var bar = attyx.overlay_action.ActionBar{};
    bar.add(.dismiss, "Cancel");
    showAiOverlayCard(ctx, connecting_result.cells, connecting_result.width, connecting_result.height, bar);

    // Start SSE thread
    sse.start(mgr.allocator, url, token, body) catch {
        showAiErrorCard(ctx, "connection", "Failed to start SSE connection");
        return;
    };
}

pub fn loadTokensAndStream(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    if (g_token_store == null) {
        g_token_store = overlay_ai_auth.TokenStore.load(mgr.allocator) catch
            overlay_ai_auth.TokenStore.init(mgr.allocator);
    }
    var store = &(g_token_store.?);
    if (store.hasAccessToken()) {
        spawnSseStream(ctx);
    } else if (store.hasRefreshToken()) {
        startAuthFlow(ctx, store.refresh_token);
    } else {
        startAuthFlow(ctx, null);
    }
}

pub fn startAiInvocation(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;

    // Capture terminal context
    captureAiContext(ctx);

    // If selection exists, enter edit mode
    if (g_context_bundle) |*bundle| {
        std.debug.print("[ai-edit] invocation={}, sel_text={?}, sel_active={d}, bounds=({d},{d})-({d},{d}), grid={d}x{d}\n", .{
            bundle.invocation,
            if (bundle.selection_text) |s| s.len else null,
            @as(i32, @bitCast(c.g_sel_active)),
            @as(i32, @bitCast(c.g_sel_start_row)),
            @as(i32, @bitCast(c.g_sel_start_col)),
            @as(i32, @bitCast(c.g_sel_end_row)),
            @as(i32, @bitCast(c.g_sel_end_col)),
            bundle.grid_cols,
            bundle.grid_rows,
        });
        if (bundle.selection_text != null) {
            std.debug.print("[ai-edit] entering edit mode\n", .{});
            if (g_ai_edit == null) g_ai_edit = overlay_ai_edit.EditContext.init(mgr.allocator);
            var edit = &(g_ai_edit.?);
            edit.open(bundle.selection_text.?) catch {
                showAiErrorCard(ctx, "selection", "Selection too large (max 64KB)");
                return;
            };
            terminal.g_ai_prompt_active = 1;
            renderEditPromptCard(ctx);
            return;
        }
    }

    // No selection — existing auto-invoke flow
    std.debug.print("[ai-edit] no selection, normal flow\n", .{});
    loadTokensAndStream(ctx);
}

fn startAuthFlow(ctx: *PtyThreadCtx, refresh_token: ?[]const u8) void {
    const mgr = ctx.overlay_mgr orelse return;

    if (g_auth_thread == null) g_auth_thread = overlay_ai_auth.AuthThread.init();
    var auth = &(g_auth_thread.?);

    auth.startAuth(mgr.allocator, g_ai_base_url, refresh_token) catch {
        showAiErrorCard(ctx, "auth", "Failed to start authentication");
        return;
    };

    // Show connecting/refreshing card
    const result = overlay_ai_error.layoutConnectingCard(mgr.allocator, 48) catch return;
    var bar = attyx.overlay_action.ActionBar{};
    bar.add(.dismiss, "Cancel");
    showAiOverlayCard(ctx, result.cells, result.width, result.height, bar);
}

fn showAiErrorCard(ctx: *PtyThreadCtx, code: []const u8, msg: []const u8) void {
    const mgr = ctx.overlay_mgr orelse return;
    const result = overlay_ai_error.layoutErrorCard(mgr.allocator, code, msg, 48) catch return;
    var bar = attyx.overlay_action.ActionBar{};
    bar.add(.retry, "Retry");
    bar.add(.copy, "Copy diagnostics");
    bar.add(.dismiss, "Dismiss");
    showAiOverlayCard(ctx, result.cells, result.width, result.height, bar);
}

fn showDeviceCodeCard(ctx: *PtyThreadCtx, user_code: []const u8) void {
    const mgr = ctx.overlay_mgr orelse return;
    const result = overlay_ai_error.layoutDeviceCodeCard(mgr.allocator, user_code, 48) catch return;
    var bar = attyx.overlay_action.ActionBar{};
    bar.add(.dismiss, "Cancel");
    showAiOverlayCard(ctx, result.cells, result.width, result.height, bar);
}

pub fn publishAiStreamingFrame(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    var so = &(g_streaming orelse return);

    var scratch: [c.ATTYX_OVERLAY_MAX_CELLS]overlay_mod.OverlayCell = undefined;
    const vis = so.buildVisibleCells(&scratch) orelse return;

    // Bottom-anchored: row computed from anchor_bottom_row - visible_height + 1
    const top_row = so.topRow();
    mgr.setContent(.ai_demo, so.col, top_row, vis.width, vis.height, scratch[0 .. @as(usize, vis.width) * vis.height]) catch return;
    publish.publishOverlays(ctx);
}

pub fn tickAi(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;

    // --- Check auth thread status ---
    if (g_auth_thread) |*auth| {
        const auth_status = auth.getStatus();
        switch (auth_status) {
            .device_show_code, .device_polling => {
                const user_code = auth.getUserCode();
                if (user_code.len > 0) {
                    showDeviceCodeCard(ctx, user_code);
                    publish.publishOverlays(ctx);
                }
            },
            .authenticated => {
                const at = auth.getAccessToken();
                const rt = auth.getRefreshToken();
                if (at.len > 0) {
                    if (g_token_store) |*store| {
                        store.update(at, rt) catch {};
                        store.save() catch {};
                    }
                }
                _ = auth.tryJoin();
                g_auth_thread = null;
                spawnSseStream(ctx);
                publish.publishOverlays(ctx);
            },
            .failed => {
                const err_msg = auth.getErrorMsg();
                showAiErrorCard(ctx, "auth", if (err_msg.len > 0) err_msg else "Authentication failed");
                _ = auth.tryJoin();
                g_auth_thread = null;
                publish.publishOverlays(ctx);
            },
            else => {},
        }
    }

    // --- Check SSE thread status ---
    if (g_sse_thread) |*sse| {
        const sse_status = sse.getStatus();
        switch (sse_status) {
            .streaming => {
                var drain_buf: [4096]u8 = undefined;
                const drained = sse.delta_ring.drain(&drain_buf);
                if (drained.len > 0) {
                    if (g_ai_accumulator) |*acc| {
                        acc.appendDelta(drained) catch {};
                        const blocks = acc.reparse() catch &.{};
                        if (blocks.len > 0) {
                            relayoutAiStreamContent(ctx, blocks);
                        }
                    }
                }
            },
            .done => {
                const is_edit = if (g_ai_edit) |*edit| edit.state == .streaming else false;
                if (is_edit) {
                    handleEditDoneResponse(ctx, sse);
                } else {
                    handleNormalDoneResponse(ctx, sse, mgr);
                }
                _ = sse.tryJoin();
                g_sse_thread = null;
            },
            .errored => {
                const http_code = sse.getHttpStatus();
                _ = sse.tryJoin();
                g_sse_thread = null;

                if (http_code == 401) {
                    if (g_token_store) |*store| {
                        if (store.access_token) |at| store.allocator.free(at);
                        store.access_token = null;
                        startAuthFlow(ctx, store.refresh_token);
                    }
                } else {
                    const code = sse.getErrorCode();
                    const msg = sse.getErrorMsg();
                    showAiErrorCard(ctx, code, if (msg.len > 0) msg else "Request failed");
                }
                publish.publishOverlays(ctx);
            },
            .canceled => {
                _ = sse.tryJoin();
                g_sse_thread = null;
            },
            else => {},
        }
    }

    // --- Tick streaming reveal animation ---
    if (g_streaming) |*so| {
        if (so.state != .active) return;
        if (so.tick(std.time.nanoTimestamp())) {
            publishAiStreamingFrame(ctx);
        }
    }
}

pub fn tickUpdateCheck(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    var checker = &(g_update_checker orelse return);

    const status = checker.getStatus();
    switch (status) {
        .update_available => {
            const latest = checker.getLatestVersion();
            logging.info("update", "update available: {s}", .{latest});
            if (latest.len > 0) {
                const result = update_check.layoutUpdateCard(mgr.allocator, latest) catch |err| {
                    logging.err("update", "layoutUpdateCard failed: {}", .{err});
                    return;
                };

                const eng = publish.ctxEngine(ctx);
                const cols: u16 = @intCast(eng.state.grid.cols);
                const rows: u16 = @intCast(eng.state.grid.rows);
                const card_col = if (cols > result.width + 1) cols - result.width - 1 else 0;
                const card_row = if (rows > result.height + 1) rows - result.height - 1 else 0;

                logging.info("update", "showing card at col={d} row={d} w={d} h={d}", .{ card_col, card_row, result.width, result.height });
                mgr.setContent(.update_notification, card_col, card_row, result.width, result.height, result.cells) catch {
                    mgr.allocator.free(result.cells);
                    logging.err("update", "setContent failed", .{});
                    return;
                };
                mgr.allocator.free(result.cells);

                mgr.layers[@intFromEnum(overlay_mod.OverlayId.update_notification)].action_bar = result.action_bar;
                mgr.show(.update_notification);
                publish.publishOverlays(ctx);
                logging.info("update", "overlay published", .{});
            }
            checker.tryJoin();
            g_update_checker = null;
        },
        .up_to_date => {
            logging.info("update", "up to date", .{});
            checker.tryJoin();
            g_update_checker = null;
        },
        .throttled => {
            logging.info("update", "throttled (checked within 24h)", .{});
            checker.tryJoin();
            g_update_checker = null;
        },
        .failed => {
            logging.warn("update", "update check failed", .{});
            checker.tryJoin();
            g_update_checker = null;
        },
        else => {},
    }
}

/// Relayout the streaming overlay with new content blocks from the accumulator.
pub fn relayoutAiStreamContent(ctx: *PtyThreadCtx, blocks: []const overlay_content.ContentBlock) void {
    const mgr = ctx.overlay_mgr orelse return;

    const title = if (g_context_bundle) |*bundle| switch (bundle.invocation) {
        .error_explain => "Error Explanation",
        .selection_explain => "Selection Explanation",
        .command_generate => "Generate Command",
        .general => "AI Response",
        .edit_selection => "Edit Selection",
    } else "AI Response";

    var bar = attyx.overlay_action.ActionBar{};
    bar.add(.dismiss, "Cancel");

    const result = overlay_content.layoutStructuredCard(
        mgr.allocator,
        title,
        blocks,
        48,
        .{},
        bar,
    ) catch return;

    if (g_streaming) |*so| {
        so.replaceContent(result.cells, result.width, result.height);
        publishAiStreamingFrame(ctx);
    } else {
        showAiOverlayCard(ctx, result.cells, result.width, result.height, bar);
    }
}

/// Reposition the AI demo streaming overlay after a window resize.
pub fn relayoutAiDemo(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    if (!mgr.isVisible(.ai_demo)) return;
    var so = &(g_streaming orelse return);

    const vp = publish.viewportInfoFromCtx(ctx);
    const margin: u16 = 1;
    const bottom_row: u16 = if (vp.grid_rows > margin + 1) vp.grid_rows - 1 - margin else vp.grid_rows -| 1;
    const max_vis: u16 = if (vp.grid_rows > margin * 2) vp.grid_rows - margin * 2 else 3;

    const anchor = overlay_anchor.Anchor{ .kind = .viewport_dock, .dock = .bottom_right };
    const placement = overlay_anchor.placeOverlay(anchor, so.full_width, so.full_height, vp, .{});

    so.anchor_bottom_row = bottom_row;
    so.max_visible_height = max_vis;
    so.col = placement.col;

    publishAiStreamingFrame(ctx);
}

pub fn placeContextPreviewCard(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    const bundle = &(g_context_bundle orelse return);
    const vp = publish.viewportInfoFromCtx(ctx);

    const result = overlay_context_ui.layoutContextPreview(
        mgr.allocator,
        bundle,
        @min(vp.grid_cols, 50),
        .{},
    ) catch return;
    defer mgr.allocator.free(result.cells);

    const margin: u16 = 1;
    const bottom_row: u16 = if (vp.grid_rows > margin + 1) vp.grid_rows - 1 - margin else vp.grid_rows -| 1;
    const max_vis: u16 = if (vp.grid_rows > margin * 2) vp.grid_rows - margin * 2 else 3;
    const vis_h: u16 = @min(result.height, max_vis);
    const top_row: u16 = if (bottom_row + 1 >= vis_h) bottom_row + 1 - vis_h else 0;
    const col: u16 = if (vp.grid_cols > result.width + margin) vp.grid_cols - result.width - margin else 0;

    if (vis_h >= result.height) {
        mgr.setContent(.context_preview, col, top_row, result.width, result.height, result.cells) catch return;
    } else {
        const w: usize = result.width;
        const fh: usize = result.height;
        const vh: usize = vis_h;
        if (vh < 3 or w == 0) return;
        const needed = vh * w;
        var scratch: [c.ATTYX_OVERLAY_MAX_CELLS]overlay_mod.OverlayCell = undefined;
        if (needed > scratch.len) return;

        @memcpy(scratch[0..w], result.cells[0..w]);
        const visible_content = vh -| 3;
        if (visible_content > 0) {
            const src_start = 1 * w;
            const dst_start = 1 * w;
            const count = visible_content * w;
            if (src_start + count <= result.cells.len) {
                @memcpy(scratch[dst_start .. dst_start + count], result.cells[src_start .. src_start + count]);
            }
        }
        {
            const src_row = fh - 2;
            const dst_row = vh - 2;
            @memcpy(scratch[dst_row * w .. (dst_row + 1) * w], result.cells[src_row * w .. (src_row + 1) * w]);
        }
        {
            const src_row = fh - 1;
            const dst_row = vh - 1;
            @memcpy(scratch[dst_row * w .. (dst_row + 1) * w], result.cells[src_row * w .. (src_row + 1) * w]);
        }
        mgr.setContent(.context_preview, col, top_row, result.width, @intCast(vh), scratch[0..needed]) catch return;
    }

    var bar = attyx.overlay_action.ActionBar{};
    bar.add(.dismiss, "Back");
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.context_preview)].action_bar = bar;
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.context_preview)].z_order = 3;
}

pub fn relayoutContextPreview(ctx: *PtyThreadCtx) void {
    if (ctx.overlay_mgr) |mgr| {
        if (!mgr.isVisible(.context_preview)) return;
    } else return;
    placeContextPreviewCard(ctx);
}

pub fn toggleContextPreview(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;

    if (mgr.isVisible(.context_preview)) {
        mgr.hide(.context_preview);
        mgr.show(.ai_demo);
        publish.publishOverlays(ctx);
        return;
    }

    placeContextPreviewCard(ctx);

    mgr.hide(.ai_demo);
    mgr.show(.context_preview);
    publish.publishOverlays(ctx);
}

pub fn handleInsertAction(ctx: *PtyThreadCtx) void {
    const code = blk: {
        if (g_ai_accumulator) |*acc| {
            const blocks = acc.reparse() catch break :blk @as(?[]const u8, null);
            if (overlay_content.firstCodeBlock(blocks)) |cb| break :blk @as(?[]const u8, cb);
        }
        break :blk overlay_content.firstCodeBlock(&overlay_demo.mock_blocks);
    } orelse return;

    if (publish.ctxEngine(ctx).state.bracketed_paste) {
        c.attyx_send_input("\x1b[200~", 6);
    }
    c.attyx_send_input(code.ptr, @intCast(code.len));
    if (publish.ctxEngine(ctx).state.bracketed_paste) {
        c.attyx_send_input("\x1b[201~", 6);
    }
}

pub fn handleCopyAction(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    if (mgr.isVisible(.context_preview)) {
        if (g_context_bundle) |*bundle| {
            const diag_text = bundle.serializeDiagnostics() catch return;
            defer bundle.allocator.free(diag_text);
            c.attyx_clipboard_copy(diag_text.ptr, @intCast(diag_text.len));
        }
    } else {
        const code = blk: {
            if (g_ai_accumulator) |*acc| {
                const blocks = acc.reparse() catch break :blk @as(?[]const u8, null);
                if (overlay_content.firstCodeBlock(blocks)) |cb| break :blk @as(?[]const u8, cb);
            }
            break :blk overlay_content.firstCodeBlock(&overlay_demo.mock_blocks);
        } orelse return;
        c.attyx_clipboard_copy(code.ptr, @intCast(code.len));
    }
}

