const thread = @import("std").Thread;

const Debug = @import("Debug.zig");
const Mem = @import("Mem.zig");
const OS = @import("OS.zig");
const Wasm = @import("Wasm.zig");

pub const Id = thread.Id;
pub const getCurrentId = thread.getCurrentId;
pub const yield = thread.yield;
pub const Thread = if (OS.is_wasm) WasmThread else thread;
const SpawnConfig = thread.SpawnConfig;
const SpawnError = thread.SpawnError;

pub const default = ThreadFunction.hot_reload;

// Registry of spawnable functions
pub const ThreadFunction = enum(u32) {
    hot_reload,

    pub fn run(self: ThreadFunction) void {
        switch (self) {
            .hot_reload => hotReloadLoop(),
        }
    }
};

// Map function pointers to ThreadFunction enum at compile time
fn getFunctionId(comptime function: anytype) ThreadFunction {
    const function_name = @typeName(@TypeOf(function));

    // Check function signatures or names
    if (function == hotReloadLoop) return .hot_reload;

    @compileError("Function not registered for WASM threading: " ++ function_name);
}

pub fn spawn(config: SpawnConfig, comptime function: anytype, args: anytype) SpawnError!Thread {
    if (OS.is_wasm) {
        const func_id = comptime getFunctionId(function);
        return wasmSpawn(func_id, args);
    } else {
        return thread.spawn(config, function, args);
    }
}

const WasmThread = struct {
    thread_id: u32,

    pub fn join(self: WasmThread) void {
        Wasm.threadJoin(self.thread_id);
    }

    pub fn detach(_: WasmThread) void {
        // Web workers should auto cleanup
    }
};

// Store args for each thread
const MAX_THREADS = 16;
var thread_args: [MAX_THREADS]?*anyopaque = [_]?*anyopaque{null} ** MAX_THREADS;
fn wasmSpawn(func_id: ThreadFunction, args: anytype) SpawnError!WasmThread {
    const thread_id = Wasm.createThread(@intFromEnum(func_id));

    // TODO: Store args if needed (requires heap allocation for now)
    if (@sizeOf(@TypeOf(args)) > 0) {}

    return WasmThread{ .thread_id = thread_id };
}

// Web Worker entry point
export fn invoke_thread(func_id: u32) void {
    const func = @as(ThreadFunction, @enumFromInt(func_id));
    Debug.setThreadScope(.wasm, func);

    // Run the function
    func.run();
}

// TODO is_wasm == Wasm.sleep
pub const sleep = thread.sleep;

pub fn hotReloadLoop() void {
    Wasm.fetch("/star.wasm", "HEAD", FETCH_WASM_SIZE);
    waiting = true;
    Wasm.sleep(1000, @intFromEnum(ThreadFunction.hot_reload)); // Schedule next iteration
}

const FETCH_WASM_SIZE = 0;
var waiting = true;
export fn sleep_callback(func_id: u32) void {
    waiting = false;
    invoke_thread(func_id);
    //Debug.default.success("started for {}.", .{func_id});
}

var last_wasm_hash: u32 = 0;
export fn reload_wasm_callback(callback_id: u32, value: u32) void {
    if (callback_id == FETCH_WASM_SIZE) {
        if (last_wasm_hash != 0 and value != last_wasm_hash) {
            Wasm.reloadWasm();
        }

        // Track latest hash
        last_wasm_hash = value;
    }
}
