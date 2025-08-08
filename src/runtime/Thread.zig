const thread = @import("std").Thread;
const Debug = @import("Debug.zig");

const Thread = if (Debug.is_wasm) WasmThread else thread;
const SpawnConfig = thread.SpawnConfig;
const SpawnError = thread.SpawnError;
const Wasm = @import("Wasm.zig");

pub fn spawn(config: SpawnConfig, comptime function: anytype, args: anytype) SpawnError!Thread {
    if (Debug.is_wasm) {
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
    Debug.wasm.warn("invoke_thread_task called with task_id: {}", .{task_id});
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
        //while (true) {
        Debug.wasm.warn("Hot reloading!", .{});
        checkWasmSize() catch |err| {
            Debug.wasm.warn("Hot reload check failed: {}", .{err});
            //continue;
        };
        //}
    }
};

pub fn hotReloadTask() void {
    TaskType.hot_reload.execute();
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
    //         reloadWasm();
    //     }
    //     last_wasm_size = size;
    // } else {
    //     runtime.Debug.wasm.warn("No content-length header in response", .{});
    // }
}
