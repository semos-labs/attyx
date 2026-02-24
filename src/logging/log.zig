const std = @import("std");

pub const Level = enum(u8) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,
    trace = 4,

    pub fn fromString(s: []const u8) ?Level {
        if (std.mem.eql(u8, s, "err") or std.mem.eql(u8, s, "error")) return .err;
        if (std.mem.eql(u8, s, "warn") or std.mem.eql(u8, s, "warning")) return .warn;
        if (std.mem.eql(u8, s, "info")) return .info;
        if (std.mem.eql(u8, s, "debug")) return .debug;
        if (std.mem.eql(u8, s, "trace")) return .trace;
        return null;
    }

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .err => "ERR",
            .warn => "WRN",
            .info => "INF",
            .debug => "DBG",
            .trace => "TRC",
        };
    }
};

pub const Logger = struct {
    level: Level = .info,
    file: ?std.fs.File = null,
    mutex: std.Thread.Mutex = .{},

    pub fn write(self: *Logger, level: Level, scope: []const u8, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(level) > @intFromEnum(self.level)) return;
        var msg_buf: [2048]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch msg_buf[0..];
        const ts = wallClock();
        var line_buf: [2176]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf,
            "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} [{s}] [{s}] {s}\n",
            .{ ts.h, ts.m, ts.s, ts.ms, level.label(), scope, msg }) catch line_buf[0..];
        self.mutex.lock();
        defer self.mutex.unlock();
        std.fs.File.stderr().writeAll(line) catch {};
        if (self.file) |f| f.writeAll(line) catch {};
    }
};

const TimeOfDay = struct { h: u8, m: u8, s: u8, ms: u16 };

fn wallClock() TimeOfDay {
    const ns = std.time.nanoTimestamp();
    if (ns <= 0) return .{ .h = 0, .m = 0, .s = 0, .ms = 0 };
    const secs: u64 = @intCast(@divTrunc(ns, std.time.ns_per_s));
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = epoch.getDaySeconds();
    const ms: u16 = @intCast(@mod(@divTrunc(ns, std.time.ns_per_ms), 1000));
    return .{
        .h = day.getHoursIntoDay(),
        .m = day.getMinutesIntoHour(),
        .s = day.getSecondsIntoMinute(),
        .ms = ms,
    };
}

// Global logger — valid before init(); defaults to .info, stderr only.
pub var global: Logger = .{};

pub fn init(level: Level, log_file_path: ?[]const u8) void {
    global.level = level;
    if (log_file_path) |path| {
        if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch {};
        const f = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
        f.seekFromEnd(0) catch {};
        global.file = f;
    }
}

pub fn deinit() void {
    if (global.file) |f| f.close();
    global.file = null;
}

pub fn err(comptime scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    global.write(.err, scope, fmt, args);
}
pub fn warn(comptime scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    global.write(.warn, scope, fmt, args);
}
pub fn info(comptime scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    global.write(.info, scope, fmt, args);
}
pub fn debug(comptime scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    global.write(.debug, scope, fmt, args);
}
pub fn trace(comptime scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    global.write(.trace, scope, fmt, args);
}

/// Hook for std_options.logFn — routes std.log.* through the global logger.
pub fn stdLogFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const level: Level = switch (message_level) {
        .err => .err,
        .warn => .warn,
        .info => .info,
        .debug => .debug,
    };
    global.write(level, @tagName(scope), format, args);
}
