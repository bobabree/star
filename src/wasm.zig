const runtime = @import("runtime.zig");
const ui = @import("ui.zig");

const Allocator = runtime.Mem.Allocator;
const Debug = runtime.Debug;
const FixedBufferAllocator = runtime.Heap.FixedBufferAllocator;
const Mem = runtime.Mem;
const Utf8Buffer = runtime.Utf8Buffer.Utf8Buffer;

var buffer: [1024]u8 = undefined;
var fba: FixedBufferAllocator = undefined;
var allocator: Allocator = undefined;

export fn _start() void {
    fba = FixedBufferAllocator.init(&buffer);
    allocator = fba.allocator();

    Debug.wasm.info("WASM module initialized!", .{});

    // Build the UI
    ui.buildUI();

    Debug.wasm.success("UI built successfully!", .{});
}

export fn runTests() void {
    const result1 = ui.add(2, 3);
    if (result1 == 5) {
        Debug.wasm.success("✅ Test 1 passed: add(2, 3) = 5", .{});
    } else {
        Debug.wasm.err("❌ Test 1 failed: add(2, 3) != 5", .{});
    }

    const result2 = ui.add(-1, 1);
    if (result2 == 0) {
        Debug.wasm.success("✅ Test 2 passed: add(-1, 1) = 0", .{});
    } else {
        Debug.wasm.err("❌ Test 2 failed: add(-1, 1) != 0", .{});
    }

    Debug.wasm.info("Tests completed", .{});
}

export fn allocate(size: usize) [*]u8 {
    const memory = allocator.alloc(u8, size) catch |err| {
        Debug.wasm.panic("allocate failed with error {}: size {}", .{ err, size });
    };
    return memory.ptr;
}
