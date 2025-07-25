const runtime = @import("runtime.zig");

const builtin = runtime.builtin;
const Heap = runtime.Heap;
const Mem = runtime.Mem;
const Process = runtime.Process;
const Server = runtime.server.Server;
const Debug = runtime.Debug;

pub fn main() !void {
    if (Debug.is_wasm) {
        return;
    }

    // Single FBA for everything
    var buffer: [2 * 1024 * 1024]u8 = undefined;
    var fba = Heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    if (Debug.is_ios) {
        Debug.ios.success("Hello World from Zig iOS!", .{});
    } else {
        // Check for --dev
        // TODO: non-alloc solution
        const args = try Process.argsAlloc(allocator);
        defer Process.argsFree(allocator, args);

        const is_dev = for (args) |arg| {
            if (Mem.eql(u8, arg, "--dev")) break true;
        } else false;

        // TODO: Check for --web flag
        // TODO: maybe use wasi?
        var server = Server.init(allocator, is_dev);
        try server.run();
    }
}
