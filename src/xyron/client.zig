// client.zig — Spawn and manage a xyron headless process.
//
// Creates two pipes (attyx→xyron stdin, xyron→attyx stdout),
// forks the xyron --headless child, and provides methods to
// send protocol requests and read events.

const std = @import("std");
const posix = std.posix;
const proto = @import("protocol.zig");

extern "c" fn waitpid(pid: std.c.pid_t, status: ?*c_int, options: c_int) std.c.pid_t;

pub const prompt_buf_size = 2048;

pub const State = enum {
    waiting_ready,
    idle,
    running_command,
};

pub const XyronClient = struct {
    /// Write protocol requests here (xyron's stdin)
    stdin_fd: posix.fd_t,
    /// Read protocol responses/events here (xyron's stdout)
    stdout_fd: posix.fd_t,
    /// Xyron child PID
    pid: posix.pid_t,
    /// Current lifecycle state
    state: State = .waiting_ready,
    /// Non-blocking frame reader
    reader: proto.FrameReader = .{},
    /// Request ID counter
    next_req_id: i64 = 1,

    /// Cached prompt from xyron (ANSI-formatted)
    prompt_buf: [prompt_buf_size]u8 = undefined,
    prompt_len: usize = 0,
    prompt_visible_len: usize = 0,
    prompt_lines: usize = 1,

    /// Last CWD reported by xyron
    cwd_buf: [std.fs.max_path_bytes]u8 = undefined,
    cwd_len: usize = 0,

    /// Thread-safe command input buffer for idle mode.
    /// Main thread appends chars; run_command sent when Enter is received.
    cmd_input: [4096]u8 = undefined,
    cmd_input_len: usize = 0,

    /// Echo queue: bytes that need to be fed to the engine for display.
    /// Written by main thread (appendIdleInput), read by PTY thread.
    echo_buf: [4096]u8 = undefined,
    echo_len: usize = 0,

    /// Spawn xyron --headless as a child process with pipes.
    pub fn spawn(xyron_path: [:0]const u8, cwd: ?[*:0]const u8) !XyronClient {
        // Create pipes: [0]=read, [1]=write
        const to_xyron = try posix.pipe(); // attyx writes [1], xyron reads [0]
        const from_xyron = try posix.pipe(); // xyron writes [1], attyx reads [0]

        const pid = try posix.fork();
        if (pid == 0) {
            // --- Child ---
            posix.close(to_xyron[1]);
            posix.close(from_xyron[0]);

            // Redirect stdin to our pipe
            _ = posix.dup2(to_xyron[0], posix.STDIN_FILENO) catch {};
            if (to_xyron[0] > 2) posix.close(to_xyron[0]);

            // Redirect stdout to our pipe
            _ = posix.dup2(from_xyron[1], posix.STDOUT_FILENO) catch {};
            if (from_xyron[1] > 2) posix.close(from_xyron[1]);

            // Set CWD if provided
            if (cwd) |dir| _ = std.c.chdir(dir);

            const c_execvp = struct {
                extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
            };
            const argv = [_:null]?[*:0]const u8{ xyron_path.ptr, "--headless" };
            _ = c_execvp.execvp(xyron_path.ptr, &argv);
            const c_exit = struct {
                extern "c" fn _exit(status: c_int) noreturn;
            };
            c_exit._exit(127);
        }

        // --- Parent ---
        posix.close(to_xyron[0]);
        posix.close(from_xyron[1]);

        // Set non-blocking on read fd
        const c_fcntl = struct {
            extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
        };
        const F_GETFL: c_int = 3;
        const F_SETFL: c_int = 4;
        const O_NONBLOCK: c_int = 0x0004;
        const flags = c_fcntl.fcntl(from_xyron[0], F_GETFL);
        _ = c_fcntl.fcntl(from_xyron[0], F_SETFL, flags | O_NONBLOCK);

        return .{
            .stdin_fd = to_xyron[1],
            .stdout_fd = from_xyron[0],
            .pid = pid,
        };
    }

    /// File descriptor to poll for incoming events.
    pub fn pollFd(self: *const XyronClient) posix.fd_t {
        return self.stdout_fd;
    }

    /// Get the next request ID.
    pub fn nextReqId(self: *XyronClient) i64 {
        const id = self.next_req_id;
        self.next_req_id += 1;
        return id;
    }

    /// Send init_session request.
    pub fn sendInitSession(self: *XyronClient) void {
        proto.sendInitSession(self.stdin_fd, self.nextReqId());
    }

    /// Send a command to execute.
    pub fn sendRunCommand(self: *XyronClient, command: []const u8) void {
        proto.sendRunCommand(self.stdin_fd, self.nextReqId(), command);
        self.state = .running_command;
    }

    /// Forward raw input bytes to running command's stdin.
    pub fn sendInput(self: *XyronClient, data: []const u8) void {
        proto.sendInput(self.stdin_fd, data);
    }

    /// Send terminal resize to xyron.
    pub fn sendResize(self: *XyronClient, rows: u16, cols: u16) void {
        proto.sendResize(self.stdin_fd, rows, cols);
    }

    /// Send interrupt (Ctrl+C).
    pub fn sendInterrupt(self: *XyronClient) void {
        proto.sendInterrupt(self.stdin_fd, self.nextReqId());
    }

    /// Try to read the next event/response frame. Non-blocking.
    /// Returns null if no complete frame available yet.
    pub fn readEvent(self: *XyronClient) ?proto.Frame {
        return self.reader.tryRead(self.stdout_fd) catch null;
    }

    /// Process a received frame, updating internal state.
    /// Returns true if the frame was an output_chunk (caller should feed to engine).
    pub fn handleFrame(self: *XyronClient, frame: proto.Frame) FrameAction {
        switch (frame.msg_type) {
            .evt_ready => {
                self.state = .idle;
                self.sendInitSession();
                return .ready;
            },
            .evt_prompt => {
                var r = proto.PayloadReader.init(frame.payload);
                const text = r.readStr();
                const visible_len: usize = @intCast(@max(r.readInt(), 0));
                const line_count: usize = @intCast(@max(r.readInt(), 1));
                const copy_len = @min(text.len, self.prompt_buf.len);
                @memcpy(self.prompt_buf[0..copy_len], text[0..copy_len]);
                self.prompt_len = copy_len;
                self.prompt_visible_len = visible_len;
                self.prompt_lines = line_count;
                return .prompt_updated;
            },
            .evt_command_started => {
                self.state = .running_command;
                return .command_started;
            },
            .evt_output_chunk => {
                return .output_chunk;
            },
            .evt_command_finished => {
                self.state = .idle;
                return .command_finished;
            },
            .evt_cwd_changed => {
                var r = proto.PayloadReader.init(frame.payload);
                _ = r.readStr(); // old cwd
                const new_cwd = r.readStr();
                const copy_len = @min(new_cwd.len, self.cwd_buf.len);
                @memcpy(self.cwd_buf[0..copy_len], new_cwd[0..copy_len]);
                self.cwd_len = copy_len;
                return .cwd_changed;
            },
            .evt_block_started => return .block_started,
            .evt_block_finished => return .block_finished,
            .resp_success, .resp_error => return .response,
            else => return .ignored,
        }
    }

    /// Get prompt text slice.
    pub fn promptText(self: *const XyronClient) []const u8 {
        return self.prompt_buf[0..self.prompt_len];
    }

    /// Append bytes to the idle command input buffer.
    /// On Enter (0x0D or 0x0A), submits the buffer as run_command.
    /// On Backspace (0x7F or 0x08), removes last byte.
    /// On Ctrl+C (0x03), clears the buffer.
    /// Called from the main thread — pipe writes are atomic for small sizes.
    pub fn appendIdleInput(self: *XyronClient, data: []const u8) void {
        for (data) |byte| {
            switch (byte) {
                0x0D, 0x0A => { // Enter
                    if (self.cmd_input_len > 0) {
                        self.sendRunCommand(self.cmd_input[0..self.cmd_input_len]);
                        self.echoBytes("\r\n");
                        self.cmd_input_len = 0;
                    }
                },
                0x7F, 0x08 => { // Backspace/Delete
                    if (self.cmd_input_len > 0) {
                        self.cmd_input_len -= 1;
                        self.echoBytes("\x08 \x08"); // BS + space + BS
                    }
                },
                0x03 => { // Ctrl+C
                    if (self.cmd_input_len > 0) {
                        // Erase typed text then show ^C
                        self.echoBytes("^C\r\n");
                        self.cmd_input_len = 0;
                        // Re-feed prompt
                        self.echoBytes(self.prompt_buf[0..self.prompt_len]);
                    }
                },
                0x15 => { // Ctrl+U — kill line
                    // Erase all typed chars visually
                    var i: usize = 0;
                    while (i < self.cmd_input_len) : (i += 1) {
                        self.echoBytes("\x08 \x08");
                    }
                    self.cmd_input_len = 0;
                },
                else => {
                    if (byte >= 0x20 and self.cmd_input_len < self.cmd_input.len) {
                        self.cmd_input[self.cmd_input_len] = byte;
                        self.cmd_input_len += 1;
                        self.echoBytes(&.{byte});
                    }
                },
            }
        }
    }

    fn echoBytes(self: *XyronClient, data: []const u8) void {
        const avail = self.echo_buf.len - self.echo_len;
        const n = @min(data.len, avail);
        @memcpy(self.echo_buf[self.echo_len..][0..n], data[0..n]);
        self.echo_len += n;
    }

    /// Drain echo buffer — called by the PTY thread to feed to engine.
    pub fn drainEcho(self: *XyronClient, out: []u8) usize {
        const n = @min(self.echo_len, out.len);
        if (n == 0) return 0;
        @memcpy(out[0..n], self.echo_buf[0..n]);
        // Shift remaining
        if (n < self.echo_len) {
            std.mem.copyForwards(u8, self.echo_buf[0..self.echo_len - n], self.echo_buf[n..self.echo_len]);
        }
        self.echo_len -= n;
        return n;
    }

    /// Get the current idle command input text.
    pub fn idleInputText(self: *const XyronClient) []const u8 {
        return self.cmd_input[0..self.cmd_input_len];
    }

    /// Get CWD slice.
    pub fn cwdText(self: *const XyronClient) []const u8 {
        return self.cwd_buf[0..self.cwd_len];
    }

    /// Check if xyron process is still alive.
    pub fn isAlive(self: *const XyronClient) bool {
        // WNOHANG = 1: returns 0 if still running, pid if exited
        const result = waitpid(self.pid, null, 1);
        return result == 0;
    }

    pub fn deinit(self: *XyronClient) void {
        posix.close(self.stdin_fd);
        posix.close(self.stdout_fd);
        _ = std.c.kill(self.pid, std.posix.SIG.TERM);
        _ = waitpid(self.pid, null, 0);
    }
};

pub const FrameAction = enum {
    ready,
    prompt_updated,
    command_started,
    output_chunk,
    command_finished,
    block_started,
    block_finished,
    cwd_changed,
    response,
    ignored,
};
