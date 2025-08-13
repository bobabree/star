const Mem = @import("Mem.zig");
const OS = @import("OS.zig");
const builtin = @import("builtin");
const IO = @import("IO.zig");

var is_initialized: bool = false;

pub const Shell = enum {
    wasm,
    ios,
    macos,
    linux,
    windows,

    pub fn init(comptime self: Shell) void {
        IO.stdio.in.channel().onSend(struct {
            fn callback() void {
                self.tick();
            }
        }.callback);
    }

    pub fn run(comptime self: Shell) void {
        // Show welcome after everything is initialized
        if (!is_initialized) {
            is_initialized = true;
            self.showGreeting();
        }
    }
    pub fn tick(comptime self: Shell) void {
        self.processCommands();
    }

    fn processCommands(comptime self: Shell) void {
        while (IO.stdio.in.recv()) |cmd| {
            self.executeCommand(cmd);
        }
    }

    fn executeCommand(comptime self: Shell, cmd: []const u8) void {
        if (Mem.eql(u8, cmd, "ls")) {
            IO.stdio.out.send("star.wasm  index.html");
        } else if (Mem.eql(u8, cmd, "clear")) {
            self.showGreeting();
            return;
        } else if (Mem.eql(u8, cmd, "help")) {
            IO.stdio.out.send("Commands: ls, clear, help");
        } else if (cmd.len > 0) {
            IO.stdio.out.send("Unknown command: ");
            IO.stdio.out.send(cmd);
        }

        if (cmd.len > 0) {
            IO.stdio.out.send("\r\n");
        }
        self.showPrompt();
    }

    fn showGreeting(comptime self: Shell) void {
        IO.stdio.out.send("\x1b[2J\x1b[H");
        IO.stdio.out.send("Welcome to \x1b[1;36mStarOS!\x1b[0m\r\n");
        IO.stdio.out.send("Type \x1b[1;32mhelp\x1b[0m for instructions on how to use StarOS\r\n");
        self.showPrompt();
    }

    fn showPrompt(comptime self: Shell) void {
        _ = self;
        // TODO: shell.json, bold green
        IO.stdio.out.send("\x1b[1;32mroot\x1b[0m@\x1b[1;36mStarOS\x1b[0m \x1b[1;32m~\x1b[0m> ");
    }

    fn processCommand(comptime self: Shell, cmd: []const u8) void {
        if (Mem.eql(u8, cmd, "ls")) {
            IO.stdio.out.send("star.wasm  index.html");
        } else if (Mem.eql(u8, cmd, "clear")) {
            self.showGreeting();
            return; // Don't double-prompt
        } else if (Mem.eql(u8, cmd, "help")) {
            IO.stdio.out.send("Commands: ls, clear, help");
        } else if (cmd.len > 0) {
            IO.stdio.out.send("Unknown: ");
            IO.stdio.out.send(cmd);
        }

        IO.stdio.out.send("\r\n");
        self.showPrompt();
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
    else => @compileError("Unsupported shell platform"),
};
