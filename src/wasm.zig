const runtime = @import("runtime.zig");

const Allocator = runtime.Mem.Allocator;
const Debug = runtime.Debug;
const FixedBufferAllocator = runtime.Heap.FixedBufferAllocator;
const Mem = runtime.Mem;
const Utf8Buffer = runtime.Utf8Buffer.Utf8Buffer;
const UI = runtime.UI;

var buffer: [1024]u8 = undefined;
var fba: FixedBufferAllocator = undefined;
var allocator: Allocator = undefined;

export fn _start() void {
    fba = FixedBufferAllocator.init(&buffer);
    allocator = fba.allocator();

    // Build the UI
    UI.buildUI();

    Debug.wasm.success("UI built successfully!", .{});
}
