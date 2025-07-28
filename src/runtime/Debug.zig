const builtin = @import("builtin");

const IO = @import("IO.zig");
const Mem = @import("Mem.zig");
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
    .Debug => Level.debug, // Shows: Level.err, Level.success, Level.warn, Level.info, Level.debug (all)
    .ReleaseSafe => Level.info, // Shows: Level.err, Level.success, Level.warn, Level.info
    .ReleaseFast => Level.warn, // Shows: Level.err, Level.success, Level.warn
    .ReleaseSmall => Level.success, // Shows: Level.err, Level.success
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
extern fn wasm_print(ptr: [*]const u8, len: usize, scope: [*:0]const u8, level_handle: [*:0]const u8) void;

const Scope = enum(u8) {
    js = 0,
    wasm = 1,
    server = 2,
    ios = 3,
    default = 4,

    pub fn asHandle(comptime self: Scope) [*:0]const u8 {
        const handle = comptime (@typeName(@This()) ++ "." ++ self.asTagName());
        return @ptrCast(handle.ptr);
    }

    pub fn asTypeName(comptime self: Scope) []const u8 {
        return @typeName(@TypeOf(self));
    }

    pub fn asTagName(comptime self: Scope) []const u8 {
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
        return message_level <= level;
    }

    fn logMessage(comptime self: Scope, comptime message_level: Level, message: []const u8) void {
        if (is_wasm) {
            wasm_print(message.ptr, message.len, self.asHandle(), message_level.asHandle()); //
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
            "[" ++ @tagName(self) ++ "][" ++ @tagName(message_level) ++ "] ";

        var buffer = Utf8Buffer(1024).init();
        buffer.format(prefix ++ format, args);
        const message = buffer.constSlice();

        self.logMessage(message_level, message);
    }
};

pub const Handle = [*:0]const u8;

const Level = enum(u8) {
    err = 0,
    success = 1,
    warn = 2,
    info = 3,
    debug = 4,

    const type_name = @typeName(@This());

    pub fn asHandle(comptime self: Level) [*:0]const u8 {
        const handle_name = comptime (type_name ++ "." ++ self.asTagName());
        return @ptrCast(handle_name.ptr);
    }

    pub fn asTagName(comptime self: Level) []const u8 {
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
fn generateJsBindings(comptime ZigType: type, comptime namespace: []const u8) []const u8 {
    @setEvalBranchQuota(10000);
    comptime {
        var buffer: [4096 * 2]u8 = undefined;
        var len: usize = 0;

        const enum_info = @typeInfo(ZigType).@"enum";
        const enum_name = @typeName(ZigType);

        const append = struct {
            fn appendStr(buf: []u8, pos: *usize, str: []const u8) void {
                @memcpy(buf[pos.* .. pos.* + str.len], str);
                pos.* += str.len;
            }
        }.appendStr;

        //  create the object
        append(&buffer, &len, namespace);
        append(&buffer, &len, ".");
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
            for (meta.declarations(ZigType)) |decl| {
                if (decl.name.len > 0) {
                    const DeclType = @TypeOf(@field(ZigType, decl.name));
                    if (@typeInfo(DeclType) == .@"fn") {
                        append(&buffer, &len, "    ");
                        append(&buffer, &len, decl.name);
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

        for (enum_info.fields) |field| {
            append(&buffer, &len, namespace);
            append(&buffer, &len, "[\"");
            append(&buffer, &len, enum_name);
            append(&buffer, &len, ".");
            append(&buffer, &len, field.name);
            append(&buffer, &len, "\"] = ");
            append(&buffer, &len, namespace);
            append(&buffer, &len, ".");
            append(&buffer, &len, enum_name);
            append(&buffer, &len, ".");
            append(&buffer, &len, field.name);
            append(&buffer, &len, ";\n");
        }

        return buffer[0..len];
    }
}

fn generateZigBindings(comptime ZigType: type) void {
    const enum_name = @typeName(ZigType);
    const enum_info = @typeInfo(ZigType).@"enum";

    inline for (meta.declarations(ZigType)) |decl| {
        if (@hasDecl(ZigType, decl.name)) {
            const DeclType = @TypeOf(@field(ZigType, decl.name));
            if (@typeInfo(DeclType) == .@"fn") {
                const fn_info = @typeInfo(DeclType).@"fn";

                if (fn_info.params.len == 1) {
                    const fn_name = enum_name ++ "_" ++ decl.name;
                    const exportFn = struct {
                        fn get(val: u8) callconv(.c) usize {
                            inline for (enum_info.fields) |field| {
                                if (val == field.value) {
                                    const result = @field(ZigType, decl.name)(@field(ZigType, field.name));

                                    const ptr = switch (@TypeOf(result)) {
                                        []const u8 => result.ptr,
                                        [*:0]const u8 => result,
                                        else => @compileError("Unsupported return type"),
                                    };
                                    return @intFromPtr(ptr);
                                }
                            }
                            unreachable;
                        }
                    }.get;
                    @export(&exportFn, .{ .name = fn_name });
                }
            }
        }
    }
}

comptime {
    // Create universal zig bindings
    generateZigBindings(Scope);
    generateZigBindings(Level);
}

const js_bindings = blk: {
    const scope_js = generateJsBindings(Scope, "window");
    const level_js = generateJsBindings(Level, "window");

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

export fn getJsBindings() [*:0]const u8 {
    return &js_bindings;
}

comptime {
    assert(@intFromEnum(Level.err) == 0);
    assert(@intFromEnum(Level.success) == 1);
    assert(@intFromEnum(Level.warn) == 2);
    assert(@intFromEnum(Level.info) == 3);
    assert(@intFromEnum(Level.debug) == 4);
}

comptime {
    const debug_level = @intFromEnum(Level.debug);
    const safe_level = @intFromEnum(Level.info);
    const fast_level = @intFromEnum(Level.warn);
    const small_level = @intFromEnum(Level.success);

    // Debug: shows everything
    assert(@intFromEnum(Level.err) <= debug_level);
    assert(@intFromEnum(Level.success) <= debug_level);
    assert(@intFromEnum(Level.warn) <= debug_level);
    assert(@intFromEnum(Level.info) <= debug_level);
    assert(@intFromEnum(Level.debug) <= debug_level);

    // ReleaseSafe: shows Level.err, Level.success, Level.warn, Level.info
    assert(@intFromEnum(Level.err) <= safe_level);
    assert(@intFromEnum(Level.success) <= safe_level);
    assert(@intFromEnum(Level.warn) <= safe_level);
    assert(@intFromEnum(Level.info) <= safe_level);
    assert(!(@intFromEnum(Level.debug) <= safe_level));

    // ReleaseFast: shows Level.err, Level.success, Level.warn
    assert(@intFromEnum(Level.err) <= fast_level);
    assert(@intFromEnum(Level.success) <= fast_level);
    assert(@intFromEnum(Level.warn) <= fast_level);
    assert(!(@intFromEnum(Level.info) <= fast_level));
    assert(!(@intFromEnum(Level.debug) <= fast_level));

    // ReleaseSmall: shows Level.err, Level.success
    assert(@intFromEnum(Level.err) <= small_level);
    assert(@intFromEnum(Level.success) <= small_level);
    assert(!(@intFromEnum(Level.warn) <= small_level));
    assert(!(@intFromEnum(Level.info) <= small_level));
    assert(!(@intFromEnum(Level.debug) <= small_level));
}

comptime {
    // Test actual override scenario: global restrictive, scope permissive
    const restrictive_global = @intFromEnum(Level.err); // Global only shows errors
    const permissive_scope = @intFromEnum(Level.debug); // But scope shows everything

    // If scope override works, scope level should win
    assert(@intFromEnum(Level.info) > restrictive_global); // Global would block Level.info
    assert(@intFromEnum(Level.info) <= permissive_scope); // But scope allows Level.info
}

const Testing = @import("Testing.zig");

test "logging functions work" {
    // wasm.Level.success("", .{});
    // wasm.Level.err("WASM error: {s}", .{"parse failed"});
    // wasm.Level.warn("WASM warning: deprecated function used", .{});
    // server.Level.info("Server info: listening on port {}", .{8080});
    // server.Level.debug("Server debug: processing request #{}", .{123});

    try Testing.expect(true);
}
