// Linux-specific constants and platform behavior.

pub const TIOCSWINSZ: c_ulong = 0x5414;
pub const TIOCSCTTY: c_ulong = 0x540E;
pub const O_NONBLOCK: usize = 0x0800;
