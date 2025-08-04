const thread = @import("std").Thread;
const Debug = @import("Debug.zig");

const Thread = if (Debug.is_wasm) WasmThread else thread;
const SpawnConfig = thread.SpawnConfig;
const SpawnError = thread.SpawnError;

pub fn spawn(config: SpawnConfig, comptime function: anytype, args: anytype) SpawnError!Thread {
    if (Debug.is_wasm) {
        return wasmSpawn(config, function, args);
    } else {
        return Thread.spawn(config, function, args);
    }
}

const WasmThread = struct {
    worker_id: u32,

    pub fn join(self: WasmThread) void {
        worker_join(self.worker_id);
    }

    pub fn detach(self: WasmThread) void {
        // Web Workers auto-cleanup
        _ = self;
    }
};

extern fn create_web_worker(func_id: u32) u32;
extern fn worker_join(worker_id: u32) void;

var worker_registry: [32]?*const fn () void = [_]?*const fn () void{null} ** 32;
var worker_count: u8 = 0;

fn wasmSpawn(config: SpawnConfig, comptime function: anytype, args: anytype) SpawnError!WasmThread {
    _ = config;
    _ = args; // TODO: handle args later

    const func_id = worker_count;
    worker_registry[func_id] = &function;
    worker_count += 1;

    const worker_id = create_web_worker(func_id);
    Debug.wasm.warn("Thread created!", .{});

    return WasmThread{ .worker_id = worker_id };
}

export fn invoke_worker_func(func_id: u32) void {
    Debug.wasm.warn("invoke_worker_func called with ID: {}", .{func_id});
    if (func_id < worker_count and worker_registry[func_id] != null) {
        Debug.wasm.warn("Calling function at ID: {}", .{func_id});
        worker_registry[func_id].?();
    } else {
        Debug.wasm.warn("Function not found for ID: {}", .{func_id});
    }
}

pub const sleep = thread.sleep;
