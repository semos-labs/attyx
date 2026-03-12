// Attyx — IPC subcommand parser
//
// Parses two-level CLI subcommands for IPC control:
//   attyx tab create [--cmd <cmd>]
//   attyx tab close
//   attyx focus left
//   attyx send-text "hello"
//   etc.
//
// Every subcommand supports --help / -h.
// Help text lives in cli_ipc_help.zig (split for the 600-line limit).

const std = @import("std");
const help = @import("cli_ipc_help.zig");

pub const IpcCommand = enum {
    tab_create,
    tab_close,
    tab_next,
    tab_prev,
    tab_select,
    tab_move_left,
    tab_move_right,
    tab_rename,
    split_vertical,
    split_horizontal,
    split_close,
    split_rotate,
    split_zoom,
    focus_up,
    focus_down,
    focus_left,
    focus_right,
    send_keys,
    send_text,
    get_text,
    config_reload,
    theme_set,
    scroll_to_top,
    scroll_to_bottom,
    scroll_page_up,
    scroll_page_down,
    list,
    list_tabs,
    list_splits,
    popup,
    session_list,
    session_create,
    session_kill,
    session_switch,
    session_rename,
};

pub const IpcRequest = struct {
    command: IpcCommand,
    text_arg: []const u8 = "",
    index_arg: u8 = 0,
    session_id_arg: u32 = 0,
    target_pid: ?u32 = null,
    json_output: bool = false,
    wait: bool = false,
    background: bool = false,
    width_pct: u8 = 80,
    height_pct: u8 = 80,
    border_style: u8 = 2, // 0=single, 1=double, 2=rounded, 3=heavy, 4=none
    /// Pane targeting by stable IPC ID. 0 = active/focused (default).
    pane_id: u32 = 0,
    /// Tab targeting by 0-based index. 0xFF = active (default).
    tab_idx: u8 = 0xFF,
};

fn fatal(msg: []const u8) noreturn {
    std.debug.print("error: {s}\n", .{msg});
    std.process.exit(1);
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn showHelp(comptime text: []const u8) noreturn {
    std.fs.File.stderr().writeAll(text) catch {};
    std.process.exit(0);
}

fn printHelp(comptime text: []const u8) void {
    std.fs.File.stderr().writeAll(text) catch {};
}

/// Parse --pane/-p argument: a flat stable IPC ID (e.g. "5").
fn parsePaneArg(arg: []const u8, result: *IpcRequest) void {
    result.pane_id = std.fmt.parseInt(u32, arg, 10) catch fatal("--pane: invalid pane ID");
    if (result.pane_id == 0) fatal("--pane: pane ID must be >= 1");
}

/// Check if any arg after `start` is --help / -h.
fn hasHelp(args: []const [:0]const u8, start: usize) bool {
    for (args[start + 1 ..]) |a| {
        if (isHelp(a)) return true;
    }
    return false;
}

pub fn printUsage() void {
    printHelp(help.top_level);
}

/// Parse IPC subcommands. Returns null on unrecognized input (after printing help).
pub fn parse(args: []const [:0]const u8) ?IpcRequest {
    if (args.len < 2) {
        printUsage();
        return null;
    }

    var target_pid: ?u32 = null;
    var json_output: bool = false;
    var start: usize = 1;

    // Parse global flags (--target, --json) before subcommand
    while (start < args.len) {
        if (std.mem.eql(u8, args[start], "--target")) {
            if (start + 1 >= args.len) fatal("--target requires a PID value");
            target_pid = std.fmt.parseInt(u32, args[start + 1], 10) catch fatal("invalid --target PID");
            start += 2;
        } else if (std.mem.eql(u8, args[start], "--json")) {
            json_output = true;
            start += 1;
        } else break;
    }

    if (start >= args.len) {
        printUsage();
        return null;
    }

    const sub = args[start];

    if (isHelp(sub)) showHelp(help.top_level);
    if (std.mem.eql(u8, sub, "tab")) return parseTab(args, start, target_pid, json_output);
    if (std.mem.eql(u8, sub, "split")) return parseSplit(args, start, target_pid, json_output);
    if (std.mem.eql(u8, sub, "focus")) return parseFocus(args, start, target_pid, json_output);

    if (std.mem.eql(u8, sub, "send-keys")) {
        if (hasHelp(args, start)) showHelp(help.send_keys);
        return parseSendText(args, start, .send_keys, target_pid, json_output);
    }
    if (std.mem.eql(u8, sub, "send-text")) {
        if (hasHelp(args, start)) showHelp(help.send_text);
        return parseSendText(args, start, .send_text, target_pid, json_output);
    }
    if (std.mem.eql(u8, sub, "get-text")) {
        if (hasHelp(args, start)) showHelp(help.get_text);
        var gt_result = IpcRequest{ .command = .get_text, .target_pid = target_pid, .json_output = json_output };
        var gi = start + 1;
        while (gi < args.len) {
            if (std.mem.eql(u8, args[gi], "--pane") or std.mem.eql(u8, args[gi], "-p")) {
                if (gi + 1 >= args.len) fatal("--pane requires a pane ID");
                gi += 1;
                parsePaneArg(args[gi], &gt_result);
            }
            gi += 1;
        }
        return gt_result;
    }
    if (std.mem.eql(u8, sub, "reload")) {
        if (hasHelp(args, start)) showHelp(help.reload);
        return .{ .command = .config_reload, .target_pid = target_pid, .json_output = json_output };
    }
    if (std.mem.eql(u8, sub, "theme")) {
        if (hasHelp(args, start)) showHelp(help.theme);
        if (start + 1 >= args.len) { printHelp(help.theme); return null; }
        return .{ .command = .theme_set, .text_arg = args[start + 1], .target_pid = target_pid, .json_output = json_output };
    }
    if (std.mem.eql(u8, sub, "scroll-to")) return parseScrollTo(args, start, target_pid, json_output);
    if (std.mem.eql(u8, sub, "popup")) return parsePopup(args, start, target_pid, json_output);
    if (std.mem.eql(u8, sub, "list")) return parseList(args, start, target_pid, json_output);
    if (std.mem.eql(u8, sub, "session")) return parseSession(args, start, target_pid, json_output);
    if (std.mem.eql(u8, sub, "run")) {
        if (hasHelp(args, start)) showHelp(help.run);
        if (start + 1 >= args.len) { printHelp(help.run); return null; }
        var run_cmd: []const u8 = "";
        var run_wait = false;
        var ri = start + 1;
        while (ri < args.len) {
            if (std.mem.eql(u8, args[ri], "--wait") or std.mem.eql(u8, args[ri], "-w")) {
                run_wait = true;
            } else if (run_cmd.len == 0) {
                run_cmd = args[ri];
            }
            ri += 1;
        }
        if (run_cmd.len == 0) { printHelp(help.run); return null; }
        return .{ .command = .tab_create, .text_arg = run_cmd, .target_pid = target_pid, .json_output = json_output, .wait = run_wait };
    }

    std.debug.print("error: unknown command '{s}'\n\n", .{sub});
    printUsage();
    return null;
}

// ---------------------------------------------------------------------------
// Tab
// ---------------------------------------------------------------------------

fn parseTab(args: []const [:0]const u8, start: usize, target_pid: ?u32, json_output: bool) ?IpcRequest {
    if (start + 1 >= args.len or isHelp(args[start + 1])) {
        if (start + 1 < args.len and isHelp(args[start + 1])) showHelp(help.tab);
        printHelp(help.tab);
        return null;
    }
    const action = args[start + 1];
    if (std.mem.eql(u8, action, "create")) {
        if (hasHelp(args, start + 1)) showHelp(help.tab_create);
        var cmd: []const u8 = "";
        var wait = false;
        var i = start + 2;
        while (i < args.len) {
            if (std.mem.eql(u8, args[i], "--cmd")) {
                if (i + 1 < args.len) {
                    cmd = args[i + 1];
                    i += 2;
                } else i += 1;
            } else if (std.mem.eql(u8, args[i], "--wait") or std.mem.eql(u8, args[i], "-w")) {
                wait = true;
                i += 1;
            } else i += 1;
        }
        return .{ .command = .tab_create, .text_arg = cmd, .target_pid = target_pid, .json_output = json_output, .wait = wait };
    } else if (std.mem.eql(u8, action, "close") or std.mem.eql(u8, action, "kill")) {
        var result = IpcRequest{ .command = .tab_close, .target_pid = target_pid, .json_output = json_output };
        if (start + 2 < args.len) {
            const tab_arg = args[start + 2];
            const n = std.fmt.parseInt(u8, tab_arg, 10) catch fatal("tab number must be an integer");
            if (n < 1) fatal("tab number must be >= 1");
            result.tab_idx = n - 1;
        }
        return result;
    } else if (std.mem.eql(u8, action, "next")) {
        return .{ .command = .tab_next, .target_pid = target_pid, .json_output = json_output };
    } else if (std.mem.eql(u8, action, "prev")) {
        return .{ .command = .tab_prev, .target_pid = target_pid, .json_output = json_output };
    } else if (std.mem.eql(u8, action, "select")) {
        if (hasHelp(args, start + 1)) showHelp(help.tab_select);
        if (start + 2 >= args.len) { printHelp(help.tab_select); return null; }
        const idx = std.fmt.parseInt(u8, args[start + 2], 10) catch fatal("tab index must be 1-9");
        if (idx < 1 or idx > 9) fatal("tab index must be 1-9");
        return .{ .command = .tab_select, .index_arg = idx, .target_pid = target_pid, .json_output = json_output };
    } else if (std.mem.eql(u8, action, "move")) {
        if (start + 2 >= args.len or isHelp(args[start + 2])) {
            if (start + 2 < args.len and isHelp(args[start + 2])) showHelp(help.tab_move);
            printHelp(help.tab_move);
            return null;
        }
        const dir = args[start + 2];
        if (std.mem.eql(u8, dir, "left")) return .{ .command = .tab_move_left, .target_pid = target_pid, .json_output = json_output };
        if (std.mem.eql(u8, dir, "right")) return .{ .command = .tab_move_right, .target_pid = target_pid, .json_output = json_output };
        std.debug.print("error: unknown direction '{s}'\n\n", .{dir});
        printHelp(help.tab_move);
        return null;
    } else if (std.mem.eql(u8, action, "rename")) {
        if (hasHelp(args, start + 1)) showHelp(help.tab_rename);
        if (start + 2 >= args.len) { printHelp(help.tab_rename); return null; }
        // Try: tab rename <N> <name>  or  tab rename <name>
        if (start + 3 < args.len) {
            if (std.fmt.parseInt(u8, args[start + 2], 10)) |n| {
                if (n < 1) fatal("tab number must be >= 1");
                return .{ .command = .tab_rename, .tab_idx = n - 1, .text_arg = args[start + 3], .target_pid = target_pid, .json_output = json_output };
            } else |_| {}
        }
        return .{ .command = .tab_rename, .text_arg = args[start + 2], .target_pid = target_pid, .json_output = json_output };
    }
    std.debug.print("error: unknown tab command '{s}'\n\n", .{action});
    printHelp(help.tab);
    return null;
}

// ---------------------------------------------------------------------------
// Split
// ---------------------------------------------------------------------------

fn parseSplit(args: []const [:0]const u8, start: usize, target_pid: ?u32, json_output: bool) ?IpcRequest {
    if (start + 1 >= args.len or isHelp(args[start + 1])) {
        if (start + 1 < args.len and isHelp(args[start + 1])) showHelp(help.split);
        printHelp(help.split);
        return null;
    }
    const action = args[start + 1];
    if (std.mem.eql(u8, action, "vertical") or std.mem.eql(u8, action, "v")) {
        if (hasHelp(args, start + 1)) showHelp(help.split_create);
        var cmd: []const u8 = "";
        var wait = false;
        var i = start + 2;
        while (i < args.len) {
            if (std.mem.eql(u8, args[i], "--cmd")) {
                if (i + 1 < args.len) {
                    cmd = args[i + 1];
                    i += 2;
                } else i += 1;
            } else if (std.mem.eql(u8, args[i], "--wait") or std.mem.eql(u8, args[i], "-w")) {
                wait = true;
                i += 1;
            } else i += 1;
        }
        return .{ .command = .split_vertical, .text_arg = cmd, .target_pid = target_pid, .json_output = json_output, .wait = wait };
    } else if (std.mem.eql(u8, action, "horizontal") or std.mem.eql(u8, action, "h")) {
        if (hasHelp(args, start + 1)) showHelp(help.split_create);
        var cmd: []const u8 = "";
        var wait = false;
        var i = start + 2;
        while (i < args.len) {
            if (std.mem.eql(u8, args[i], "--cmd")) {
                if (i + 1 < args.len) {
                    cmd = args[i + 1];
                    i += 2;
                } else i += 1;
            } else if (std.mem.eql(u8, args[i], "--wait") or std.mem.eql(u8, args[i], "-w")) {
                wait = true;
                i += 1;
            } else i += 1;
        }
        return .{ .command = .split_horizontal, .text_arg = cmd, .target_pid = target_pid, .json_output = json_output, .wait = wait };
    } else if (std.mem.eql(u8, action, "close") or std.mem.eql(u8, action, "kill")) {
        var result = IpcRequest{ .command = .split_close, .target_pid = target_pid, .json_output = json_output };
        var i = start + 2;
        while (i < args.len) {
            if ((std.mem.eql(u8, args[i], "--pane") or std.mem.eql(u8, args[i], "-p")) and i + 1 < args.len) {
                i += 1;
                parsePaneArg(args[i], &result);
            }
            i += 1;
        }
        return result;
    } else if (std.mem.eql(u8, action, "rotate")) {
        var result = IpcRequest{ .command = .split_rotate, .target_pid = target_pid, .json_output = json_output };
        var i = start + 2;
        while (i < args.len) {
            if ((std.mem.eql(u8, args[i], "--pane") or std.mem.eql(u8, args[i], "-p")) and i + 1 < args.len) {
                i += 1;
                parsePaneArg(args[i], &result);
            }
            i += 1;
        }
        return result;
    } else if (std.mem.eql(u8, action, "zoom")) {
        var result = IpcRequest{ .command = .split_zoom, .target_pid = target_pid, .json_output = json_output };
        var i = start + 2;
        while (i < args.len) {
            if ((std.mem.eql(u8, args[i], "--pane") or std.mem.eql(u8, args[i], "-p")) and i + 1 < args.len) {
                i += 1;
                parsePaneArg(args[i], &result);
            }
            i += 1;
        }
        return result;
    }
    std.debug.print("error: unknown split command '{s}'\n\n", .{action});
    printHelp(help.split);
    return null;
}

// ---------------------------------------------------------------------------
// Focus
// ---------------------------------------------------------------------------

fn parseFocus(args: []const [:0]const u8, start: usize, target_pid: ?u32, json_output: bool) ?IpcRequest {
    if (start + 1 >= args.len or isHelp(args[start + 1])) {
        if (start + 1 < args.len and isHelp(args[start + 1])) showHelp(help.focus);
        printHelp(help.focus);
        return null;
    }
    const dir = args[start + 1];
    if (std.mem.eql(u8, dir, "up")) return .{ .command = .focus_up, .target_pid = target_pid, .json_output = json_output };
    if (std.mem.eql(u8, dir, "down")) return .{ .command = .focus_down, .target_pid = target_pid, .json_output = json_output };
    if (std.mem.eql(u8, dir, "left")) return .{ .command = .focus_left, .target_pid = target_pid, .json_output = json_output };
    if (std.mem.eql(u8, dir, "right")) return .{ .command = .focus_right, .target_pid = target_pid, .json_output = json_output };
    std.debug.print("error: unknown direction '{s}'\n\n", .{dir});
    printHelp(help.focus);
    return null;
}

// ---------------------------------------------------------------------------
// Send text / keys
// ---------------------------------------------------------------------------

fn parseSendText(args: []const [:0]const u8, start: usize, cmd: IpcCommand, target_pid: ?u32, json_output: bool) ?IpcRequest {
    var result = IpcRequest{
        .command = cmd,
        .target_pid = target_pid,
        .json_output = json_output,
    };

    var i = start + 1;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--pane") or std.mem.eql(u8, arg, "-p")) {
            if (i + 1 >= args.len) fatal("--pane requires a pane ID");
            i += 1;
            parsePaneArg(args[i], &result);
        } else if (result.text_arg.len == 0) {
            result.text_arg = arg;
        }
        i += 1;
    }

    if (result.text_arg.len == 0) {
        if (cmd == .send_keys) {
            printHelp(help.send_keys);
        } else {
            printHelp(help.send_text);
        }
        return null;
    }
    return result;
}

// ---------------------------------------------------------------------------
// Scroll-to
// ---------------------------------------------------------------------------

fn parseScrollTo(args: []const [:0]const u8, start: usize, target_pid: ?u32, json_output: bool) ?IpcRequest {
    if (start + 1 >= args.len or isHelp(args[start + 1])) {
        if (start + 1 < args.len and isHelp(args[start + 1])) showHelp(help.scroll_to);
        printHelp(help.scroll_to);
        return null;
    }
    const pos = args[start + 1];
    if (std.mem.eql(u8, pos, "top")) return .{ .command = .scroll_to_top, .target_pid = target_pid, .json_output = json_output };
    if (std.mem.eql(u8, pos, "bottom")) return .{ .command = .scroll_to_bottom, .target_pid = target_pid, .json_output = json_output };
    std.debug.print("error: unknown position '{s}'\n\n", .{pos});
    printHelp(help.scroll_to);
    return null;
}

// ---------------------------------------------------------------------------
// Popup
// ---------------------------------------------------------------------------

fn parsePopup(args: []const [:0]const u8, start: usize, target_pid: ?u32, json_output: bool) ?IpcRequest {
    if (start + 1 >= args.len or isHelp(args[start + 1])) {
        if (start + 1 < args.len and isHelp(args[start + 1])) showHelp(help.popup);
        printHelp(help.popup);
        return null;
    }

    var result = IpcRequest{
        .command = .popup,
        .target_pid = target_pid,
        .json_output = json_output,
    };

    var i = start + 1;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--width") or std.mem.eql(u8, arg, "-w")) {
            if (i + 1 >= args.len) fatal("--width requires a value (1-100)");
            i += 1;
            result.width_pct = std.fmt.parseInt(u8, args[i], 10) catch fatal("--width must be 1-100");
            if (result.width_pct < 1 or result.width_pct > 100) fatal("--width must be 1-100");
        } else if (std.mem.eql(u8, arg, "--height")) {
            if (i + 1 >= args.len) fatal("--height requires a value (1-100)");
            i += 1;
            result.height_pct = std.fmt.parseInt(u8, args[i], 10) catch fatal("--height must be 1-100");
            if (result.height_pct < 1 or result.height_pct > 100) fatal("--height must be 1-100");
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            showHelp(help.popup);
        } else if (std.mem.eql(u8, arg, "--border") or std.mem.eql(u8, arg, "-b")) {
            if (i + 1 >= args.len) fatal("--border requires a value");
            i += 1;
            const bs = args[i];
            if (std.mem.eql(u8, bs, "single")) {
                result.border_style = 0;
            } else if (std.mem.eql(u8, bs, "double")) {
                result.border_style = 1;
            } else if (std.mem.eql(u8, bs, "rounded")) {
                result.border_style = 2;
            } else if (std.mem.eql(u8, bs, "heavy")) {
                result.border_style = 3;
            } else if (std.mem.eql(u8, bs, "none")) {
                result.border_style = 4;
            } else {
                fatal("--border must be single, double, rounded, heavy, or none");
            }
        } else if (result.text_arg.len == 0) {
            result.text_arg = arg;
        } else {
            std.debug.print("error: unexpected argument '{s}'\n\n", .{arg});
            printHelp(help.popup);
            return null;
        }
        i += 1;
    }

    if (result.text_arg.len == 0) {
        printHelp(help.popup);
        return null;
    }

    return result;
}

// ---------------------------------------------------------------------------
// List
// ---------------------------------------------------------------------------

fn parseList(args: []const [:0]const u8, start: usize, target_pid: ?u32, json_output: bool) ?IpcRequest {
    if (start + 1 >= args.len) {
        // Bare `attyx list` — show full tree
        return .{ .command = .list, .target_pid = target_pid, .json_output = json_output };
    }
    const sub = args[start + 1];
    if (isHelp(sub)) showHelp(help.list);
    if (std.mem.eql(u8, sub, "sessions")) {
        return .{ .command = .session_list, .target_pid = target_pid, .json_output = json_output };
    } else if (std.mem.eql(u8, sub, "tabs")) {
        return .{ .command = .list_tabs, .target_pid = target_pid, .json_output = json_output };
    } else if (std.mem.eql(u8, sub, "splits") or std.mem.eql(u8, sub, "panes")) {
        return .{ .command = .list_splits, .target_pid = target_pid, .json_output = json_output };
    }
    std.debug.print("error: unknown list target '{s}'\n\n", .{sub});
    printHelp(help.list);
    return null;
}

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

fn parseSession(args: []const [:0]const u8, start: usize, target_pid: ?u32, json_output: bool) ?IpcRequest {
    if (start + 1 >= args.len or isHelp(args[start + 1])) {
        if (start + 1 < args.len and isHelp(args[start + 1])) showHelp(help.session);
        printHelp(help.session);
        return null;
    }
    const action = args[start + 1];
    if (std.mem.eql(u8, action, "list")) {
        return .{ .command = .session_list, .target_pid = target_pid, .json_output = json_output };
    } else if (std.mem.eql(u8, action, "create")) {
        if (hasHelp(args, start + 1)) showHelp(help.session_create);
        var bg = false;
        var name: []const u8 = "";
        var i = start + 2;
        while (i < args.len) {
            if (std.mem.eql(u8, args[i], "-b") or std.mem.eql(u8, args[i], "--background")) {
                bg = true;
            } else if (name.len == 0) {
                name = args[i];
            }
            i += 1;
        }
        return .{ .command = .session_create, .text_arg = name, .background = bg, .target_pid = target_pid, .json_output = json_output };
    } else if (std.mem.eql(u8, action, "kill")) {
        if (hasHelp(args, start + 1)) showHelp(help.session_kill);
        if (start + 2 >= args.len) { printHelp(help.session_kill); return null; }
        const id = std.fmt.parseInt(u32, args[start + 2], 10) catch fatal("invalid session id");
        return .{ .command = .session_kill, .session_id_arg = id, .target_pid = target_pid, .json_output = json_output };
    } else if (std.mem.eql(u8, action, "switch")) {
        if (hasHelp(args, start + 1)) showHelp(help.session_switch);
        if (start + 2 >= args.len) { printHelp(help.session_switch); return null; }
        const id = std.fmt.parseInt(u32, args[start + 2], 10) catch fatal("invalid session id");
        return .{ .command = .session_switch, .session_id_arg = id, .target_pid = target_pid, .json_output = json_output };
    } else if (std.mem.eql(u8, action, "rename")) {
        if (hasHelp(args, start + 1)) showHelp(help.session_rename);
        if (start + 2 >= args.len) { printHelp(help.session_rename); return null; }
        // Try `session rename <id> <name>` first, fall back to `session rename <name>` (current session)
        if (start + 3 < args.len) {
            if (std.fmt.parseInt(u32, args[start + 2], 10)) |id| {
                return .{ .command = .session_rename, .session_id_arg = id, .text_arg = args[start + 3], .target_pid = target_pid, .json_output = json_output };
            } else |_| {}
        }
        // No id or parse failed — rename current session
        return .{ .command = .session_rename, .session_id_arg = 0, .text_arg = args[start + 2], .target_pid = target_pid, .json_output = json_output };
    }
    std.debug.print("error: unknown session command '{s}'\n\n", .{action});
    printHelp(help.session);
    return null;
}
