// render.zig — Xyron block-based UI rendering helpers.

const std = @import("std");
const client_mod = @import("client.zig");
const attyx = @import("attyx");

/// Feed the xyron prompt into the pane's engine for native ANSI rendering.
pub fn feedPromptToEngine(pane: anytype, xc: *const client_mod.XyronClient) void {
    const prompt = xc.promptText();
    if (prompt.len == 0) return;
    pane.feedXyron(prompt);
}

/// Create a temporary engine, feed prompt + input, return the engine.
/// Caller must deinit. Returns null on allocation failure.
pub fn createPromptEngine(
    allocator: std.mem.Allocator,
    prompt_rows: u16,
    cols: u16,
    xc: *const client_mod.XyronClient,
) ?attyx.Engine {
    var eng = attyx.Engine.init(allocator, prompt_rows, cols, 0) catch return null;
    const prompt = xc.promptText();
    if (prompt.len > 0) eng.feed(prompt);
    const input_text = xc.idleInputText();
    if (input_text.len > 0) eng.feed(input_text);
    _ = eng.state.drainResponse();
    return eng;
}
