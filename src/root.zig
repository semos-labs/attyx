//! Attyx — a deterministic VT-compatible terminal state machine.
//!
//! This is the library root. It re-exports the core types so consumers
//! can write `const attyx = @import("attyx");` and reach everything.

pub const actions = @import("term/actions.zig");
pub const grid = @import("term/grid.zig");
pub const parser = @import("term/parser.zig");
pub const csi = @import("term/csi.zig");
pub const state = @import("term/state.zig");
pub const sgr = @import("term/sgr.zig");
pub const snapshot = @import("term/snapshot.zig");
pub const engine = @import("term/engine.zig");
pub const input = @import("term/input.zig");
pub const key_encode = @import("term/key_encode.zig");

pub const scrollback = @import("term/scrollback.zig");
pub const search = @import("term/search.zig");
pub const dirty = @import("term/dirty.zig");
pub const hash = @import("term/hash.zig");
pub const render_color = @import("render/color.zig");
pub const graphics_cmd = @import("term/graphics_cmd.zig");
pub const graphics_store = @import("term/graphics_store.zig");
pub const graphics_decode = @import("term/graphics_decode.zig");

pub const overlay_mod = @import("overlay/overlay.zig");
pub const overlay_layout = @import("overlay/layout.zig");
pub const overlay_anchor = @import("overlay/anchor.zig");
pub const overlay_action = @import("overlay/action.zig");
pub const overlay_content = @import("overlay/content.zig");
pub const overlay_streaming = @import("overlay/streaming.zig");
pub const overlay_demo = @import("overlay/demo.zig");
pub const overlay_search = @import("overlay/search.zig");
pub const overlay_context_extract = @import("overlay/context_extract.zig");
pub const overlay_context = @import("overlay/context.zig");
pub const overlay_context_ui = @import("overlay/context_ui.zig");
pub const overlay_ai_config = @import("overlay/ai_config.zig");
pub const overlay_ai_auth = @import("overlay/ai_auth.zig");
pub const overlay_ai_stream = @import("overlay/ai_stream.zig");
pub const overlay_ai_content = @import("overlay/ai_content.zig");
pub const overlay_ai_error = @import("overlay/ai_error.zig");

pub const Action = actions.Action;
pub const ControlCode = actions.ControlCode;
pub const Direction = actions.Direction;
pub const EraseMode = actions.EraseMode;
pub const Sgr = actions.Sgr;
pub const ScrollRegion = actions.ScrollRegion;
pub const MouseTrackingMode = actions.MouseTrackingMode;
pub const DecPrivateModes = actions.DecPrivateModes;
pub const SavedCursor = state.SavedCursor;
pub const Cell = grid.Cell;
pub const Grid = grid.Grid;
pub const Color = grid.Color;
pub const Style = grid.Style;
pub const Parser = parser.Parser;
pub const TerminalState = state.TerminalState;
pub const Cursor = state.Cursor;
pub const Engine = engine.Engine;
pub const MouseEvent = input.MouseEvent;
pub const MouseButton = input.MouseButton;
pub const MouseEventKind = input.MouseEventKind;
pub const Scrollback = scrollback.Scrollback;
pub const SearchState = search.SearchState;
pub const SearchMatch = search.SearchMatch;
pub const DirtyRows = dirty.DirtyRows;

test {
    _ = @import("term/actions.zig");
    _ = @import("term/grid.zig");
    _ = @import("term/parser.zig");
    _ = @import("term/csi.zig");
    _ = @import("term/sgr.zig");
    _ = @import("term/state.zig");
    _ = @import("term/snapshot.zig");
    _ = @import("term/engine.zig");
    _ = @import("term/input.zig");
    _ = @import("term/scrollback.zig");
    _ = @import("term/search.zig");
    _ = @import("term/dirty.zig");
    _ = @import("term/hash.zig");
    _ = @import("term/graphics_cmd.zig");
    _ = @import("term/graphics_store.zig");
    _ = @import("term/graphics_decode.zig");
    _ = @import("term/state_report.zig");
    _ = @import("term/state_graphics.zig");
    _ = @import("term/key_encode.zig");
    _ = @import("term/key_encode_test.zig");
    _ = @import("headless/runner.zig");
    _ = @import("headless/tests.zig");
    _ = @import("overlay/overlay.zig");
    _ = @import("overlay/layout.zig");
    _ = @import("overlay/anchor.zig");
    _ = @import("overlay/action.zig");
    _ = @import("overlay/content.zig");
    _ = @import("overlay/streaming.zig");
    _ = @import("overlay/demo.zig");
    _ = @import("overlay/search.zig");
    _ = @import("overlay/context_extract.zig");
    _ = @import("overlay/context.zig");
    _ = @import("overlay/context_ui.zig");
    _ = @import("overlay/ai_config.zig");
    _ = @import("overlay/ai_auth.zig");
    _ = @import("overlay/ai_stream.zig");
    _ = @import("overlay/ai_content.zig");
    _ = @import("overlay/ai_error.zig");
}
