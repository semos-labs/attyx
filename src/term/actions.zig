/// The set of control codes handled by the terminal.
pub const ControlCode = enum {
    lf,
    cr,
    bs,
    tab,
};

/// Direction for relative cursor movement (CUU/CUD/CUF/CUB).
pub const Direction = enum {
    up,
    down,
    right,
    left,
};

/// Mode argument for erase operations (ED / EL).
pub const EraseMode = enum(u2) {
    to_end = 0,
    to_start = 1,
    all = 2,
};

/// Absolute cursor positioning (CUP). Values are 0-based.
/// The parser converts from the 1-based CSI encoding.
pub const CursorAbs = struct {
    row: u16 = 0,
    col: u16 = 0,
};

/// Relative cursor movement (CUU / CUD / CUF / CUB).
pub const CursorRel = struct {
    dir: Direction,
    n: u16 = 1,
};

/// SGR (Select Graphic Rendition) parameters.
/// Carries the raw numeric codes for the state to interpret.
pub const Sgr = struct {
    params: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    len: u8 = 0,
};

/// Scroll region bounds (1-based, 0 = use default).
/// The state converts to 0-based and validates.
pub const ScrollRegion = struct {
    top: u16 = 0,
    bottom: u16 = 0,
};

/// Cursor shape set by DECSCUSR (CSI Ps SP q).
pub const CursorShape = enum(u3) {
    blinking_block = 0,
    steady_block = 1,
    blinking_underline = 2,
    steady_underline = 3,
    blinking_bar = 4,
    steady_bar = 5,
};

/// Mouse tracking mode, controlled by DEC private modes 1000/1002/1003.
pub const MouseTrackingMode = enum {
    off,
    x10,
    button_event,
    any_event,
};

/// Payload for a DEC private mode set (h) or reset (l) sequence.
/// Carries up to 8 mode numbers so multi-param sequences like
/// ESC[?1000;1006h can be applied atomically.
pub const DecPrivateModes = struct {
    params: [8]u16 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    len: u8 = 0,
    set: bool = true,
};

/// A single terminal action produced by the parser.
///
/// The parser converts raw bytes into Actions; TerminalState
/// consumes Actions and mutates the grid.
pub const Action = union(enum) {
    /// Write a printable character (Unicode codepoint) at the cursor position.
    print: u21,
    /// Execute a C0 control code (LF, CR, BS, TAB).
    control: ControlCode,
    /// No-op: ignored byte or unsupported escape sequence.
    nop,
    /// CSI H / f — set cursor to absolute position (0-based).
    cursor_abs: CursorAbs,
    /// CSI A/B/C/D — move cursor relative to current position.
    cursor_rel: CursorRel,
    /// CSI J — erase in display.
    erase_display: EraseMode,
    /// CSI K — erase in line.
    erase_line: EraseMode,
    /// CSI m — select graphic rendition (colors, bold, underline).
    sgr: Sgr,
    /// CSI r — DECSTBM: set top and bottom scroll margins.
    set_scroll_region: ScrollRegion,
    /// ESC D — Index: move cursor down, scroll within region if at bottom.
    index,
    /// ESC M — Reverse Index: move cursor up, scroll within region if at top.
    reverse_index,
    /// ESC[?1049h / ?47h / ?1047h — switch to alternate screen buffer.
    enter_alt_screen,
    /// ESC[?1049l / ?47l / ?1047l — switch back to main screen buffer.
    leave_alt_screen,
    /// ESC 7 / CSI s — save cursor position + attributes.
    save_cursor,
    /// ESC 8 / CSI u — restore cursor position + attributes.
    restore_cursor,
    /// OSC 8 — start a hyperlink. Payload is a URI borrowed from parser buffer.
    hyperlink_start: []const u8,
    /// OSC 8 with empty URI — end current hyperlink.
    hyperlink_end,
    /// OSC 0/2 — set terminal title. Payload borrowed from parser buffer.
    set_title: []const u8,
    /// CSI E — move cursor down n rows, set column to 0.
    cursor_next_line: u16,
    /// CSI F — move cursor up n rows, set column to 0.
    cursor_prev_line: u16,
    /// CSI L — insert n blank lines at cursor, pushing content down.
    insert_lines: u16,
    /// CSI M — delete n lines at cursor, pulling content up.
    delete_lines: u16,
    /// CSI @ — insert n blank characters at cursor, shifting right.
    insert_chars: u16,
    /// CSI P — delete n characters at cursor, shifting left.
    delete_chars: u16,
    /// CSI X — erase n characters at cursor (no shift, just blank).
    erase_chars: u16,
    /// CSI G — move cursor to absolute column (0-based).
    cursor_col_abs: u16,
    /// CSI d — move cursor to absolute row (0-based).
    cursor_row_abs: u16,
    /// CSI S — scroll up n lines within scroll region.
    scroll_up: u16,
    /// CSI T — scroll down n lines within scroll region.
    scroll_down: u16,
    /// DEC private mode set/reset (ESC[?...h / ESC[?...l).
    /// Carries all mode params; state iterates and applies each.
    dec_private_mode: DecPrivateModes,

    /// CSI 5 n — Device Status Report: terminal OK.
    device_status,
    /// CSI 6 n — Cursor Position Report.
    cursor_position_report,
    /// CSI c / CSI 0 c — Primary Device Attributes (DA1).
    device_attributes,
    /// CSI > c / CSI > 0 c — Secondary Device Attributes (DA2).
    secondary_device_attributes,
    /// CSI Ps SP q — DECSCUSR: set cursor shape.
    set_cursor_shape: CursorShape,
};
