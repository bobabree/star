const builtin = @import("builtin");
const Channel = @import("Channel.zig");
const Debug = @import("Debug.zig");
const Fs = @import("Fs.zig");
const OS = @import("OS.zig");
const Posix = @import("Posix.zig");
const Thread = @import("Thread.zig");

pub const ASCII = struct {
    pub const BACKSPACE_ALT = 8;
    pub const TAB = 9;
    pub const NEWLINE = 10;
    pub const ENTER = 13;
    pub const ESCAPE = 27;
    pub const SPACE = 32;
    pub const DEL = 127;
    pub const BACKSPACE = 127;

    // Control keys
    pub const CTRL_C = 3;
    pub const CTRL_D = 4;
    pub const CTRL_L = 12;
    pub const CTRL_Z = 26;
};

var registered_channels: [16]*Channel.DefaultChannel = undefined;
var channel_count: usize = 0;

// For native platforms
var stdin_reader: ?Fs.File.Reader = null;

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
            .macos, .linux, .windows => {
                // Spawn polling thread for stdin
                const thread = Thread.spawn(.{}, pollStdin, .{self}) catch |err| {
                    Debug.default.err("Failed to spawn input thread: {}", .{err});
                    return;
                };
                thread.detach();
            },
            .ios => {
                // TODO: iOS event handling
            },
        }
    }

    fn pollStdin(comptime self: Input) void {
        const handle = switch (builtin.target.os.tag) {
            .windows => OS.windows.GetStdHandle(OS.windows.STD_INPUT_HANDLE) catch |err| {
                Debug.default.err("Failed to get stdin handle: {}", .{err});
                return;
            },
            else => Posix.STDIN_FILENO,
        };

        const stdin = Fs.File{ .handle = handle };

        var buffer: [1]u8 = undefined;
        while (true) {
            const n = stdin.read(&buffer) catch |err| {
                Debug.default.err("Failed to read stdin: {}", .{err});
                Thread.sleep(10_000_000);
                continue;
            };
            if (n > 0) {
                const event = InputEvent.read(buffer[0]);
                self.broadcast(event);
            }
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
