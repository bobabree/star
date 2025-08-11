const runtime = @import("runtime.zig");

const Allocator = runtime.Mem.Allocator;
const Debug = runtime.Debug;
const FixedBufferAllocator = runtime.Heap.FixedBufferAllocator;
const Mem = runtime.Mem;
const Terminal = runtime.Terminal;
const Thread = runtime.Thread;
const Utf8Buffer = runtime.Utf8Buffer.Utf8Buffer;
const Wasm = runtime.Wasm;

var buffer: [1024 * 1024]u8 = undefined;
var fba: FixedBufferAllocator = undefined;
var allocator: Allocator = undefined;

var enable_hot_reload: bool = false;
export fn configure(hot_reload: bool) void {
    enable_hot_reload = hot_reload;
}

export fn _start() void {
    fba = FixedBufferAllocator.init(&buffer);
    allocator = fba.allocator();

    // Link js/wasm libs
    Wasm.linkLibs(allocator) catch |err| {
        Debug.wasm.err("Failed to link libs: {}", .{err});
    };

    Wasm.buildUI();

    if (enable_hot_reload) {
        startHotReload();
    }

    Terminal.init();
}

var last_wasm_size: u32 = 0;
var hmr_enabled: bool = false;

fn startHotReload() void {
    if (!hmr_enabled) {
        hmr_enabled = true;

        Debug.wasm.info("Hot reload enabled (polling mode)", .{});

        // Spawn background thread for polling
        const thread = Thread.spawn(.{}, Thread.hotReloadTask, .{}) catch |err| {
            Debug.wasm.err("Failed to spawn hot reload thread: {}", .{err});
            return;
        };
        thread.detach();
    }
}
