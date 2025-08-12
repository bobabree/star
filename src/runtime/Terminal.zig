const builtin = @import("builtin");

const Debug = @import("Debug.zig");
const Mem = @import("Mem.zig");
const OS = @import("OS.zig");
const Wasm = @import("Wasm.zig");
const shell = @import("Shell.zig").shell;

// Platform-specific state
var input_buffer: [256]u8 = undefined;
var input_len: usize = 0;
var is_initialized: bool = false;

// Native terminal state (for non-wasm platforms)
var original_mode: if (OS.is_windows) @import("std").os.windows.DWORD else if (OS.is_wasm) void else @import("std").posix.termios = undefined;
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
        if (is_initialized) return;
        is_initialized = true;
        input_len = 0;
        @memset(&input_buffer, 0);

        switch (self) {
            .wasm => {},
            .windows => {
                // Save original console mode
                // const std = @import("std");
                // const handle = std.io.getStdIn().handle;
                // _ = std.os.windows.kernel32.GetConsoleMode(handle, &original_mode);
            },
            .macos, .linux => {
                // Save original terminal mode
                // const std = @import("std");
                // const fd = std.io.getStdIn().handle;
                // original_mode = std.posix.tcgetattr(fd) catch return;
            },
            else => {
                Debug.default.warn("Unsupported platform: {s}", .{@tagName(self)});
            },
        }
    }

    pub fn enterRawMode(comptime self: Terminal) void {
        if (is_raw_mode) return;

        switch (self) {
            .wasm => {
                // WASM terminal is always in "raw" mode
            },
            .windows => {
                // const std = @import("std");
                // const handle = std.io.getStdIn().handle;
                // const ENABLE_ECHO_INPUT: u32 = 0x0004;
                // const ENABLE_LINE_INPUT: u32 = 0x0002;
                // const ENABLE_PROCESSED_INPUT: u32 = 0x0001;

                // const new_mode = original_mode & ~@as(u32, ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT);
                // _ = std.os.windows.kernel32.SetConsoleMode(handle, new_mode);
            },
            .macos, .linux => {
                // const std = @import("std");
                // const fd = std.io.getStdIn().handle;

                // var new_mode = original_mode;
                // new_mode.lflag.ECHO = false;
                // new_mode.lflag.ICANON = false;
                // new_mode.lflag.ISIG = false;
                // new_mode.lflag.IEXTEN = false;
                // new_mode.iflag.IXON = false;
                // new_mode.iflag.ICRNL = false;
                // new_mode.cc[@intFromEnum(std.posix.V.MIN)] = 1;
                // new_mode.cc[@intFromEnum(std.posix.V.TIME)] = 0;

                // std.posix.tcsetattr(fd, std.posix.TCSA.NOW, new_mode) catch {};
            },
            else => {
                Debug.default.warn("Unsupported platform: {s}", .{@tagName(self)});
            },
        }

        is_raw_mode = true;
    }

    pub fn exitRawMode(comptime self: Terminal) void {
        if (!is_raw_mode) return;

        switch (self) {
            .wasm => {
                // Nothing to restore in WASM
            },
            .windows => {
                // const std = @import("std");
                // const handle = std.io.getStdIn().handle;
                // _ = std.os.windows.kernel32.SetConsoleMode(handle, original_mode);
            },
            .macos, .linux => {
                // const std = @import("std");
                // const fd = std.io.getStdIn().handle;
                // std.posix.tcsetattr(fd, std.posix.TCSA.NOW, original_mode) catch {};
            },
            else => {
                Debug.default.warn("Unsupported platform: {s}", .{@tagName(self)});
            },
        }

        is_raw_mode = false;
    }

    pub fn clear(comptime self: Terminal) void {
        switch (self) {
            .wasm => Wasm.terminalWrite("\x1b[2J\x1b[H"),
            .windows, .macos, .linux => {
                // const std = @import("std");
                // std.io.getStdOut().writeAll("\x1b[2J\x1b[H") catch {};
            },
            else => {
                Debug.default.warn("Unsupported platform: {s}", .{@tagName(self)});
            },
        }
    }

    pub fn write(comptime self: Terminal, text: []const u8) void {
        switch (self) {
            .wasm => Wasm.terminalWrite(text),
            .windows, .macos, .linux => {
                // const std = @import("std");
                // std.io.getStdOut().writeAll(text) catch {};
            },
            else => {
                Debug.default.warn("Unsupported platform: {s}", .{@tagName(self)});
            },
        }
    }

    pub fn getSize(comptime self: Terminal) struct { cols: u16, rows: u16 } {
        switch (self) {
            .wasm => {
                // TODO: These are set by JavaScript when terminal is initialized
                return .{ .cols = 80, .rows = 24 };
            },
            .windows => {
                // const std = @import("std");
                // var csbi: std.os.windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
                // const handle = std.os.windows.kernel32.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) orelse {
                //     return .{ .cols = 80, .rows = 24 };
                // };

                // if (std.os.windows.kernel32.GetConsoleScreenBufferInfo(handle, &csbi) == 0) {
                //     return .{ .cols = 80, .rows = 24 };
                // }

                // return .{
                //     .cols = @intCast(csbi.srWindow.Right - csbi.srWindow.Left + 1),
                //     .rows = @intCast(csbi.srWindow.Bottom - csbi.srWindow.Top + 1),
                // };
            },
            .macos, .linux => {
                // const std = @import("std");
                // var ws: std.posix.winsize = undefined;
                // const result = std.c.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));

                // if (result != 0) {
                //     return .{ .cols = 80, .rows = 24 };
                // }

                // return .{ .cols = ws.col, .rows = ws.row };
            },
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

// WASM-specific export for keyboard input
export fn terminal_key(char: u8) void {
    if (char == 13) { // Enter key
        const cmd = input_buffer[0..input_len];
        shell.processCommand(comptime terminal, cmd);

        input_len = 0;

        terminal.write("\r\n");
        shell.showPrompt(comptime terminal);
    } else if (char == 127 or char == 8) { // Backspace
        if (input_len > 0) {
            input_len -= 1;
            terminal.write("\x08 \x08");
        }
    } else if (input_len < 255) {
        input_buffer[input_len] = char;
        input_len += 1;

        var echo: [1]u8 = .{char};
        terminal.write(&echo);
    }
}
