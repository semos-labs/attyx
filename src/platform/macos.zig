// macOS-specific constants and platform behavior.

pub const TIOCSWINSZ: c_ulong = 0x80087467;
pub const TIOCSCTTY: c_ulong = 0x20007461;
pub const O_NONBLOCK: usize = 0x0004;
