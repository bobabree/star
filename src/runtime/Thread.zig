const thread = @import("std").Thread;
const Debug = @import("Debug.zig");
const OS = @import("OS.zig");

const Thread = if (OS.is_wasm) WasmThread else thread;
const SpawnConfig = thread.SpawnConfig;
const SpawnError = thread.SpawnError;
const Wasm = @import("Wasm.zig");

pub fn spawn(config: SpawnConfig, comptime function: anytype, args: anytype) SpawnError!Thread {
    if (OS.is_wasm) {
        return wasmSpawn(config, function, args);
    } else {
        return Thread.spawn(config, function, args);
    }
}

const WasmThread = struct {
    thread_id: u32,

    pub fn join(self: WasmThread) void {
        Wasm.threadJoin(self.thread_id);
    }

    pub fn detach(self: WasmThread) void {
        // Web Workers auto-cleanup
        _ = self;
    }
};

fn wasmSpawn(config: SpawnConfig, comptime _: anytype, args: anytype) SpawnError!WasmThread {
    _ = config;
    _ = args;

    // TODO: For now, just use hot_reload as default task
    const task_id = @intFromEnum(TaskType.hot_reload);
    const thread_id = Wasm.createThread(task_id);
    return WasmThread{ .thread_id = thread_id };
}

export fn invoke_thread_task(task_id: u32) void {
    const type_info = @typeInfo(TaskType);
    inline for (type_info.@"enum".fields) |field| {
        if (task_id == field.value) {
            const task = @as(TaskType, @enumFromInt(field.value));
            Debug.setThreadScope(.wasm, task);
            task.execute();
            return;
        }
    }
    Debug.wasm.warn("Unknown task_id: {}", .{task_id});
}

// TODO is_wasm == Wasm.sleep
pub const sleep = thread.sleep;

pub const TaskType = enum(u32) {
    hot_reload = 0,
    default = 1,

    pub fn getTaskId(comptime self: TaskType) u32 {
        return @intFromEnum(self);
    }

    pub fn execute(comptime self: TaskType) void {
        switch (self) {
            .hot_reload, .default => self.hotReloadLoop(),
        }
    }

    fn hotReloadLoop(comptime self: TaskType) void {
        _ = self;

        // Initial check
        Wasm.fetch("/star.wasm", "HEAD", FETCH_WASM_SIZE);

        // Sleep and continue
        waiting = true;
        Wasm.sleep(2000);
    }
};

pub fn hotReloadTask() void {
    TaskType.hot_reload.execute();
}

// TODO:
// 1. Hot reload in release mode
// 2. CheckFileSize not reliable if change too small
// 3. There seems to be unncessary building/serve spams
// 4. Building in debug mode should skip minify/wasm-opt
// 5. index.html/js hot reloading

const FETCH_WASM_SIZE = 0;
var waiting = true;
export fn sleep_callback() void {
    //Debug.wasm.warn("SLEEP CALLED.", .{});

    waiting = false;
    // Continue the loop
    Wasm.fetch("/star.wasm", "HEAD", FETCH_WASM_SIZE);

    // Schedule next check
    Wasm.sleep(1000);
}

var last_wasm_hash: u32 = 0;
var reload_counter: u32 = 0;
export fn fetch_callback(callback_id: u32, value: u32) void {
    if (callback_id == FETCH_WASM_SIZE) {
        reload_counter += 1;

        if (last_wasm_hash != 0 and value != last_wasm_hash) {
            // File changed! But wait - builds write files in stages (truncate -> write -> flush).
            // Reloading mid-write = corrupted WASM. After 3+ checks, file is definitely stable.
            if (reload_counter > 3) {
                Debug.wasm.info("🔄 WASM changed (hash: {} -> {})", .{ last_wasm_hash, value });
                Wasm.reloadWasm();
                reload_counter = 0; // Reset to enforce minimum time between reloads
            }
        }

        // Track latest hash even during debounce
        last_wasm_hash = value;
    }
}
