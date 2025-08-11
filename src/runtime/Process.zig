const process = @import("std").process;
const builtin = @import("builtin");

const Debug = @import("Debug.zig");
const FixedBuffer = @import("FixedBuffer.zig").FixedBuffer;
const Fs = @import("Fs.zig");
const Heap = @import("Heap.zig");
const Mem = @import("Mem.zig");
const OS = @import("OS.zig");
const Utf8Buffer = @import("Utf8Buffer.zig").Utf8Buffer;

const ExecvError = process.ExecvError;

pub const Child = process.Child;
pub const exit = process.exit;

pub fn argsMaybeAlloc(allocator: Mem.Allocator) ArgsBuffer {
    var args_buffer = ArgsBuffer.init(0);

    if (OS.is_windows) {
        const args = process.argsAlloc(allocator) catch |err| {
            Debug.panic("Failed to get args on Windows: {}", .{err});
        };
        defer process.argsFree(allocator, args);

        for (args) |arg| {
            const utf8_arg = Utf8Buffer(MAX_ARG_LEN).copy(arg); // Validates UTF-8
            // fail fast -- WTF-8 bugs are hard to debug when they happen far from the source
            args_buffer.append(utf8_arg);
        }
    } else {
        const argv = @import("std").os.argv;
        for (argv) |arg_ptr| {
            const arg = Mem.span(arg_ptr);
            const utf8_arg = Utf8Buffer(MAX_ARG_LEN).copy(arg);
            args_buffer.append(utf8_arg);
        }
    }

    return args_buffer;
}

pub const MAX_ARGS = 32;
const MAX_ARG_LEN = 256;

pub const ArgsBuffer = FixedBuffer(Utf8Buffer(MAX_ARG_LEN), MAX_ARGS);

pub fn restartSelf(allocator: Mem.Allocator) !void {
    // Get current executable path
    var exe_path_buf: [Fs.max_path_bytes]u8 = undefined;
    const exe_path = try Fs.selfExePath(&exe_path_buf);

    // Get current args
    const argv_buffers = argsMaybeAlloc(allocator);

    // Build argv with current exe path
    var argv_strings: [MAX_ARGS][]const u8 = undefined;
    argv_strings[0] = exe_path;
    for (argv_buffers.constSlice()[1..], 1..) |arg, i| {
        argv_strings[i] = arg.constSlice();
    }
    const argv = argv_strings[0..argv_buffers.len];

    if (comptime builtin.target.os.tag == .windows) {
        Debug.default.warn("TODO: Auto-restart may not be supported on this platform", .{});

        // Windows: spawn new process then exit
        var child = Child.init(argv, allocator);
        try child.spawn();

        // Exit current process
        process.exit(0);
    } else {
        // Unix: replace current process
        return process.execve(allocator, argv, null);
    }
}
