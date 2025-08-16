const builtin = @import("builtin");
const Channel = @import("Channel.zig");
const Debug = @import("Debug.zig");
const Fs = @import("Fs.zig");
const Input = @import("Input.zig");
const IO = @import("IO.zig");
const Mem = @import("Mem.zig");
const OS = @import("OS.zig");
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
pub const TerminalMode = if (builtin.os.tag == .windows) OS.windows.DWORD else OS.posix.termios;
// Store original terminal mode for restoration
pub var original_mode: TerminalMode = Mem.zeroes(TerminalMode);

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
                self.terminalInit("terminal");
            },
        }
    }

    fn terminalInit(comptime self: Terminal, _: []const u8) void {
        const stderr_thread = Thread.spawn(.{}, terminalWrite, .{}) catch return;
        stderr_thread.detach();

        switch (self) {
            .wasm => {},
            .macos, .linux => {
                const stdin_handle = OS.posix.STDIN_FILENO;

                // Get current terminal settings
                original_mode = OS.posix.tcgetattr(stdin_handle) catch |err| {
                    Debug.default.warn("Failed to get terminal attributes: {}", .{err});
                    return;
                };

                var new_mode = original_mode;

                new_mode.lflag.ECHO = false;
                new_mode.lflag.ICANON = false;
                new_mode.lflag.ISIG = false; // ctrl +C
                //new_mode.lflag.ISIG = false; // TODO: isable signal generation
                new_mode.cc[@intFromEnum(OS.posix.V.MIN)] = 1;
                new_mode.cc[@intFromEnum(OS.posix.V.TIME)] = 0;

                OS.posix.tcsetattr(stdin_handle, .FLUSH, new_mode) catch |err| {
                    Debug.default.warn("Failed to set terminal attributes: {}", .{err});
                    return;
                };
            },
            .windows => {
                // TODO: Implement Windows terminal configuration
                // Need to:
                // 1. GetConsoleMode to save original
                // 2. SetConsoleMode to disable line buffering
                // 3. Enable virtual terminal processing for ANSI colors
            },
            else => {},
        }
    }

    fn terminalWrite() void {
        const handle = switch (builtin.target.os.tag) {
            .windows => OS.windows.GetStdHandle(OS.windows.STD_ERROR_HANDLE) catch |err| {
                Debug.default.err("Failed to get stderr handle: {}", .{err});
                return;
            },
            else => OS.posix.STDERR_FILENO,
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

                switch (event) {
                    .ctrl_key => |k| if (k == .ctrl_c) {
                        input_buffer.clear();
                        self.write("^C\r\n");
                        self.write("(to exit Star, type 'exit')\r\n");
                        IO.stdio.in.send("");
                        return;
                    },
                    .key => |byte| if (byte < ASCII.DEL and byte >= ASCII.SPACE) {
                        var char_bytes = [1]u8{byte};
                        input_buffer.appendSlice(&char_bytes);
                    },
                    else => {},
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
