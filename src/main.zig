const runtime = @import("runtime.zig");

const builtin = runtime.builtin;
const Debug = runtime.Debug;
const Heap = runtime.Heap;
const Mem = runtime.Mem;
const OS = runtime.OS;
const Process = runtime.Process;
const Server = runtime.server.Server;
const Thread = runtime.Thread;
const Time = runtime.Time;

pub fn main() !void {
    if (OS.is_wasm) {
        return;
    }

    // Single FBA for everything
    var buffer: [2 * 1024 * 1024]u8 = undefined;
    var fba = Heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    if (OS.is_ios) {
        Debug.ios.success("Hello World from Zig iOS!", .{});
    } else {
        const args = Process.argsMaybeAlloc(allocator);
        const is_dev = for (args.constSlice()) |arg| {
            if (Mem.eql(u8, arg.constSlice(), "--dev")) break true;
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
            Debug.server.warn("Current time: {}", .{timestamp});
            Thread.sleep(30 * Time.ns_per_s);
        }
    }
}
