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
        const thread = runtime.Thread.spawn(.{}, hotReloadLoop, .{}) catch |err| {
            Debug.wasm.err("Failed to spawn hot reload thread: {}", .{err});
            return;
        };
        thread.detach();
    }
}

fn hotReloadLoop() void {
    while (true) {
        //runtime.Thread.sleep(500 * runtime.Time.ns_per_s / 1000);
        runtime.Debug.wasm.warn("Hot reloadingggg", .{});

        checkWasmSize() catch |err| {
            runtime.Debug.wasm.warn("Hot reload check failed: {}", .{err});
            continue;
        };
    }
}

fn checkWasmSize() !void {
    // var client = std.http.Client{ .allocator = allocator };
    // defer client.deinit();

    // const uri = std.Uri.parse("http://127.0.0.1:8080/star.wasm") catch |err| {
    //     runtime.Debug.wasm.err("Failed to parse URI: {}", .{err});
    //     return err;
    // };

    // var request = client.request(.HEAD, uri, .{}, .{}) catch |err| {
    //     runtime.Debug.wasm.err("Failed to create HTTP request: {}", .{err});
    //     return err;
    // };
    // defer request.deinit();

    // request.start() catch |err| {
    //     runtime.Debug.wasm.err("Failed to start HTTP request: {}", .{err});
    //     return err;
    // };

    // request.wait() catch |err| {
    //     runtime.Debug.wasm.err("HTTP request failed: {}", .{err});
    //     return err;
    // };

    // if (request.response.headers.getFirstValue("content-length")) |size_str| {
    //     const size = std.fmt.parseInt(u32, size_str, 10) catch |err| {
    //         runtime.Debug.wasm.warn("Failed to parse content-length '{}': {}", .{ size_str, err });
    //         return;
    //     };

    //     if (last_wasm_size != 0 and size != last_wasm_size) {
    //         runtime.Debug.wasm.info("🔄 WASM file changed, reloading...", .{});
    //         reload_wasm();
    //     }
    //     last_wasm_size = size;
    // } else {
    //     runtime.Debug.wasm.warn("No content-length header in response", .{});
    // }
}
