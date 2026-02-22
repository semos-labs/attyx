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

pub const render_color = @import("render/color.zig");

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
    _ = @import("headless/runner.zig");
    _ = @import("headless/tests.zig");
}
