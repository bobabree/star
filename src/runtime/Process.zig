const process = @import("std").process;
const builtin = @import("builtin");

const Debug = @import("Debug.zig");
const FixedBuffer = @import("FixedBuffer.zig").FixedBuffer;
const Fmt = @import("Fmt.zig");
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

pub fn restartSelf(allocator: Mem.Allocator, exe_name: []const u8) !void {
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
        // Find the NEW exe in .zig-cache
        var newest_exe_path: [Fs.max_path_bytes]u8 = undefined;
        var newest_exe: []const u8 = exe_path;
        var newest_mtime: i128 = 0;

        var cache_dir = Fs.cwd().openDir(".zig-cache/o", .{ .iterate = true }) catch |err| {
            Debug.server.warn("No cache dir, using current exe: {}", .{err});
            var child = Child.init(argv, allocator);
            try child.spawn();
            process.exit(0);
        };
        defer cache_dir.close();

        var walker = cache_dir.walk(allocator) catch |err| {
            Debug.server.err("Failed to walk cache dir: {}", .{err});
            var child = Child.init(argv, allocator);
            try child.spawn();
            process.exit(0);
        };
        defer walker.deinit();

        while (walker.next() catch null) |entry| {
            if (entry.kind == .file and Mem.eql(u8, entry.basename, exe_name)) {
                var temp_path: [Fs.max_path_bytes]u8 = undefined;
                const full_path = Fmt.bufPrint(&temp_path, ".zig-cache/o/{s}", .{entry.path}) catch |err| {
                    Debug.server.warn("Path too long for {s}: {}", .{ entry.path, err });
                    continue;
                };
                const file = Fs.cwd().openFile(full_path, .{}) catch continue;
                defer file.close();
                const stat = file.stat() catch continue;
                if (stat.mtime > newest_mtime) {
                    newest_mtime = stat.mtime;
                    @memcpy(newest_exe_path[0..full_path.len], full_path);
                    newest_exe = newest_exe_path[0..full_path.len];
                }
            }
        }

        argv_strings[0] = newest_exe;

        var child: Child = undefined;
        if (argv_buffers.len < MAX_ARGS) {
            argv_strings[argv_buffers.len] = "--restarted";
            child = Child.init(argv_strings[0 .. argv_buffers.len + 1], allocator);
        } else {
            child = Child.init(argv_strings[0..argv_buffers.len], allocator);
        }

        try child.spawn();
        process.exit(0);
    } else {
        // Unix: replace current process
        return process.execve(allocator, argv, null);
    }
}
