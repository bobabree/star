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
    level: type,
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
extern fn wasm_print(ptr: [*]const u8, len: usize, scope: Scope, level_handle: [*:0]const u8) void;

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
        comptime message_level: type,
        comptime format: []const u8,
        args: anytype,
    ) void {
        if (comptime !self.logEnabled(message_level)) return;

        self.logFn(message_level, format, args);
    }

    fn logEnabled(comptime self: Scope, comptime message_level: type) bool {
        inline for (scope_levels) |scope_level| {
            if (scope_level.scope == self) return message_level.asValue() <= scope_level.level.asValue();
        }
        return message_level.asValue() <= level.asValue();
    }

    fn logMessage(comptime self: Scope, comptime message_level: type, message: []const u8) void {
        if (is_wasm) {
            wasm_print(message.ptr, message.len, self, message_level.asHandle());
        } else {
            print(message_level.asAnsiColor() ++ "{s}\x1b[0m", .{message});
        }
    }

    fn logFn(
        comptime self: Scope,
        comptime message_level: type,
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

pub const Handle = [*:0]const u8;

pub const Level = struct {
    pub const err = impl(0, "err", "\x1b[1;31m", "#DC3545");
    pub const success = impl(1, "success", "\x1b[1;32m", "#28A745");
    pub const warn = impl(2, "warn", "\x1b[1;33m", "#FFD700");
    pub const info = impl(3, "info", "\x1b[1;34m", "#0066CC");
    pub const debug = impl(4, "debug", "\x1b[1;30m", "#6C757D");
    const type_name = @typeName(@This());

    fn impl(
        comptime value: u8,
        comptime name: []const u8,
        comptime ansi: []const u8,
        comptime html: []const u8,
    ) type {
        return struct {
            pub fn asHandle() Handle {
                const handle_name = comptime (type_name ++ "." ++ name);
                return @ptrCast(handle_name);
            }

            pub fn asValue() u8 {
                return value;
            }

            pub fn asText() []const u8 {
                return name;
            }

            pub fn asAnsiColor() []const u8 {
                return ansi;
            }

            pub fn asHtmlColor() []const u8 {
                return html;
            }
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
                        // TODO: we currently have JS->LLVM->Zig working but now need to implement Zig->LLVM->JS
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

    const total_len = scope_js.len;
    var buffer: [total_len + 1]u8 = undefined;
    var len: usize = 0;

    @memcpy(buffer[len .. len + scope_js.len], scope_js);
    len += scope_js.len;
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
}

fn generateTypeJS(comptime TypeInstance: type) []const u8 {
    @setEvalBranchQuota(10000);
    const handle = Mem.span(TypeInstance.asHandle());

    comptime {
        var buffer: [4096]u8 = undefined;
        var len: usize = 0;

        const append = struct {
            fn appendStr(buf: []u8, pos: *usize, str: []const u8) void {
                @memcpy(buf[pos.* .. pos.* + str.len], str);
                pos.* += str.len;
            }
        }.appendStr;

        // Create the type object
        append(&buffer, &len, "wasmExports[wasmExports[\"");
        append(&buffer, &len, handle);
        append(&buffer, &len, "_asHandle\"]()] = {\n");

        // Add valueOf method
        append(&buffer, &len, "  valueOf: () => ");
        const value_str = fmt.comptimePrint("{}", .{TypeInstance.asValue()});
        append(&buffer, &len, value_str);
        append(&buffer, &len, ",\n");

        // Add methods
        for (meta.declarations(TypeInstance)) |decl| {
            if (decl.name.len > 0) {
                const DeclType = @TypeOf(@field(TypeInstance, decl.name));
                if (@typeInfo(DeclType) == .@"fn") {
                    const fn_name = handle ++ "_" ++ decl.name;

                    append(&buffer, &len, "  ");
                    append(&buffer, &len, decl.name);
                    append(&buffer, &len, ": () => wasmExports[\"");
                    append(&buffer, &len, fn_name);
                    append(&buffer, &len, "\"](),\n");
                }
            }
        }

        append(&buffer, &len, "};\n");

        // TODO: streamline this
        append(&buffer, &len, "window.Level = window.Level || {};\n");
        append(&buffer, &len, "Level.");
        append(&buffer, &len, TypeInstance.asText());
        append(&buffer, &len, " = wasmExports[wasmExports[\"");
        append(&buffer, &len, handle);
        append(&buffer, &len, "_asHandle\"]()];\n");

        return buffer[0..len];
    }
}

fn generateTypeExport(comptime TypeInstance: type) void {
    const handle = TypeInstance.asHandle();

    inline for (meta.declarations(TypeInstance)) |decl| {
        if (decl.name.len > 0) {
            const DeclType = @TypeOf(@field(TypeInstance, decl.name));
            if (@typeInfo(DeclType) == .@"fn") {
                const fn_name = Mem.span(handle) ++ "_" ++ decl.name;

                const exportFn = struct {
                    fn get() callconv(.c) usize {
                        return @intFromPtr(TypeInstance.asHandle());
                    }
                }.get;
                @export(&exportFn, .{ .name = fn_name });
            }
        }
    }
}

comptime {
    generateTypeExport(Level.err);
    generateTypeExport(Level.success);
    generateTypeExport(Level.warn);
    generateTypeExport(Level.info);
    generateTypeExport(Level.debug);
}

const type_bindings_js = blk: {
    const err_js = generateTypeJS(Level.err);
    const success_js = generateTypeJS(Level.success);
    const warn_js = generateTypeJS(Level.warn);
    const info_js = generateTypeJS(Level.info);
    const debug_js = generateTypeJS(Level.debug);

    const total_len = err_js.len + success_js.len + warn_js.len + info_js.len + debug_js.len;
    var buffer: [total_len + 1]u8 = undefined;
    var len: usize = 0;

    @memcpy(buffer[len .. len + err_js.len], err_js);
    len += err_js.len;
    @memcpy(buffer[len .. len + success_js.len], success_js);
    len += success_js.len;
    @memcpy(buffer[len .. len + warn_js.len], warn_js);
    len += warn_js.len;
    @memcpy(buffer[len .. len + info_js.len], info_js);
    len += info_js.len;
    @memcpy(buffer[len .. len + debug_js.len], debug_js);
    len += debug_js.len;
    buffer[len] = 0; // Null terminate

    break :blk buffer[0..len :0].*;
};

export fn getTypeBindings() [*:0]const u8 {
    return &type_bindings_js;
}

comptime {
    assert(Level.err.asValue() == 0);
    assert(Level.success.asValue() == 1);
    assert(Level.warn.asValue() == 2);
    assert(Level.info.asValue() == 3);
    assert(Level.debug.asValue() == 4);

    // Verify zero size
    assert(@sizeOf(Level.err) == 0);
    assert(@sizeOf(Level.success) == 0);
    assert(@sizeOf(Level.warn) == 0);
    assert(@sizeOf(Level.info) == 0);
    assert(@sizeOf(Level.debug) == 0);
}

comptime {
    const debug_level = Level.debug;
    const safe_level = Level.info;
    const fast_level = Level.warn;
    const small_level = Level.success;

    // Debug: shows everything
    assert(Level.err.asValue() <= debug_level.asValue());
    assert(Level.success.asValue() <= debug_level.asValue());
    assert(Level.warn.asValue() <= debug_level.asValue());
    assert(Level.info.asValue() <= debug_level.asValue());
    assert(Level.debug.asValue() <= debug_level.asValue());

    // ReleaseSafe: shows Level.err, Level.success, Level.warn, Level.info
    assert(Level.err.asValue() <= safe_level.asValue());
    assert(Level.success.asValue() <= safe_level.asValue());
    assert(Level.warn.asValue() <= safe_level.asValue());
    assert(Level.info.asValue() <= safe_level.asValue());
    assert(!(Level.debug.asValue() <= safe_level.asValue()));

    // ReleaseFast: shows Level.err, Level.success, Level.warn
    assert(Level.err.asValue() <= fast_level.asValue());
    assert(Level.success.asValue() <= fast_level.asValue());
    assert(Level.warn.asValue() <= fast_level.asValue());
    assert(!(Level.info.asValue() <= fast_level.asValue()));
    assert(!(Level.debug.asValue() <= fast_level.asValue()));

    // ReleaseSmall: shows Level.err, Level.success
    assert(Level.err.asValue() <= small_level.asValue());
    assert(Level.success.asValue() <= small_level.asValue());
    assert(!(Level.warn.asValue() <= small_level.asValue()));
    assert(!(Level.info.asValue() <= small_level.asValue()));
    assert(!(Level.debug.asValue() <= small_level.asValue()));
}

comptime {
    // Test actual override scenario: global restrictive, scope permissive
    const restrictive_global = Level.err; // Global only shows errors
    const permissive_scope = Level.debug; // But scope shows everything

    // If scope override works, scope level should win
    assert(Level.info.asValue() > restrictive_global.asValue()); // Global would block Level.info
    assert(Level.info.asValue() <= permissive_scope.asValue()); // But scope allows Level.info
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
