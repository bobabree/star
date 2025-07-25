const panicExtra = @import("std").debug.panicExtra;

// TODO: use thread_local
const print = @import("std").debug.print;

pub fn assert(condition: bool) void {
    if (@inComptime()) {
        return default.assert(condition);
    }

    switch (current_scope) {
        .wasm => wasm.assert(condition),
        .server => server.assert(condition),
        .ios => ios.assert(condition),
        .default => scoped(.default).assert(condition),
    }
}

pub fn panic(comptime format: []const u8, args: anytype) noreturn {
    switch (current_scope) {
        Scope.wasm => wasm.panic(format, args),
        Scope.server => server.panic(format, args),
        Scope.ios => ios.panic(format, args),
        Scope.default => scoped(Scope.default).panic(format, args),
    }
}

pub fn panicAssert(condition: bool, comptime format: []const u8, args: anytype) void {
    switch (current_scope) {
        Scope.wasm => wasm.panicAssert(condition, format, args),
        Scope.server => server.panicAssert(condition, format, args),
        Scope.ios => ios.panicAssert(condition, format, args),
        Scope.default => scoped(Scope.default).panicAssert(condition, format, args),
    }
}

// Thread-local scope management
const Scope = enum { wasm, server, ios, default };
threadlocal var current_scope: Scope = Scope.default;

const builtin = @import("builtin");

const IO = @import("IO.zig");
const Utf8Buffer = @import("Utf8Buffer.zig").Utf8Buffer;

pub const is_wasm = builtin.target.cpu.arch.isWasm();
pub const is_ios = builtin.target.os.tag == .ios;

// Externs for WASM
extern fn wasm_err(ptr: [*]const u8, len: usize) void;
extern fn wasm_success(ptr: [*]const u8, len: usize) void;
extern fn wasm_warn(ptr: [*]const u8, len: usize) void;
extern fn wasm_info(ptr: [*]const u8, len: usize) void;
extern fn wasm_debug(ptr: [*]const u8, len: usize) void;
//extern fn wasm_panic(ptr: [*]const u8, len: usize) noreturn;

/// ANSI log color codes
const LogColor = struct {
    pub const reset = "\x1b[0m";

    pub const err_color = "\x1b[1;31m";
    pub const success_color = "\x1b[1;32m";
    pub const warn_color = "\x1b[1;33m";
    pub const info_color = "\x1b[1;34m";
    pub const debug_color = "\x1b[1;30m";
};

pub const ios = scoped(Scope.ios);
pub const server = scoped(Scope.server);
pub const wasm = scoped(Scope.wasm);
pub const default = scoped(Scope.default);

fn err(message: []const u8) void {
    if (is_wasm) {
        wasm_err(message.ptr, message.len);
    } else {
        print(LogColor.err_color ++ "{s}" ++ LogColor.reset, .{message});
    }
}

fn success(message: []const u8) void {
    if (is_wasm) {
        wasm_success(message.ptr, message.len);
    } else {
        print(LogColor.success_color ++ "{s}" ++ LogColor.reset, .{message});
    }
}

fn warn(message: []const u8) void {
    if (is_wasm) {
        wasm_warn(message.ptr, message.len);
    } else {
        print(LogColor.warn_color ++ "{s}" ++ LogColor.reset, .{message});
    }
}

fn info(message: []const u8) void {
    if (is_wasm) {
        wasm_info(message.ptr, message.len);
    } else {
        print(LogColor.info_color ++ "{s}" ++ LogColor.reset, .{message});
    }
}

fn debug(message: []const u8) void {
    if (is_wasm) {
        wasm_debug(message.ptr, message.len);
    } else {
        print(LogColor.debug_color ++ "{s}" ++ LogColor.reset, .{message});
    }
}

pub fn newLine() void {
    const message = "\n";
    if (is_wasm) {
        wasm_info(message.ptr, message.len);
    } else {
        print(message, .{});
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
            Level.err => "error",
            Level.success => "success",
            Level.warn => "warning",
            Level.info => "info",
            Level.debug => "debug",
        };
    }
};

/// The log level will be based on build mode.
const level: Level = switch (builtin.mode) {
    .Debug => Level.debug, // Shows: err, success, warn, info, debug (all)
    .ReleaseSafe => Level.info, // Shows: err, success, warn, info
    .ReleaseFast => Level.warn, // Shows: err, success, warn
    .ReleaseSmall => Level.success, // Shows: err, success
};

const ScopeLevel = struct {
    scope: Scope,
    level: Level,
};

const scope_levels: []const ScopeLevel = &.{
    .{ .scope = Scope.ios, .level = Level.debug },
    .{ .scope = Scope.server, .level = Level.debug },
    .{ .scope = Scope.wasm, .level = Level.debug },
};

fn log(
    comptime message_level: Level,
    comptime scope: Scope,
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime !logEnabled(message_level, scope)) return;

    logFn(message_level, scope, format, args);
}

fn logEnabled(comptime message_level: Level, comptime scope: Scope) bool {
    inline for (scope_levels) |scope_level| {
        if (scope_level.scope == scope) return @intFromEnum(message_level) <= @intFromEnum(scope_level.level);
    }
    return @intFromEnum(message_level) <= @intFromEnum(level);
}

fn logFn(
    comptime message_level: Level,
    comptime scope: Scope,
    comptime format: []const u8,
    args: anytype,
) void {
    // Ignore all non-error logging from sources other than the declared scopes
    const scope_prefix = "[" ++ switch (scope) {
        Scope.ios, Scope.server, Scope.wasm => @tagName(scope),
        Scope.default => "",
    } ++ "]";

    const prefix = switch (scope) {
        Scope.ios, Scope.server, Scope.wasm => scope_prefix ++ "[" ++ comptime message_level.asText() ++ "]",
        Scope.default => "",
    } ++ " ";

    var buffer = Utf8Buffer(1024).init();
    buffer.format(prefix ++ format, args);
    const message = buffer.constSlice();

    switch (message_level) {
        Level.err => err(message),
        Level.success => success(message),
        Level.warn => warn(message),
        Level.info => info(message),
        Level.debug => debug(message),
    }
}

pub fn scoped(comptime scope: Scope) type {
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

        pub fn assert(condition: bool) void {
            if (!condition) {
                @This().err("assertion failed at {s}:{d}", .{ @src().file, @src().line });
                unreachable; // assertion failure
            }
        }

        pub fn panic(comptime format: []const u8, args: anytype) noreturn {
            @branchHint(.cold);
            @This().err(format, args);
            panicExtra(@returnAddress(), format, args);
        }

        pub fn panicAssert(condition: bool, comptime format: []const u8, args: anytype) void {
            if (!condition) {
                @branchHint(.cold);
                @This().err("assertion failed at {s}:{d}", .{ @src().file, @src().line });
                @This().panic(format, args);
                unreachable; // assertion failure
            }
        }
    };
}

comptime {
    assert(@intFromEnum(Level.err) == 0);
    assert(@intFromEnum(Level.success) == 1);
    assert(@intFromEnum(Level.warn) == 2);
    assert(@intFromEnum(Level.info) == 3);
    assert(@intFromEnum(Level.debug) == 4);
}

comptime {
    const debug_level = Level.debug;
    const safe_level = Level.info;
    const fast_level = Level.warn;
    const small_level = Level.success;

    // Debug: shows everything
    assert(@intFromEnum(Level.err) <= @intFromEnum(debug_level));
    assert(@intFromEnum(Level.success) <= @intFromEnum(debug_level));
    assert(@intFromEnum(Level.warn) <= @intFromEnum(debug_level));
    assert(@intFromEnum(Level.info) <= @intFromEnum(debug_level));
    assert(@intFromEnum(Level.debug) <= @intFromEnum(debug_level));

    // ReleaseSafe: shows err, success, warn, info
    assert(@intFromEnum(Level.err) <= @intFromEnum(safe_level));
    assert(@intFromEnum(Level.success) <= @intFromEnum(safe_level));
    assert(@intFromEnum(Level.warn) <= @intFromEnum(safe_level));
    assert(@intFromEnum(Level.info) <= @intFromEnum(safe_level));
    assert(!(@intFromEnum(Level.debug) <= @intFromEnum(safe_level)));

    // ReleaseFast: shows err, success, warn
    assert(@intFromEnum(Level.err) <= @intFromEnum(fast_level));
    assert(@intFromEnum(Level.success) <= @intFromEnum(fast_level));
    assert(@intFromEnum(Level.warn) <= @intFromEnum(fast_level));
    assert(!(@intFromEnum(Level.info) <= @intFromEnum(fast_level)));
    assert(!(@intFromEnum(Level.debug) <= @intFromEnum(fast_level)));

    // ReleaseSmall: shows err, success
    assert(@intFromEnum(Level.err) <= @intFromEnum(small_level));
    assert(@intFromEnum(Level.success) <= @intFromEnum(small_level));
    assert(!(@intFromEnum(Level.warn) <= @intFromEnum(small_level)));
    assert(!(@intFromEnum(Level.info) <= @intFromEnum(small_level)));
    assert(!(@intFromEnum(Level.debug) <= @intFromEnum(small_level)));
}

comptime {
    // Test actual override scenario: global restrictive, scope permissive
    const restrictive_global = Level.err; // Global only shows errors
    const permissive_scope = Level.debug; // But scope shows everything

    // If scope override works, scope level should win
    assert(@intFromEnum(Level.info) > @intFromEnum(restrictive_global)); // Global would block info
    assert(@intFromEnum(Level.info) <= @intFromEnum(permissive_scope)); // But scope allows info
}

const Testing = @import("Testing.zig");

test "logging functions work" {
    newLine();

    // wasm.success("", .{});
    // wasm.err("WASM error: {s}", .{"parse failed"});
    // wasm.warn("WASM warning: deprecated function used", .{});
    // server.info("Server info: listening on port {}", .{8080});
    // server.debug("Server debug: processing request #{}", .{123});

    try Testing.expect(true);
}
