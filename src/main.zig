const runtime = @import("runtime.zig");

const builtin = runtime.builtin;
const Heap = runtime.Heap;
const Mem = runtime.Mem;
const Process = runtime.Process;
const Server = runtime.server.Server;
const Debug = runtime.Debug;
const Thread = runtime.Thread;
const Time = runtime.Time;

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
        // TODO: non-alloc solution
        const args = try Process.argsAlloc(allocator);
        defer Process.argsFree(allocator, args);

        const is_dev = for (args) |arg| {
            if (Mem.eql(u8, arg, "--dev")) break true;
        } else false;

        if (is_dev) {
            var server = Server.init(allocator, is_dev);
            // Run server in background thread
            const server_thread = try Thread.spawn(.{}, Server.run, .{&server});
            server_thread.detach();
        }

        // TODO: Main thread
        while (true) {
            const timestamp = Time.timestamp();
            Debug.default.success("\nCurrent time: {}", .{timestamp});
            Thread.sleep(1 * Time.ns_per_s);
        }
    }
}
