const builtin = @import("builtin");
const Channel = @import("Channel.zig");
const Debug = @import("Debug.zig");
const Fs = @import("Fs.zig");
const Input = @import("Input.zig");
const IO = @import("IO.zig");
const Mem = @import("Mem.zig");
const OS = @import("OS.zig");
const Posix = @import("Posix.zig");
const Thread = @import("Thread.zig");
const Time = @import("Time.zig");
const Utf8Buffer = @import("Utf8Buffer.zig").Utf8Buffer;
const Wasm = @import("Wasm.zig");

const ASCII = Input.ASCII;

var input_buffer = Utf8Buffer(256).init();
var input_channel = Channel.DefaultChannel{};

// Native terminal state (for non-wasm platforms)
var width: u16 = 80;
var height: u16 = 24;
var is_raw_mode: bool = false;

pub const Terminal = enum {
    wasm,
    windows,
    macos,
    linux,
    ios,

    pub fn init(comptime self: Terminal) void {
        // Register callbacks
        input_channel.onSend(struct {
            fn callback() void {
                self.tick();
            }
        }.callback);

        IO.stdio.out.channel().onSend(struct {
            fn callback() void {
                self.tick();
            }
        }.callback);
    }

    pub fn run(comptime self: Terminal) void {
        switch (self) {
            .wasm => {
                // Initialize the xterm terminal
                Wasm.terminalInit("terminal");
            },
            else => {
                // Native
                terminalInit("terminal");
            },
        }
    }

    fn terminalInit(_: []const u8) void {
        const stderr_thread = Thread.spawn(.{}, terminalWrite, .{}) catch return;
        stderr_thread.detach();
    }

    fn terminalWrite() void {
        const handle = switch (builtin.target.os.tag) {
            .windows => OS.windows.GetStdHandle(OS.windows.STD_ERROR_HANDLE) catch |err| {
                Debug.default.err("Failed to get stderr handle: {}", .{err});
                return;
            },
            else => Posix.STDERR_FILENO,
        };

        const stderr = Fs.File{ .handle = handle };

        while (true) {
            if (IO.stdio.err.recv()) |text| {
                stderr.writeAll(text) catch |err| {
                    Debug.default.err("Failed to write stderr: {}", .{err});
                };
            }
            Thread.sleep(1_000_000);
        }
    }

    pub fn tick(comptime self: Terminal) void {
        self.processInput();
        self.processOutput();
    }

    fn processInput(comptime self: Terminal) void {
        while (input_channel.recv()) |data| {
            if (data.len > 0) {
                const event = Input.InputEvent.read(data[0]);
                const char_opt: ?u8 = switch (event) {
                    .key => |k| k,
                    .special => |s| switch (s) {
                        .enter => @as(u8, ASCII.ENTER),
                        .backspace => @as(u8, ASCII.BACKSPACE),
                        .tab => @as(u8, ASCII.TAB),
                        .escape => @as(u8, ASCII.ESCAPE),
                        else => null,
                    },
                    .ctrl_key => |k| switch (k) {
                        .ctrl_c => @as(u8, ASCII.CTRL_C),
                        .ctrl_d => @as(u8, ASCII.CTRL_D),
                        .ctrl_z => @as(u8, ASCII.CTRL_Z),
                        .ctrl_l => @as(u8, ASCII.CTRL_L),
                    },
                    else => null,
                };

                const char = char_opt orelse continue;

                if (char == ASCII.ENTER) {
                    const cmd = input_buffer.constSlice(); // Get the buffer content
                    input_buffer.clear();

                    switch (self) {
                        .wasm => self.write("\r\n"),
                        else => {},
                    }

                    IO.stdio.in.send(cmd);
                } else if (char == ASCII.BACKSPACE or char == ASCII.BACKSPACE_ALT) {
                    if (input_buffer.len() > 0) {
                        input_buffer.removeAt(input_buffer.len() - 1); // Remove last char
                        switch (self) {
                            .wasm => self.write("\x08 \x08"),
                            else => {},
                        }
                    }
                } else if (input_buffer.constSlice().len < 255) { // Check byte length
                    var char_bytes = [1]u8{char};
                    input_buffer.appendSlice(&char_bytes);
                    switch (self) {
                        .wasm => {
                            var echo: [1]u8 = .{char};
                            self.write(&echo);
                        },
                        else => {},
                    }
                }
            }
        }
    }

    fn processOutput(comptime self: Terminal) void {
        while (IO.stdio.out.recv()) |output| {
            self.write(output);
        }
    }

    pub fn getChannel(_: Terminal) *Channel.DefaultChannel {
        return &input_channel;
    }

    pub fn enterRawMode(comptime self: Terminal) void {
        if (is_raw_mode) return;

        switch (self) {
            .wasm => {},
            .windows => {},
            .macos, .linux => {},
            else => {
                Debug.default.warn("Unsupported platform: {s}", .{@tagName(self)});
            },
        }

        is_raw_mode = true;
    }

    pub fn exitRawMode(comptime self: Terminal) void {
        if (!is_raw_mode) return;

        switch (self) {
            .wasm => {},
            .windows => {},
            .macos, .linux => {},
            else => {
                Debug.default.warn("Unsupported platform: {s}", .{@tagName(self)});
            },
        }

        is_raw_mode = false;
    }

    pub fn clear(comptime self: Terminal) void {
        switch (self) {
            .wasm => Wasm.terminalWrite("\x1b[2J\x1b[H"),
            .windows, .macos, .linux => {},
            else => {
                Debug.default.warn("Unsupported platform: {s}", .{@tagName(self)});
            },
        }
    }

    pub fn write(comptime self: Terminal, text: []const u8) void {
        switch (self) {
            .wasm => Wasm.terminalWrite(text),
            .windows, .macos, .linux => {
                IO.stdio.err.send(text); // this will trigger native terminalWrite
            },
            else => {
                Debug.default.warn("Unsupported platform: {s}", .{@tagName(self)});
            },
        }
    }

    pub fn getSize(comptime self: Terminal) struct { cols: u16, rows: u16 } {
        switch (self) {
            .wasm => {
                return .{ .cols = 80, .rows = 24 };
            },
            .windows => {},
            .macos, .linux => {},
            else => {
                Debug.default.warn("Unsupported platform: {s}", .{@tagName(self)});
            },
        }
    }
};

pub const terminal: Terminal = if (OS.is_wasm)
    .wasm
else if (OS.is_ios)
    .ios
else switch (builtin.target.os.tag) {
    .macos => .macos,
    .linux => .linux,
    .windows => .windows,
    else => @compileError("Unsupported terminal platform: " ++ @tagName(builtin.target.os.tag)),
};
