const builtin = @import("builtin");
const FixedBuffer = @import("FixedBuffer.zig").FixedBuffer;
const Fs = @import("Fs.zig");
const fileSys = Fs.fileSys;
const IO = @import("IO.zig");
const Mem = @import("Mem.zig");
const OS = @import("OS.zig");

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
            self.processCommand(cmd);
        }
    }

    var skip_next: bool = false;

    fn processCommand(comptime self: Shell, cmd: []const u8) void {
        // Windows sends everything twice, skip every other call
        if (comptime self == .windows) {
            if (skip_next) {
                skip_next = false;
                return;
            }
            skip_next = true;
        }

        // Parse and execute command
        const shell_cmd = ShellCmd.parse(cmd);
        shell_cmd.execute(cmd);

        // Commands handle their own output/newlines
        if (shell_cmd != .clear) {
            self.showPrompt();
        }
    }

    fn showGreeting(comptime self: Shell) void {
        IO.stdio.out.send("\x1b[2J\x1b[H");
        IO.stdio.out.send("Welcome to \x1b[1;36mStarOS!\x1b[0m\r\n");
        IO.stdio.out.send("Type \x1b[1;32mhelp\x1b[0m for instructions on how to use StarOS\r\n");
        self.showPrompt();
    }

    fn showPrompt(comptime self: Shell) void {
        _ = self;

        // Build current path
        var path = Fs.PathBuffer.init();
        var indices = FixedBuffer(u8, 32).init(0);
        var current = Fs.fileSys.getCurrentDir();

        // If we're at root, just show ~
        if (current == 0) {
            path.setSlice("~");
        } else {
            // Build path from root
            while (current != 0) {
                indices.append(current);
                current = Fs.fileSys.getParent(current);
            }

            path.setSlice("~");
            while (indices.pop()) |idx| {
                const name = Fs.fileSys.getName(idx);
                path.appendSlice("/");
                path.appendSlice(name.constSlice());
            }
        }

        // Show prompt with current directory (fish style)
        IO.stdio.out.send("\x1b[1;32mroot\x1b[0m@\x1b[1;36mStarOS\x1b[0m \x1b[1;32m");
        IO.stdio.out.send(path.constSlice());
        IO.stdio.out.send("\x1b[0m> ");
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
pub const ShellCmd = enum {
    ls,
    pwd,
    cd,
    mkdir,
    touch,
    rm,
    clear,
    help,
    unknown,

    pub fn parse(cmd: []const u8) ShellCmd {
        // Trim whitespace first
        const trimmed = Mem.trim(u8, cmd, " \t\r\n");

        if (Mem.eql(u8, trimmed, "ls")) return .ls;
        if (Mem.eql(u8, trimmed, "pwd")) return .pwd;
        if (Mem.eql(u8, trimmed, "clear")) return .clear;
        if (Mem.eql(u8, trimmed, "help")) return .help;
        if (Mem.startsWith(u8, trimmed, "cd ")) return .cd;
        if (Mem.startsWith(u8, trimmed, "mkdir ")) return .mkdir;
        if (Mem.startsWith(u8, trimmed, "touch ")) return .touch;
        if (Mem.startsWith(u8, trimmed, "rm ")) return .rm;
        return .unknown;
    }

    pub fn execute(self: ShellCmd, cmd: []const u8) void {
        const trimmed = Mem.trim(u8, cmd, " \t\r\n");

        switch (self) {
            .ls => cmdLs(),
            .pwd => cmdPwd(),
            .cd => if (trimmed.len > 3) cmdCd(Mem.trim(u8, trimmed[3..], " \t\r\n/")),
            .mkdir => if (trimmed.len > 6) cmdMkdir(Mem.trim(u8, trimmed[6..], " \t\r\n")),
            .touch => if (trimmed.len > 6) cmdTouch(Mem.trim(u8, trimmed[6..], " \t\r\n")),
            .rm => if (trimmed.len > 3) cmdRm(Mem.trim(u8, trimmed[3..], " \t\r\n")),
            .clear => cmdClear(),
            .help => cmdHelp(),
            .unknown => cmdUnknown(cmd),
        }
    }

    fn cmdPwd() void {
        var path = Fs.PathBuffer.init();

        // Build path by traversing up
        var indices = FixedBuffer(u8, 32).init(0);
        var current = Fs.fileSys.getCurrentDir();

        while (current != 0) {
            indices.append(current);
            current = Fs.fileSys.getParent(current);
        }

        // Build path from root
        if (indices.len == 0) {
            path.setSlice("/");
        } else {
            while (indices.pop()) |idx| {
                const name = Fs.fileSys.getName(idx);
                path.appendSlice("/");
                path.appendSlice(name.constSlice());
            }
        }

        IO.stdio.out.send(path.constSlice());
        IO.stdio.out.send("\r\n");
    }

    fn cmdLs() void {
        const current = Fs.fileSys.getCurrentDir();
        const children = Fs.fileSys.getChildren(current);

        var first = true;
        for (children.constSlice()) |child_idx| {
            const name = Fs.fileSys.getName(child_idx);
            const node_type = Fs.fileSys.getType(child_idx);

            if (!first) IO.stdio.out.send("  ");
            IO.stdio.out.send(name.constSlice());

            if (node_type == .dir) {
                IO.stdio.out.send("/");
            }

            first = false;
        }

        //newline only if we printed something
        if (children.len > 0) {
            IO.stdio.out.send("\r\n");
        }
    }

    fn cmdCd(path: []const u8) void {
        if (Mem.eql(u8, path, "/")) {
            Fs.fileSys.setCurrentDir(0) catch return;
            return;
        }

        if (Mem.eql(u8, path, "..")) {
            const current = Fs.fileSys.getCurrentDir();
            const parent = Fs.fileSys.getParent(current);
            Fs.fileSys.setCurrentDir(parent) catch return;
            return;
        }

        const current = Fs.fileSys.getCurrentDir();
        if (Fs.fileSys.findChild(current, path)) |child| {
            Fs.fileSys.setCurrentDir(child) catch |err| {
                switch (err) {
                    error.NotADirectory => IO.stdio.out.send("cd: not a directory\r\n"),
                    else => IO.stdio.out.send("cd: failed\r\n"),
                }
            };
        } else {
            IO.stdio.out.send("cd: no such directory\r\n");
        }
    }

    fn cmdMkdir(name: []const u8) void {
        const current = Fs.fileSys.getCurrentDir();

        // Check if already exists
        if (Fs.fileSys.findChild(current, name) != null) {
            IO.stdio.out.send("mkdir: directory already exists\r\n");
            return;
        }

        // Create directory node
        const new_dir = Fs.fileSys.createNode(.dir, name) catch |err| {
            switch (err) {
                error.InvalidName => IO.stdio.out.send("mkdir: invalid name\r\n"),
                error.NoSpace => IO.stdio.out.send("mkdir: no space left\r\n"),
            }
            return;
        };

        // Link to parent
        Fs.fileSys.linkChild(current, new_dir) catch {
            IO.stdio.out.send("mkdir: failed to link\r\n");
        };
    }

    fn cmdTouch(name: []const u8) void {
        const current = Fs.fileSys.getCurrentDir();

        // Check if already exists
        if (Fs.fileSys.findChild(current, name) != null) {
            IO.stdio.out.send("touch: file already exists\r\n");
            return;
        }

        // Create file node
        const new_file = Fs.fileSys.createNode(.file, name) catch |err| {
            switch (err) {
                error.InvalidName => IO.stdio.out.send("touch: invalid name\r\n"),
                error.NoSpace => IO.stdio.out.send("touch: no space left\r\n"),
            }
            return;
        };

        // Link to parent
        Fs.fileSys.linkChild(current, new_file) catch {
            IO.stdio.out.send("touch: failed to link\r\n");
        };
    }

    fn cmdRm(name: []const u8) void {
        const current = Fs.fileSys.getCurrentDir();

        if (Fs.fileSys.findChild(current, name)) |child| {
            Fs.fileSys.unlinkChild(current, child) catch {
                IO.stdio.out.send("rm: failed to unlink\r\n");
                return;
            };
            Fs.fileSys.deleteNode(child) catch {
                IO.stdio.out.send("rm: failed to delete\r\n");
            };
        } else {
            IO.stdio.out.send("rm: file not found\r\n");
        }
    }

    fn cmdClear() void {
        shell.showGreeting();
    }

    fn cmdHelp() void {
        IO.stdio.out.send("Commands: ls, pwd, cd, mkdir, touch, rm, clear, help");
        IO.stdio.out.send("\r\n");
    }

    fn cmdUnknown(cmd: []const u8) void {
        if (cmd.len == 0 or Mem.trim(u8, cmd, " \t\r\n").len == 0) {
            return; // Empty commd
        }
        IO.stdio.out.send("Unknown command: ");
        IO.stdio.out.send(cmd);
        IO.stdio.out.send("\r\n");
    }
};
