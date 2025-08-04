const runtime = @import("runtime.zig");

const Allocator = runtime.Mem.Allocator;
const Debug = runtime.Debug;
const FixedBufferAllocator = runtime.Heap.FixedBufferAllocator;
const Mem = runtime.Mem;
const Thread = runtime.Thread;
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

    startHotReload(); //TODO: dev only
}

extern fn reload_wasm() void;

var last_wasm_size: u32 = 0;
var hmr_enabled: bool = false;

fn startHotReload() void {
    if (!hmr_enabled) {
        hmr_enabled = true;

        Debug.wasm.info("Hot reload enabled (polling mode)", .{});

        // Spawn background thread for polling
        const thread = Thread.spawn(.{}, Thread.TaskType.hot_reload, .{}) catch |err| {
            Debug.wasm.err("Failed to spawn hot reload thread: {}", .{err});
            return;
        };
        thread.detach();
    }
}
