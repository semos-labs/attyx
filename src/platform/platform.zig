const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .macos => @import("macos.zig"),
    .linux => @import("linux.zig"),
    else => @compileError("Unsupported platform"),
};

pub const TIOCSWINSZ = impl.TIOCSWINSZ;
pub const TIOCSCTTY = impl.TIOCSCTTY;
pub const O_NONBLOCK = impl.O_NONBLOCK;
