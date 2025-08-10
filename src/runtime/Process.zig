const process = @import("std").process;
const builtin = @import("builtin");

const Debug = @import("Debug.zig");
const FixedBuffer = @import("FixedBuffer.zig").FixedBuffer;
const Heap = @import("Heap.zig");
const Mem = @import("Mem.zig");
const OS = @import("OS.zig");
const Utf8Buffer = @import("Utf8Buffer.zig").Utf8Buffer;

pub const Child = process.Child;
pub const execve = process.execve;
pub const exit = process.exit;

pub const ArgsBuffer = FixedBuffer(Utf8Buffer(256), 32);

pub fn argsMaybeAlloc(allocator: Mem.Allocator) ArgsBuffer {
    var args_buffer = ArgsBuffer.init(0);

    if (OS.is_windows) {
        const args = process.argsAlloc(allocator) catch |err| {
            Debug.panic("Failed to get args on Windows: {}", .{err});
        };
        defer process.argsFree(allocator, args);

        for (args) |arg| {
            const utf8_arg = Utf8Buffer(256).copy(arg); // Validates UTF-8
            // fail fast -- WTF-8 bugs are hard to debug when they happen far from the source
            args_buffer.append(utf8_arg);
        }
    } else {
        const argv = @import("std").os.argv;
        for (argv) |arg_ptr| {
            const arg = Mem.span(arg_ptr);
            const utf8_arg = Utf8Buffer(256).copy(arg);
            args_buffer.append(utf8_arg);
        }
    }

    return args_buffer;
}
