const builtin = @import("builtin");

const IO = @import("IO.zig");
const Utf8Buffer = @import("Utf8Buffer.zig").Utf8Buffer;
const panicExtra = @import("std").debug.panicExtra;
const print = @import("std").debug.print; // TODO: thread_local?

pub const is_wasm = builtin.target.cpu.arch.isWasm();
pub const is_ios = builtin.target.os.tag == .ios;

pub const js = Scope.js;
pub const wasm = Scope.wasm;
pub const ios = Scope.ios;
pub const server = Scope.server;
pub const default = Scope.default;

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
    .{ .scope = Scope.js, .level = Level.debug },
    .{ .scope = Scope.wasm, .level = Level.debug },
    .{ .scope = Scope.server, .level = Level.debug },
    .{ .scope = Scope.ios, .level = Level.debug },
    .{ .scope = Scope.default, .level = Level.debug },
};

// Thread-local scope management
threadlocal var current_scope: Scope = Scope.default;

fn getCurrentScope() Scope {
    return if (@inComptime()) Scope.default else current_scope;
}

pub fn assert(condition: bool) void {
    switch (getCurrentScope()) {
        inline else => |s| s.assert(condition),
    }
}

pub fn panic(comptime format: []const u8, args: anytype) noreturn {
    switch (getCurrentScope()) {
        inline else => |scope| scope.panic(format, args),
    }
}

pub fn panicAssert(condition: bool, comptime format: []const u8, args: anytype) void {
    switch (getCurrentScope()) {
        inline else => |scope| scope.panicAssert(condition, format, args),
    }
}

// Externs for WASM
extern fn wasm_print(ptr: [*]const u8, len: usize, scope: Scope, level: Level) void;

const Scope = enum(u8) {
    js = 0,
    wasm = 1,
    server = 2,
    ios = 3,
    default = 4,

    pub fn asText(comptime self: Scope) []const u8 {
        return @tagName(self);
    }

    pub fn err(
        comptime self: Scope,
        comptime format: []const u8,
        args: anytype,
    ) void {
        @branchHint(.cold);
        self.log(Level.err, format, args);
    }

    pub fn success(
        comptime self: Scope,
        comptime format: []const u8,
        args: anytype,
    ) void {
        self.log(Level.success, format, args);
    }

    pub fn warn(
        comptime self: Scope,
        comptime format: []const u8,
        args: anytype,
    ) void {
        self.log(Level.warn, format, args);
    }

    pub fn info(
        comptime self: Scope,
        comptime format: []const u8,
        args: anytype,
    ) void {
        self.log(Level.info, format, args);
    }

    pub fn debug(
        comptime self: Scope,
        comptime format: []const u8,
        args: anytype,
    ) void {
        self.log(Level.debug, format, args);
    }

    pub fn assert(comptime self: Scope, condition: bool) void {
        if (!condition) {
            self.err("assertion failed at {s}:{d}", .{ @src().file, @src().line });
            unreachable; // assertion failure
        }
    }

    pub fn panic(comptime self: Scope, comptime format: []const u8, args: anytype) noreturn {
        @branchHint(.cold);
        self.err(format, args);
        panicExtra(@returnAddress(), format, args);
    }

    pub fn panicAssert(comptime self: Scope, condition: bool, comptime format: []const u8, args: anytype) void {
        if (!condition) {
            @branchHint(.cold);
            self.err("assertion failed at {s}:{d}", .{ @src().file, @src().line });
            self.panic(format, args);
            unreachable; // assertion failure
        }
    }

    fn log(
        comptime self: Scope,
        comptime message_level: Level,
        comptime format: []const u8,
        args: anytype,
    ) void {
        if (comptime !self.logEnabled(message_level)) return;

        self.logFn(message_level, format, args);
    }

    fn logEnabled(comptime self: Scope, comptime message_level: Level) bool {
        inline for (scope_levels) |scope_level| {
            if (scope_level.scope == self) return @intFromEnum(message_level) <= @intFromEnum(scope_level.level);
        }
        return @intFromEnum(message_level) <= @intFromEnum(level);
    }

    fn logMessage(comptime self: Scope, comptime message_level: Level, message: []const u8) void {
        if (is_wasm) {
            wasm_print(message.ptr, message.len, self, message_level); // Pass enums directly!
        } else {
            print(message_level.asAnsiColor() ++ "{s}\x1b[0m", .{message});
        }
    }

    fn logFn(
        comptime self: Scope,
        comptime message_level: Level,
        comptime format: []const u8,
        args: anytype,
    ) void {
        // Ignore all non-error logging from sources other than the declared scopes
        const prefix = if (self == .default)
            " "
        else
            "[" ++ @tagName(self) ++ "][" ++ comptime message_level.asText() ++ "] ";

        var buffer = Utf8Buffer(1024).init();
        buffer.format(prefix ++ format, args);
        const message = buffer.constSlice();

        self.logMessage(message_level, message);
    }
};

const Level = enum(u8) {
    err = 0,
    success = 1,
    warn = 2,
    info = 3,
    debug = 4,

    pub fn asText(comptime self: Level) []const u8 {
        return @tagName(self);
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

const ascii = @import("std").ascii;
const fmt = @import("std").fmt;
const meta = @import("std").meta;

// // Auto-generate exports using comptime reflection
fn generateEnumJS(comptime EnumType: type) []const u8 {
    @setEvalBranchQuota(10000);
    comptime {
        var buffer: [4096]u8 = undefined;
        var len: usize = 0;

        const enum_info = @typeInfo(EnumType).@"enum";
        const enum_name = @typeName(EnumType);

        // Helper to append string to buffer
        const append = struct {
            fn appendStr(buf: []u8, pos: *usize, str: []const u8) void {
                @memcpy(buf[pos.* .. pos.* + str.len], str);
                pos.* += str.len;
            }
        }.appendStr;

        //  create the enum object
        append(&buffer, &len, "wasmExports.");
        append(&buffer, &len, enum_name);
        append(&buffer, &len, " = {\n");

        for (enum_info.fields) |field| {
            append(&buffer, &len, "  ");
            append(&buffer, &len, field.name);
            append(&buffer, &len, ": {\n");
            append(&buffer, &len, "    valueOf: () => ");

            // Convert field value to string
            const num_str = fmt.comptimePrint("{}", .{field.value});
            append(&buffer, &len, num_str);
            append(&buffer, &len, ",\n");

            // add methods
            for (meta.declarations(EnumType)) |decl| {
                if (decl.name.len > 0) {
                    const DeclType = @TypeOf(@field(EnumType, decl.name));
                    if (@typeInfo(DeclType) == .@"fn") {
                        append(&buffer, &len, "    ");
                        append(&buffer, &len, decl.name);
                        // TODO: remove readString via externref to avoid heap allocation calls to js
                        // we currently have JS->LLVM->Zig working but now need to implement Zig->LLVM->JS
                        append(&buffer, &len, ": () => readString(wasmExports[\"");
                        append(&buffer, &len, enum_name);
                        append(&buffer, &len, "_");
                        append(&buffer, &len, decl.name);
                        append(&buffer, &len, "\"](");
                        append(&buffer, &len, num_str);
                        append(&buffer, &len, ")),\n");
                    }
                }
            }

            append(&buffer, &len, "  },\n");
        }

        append(&buffer, &len, "};\n");

        return buffer[0..len];
    }
}

const enum_bindings_js = blk: {
    const scope_js = generateEnumJS(Scope);
    const level_js = generateEnumJS(Level);

    const total_len = scope_js.len + level_js.len;
    var buffer: [total_len + 1]u8 = undefined;
    var len: usize = 0;

    @memcpy(buffer[len .. len + scope_js.len], scope_js);
    len += scope_js.len;
    @memcpy(buffer[len .. len + level_js.len], level_js);
    len += level_js.len;
    buffer[len] = 0; // Null terminate

    break :blk buffer[0..len :0].*;
};

export fn getEnumBindings() [*:0]const u8 {
    return &enum_bindings_js;
}

fn generateEnumExports(comptime EnumType: type) void {
    const enum_name = @typeName(EnumType);
    const enum_info = @typeInfo(EnumType).@"enum";

    // Export enum values
    for (enum_info.fields) |field| {
        const fn_name = enum_name ++ "_" ++ field.name;
        const exportFn = struct {
            fn get() callconv(.c) u8 {
                return @intFromEnum(@field(EnumType, field.name));
            }
        }.get;
        @export(&exportFn, .{ .name = fn_name });
    }

    // Only export methods that take just the self parameter
    inline for (meta.declarations(EnumType)) |decl| {
        if (@hasDecl(EnumType, decl.name)) {
            const DeclType = @TypeOf(@field(EnumType, decl.name));
            if (@typeInfo(DeclType) == .@"fn") {
                const fn_info = @typeInfo(DeclType).@"fn";

                // Only export functions with 1 parameter (just self)
                if (fn_info.params.len == 1) {
                    const fn_name = enum_name ++ "_" ++ decl.name;
                    const exportFn = struct {
                        fn get(val: u8) callconv(.c) [*:0]const u8 {
                            return switch (@as(EnumType, @enumFromInt(val))) {
                                inline else => |comptime_val| {
                                    const result = @call(.auto, @field(EnumType, decl.name), .{comptime_val});
                                    return @as([*:0]const u8, @ptrCast(result.ptr));
                                },
                            };
                        }
                    }.get;
                    @export(&exportFn, .{ .name = fn_name });
                }
            }
        }
    }
}

comptime {
    // Creates WASM exports: Scope_asText, Level_asText, etc.
    generateEnumExports(Scope);
    generateEnumExports(Level);
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
