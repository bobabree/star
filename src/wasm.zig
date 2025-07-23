const runtime = @import("runtime.zig");

const Allocator = Mem.Allocator;
const Debug = runtime.Debug;
const FixedBufferAllocator = runtime.Heap.FixedBufferAllocator;
const Mem = runtime.Mem;
const Utf8Buffer = runtime.Utf8Buffer.Utf8Buffer;
const wasm_log = runtime.Log.wasm_log;

var buffer: [1024]u8 = undefined;
var fba: FixedBufferAllocator = undefined;
var allocator: Allocator = undefined;

// Import JS string builtins
const RefType = @import("std").wasm.RefType;
const externref = RefType.externref;

export fn _start() void {
    fba = FixedBufferAllocator.init(&buffer);
    allocator = fba.allocator();

    wasm_log.info("WASM module initialized!", .{});
}

export fn runTests() void {
    //TODO: somehow link with Testing framework
    const result1 = add(2, 3);
    if (result1 == 5) {
        wasm_log.success("✅ Test 1 passed: add(2, 3) = x5", .{});
    } else {
        wasm_log.err("❌ Test 1 failed: add(2, 3) != 5", .{});
    }

    const result2 = add(-1, 1);
    if (result2 == 0) {
        wasm_log.success("✅ Test 2 passed: add(-1, 1) = 0", .{});
    } else {
        wasm_log.err("❌ Test 2 failed: add(-1, 1) != 0", .{});
    }

    wasm_log.info("Tests completed", .{});
}

export fn add(a: i32, b: i32) i32 {
    return a + b;
}

export fn allocate(size: usize) [*]u8 {
    const memory = allocator.alloc(u8, size) catch |err| {
        // TODO: Panic shown on js side
        Debug.panic("allocate failed with error {}: size {}", .{ err, size });
    };
    return memory.ptr;
}

export fn install(url_ptr: [*]const u8, url_len: usize) void {
    const url_slice = url_ptr[0..url_len];
    var url_buf = Utf8Buffer(2048).copy(url_slice);
    wasm_log.info("Install called with URL: {s}", .{url_buf.constSlice()});
}

export fn zig_install_externref(url_ptr: [*]const u8, length: i32) void {
    const url_slice = url_ptr[0..@intCast(length)];
    wasm_log.info("📦 Install package from URL: {s}", .{url_slice});
    wasm_log.info("📦 Install package from externref URL (length: {} chars)", .{length});
}

const Testing = runtime.Testing;

test "add function works" {
    try Testing.expect(add(2, 3) == 5);
    try Testing.expect(add(-1, 1) == 0);
}

test "add function works2" {
    try Testing.expect(add(2, 3) == 5);
    try Testing.expect(add(-1, 1) == 0);
}
