const runtime = @import("runtime.zig");

const builtin = runtime.builtin;
const Heap = runtime.Heap;
const Mem = runtime.Mem;
const Process = runtime.Process;
const Server = runtime.server.Server;

pub fn main() !void {
    if (builtin.target.cpu.arch == .wasm32) return;

    // Single FBA for everything
    var buffer: [2 * 1024 * 1024]u8 = undefined;
    var fba = Heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    // Check for --dev flag
    // TODO: non-alloc
    const args = try Process.argsAlloc(allocator);
    defer Process.argsFree(allocator, args);

    const is_dev = for (args) |arg| {
        if (Mem.eql(u8, arg, "--dev")) break true;
    } else false;

    var server = Server.init(allocator, is_dev);
    try server.run();
}
