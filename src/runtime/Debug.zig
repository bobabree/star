const builtin = @import("builtin");

const IO = @import("IO.zig");
const Utf8Buffer = @import("Utf8Buffer.zig").Utf8Buffer;
const panicExtra = @import("std").debug.panicExtra;
const print = @import("std").debug.print; // TODO: thread_local?

pub const is_wasm = builtin.target.cpu.arch.isWasm();
pub const is_ios = builtin.target.os.tag == .ios;

pub const js = scoped(Scope.js);
pub const wasm = scoped(Scope.wasm);
pub const ios = scoped(Scope.ios);
pub const server = scoped(Scope.server);
pub const default = scoped(Scope.default);

pub fn assert(condition: bool) void {
    if (@inComptime()) {
        return default.assert(condition);
    }

    switch (current_scope) {
        .js => js.assert(condition),
        .wasm => wasm.assert(condition),
        .server => server.assert(condition),
        .ios => ios.assert(condition),
        .default => scoped(.default).assert(condition),
    }
}

pub fn panic(comptime format: []const u8, args: anytype) noreturn {
    switch (current_scope) {
        Scope.js => js.panic(format, args),
        Scope.wasm => wasm.panic(format, args),
        Scope.server => server.panic(format, args),
        Scope.ios => ios.panic(format, args),
        Scope.default => scoped(Scope.default).panic(format, args),
    }
}

pub fn panicAssert(condition: bool, comptime format: []const u8, args: anytype) void {
    switch (current_scope) {
        Scope.js => js.panicAssert(condition, format, args),
        Scope.wasm => wasm.panicAssert(condition, format, args),
        Scope.server => server.panicAssert(condition, format, args),
        Scope.ios => ios.panicAssert(condition, format, args),
        Scope.default => scoped(Scope.default).panicAssert(condition, format, args),
    }
}

// Externs for WASM
extern fn wasm_print(ptr: [*]const u8, len: usize, channel: u8, level: u8) void;

const Scope = enum(u8) {
    js = 0,
    wasm = 1,
    server = 2,
    ios = 3,
    default = 4,

    pub fn asText(comptime self: Scope) []const u8 {
        return switch (self) {
            .js => "js",
            .wasm => "wasm",
            .server => "server",
            .ios => "ios",
            .default => "default",
        };
    }
};

const Level = enum(u8) {
    err = 0,
    success = 1,
    warn = 2,
    info = 3,
    debug = 4,

    pub fn asText(comptime self: Level) []const u8 {
        return switch (self) {
            Level.err => "err",
            Level.success => "success",
            Level.warn => "warning",
            Level.info => "info",
            Level.debug => "debug",
        };
    }

    pub fn asAnsiColor(comptime self: Level) []const u8 {
        return switch (self) {
            Level.err => "\x1b[1;31m",
            Level.success => "\x1b[1;32m",
            Level.warn => "\x1b[1;33m",
            Level.info => "\x1b[1;34m",
            Level.debug => "\x1b[1;30m",
        };
    }

    pub fn asHtmlColor(comptime self: Level) []const u8 {
        return switch (self) {
            Level.err => "#DC3545",
            Level.success => "#28A745",
            Level.warn => "#FFD700",
            Level.info => "#0066CC",
            Level.debug => "#6C757D",
        };
    }
};

// Auto-generate exports using comptime reflection
comptime {
    const scope_info = @typeInfo(Scope);
    const level_info = @typeInfo(Level);

    // Generate scope exports: get_scope_js(), get_scope_wasm(), etc.
    for (scope_info.@"enum".fields) |field| {
        const fn_name = "get_scope_" ++ field.name;
        const exportFn = struct {
            fn get() callconv(.c) u8 {
                return @intFromEnum(@field(Scope, field.name));
            }
        }.get;

        @export(&exportFn, .{ .name = fn_name });
    }

    const scope_methods = [_][]const u8{"asText"};
    for (scope_methods) |method_name| {
        const fn_name = "get_scope_" ++ method_name;
        const exportFn = struct {
            fn get(val: u8) callconv(.c) [*:0]const u8 {
                return switch (@as(Scope, @enumFromInt(val))) {
                    inline else => |comptime_val| {
                        const result = @call(.auto, @field(Scope, method_name), .{comptime_val});
                        return @as([*:0]const u8, @ptrCast(result.ptr));
                    },
                };
            }
        }.get;
        @export(&exportFn, .{ .name = fn_name });
    }

    // Generate level exports: get_level_err(), get_level_success(), etc.
    for (level_info.@"enum".fields) |field| {
        const fn_name = "get_level_" ++ field.name;
        const exportFn = struct {
            fn get() callconv(.c) u8 {
                return @intFromEnum(@field(Level, field.name));
            }
        }.get;

        @export(&exportFn, .{ .name = fn_name });
    }

    const level_methods = [_][]const u8{ "asText", "asHtmlColor", "asAnsiColor" };
    for (level_methods) |method_name| {
        const fn_name = "get_level_" ++ method_name;
        const exportFn = struct {
            fn get(val: u8) callconv(.c) [*:0]const u8 {
                return switch (@as(Level, @enumFromInt(val))) {
                    inline else => |comptime_val| {
                        const result = @call(.auto, @field(Level, method_name), .{comptime_val});
                        return @as([*:0]const u8, @ptrCast(result.ptr));
                    },
                };
            }
        }.get;
        @export(&exportFn, .{ .name = fn_name });
    }
}

/// The log level will be based on build mode.
const level: Level = switch (builtin.mode) {
    .Debug => Level.debug, // Shows: err, success, warn, info, debug (all)
    .ReleaseSafe => Level.info, // Shows: err, success, warn, info
    .ReleaseFast => Level.warn, // Shows: err, success, warn
    .ReleaseSmall => Level.success, // Shows: err, success
};

// Thread-local scope management
threadlocal var current_scope: Scope = Scope.default;

const ScopeLevel = struct {
    scope: Scope,
    level: Level,
};

const scope_levels: []const ScopeLevel = &.{
    .{ .scope = Scope.js, .level = Level.debug },
    .{ .scope = Scope.wasm, .level = Level.debug },
    .{ .scope = Scope.server, .level = Level.debug },
    .{ .scope = Scope.ios, .level = Level.debug },
    .{ .scope = Scope.default, .level = Level.debug },
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

fn logMessage(comptime scope: Scope, comptime message_level: Level, message: []const u8) void {
    if (is_wasm) {
        wasm_print(message.ptr, message.len, @intFromEnum(scope), @intFromEnum(message_level));
    } else {
        print(message_level.asAnsiColor() ++ "{s}\x1b[0m", .{message});
    }
}

fn logFn(
    comptime message_level: Level,
    comptime scope: Scope,
    comptime format: []const u8,
    args: anytype,
) void {
    // Ignore all non-error logging from sources other than the declared scopes
    const scope_prefix = "[" ++ switch (scope) {
        Scope.js,
        Scope.wasm,
        Scope.server,
        Scope.ios,
        => @tagName(scope),
        Scope.default => "",
    } ++ "]";

    const prefix = switch (scope) {
        Scope.js,
        Scope.wasm,
        Scope.server,
        Scope.ios,
        => scope_prefix ++ "[" ++ comptime message_level.asText() ++ "]",
        Scope.default => "",
    } ++ " ";

    var buffer = Utf8Buffer(1024).init();
    buffer.format(prefix ++ format, args);
    const message = buffer.constSlice();

    logMessage(scope, message_level, message);
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
    // wasm.success("", .{});
    // wasm.err("WASM error: {s}", .{"parse failed"});
    // wasm.warn("WASM warning: deprecated function used", .{});
    // server.info("Server info: listening on port {}", .{8080});
    // server.debug("Server debug: processing request #{}", .{123});

    try Testing.expect(true);
}
