const runtime = @import("runtime.zig");

const Allocator = runtime.Mem.Allocator;
const ArgsBuffer = runtime.Process.ArgsBuffer;
const Debug = runtime.Debug;
const Heap = runtime.Heap;
const Mem = runtime.Mem;
const OS = runtime.OS;
const Process = runtime.Process;
const Server = runtime.server.Server;
const Thread = runtime.Thread;
const Time = runtime.Time;
const Wasm = runtime.Wasm;
const builtin = runtime.builtin;

const input = runtime.Input.input;
const shell = runtime.Shell.shell;
const terminal = runtime.Terminal.terminal;

var buffer: [1 * 1024 * 1024]u8 = undefined;
var fba: Heap.FixedBufferAllocator = undefined;
var allocator: Allocator = undefined;
var args: ArgsBuffer = undefined;
var enable_hot_reload: bool = false;

const App = enum {
    wasm,
    ios,
    macos,
    linux,
    windows,

    pub fn init(comptime self: App) void {
        // Initialize allocator
        fba = Heap.FixedBufferAllocator.init(&buffer);
        allocator = fba.allocator();

        // Initialize args
        args = if (self == .wasm)
            ArgsBuffer.init(0) // Empty args for wasm
        else
            Process.argsMaybeAlloc(allocator);

        switch (self) {
            .wasm => {
                // Link js/wasm libs
                Wasm.linkLibs(allocator) catch |err| {
                    Debug.wasm.err("Failed to link libs: {}", .{err});
                };

                Wasm.buildUI();

                // Start hot reload if configured
                if (enable_hot_reload) {
                    self.startHotReload();
                }
            },
            .ios => {
                Debug.ios.success("Hello World from Zig iOS!", .{});
            },
            .macos, .linux, .windows => {},
        }

        {
            terminal.init();
            terminal.run();
        }

        {
            shell.init();
            shell.run();
        }

        {
            input.init();
            input.register(terminal);
            input.run();
        }
    }

    pub fn run(comptime self: App) !void {
        switch (self) {
            .wasm => {
                // WASM runs everything in init/callbacks
            },
            .ios => {
                // iOS runs in its own event loop
            },
            .macos, .linux, .windows => {
                // Check for --dev flag
                const is_dev = for (args.constSlice()) |arg| {
                    if (Mem.eql(u8, arg.constSlice(), "--dev")) break true;
                } else false;

                if (is_dev) {
                    // Server uses its own allocator
                    var server_buffer: [8 * 1024 * 1024]u8 = undefined;
                    var server_fba = Heap.FixedBufferAllocator.init(&server_buffer);
                    const server_allocator = server_fba.allocator();

                    var server = Server.init(server_allocator, is_dev);
                    // Run server in background thread
                    const server_thread = try Thread.spawn(.{}, Server.run, .{&server});
                    server_thread.detach();
                }

                // TODO: Main thread
                while (true) {
                    const timestamp = Time.timestamp();
                    Debug.server.warn("Current time: {}", .{timestamp});
                    Thread.sleep(30 * Time.ns_per_s);
                }
            },
        }
    }

    pub fn startHotReload(comptime self: App) void {
        switch (self) {
            .wasm => {
                Debug.wasm.info("Hot reload enabled (polling mode)", .{});

                const thread = Thread.spawn(.{}, Thread.hotReloadLoop, .{}) catch |err| {
                    Debug.wasm.err("Failed to spawn hot reload thread: {}", .{err});
                    return;
                };
                thread.detach();
            },
            .ios => {
                // TODO: iOS hot reload implementation
            },
            .macos, .linux, .windows => {
                // TODO: Native hot reload implementation
            },
        }
    }
};

const app: App = if (OS.is_wasm)
    .wasm
else if (OS.is_ios)
    .ios
else switch (builtin.target.os.tag) {
    .macos => .macos,
    .linux => .linux,
    .windows => .windows,
    else => @compileError("Unsupported app platform: " ++ @tagName(builtin.target.os.tag)),
};

pub fn main() !void {
    switch (comptime app) {
        inline else => |a| {
            a.init();
            try a.run();
        },
    }
}

export fn configure(hot_reload: bool) void {
    enable_hot_reload = hot_reload;
}
