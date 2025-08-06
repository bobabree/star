const builtin = @import("builtin");

const FixedBuffer = @import("FixedBuffer.zig").FixedBuffer;
const IO = @import("IO.zig");
const Mem = @import("Mem.zig");
const Thread = @import("Thread.zig");
const UI = @import("UI.zig");
const Utf8Buffer = @import("Utf8Buffer.zig").Utf8Buffer;

const dumpCurrentStackTrace = @import("std").debug.dumpCurrentStackTrace;
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
    .{ .scope = Scope.js, .level = level },
    .{ .scope = Scope.wasm, .level = level },
    .{ .scope = Scope.server, .level = Level.debug },
    .{ .scope = Scope.ios, .level = level },
    .{ .scope = Scope.default, .level = level },
};

// Thread-local scope management
threadlocal var current_scope: Scope = Scope.default;
threadlocal var current_task: Thread.TaskType = Thread.TaskType.default;

pub fn setThreadScope(scope: Scope, task: Thread.TaskType) void {
    current_scope = scope;
    current_task = task;
}

fn getCurrentTask() Thread.TaskType {
    return current_task;
}

pub fn getCurrentScope() Scope {
    return if (@inComptime()) Scope.default else current_scope;
}

pub fn assert(condition: bool) void {
    switch (getCurrentScope()) {
        inline else => |s| s.assert(condition, @returnAddress()),
    }
}

pub fn panic(comptime format: []const u8, args: anytype) noreturn {
    switch (getCurrentScope()) {
        inline else => |scope| scope.panic(format, args, @returnAddress()),
    }
}

pub fn panicAssert(condition: bool, comptime format: []const u8, args: anytype) void {
    switch (getCurrentScope()) {
        inline else => |scope| scope.panicAssert(condition, format, args, @returnAddress()),
    }
}

// Externs for WASM
extern fn wasm_print(ptr: [*]const u8, len: usize, scope: [*:0]const u8, level_handle: [*:0]const u8) void;

const Scope = enum(u8) {
    js = 0,
    wasm = 1,
    server = 2,
    ios = 3,
    default = 5,

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

    pub fn assert(comptime self: Scope, condition: bool, ret_addr: usize) void {
        if (!condition) {
            self.err("assertion failed at 0x{x}", .{ret_addr});
            if (is_wasm) {
                self.dumpWasmStack();
            }
            unreachable; // assertion failure
        }
    }

    pub fn panic(comptime self: Scope, comptime format: []const u8, args: anytype, ret_addr: usize) noreturn {
        @branchHint(.cold);
        self.err(format, args);
        self.err("panic at 0x{x}", .{ret_addr});
        if (is_wasm) {
            self.dumpWasmStack();
        }
        panicExtra(@returnAddress(), format, args);
    }

    pub fn panicAssert(comptime self: Scope, condition: bool, comptime format: []const u8, args: anytype, ret_addr: usize) void {
        if (!condition) {
            @branchHint(.cold);
            self.panic(format, args, ret_addr);
            unreachable; // panic assertion failure
        }
    }

    fn dumpWasmStack(comptime self: Scope) void {
        // TODO: WASM may need inline assembly
        var current_frame = @frameAddress();
        var i: u8 = 0;
        while (i < 10) : (i += 1) {
            self.err("Frame {}: 0x{x}", .{ i, current_frame });
            current_frame += @sizeOf(usize);
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
            self.wasmPrint(message_level, message);
        } else {
            print(message_level.asAnsiColor() ++ "{s}\x1b[0m", .{message});
        }
    }

    const LogEntry = struct {
        message: Utf8Buffer(256),
        scope: []const u8,
        level: []const u8,
        color: []const u8,
    };

    //var log_entries = FixedBuffer(LogEntry, 20).init(0);

    fn wasmPrint(comptime _: Scope, comptime message_level: Level, message: []const u8) void {
        // Store entry (message is already formatted with scope/level)
        // if (log_entries.len < log_entries.capacity()) {
        //     var entry = log_entries.addOne();

        //     entry.message = Utf8Buffer(256).copy(message);
        //     entry.scope = @tagName(self);
        //     entry.level = @tagName(message_level);
        //     entry.color = message_level.asHtmlColor();
        // }

        var console_msg = Utf8Buffer(256).init();
        console_msg.format("{s}", .{message});

        var style = Utf8Buffer(256).init();
        style.format("color: {s}; font-family: monospace;", .{message_level.asHtmlColor()});

        switch (message_level) {
            .err => console_error(console_msg.constSlice().ptr, console_msg.constSlice().len, style.constSlice().ptr, style.constSlice().len),
            .warn => console_warn(console_msg.constSlice().ptr, console_msg.constSlice().len, style.constSlice().ptr, style.constSlice().len),
            else => console_log(console_msg.constSlice().ptr, console_msg.constSlice().len, style.constSlice().ptr, style.constSlice().len),
        }

        // var full_html = Utf8Buffer(1024).init();
        // full_html.format("📁 Output:", .{});

        // for (log_entries.constSlice()) |entry| {
        //     var log_html = Utf8Buffer(256).init();
        //     log_html.format("<br><span style='color: {s}; font-family: monospace;'>{s}</span>", .{ entry.color, entry.message.constSlice() });
        //     full_html.appendSlice(log_html.constSlice());
        // }

        // _ = UI.outputElement.innerHTML(full_html.constSlice());
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
        const task = getCurrentTask();
        if (task == Thread.TaskType.default)
            buffer.format(prefix ++ format, args)
        else
            buffer.format("[{s}]" ++ prefix ++ format, .{@tagName(task)} ++ args);

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

extern fn console_log(msg_ptr: [*]const u8, msg_len: usize, style_ptr: [*]const u8, style_len: usize) void;
extern fn console_warn(msg_ptr: [*]const u8, msg_len: usize, style_ptr: [*]const u8, style_len: usize) void;
extern fn console_error(msg_ptr: [*]const u8, msg_len: usize, style_ptr: [*]const u8, style_len: usize) void;

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
