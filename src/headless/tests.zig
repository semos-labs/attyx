//! Test barrel — imports all feature-specific test modules for discovery.
test {
    _ = @import("tests/helpers.zig");
    _ = @import("tests/text.zig");
    _ = @import("tests/parser.zig");
    _ = @import("tests/csi.zig");
    _ = @import("tests/scroll.zig");
    _ = @import("tests/screen.zig");
    _ = @import("tests/color.zig");
    _ = @import("tests/osc.zig");
    _ = @import("tests/modes.zig");
    _ = @import("tests/scrollback.zig");
    _ = @import("tests/search.zig");
}
