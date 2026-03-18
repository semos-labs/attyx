const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .windows => @import("pty_windows.zig"),
    else => @import("pty_posix.zig"),
};

pub const Pty = impl.Pty;
