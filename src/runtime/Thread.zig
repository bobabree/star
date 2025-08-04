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

extern fn create_worker(task_id: u32) u32;
extern fn worker_join(worker_id: u32) void;

fn wasmSpawn(config: SpawnConfig, comptime task: anytype, args: anytype) SpawnError!WasmThread {
    _ = config;
    _ = args;

    const task_id = task.getTaskId();
    const worker_id = create_worker(task_id);
    return WasmThread{ .worker_id = worker_id };
}

export fn invoke_worker_task(task_id: u32) void {
    Debug.wasm.warn("invoke_worker_task called with task_id: {}", .{task_id});
    const type_info = @typeInfo(TaskType);
    inline for (type_info.@"enum".fields) |field| {
        if (task_id == field.value) {
            @as(TaskType, @enumFromInt(field.value)).execute();
            return;
        }
    }
    Debug.wasm.warn("Unknown task_id: {}", .{task_id});
}

pub const sleep = thread.sleep;

pub const TaskType = enum(u32) {
    hot_reload = 0,
    background_sync = 1,
    network_task = 2,

    pub fn getTaskId(comptime self: TaskType) u32 {
        return @intFromEnum(self);
    }

    pub fn execute(comptime self: TaskType) void {
        switch (self) {
            .hot_reload => self.hotReloadLoop(),
            .background_sync => self.backgroundSyncLoop(),
            .network_task => self.networkTaskLoop(),
        }
    }

    fn hotReloadLoop(comptime self: TaskType) void {
        _ = self;
        while (true) {
            Debug.wasm.warn("Hot reloading!", .{});
            checkWasmSize() catch |err| {
                Debug.wasm.warn("Hot reload check failed: {}", .{err});
                continue;
            };
        }
    }

    fn backgroundSyncLoop(comptime self: TaskType) void {
        _ = self;
        Debug.wasm.warn("Background sync running", .{});
    }

    fn networkTaskLoop(comptime self: TaskType) void {
        _ = self;
        Debug.wasm.warn("Network task running", .{});
    }
};

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
