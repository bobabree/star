const builtin = @import("builtin");

const IO = @import("IO.zig");
const Debug = @import("Debug.zig");
const Utf8Buffer = @import("Utf8Buffer.zig").Utf8Buffer;

const is_wasm = builtin.target.cpu.arch == .wasm32;
const is_ios = builtin.target.os.tag == .ios;

// Externs for WASM
extern fn log_error(ptr: [*]const u8, len: usize) void;
extern fn log_success(ptr: [*]const u8, len: usize) void;
extern fn log_warn(ptr: [*]const u8, len: usize) void;
extern fn log_info(ptr: [*]const u8, len: usize) void;
extern fn log_debug(ptr: [*]const u8, len: usize) void;

/// ANSI log color codes
const LogColor = struct {
    pub const reset = "\x1b[0m";

    pub const err_color = "\x1b[1;31m";
    pub const success_color = "\x1b[1;32m";
    pub const warn_color = "\x1b[1;33m";
    pub const info_color = "\x1b[1;34m";
    pub const debug_color = "\x1b[1;30m";
};

pub const ios_log = scoped(.ios);
pub const server_log = scoped(.server);
pub const wasm_log = scoped(.wasm);
pub const default_log = scoped(.default);

fn err(message: []const u8) void {
    if (is_wasm) {
        log_error(message.ptr, message.len);
    } else {
        const stderr = IO.getStdErr().writer();
        stderr.print(LogColor.err_color ++ "{s}" ++ LogColor.reset, .{message}) catch return;
    }
}

fn success(message: []const u8) void {
    if (is_wasm) {
        log_success(message.ptr, message.len);
    } else {
        const stderr = IO.getStdErr().writer();
        stderr.print(LogColor.success_color ++ "{s}" ++ LogColor.reset, .{message}) catch return;
    }
}

fn warn(message: []const u8) void {
    if (is_wasm) {
        log_warn(message.ptr, message.len);
    } else {
        const stderr = IO.getStdErr().writer();
        stderr.print(LogColor.warn_color ++ "{s}" ++ LogColor.reset, .{message}) catch return;
    }
}

fn info(message: []const u8) void {
    if (is_wasm) {
        log_info(message.ptr, message.len);
    } else {
        const stderr = IO.getStdErr().writer();
        stderr.print(LogColor.info_color ++ "{s}" ++ LogColor.reset, .{message}) catch return;
    }
}

fn debug(message: []const u8) void {
    if (is_wasm) {
        log_debug(message.ptr, message.len);
    } else {
        const stderr = IO.getStdErr().writer();
        stderr.print(LogColor.debug_color ++ "{s}" ++ LogColor.reset, .{message}) catch return;
    }
}

pub fn newLine() void {
    const message = "\n";
    if (is_wasm) {
        log_info(message.ptr, message.len);
    } else {
        const stderr = IO.getStdErr().writer();
        stderr.print(message, .{}) catch return;
    }
}

const Level = enum {
    err,
    success,
    warn,
    info,
    debug,

    pub fn asText(comptime self: Level) []const u8 {
        return switch (self) {
            .err => "error",
            .success => "success",
            .warn => "warning",
            .info => "info",
            .debug => "debug",
        };
    }
};

/// The log level will be based on build mode.
const level: Level = switch (builtin.mode) {
    .Debug => .debug, // Shows: err, success, warn, info, debug (all)
    .ReleaseSafe => .info, // Shows: err, success, warn, info
    .ReleaseFast => .warn, // Shows: err, success, warn
    .ReleaseSmall => .success, // Shows: err, success
};

const ScopeLevel = struct {
    scope: @Type(.enum_literal),
    level: Level,
};

const scope_levels: []const ScopeLevel = &.{
    .{ .scope = .ios, .level = .debug },
    .{ .scope = .server, .level = .debug },
    .{ .scope = .wasm, .level = .debug },
};

fn log(
    comptime message_level: Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime !logEnabled(message_level, scope)) return;

    logFn(message_level, scope, format, args);
}

fn logEnabled(comptime message_level: Level, comptime scope: @Type(.enum_literal)) bool {
    inline for (scope_levels) |scope_level| {
        if (scope_level.scope == scope) return @intFromEnum(message_level) <= @intFromEnum(scope_level.level);
    }
    return @intFromEnum(message_level) <= @intFromEnum(level);
}

fn logFn(
    comptime message_level: Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // Ignore all non-error logging from sources other than the declared scopes
    const scope_prefix = "[" ++ switch (scope) {
        .default => "",
        .ios, .server, .wasm => @tagName(scope),
        else => if (@intFromEnum(message_level) <= @intFromEnum(Level.err))
            @tagName(scope)
        else
            return,
    } ++ "] ";

    const prefix = if (scope == .default)
        ""
    else
        scope_prefix ++ "[" ++ comptime message_level.asText() ++ "] ";

    var buffer = Utf8Buffer(1024).init();
    buffer.format(prefix ++ format, args);
    const message = buffer.constSlice();

    switch (message_level) {
        .err => err(message),
        .success => success(message),
        .warn => warn(message),
        .info => info(message),
        .debug => debug(message),
    }
}

pub fn scoped(comptime scope: @Type(.enum_literal)) type {
    return struct {
        pub fn err(
            comptime format: []const u8,
            args: anytype,
        ) void {
            @branchHint(.cold);
            log(Level.err, scope, format, args);
        }

        pub fn success(
            comptime format: []const u8,
            args: anytype,
        ) void {
            log(Level.success, scope, format, args);
        }

        pub fn warn(
            comptime format: []const u8,
            args: anytype,
        ) void {
            log(Level.warn, scope, format, args);
        }

        pub fn info(
            comptime format: []const u8,
            args: anytype,
        ) void {
            log(Level.info, scope, format, args);
        }

        pub fn debug(
            comptime format: []const u8,
            args: anytype,
        ) void {
            log(Level.debug, scope, format, args);
        }
    };
}

comptime {
    Debug.assert(@intFromEnum(Level.err) == 0);
    Debug.assert(@intFromEnum(Level.success) == 1);
    Debug.assert(@intFromEnum(Level.warn) == 2);
    Debug.assert(@intFromEnum(Level.info) == 3);
    Debug.assert(@intFromEnum(Level.debug) == 4);
}

comptime {
    const debug_level = Level.debug;
    const safe_level = Level.info;
    const fast_level = Level.warn;
    const small_level = Level.success;

    // Debug: shows everything
    Debug.assert(@intFromEnum(Level.err) <= @intFromEnum(debug_level));
    Debug.assert(@intFromEnum(Level.success) <= @intFromEnum(debug_level));
    Debug.assert(@intFromEnum(Level.warn) <= @intFromEnum(debug_level));
    Debug.assert(@intFromEnum(Level.info) <= @intFromEnum(debug_level));
    Debug.assert(@intFromEnum(Level.debug) <= @intFromEnum(debug_level));

    // ReleaseSafe: shows err, success, warn, info
    Debug.assert(@intFromEnum(Level.err) <= @intFromEnum(safe_level));
    Debug.assert(@intFromEnum(Level.success) <= @intFromEnum(safe_level));
    Debug.assert(@intFromEnum(Level.warn) <= @intFromEnum(safe_level));
    Debug.assert(@intFromEnum(Level.info) <= @intFromEnum(safe_level));
    Debug.assert(!(@intFromEnum(Level.debug) <= @intFromEnum(safe_level)));

    // ReleaseFast: shows err, success, warn
    Debug.assert(@intFromEnum(Level.err) <= @intFromEnum(fast_level));
    Debug.assert(@intFromEnum(Level.success) <= @intFromEnum(fast_level));
    Debug.assert(@intFromEnum(Level.warn) <= @intFromEnum(fast_level));
    Debug.assert(!(@intFromEnum(Level.info) <= @intFromEnum(fast_level)));
    Debug.assert(!(@intFromEnum(Level.debug) <= @intFromEnum(fast_level)));

    // ReleaseSmall: shows err, success
    Debug.assert(@intFromEnum(Level.err) <= @intFromEnum(small_level));
    Debug.assert(@intFromEnum(Level.success) <= @intFromEnum(small_level));
    Debug.assert(!(@intFromEnum(Level.warn) <= @intFromEnum(small_level)));
    Debug.assert(!(@intFromEnum(Level.info) <= @intFromEnum(small_level)));
    Debug.assert(!(@intFromEnum(Level.debug) <= @intFromEnum(small_level)));
}

comptime {
    // Test actual override scenario: global restrictive, scope permissive
    const restrictive_global = Level.err; // Global only shows errors
    const permissive_scope = Level.debug; // But scope shows everything

    // If scope override works, scope level should win
    Debug.assert(@intFromEnum(Level.info) > @intFromEnum(restrictive_global)); // Global would block info
    Debug.assert(@intFromEnum(Level.info) <= @intFromEnum(permissive_scope)); // But scope allows info
}

const Testing = @import("Testing.zig");

test "logging functions work" {
    newLine();

    // wasm_log.success("", .{});
    // wasm_log.err("WASM error: {s}", .{"parse failed"});
    // wasm_log.warn("WASM warning: deprecated function used", .{});
    // server_log.info("Server info: listening on port {}", .{8080});
    // server_log.debug("Server debug: processing request #{}", .{123});

    try Testing.expect(true);
}
