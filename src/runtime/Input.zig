const OS = @import("OS.zig");
const Debug = @import("Debug.zig");
const builtin = @import("builtin");
const std = @import("std");
const Channel = @import("Channel.zig");

var registered_channels: [16]*Channel.DefaultChannel = undefined;
var channel_count: usize = 0;

// For native platforms
var stdin_reader: ?std.fs.File.Reader = null;

pub const InputEvent = union(enum) {
    key: u8,
    ctrl_key: enum { ctrl_c, ctrl_d, ctrl_z, ctrl_l },
    special: enum { escape, tab, enter, backspace, delete },
    arrow: enum { up, down, left, right },
    function: u8,

    pub fn read(byte: u8) InputEvent {
        return switch (byte) {
            3 => .{ .ctrl_key = .ctrl_c },
            4 => .{ .ctrl_key = .ctrl_d },
            12 => .{ .ctrl_key = .ctrl_l },
            26 => .{ .ctrl_key = .ctrl_z },
            9 => .{ .special = .tab },
            13, 10 => .{ .special = .enter },
            127, 8 => .{ .special = .backspace },
            27 => .{ .special = .escape },
            else => .{ .key = byte },
        };
    }

    pub fn write(self: InputEvent) u8 {
        return switch (self) {
            .key => |k| k,
            .ctrl_key => |k| switch (k) {
                .ctrl_c => 3,
                .ctrl_d => 4,
                .ctrl_z => 26,
                .ctrl_l => 12,
            },
            .special => |s| switch (s) {
                .enter => 13,
                .backspace => 127,
                .tab => 9,
                .escape => 27,
                .delete => 127,
            },
            else => 0,
        };
    }
};

pub const Input = enum {
    wasm,
    ios,
    macos,
    linux,
    windows,

    pub fn init(comptime _: Input) void {
        // Reset registration
        channel_count = 0;
    }

    pub fn register(comptime _: Input, component: anytype) void {
        registered_channels[channel_count] = component.getChannel();
        channel_count += 1;
    }

    pub fn run(comptime self: Input) void {
        switch (self) {
            .wasm => {
                // JavaScript calls input_key directly - no setup needed
            },
            .macos => {
                // macOS: Use kqueue to monitor stdin
                // const kq = std.os.kqueue() catch return;
                // var change = kevent{
                //     .ident = @intCast(std.posix.STDIN_FILENO),
                //     .filter = EVFILT_READ,
                //     .flags = EV_ADD | EV_ENABLE,
                // };
                // kevent(kq, &change, 1, null, 0, null);
                // Main loop will kevent(kq, null, 0, &events, 1, null) to wait
            },
            .linux => {
                // Linux: Use epoll to monitor stdin
                // const epfd = std.os.epoll_create1(0) catch return;
                // var ev = epoll_event{
                //     .events = EPOLLIN,
                //     .data = .{ .fd = std.posix.STDIN_FILENO },
                // };
                // epoll_ctl(epfd, EPOLL_CTL_ADD, std.posix.STDIN_FILENO, &ev);
                // Main loop will epoll_wait(epfd, &events, 1, -1) to wait

            },
            .windows => {
                // Windows: Use ReadConsoleInput with async callback
                // const handle = GetStdHandle(STD_INPUT_HANDLE);
                // var input_record: INPUT_RECORD = undefined;
                // ReadConsoleInput(handle, &input_record, 1, &events_read);
                // Or use IOCP for async

            },
            .ios => {
                // iOS: Use Grand Central Dispatch
                // dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, ...)
                // dispatch_source_set_event_handler(source, ^{ processStdin(); });
                // dispatch_resume(source);
            },
        }
    }

    fn broadcast(comptime self: Input, event: InputEvent) void {
        const data = [_]u8{event.write()};

        var i: usize = 0;
        while (i < channel_count) : (i += 1) {
            if (!registered_channels[i].send(&data)) {
                Debug.default.warn("input.{s}: channel full, dropped message", .{@tagName(self)});
            }
        }
    }

    // Called by native event loop when stdin has data
    pub fn processStdin(comptime self: Input) void {
        if (stdin_reader) |reader| {
            const byte = reader.readByte() catch return;
            const event = InputEvent.read(byte);
            self.broadcast(event);
        }
    }
};

pub const input: Input = if (OS.is_wasm)
    .wasm
else if (OS.is_ios)
    .ios
else switch (builtin.target.os.tag) {
    .macos => .macos,
    .linux => .linux,
    .windows => .windows,
    else => @compileError("Unsupported input platform"),
};

// WASM entry point
export fn input_key(char: u8) void {
    if (!OS.is_wasm) return;
    const event = InputEvent.read(char);
    input.broadcast(event);
}
