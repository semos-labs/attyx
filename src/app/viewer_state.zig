// Attyx — ViewerState: per-viewer (client-side) UI state for a Pane.
//
// In plain mode the engine and viewer both live on the client, so this
// struct is filled in-process. In session mode (daemon owns the engine)
// the same fields are still owned by the client — each attached viewer
// can scroll independently, hold its own search highlights, etc.
//
// Phase 1: scaffolding only. viewport_offset is still driven by the
// engine in TerminalState; consumers will migrate to ViewerState in
// Phase 2 when the engine moves daemon-side and viewport becomes a
// purely client-side concept.

const std = @import("std");

pub const ViewerState = struct {
    /// Scrollback scroll position. 0 = pinned to live screen;
    /// N = scrolled up N rows into history.
    viewport_offset: usize = 0,
};
