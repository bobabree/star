const Mem = @import("Mem.zig");
const Terminal = @import("Terminal.zig").Terminal;
const OS = @import("OS.zig");
const builtin = @import("builtin");

pub const Shell = enum {
    wasm,
    ios,
    macos,
    linux,
    windows,

    pub fn showPrompt(comptime self: Shell, comptime term: Terminal) void {
        switch (self) {
            .wasm, .ios, .macos, .linux, .windows => {
                term.write("\x1b[1;32mroot\x1b[0m@\x1b[1;36mStarOS\x1b[0m \x1b[1;32m~\x1b[0m> ");
            },
        }
    }

    pub fn processCommand(comptime self: Shell, comptime term: Terminal, cmd: []const u8) void {
        switch (self) {
            .wasm, .ios, .macos, .linux, .windows => {
                if (Mem.eql(u8, cmd, "ls")) {
                    term.write("\r\nstar.wasm  index.html");
                } else if (Mem.eql(u8, cmd, "clear")) {
                    term.clear();
                } else if (Mem.eql(u8, cmd, "help")) {
                    term.write("\r\nCommands: ls, clear, help");
                } else if (cmd.len > 0) {
                    term.write("\r\nUnknown command: ");
                    term.write(cmd);
                }
            },
        }
    }
};

pub const shell: Shell = if (OS.is_wasm)
    .wasm
else if (OS.is_ios)
    .ios
else switch (builtin.target.os.tag) {
    .macos => .macos,
    .linux => .linux,
    .windows => .windows,
    else => @compileError("Unsupported shell platform: " ++ @tagName(builtin.target.os.tag)),
};
