const builtin = @import("builtin");
const Channel = @import("Channel.zig");
const Debug = @import("Debug.zig");
const Fs = @import("Fs.zig");
const OS = @import("OS.zig");
const Thread = @import("Thread.zig");

pub const ASCII = struct {
    pub const BACKSPACE_ALT = 8;
    pub const TAB = 9;
    pub const NEWLINE = 10;
    pub const ENTER = 13;
    pub const ESCAPE = 27;
    pub const SPACE = 32;
    pub const ESC_BRACKET = 91;
    pub const DEL = 127;
    pub const BACKSPACE = 127;

    // Control keys
    pub const CTRL_C = 3;
    pub const CTRL_D = 4;
    pub const CTRL_L = 12;
    pub const CTRL_Z = 26;

    // arrows
    pub const ARROW_UP = 65; // 'A'
    pub const ARROW_DOWN = 66; // 'B'
    pub const ARROW_RIGHT = 67; // 'C'
    pub const ARROW_LEFT = 68; // 'D'
};

var registered_channels: [16]*Channel.DefaultChannel = undefined;
var channel_count: usize = 0;
var input_parser = InputParser{};

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
            ASCII.ARROW_UP => .{ .arrow = .up },
            ASCII.ARROW_DOWN => .{ .arrow = .down },
            ASCII.ARROW_RIGHT => .{ .arrow = .right },
            ASCII.ARROW_LEFT => .{ .arrow = .left },
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
            .arrow => |a| switch (a) {
                .up => ASCII.ARROW_UP,
                .down => ASCII.ARROW_DOWN,
                .right => ASCII.ARROW_RIGHT,
                .left => ASCII.ARROW_LEFT,
            },
            else => 0,
        };
    }
};

const InputParser = struct {
    buffer: [8]u8 = undefined,
    len: u8 = 0,

    fn feed(self: *InputParser, byte: u8) ?InputEvent {
        self.buffer[self.len] = byte;
        self.len += 1;

        if (self.len == 1) {
            if (byte != ASCII.ESCAPE) {
                const event = InputEvent.read(byte);
                self.len = 0;
                return event;
            }
            return null;
        }

        // ESC sequence
        if (self.buffer[0] == ASCII.ESCAPE) {
            if (self.len == 2 and self.buffer[1] != ASCII.ESC_BRACKET) {
                self.len = 0;
                return .{ .special = .escape };
            }
            if (self.len == 3) {
                const event: InputEvent = switch (self.buffer[2]) {
                    ASCII.ARROW_UP => .{ .arrow = .up },
                    ASCII.ARROW_DOWN => .{ .arrow = .down },
                    ASCII.ARROW_RIGHT => .{ .arrow = .right },
                    ASCII.ARROW_LEFT => .{ .arrow = .left },
                    else => .{ .special = .escape },
                };
                self.len = 0;
                return event;
            }
        }

        return null;
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
            else => OS.posix.STDIN_FILENO,
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
                if (input_parser.feed(buffer[0])) |event| {
                    self.broadcast(event);
                }
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

export fn input_key(char: u8) void {
    if (input_parser.feed(char)) |event| {
        input.broadcast(event);
    }
}
