const builtin = @import("builtin");
const ASCII = @import("Input.zig").ASCII;
const Channel = @import("Channel.zig");
const FixedBuffer = @import("FixedBuffer.zig").FixedBuffer;
const Utf8Buffer = @import("Utf8Buffer.zig").Utf8Buffer;
const Fs = @import("Fs.zig");
const IO = @import("IO.zig");
const Mem = @import("Mem.zig");
const OS = @import("OS.zig");

const fileSys = Fs.fileSys;

const WHITESPACE = " \t\r\n";
const PROMPT_BUFFER_SIZE = 256;
const RECOLOR_BUFFER_SIZE = PROMPT_BUFFER_SIZE * 2;

var input_channel = Channel.DefaultChannel{};
var input_buffer = Utf8Buffer(PROMPT_BUFFER_SIZE).init();

var last_color_sent = AnsiColor.reset;

pub const Shell = enum {
    wasm,
    ios,
    macos,
    linux,
    windows,

    pub fn init(comptime self: Shell) void {
        // Register to receive raw input for syntax highlighting
        input_channel.onSend(struct {
            fn callback() void {
                self.processRawInput();
            }
        }.callback);

        IO.stdio.in.channel().onSend(struct {
            fn callback() void {
                self.tick();
            }
        }.callback);
    }

    pub fn run(comptime self: Shell) void {
        self.showGreeting();
    }

    pub fn getChannel(_: Shell) *Channel.DefaultChannel {
        return &input_channel;
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
        const input_cmd = ShellCmd.parse(cmd);
        input_cmd.execute(cmd);

        // Commands handle their own output/newlines
        if (input_cmd != .clear) {
            self.showPrompt();
        }
    }

    fn processRawInput(comptime self: Shell) void {
        _ = self;

        while (input_channel.recv()) |data| {
            if (data.len > 0) {
                const byte = data[0];

                if (byte == ASCII.ENTER or byte == ASCII.NEWLINE) {
                    input_buffer.clear();
                } else if (byte == ASCII.BACKSPACE or byte == ASCII.BACKSPACE_ALT) {
                    if (input_buffer.len() > 0) {
                        input_buffer.removeAt(input_buffer.len() - 1);
                        recolorInput();
                    }
                } else if (byte < ASCII.DEL and byte >= ASCII.SPACE) { // Printable char
                    var char_bytes = [1]u8{byte};
                    input_buffer.appendSlice(&char_bytes);
                    recolorInput();
                }
            }
        }
    }

    fn recolorInput() void {
        const color = if (ShellCmd.isValid(input_buffer.constSlice()))
            AnsiColor.cyan
        else
            AnsiColor.red;

        var recolor = Utf8Buffer(RECOLOR_BUFFER_SIZE).init();
        const line_len = input_buffer.constSlice().len;

        // Move back to start of input
        for (0..line_len) |_| {
            recolor.appendSlice(AnsiColor.cursor_back.code());
        }

        // rewrite with correct color
        recolor.appendSlice(color.code());
        recolor.appendSlice(input_buffer.constSlice());
        recolor.appendSlice(AnsiColor.reset.code());

        IO.stdio.out.send(recolor.constSlice());
    }

    fn showGreeting(comptime self: Shell) void {
        var greeting = Utf8Buffer(256).init();
        greeting.appendSlice(AnsiColor.clear_screen.code());
        greeting.appendSlice("Welcome to ");
        greeting.appendSlice(AnsiColor.bold.code());
        greeting.appendSlice(AnsiColor.cyan.code());
        greeting.appendSlice("StarOS!");
        greeting.appendSlice(AnsiColor.reset.code());
        greeting.appendSlice("\r\nType ");
        greeting.appendSlice(AnsiColor.green.code());
        greeting.appendSlice("help");
        greeting.appendSlice(AnsiColor.reset.code());
        greeting.appendSlice(" for instructions.\r\n");
        IO.stdio.out.send(greeting.constSlice());
        self.showPrompt();
    }

    fn showPrompt(comptime self: Shell) void {
        _ = self;

        // build curr path
        var path = Fs.PathBuffer.init();
        var indices = FixedBuffer(u8, 32).init(0);
        var current = fileSys.getCurrentDir();

        // If we're at root, just show ~
        if (current == 0) {
            path.setSlice("~");
        } else {
            // Build path from root
            while (current != 0) {
                indices.append(current);
                current = fileSys.getParent(current);
            }

            path.setSlice("~");
            while (indices.pop()) |idx| {
                const name = fileSys.getName(idx);
                path.appendSlice("/");
                path.appendSlice(name.constSlice());
            }
        }

        // Show prompt with current directory (fish style)
        var prompt = Fs.PathBuffer.init();
        prompt.appendSlice(AnsiColor.bright_green.code());
        prompt.appendSlice("root");
        prompt.appendSlice(AnsiColor.reset.code());
        prompt.appendSlice("@");
        prompt.appendSlice(AnsiColor.bold.code());
        prompt.appendSlice(AnsiColor.cyan.code());
        prompt.appendSlice("StarOS ");
        prompt.appendSlice(AnsiColor.green.code());
        prompt.appendSlice(path.constSlice());
        prompt.appendSlice(AnsiColor.reset.code());
        prompt.appendSlice("> ");
        IO.stdio.out.send(prompt.constSlice());
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
        const trimmed = Mem.trim(u8, cmd, WHITESPACE);

        // Extract command part
        const command = if (Mem.indexOf(u8, trimmed, " ")) |space_idx|
            trimmed[0..space_idx]
        else
            trimmed;

        if (Mem.eql(u8, command, "ls")) return .ls;
        if (Mem.eql(u8, command, "pwd")) return .pwd;
        if (Mem.eql(u8, command, "clear")) return .clear;
        if (Mem.eql(u8, command, "help")) return .help;
        if (Mem.eql(u8, command, "cd")) return .cd;
        if (Mem.eql(u8, command, "mkdir")) return .mkdir;
        if (Mem.eql(u8, command, "touch")) return .touch;
        if (Mem.eql(u8, command, "rm")) return .rm;

        return .unknown;
    }

    pub fn isValid(input: []const u8) bool {
        const trimmed = Mem.trim(u8, input, WHITESPACE);
        if (trimmed.len == 0) return false;

        // check if it's a complete command or partial typing
        return parse(trimmed) != .unknown;
    }

    pub fn execute(self: ShellCmd, cmd: []const u8) void {
        const trimmed = Mem.trim(u8, cmd, WHITESPACE);

        switch (self) {
            .ls => cmdLs(),
            .pwd => cmdPwd(),
            .cd => if (trimmed.len > 3) cmdCd(Mem.trim(u8, trimmed[3..], WHITESPACE ++ "/")),
            .mkdir => if (trimmed.len > 6) cmdMkdir(Mem.trim(u8, trimmed[6..], WHITESPACE)),
            .touch => if (trimmed.len > 6) cmdTouch(Mem.trim(u8, trimmed[6..], WHITESPACE)),
            .rm => if (trimmed.len > 3) cmdRm(Mem.trim(u8, trimmed[3..], WHITESPACE)),
            .clear => cmdClear(),
            .help => cmdHelp(),
            .unknown => cmdUnknown(cmd),
        }
    }

    fn cmdPwd() void {
        var path = Fs.PathBuffer.init();

        // Build path by traversing up
        var indices = FixedBuffer(u8, 32).init(0);
        var current = fileSys.getCurrentDir();

        while (current != 0) {
            indices.append(current);
            current = fileSys.getParent(current);
        }

        // Build path from root
        if (indices.len == 0) {
            path.setSlice("/");
        } else {
            while (indices.pop()) |idx| {
                const name = fileSys.getName(idx);
                path.appendSlice("/");
                path.appendSlice(name.constSlice());
            }
        }

        IO.stdio.out.send(path.constSlice());
        IO.stdio.out.send("\r\n");
    }

    fn cmdLs() void {
        const current = fileSys.getCurrentDir();
        const children = fileSys.getChildren(current);

        var first = true;
        for (children.constSlice()) |child_idx| {
            const name = fileSys.getName(child_idx);
            const node_type = fileSys.getType(child_idx);

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
            fileSys.setCurrentDir(0) catch return;
            return;
        }

        if (Mem.eql(u8, path, "..")) {
            const current = fileSys.getCurrentDir();
            const parent = fileSys.getParent(current);
            fileSys.setCurrentDir(parent) catch return;
            return;
        }

        const current = fileSys.getCurrentDir();
        if (fileSys.findChild(current, path)) |child| {
            fileSys.setCurrentDir(child) catch |err| {
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
        const current = fileSys.getCurrentDir();

        // check if already exists
        if (fileSys.findChild(current, name) != null) {
            IO.stdio.out.send("mkdir: directory already exists\r\n");
            return;
        }

        // create directory node
        const new_dir = fileSys.createNode(.dir, name) catch |err| {
            switch (err) {
                error.InvalidName => IO.stdio.out.send("mkdir: invalid name\r\n"),
                error.NoSpace => IO.stdio.out.send("mkdir: no space left\r\n"),
            }
            return;
        };

        // Link to parent
        fileSys.linkChild(current, new_dir) catch {
            IO.stdio.out.send("mkdir: failed to link\r\n");
        };
    }

    fn cmdTouch(name: []const u8) void {
        const current = fileSys.getCurrentDir();

        // Check if already exists
        if (fileSys.findChild(current, name) != null) {
            IO.stdio.out.send("touch: file already exists\r\n");
            return;
        }

        // Create file node
        const new_file = fileSys.createNode(.file, name) catch |err| {
            switch (err) {
                error.InvalidName => IO.stdio.out.send("touch: invalid name\r\n"),
                error.NoSpace => IO.stdio.out.send("touch: no space left\r\n"),
            }
            return;
        };

        // Link to parent
        fileSys.linkChild(current, new_file) catch {
            IO.stdio.out.send("touch: failed to link\r\n");
        };
    }

    fn cmdRm(name: []const u8) void {
        const current = fileSys.getCurrentDir();

        if (fileSys.findChild(current, name)) |child| {
            fileSys.unlinkChild(current, child) catch {
                IO.stdio.out.send("rm: failed to unlink\r\n");
                return;
            };
            fileSys.deleteNode(child) catch {
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
        if (cmd.len == 0 or Mem.trim(u8, cmd, WHITESPACE).len == 0) {
            return; // Empty commd
        }
        IO.stdio.out.send("Unknown command: ");
        IO.stdio.out.send(cmd);
        IO.stdio.out.send("\r\n");
    }
};

pub const AnsiColor = enum {
    // Foreground colors
    black, // 30
    red, // 31
    green, // 32
    yellow, // 33
    blue, // 34
    magenta, // 35
    cyan, // 36
    white, // 37

    // Bright foreground colors
    bright_black, // 90
    bright_red, // 91
    bright_green, // 92
    bright_yellow, // 93
    bright_blue, // 94
    bright_magenta, // 95
    bright_cyan, // 96
    bright_white, // 97

    // Background colors
    bg_black, // 40
    bg_red, // 41
    bg_green, // 42
    bg_yellow, // 43
    bg_blue, // 44
    bg_magenta, // 45
    bg_cyan, // 46
    bg_white, // 47

    // Text styles
    reset, // 0
    bold, // 1
    dim, // 2
    italic, // 3
    underline, // 4
    blink, // 5
    reverse, // 7
    hidden, // 8
    strikethrough, // 9

    // Code
    cursor_back, // Move cursor back one position
    clear_screen,

    pub fn code(self: AnsiColor) []const u8 {
        return switch (self) {
            // Foreground
            .black => "\x1b[30m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .blue => "\x1b[34m",
            .magenta => "\x1b[35m",
            .cyan => "\x1b[36m",
            .white => "\x1b[37m",

            // Bright foreground
            .bright_black => "\x1b[90m",
            .bright_red => "\x1b[91m",
            .bright_green => "\x1b[92m",
            .bright_yellow => "\x1b[93m",
            .bright_blue => "\x1b[94m",
            .bright_magenta => "\x1b[95m",
            .bright_cyan => "\x1b[96m",
            .bright_white => "\x1b[97m",

            // Background
            .bg_black => "\x1b[40m",
            .bg_red => "\x1b[41m",
            .bg_green => "\x1b[42m",
            .bg_yellow => "\x1b[43m",
            .bg_blue => "\x1b[44m",
            .bg_magenta => "\x1b[45m",
            .bg_cyan => "\x1b[46m",
            .bg_white => "\x1b[47m",

            // Styles
            .reset => "\x1b[0m",
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
            .italic => "\x1b[3m",
            .underline => "\x1b[4m",
            .blink => "\x1b[5m",
            .reverse => "\x1b[7m",
            .hidden => "\x1b[8m",
            .strikethrough => "\x1b[9m",

            // Code
            .cursor_back => "\x08",
            .clear_screen => "\x1b[2J\x1b[H",
        };
    }
};

const Testing = @import("Testing.zig");
test "Shell syntax highlighting" {
    // Invalid commands
    try Testing.expect(!ShellCmd.isValid(""));
    try Testing.expect(!ShellCmd.isValid("l"));
    try Testing.expect(!ShellCmd.isValid("lss"));
    try Testing.expect(!ShellCmd.isValid("unknown"));

    // Valid commands
    try Testing.expect(ShellCmd.isValid("ls"));
    try Testing.expect(ShellCmd.isValid("pwd"));
    try Testing.expect(ShellCmd.isValid("cd"));
    try Testing.expect(ShellCmd.isValid("mkdir test"));
    try Testing.expect(ShellCmd.isValid("clear"));

    // Simulate typing "ls" then backspace to "l"
    var buf = Utf8Buffer(PROMPT_BUFFER_SIZE).init();

    buf.appendSlice("l");
    try Testing.expect(!ShellCmd.isValid(buf.constSlice())); // "l" is invalid

    buf.appendSlice("s");
    try Testing.expect(ShellCmd.isValid(buf.constSlice())); // "ls" is valid

    buf.removeAt(buf.len() - 1); // Backspace
    try Testing.expect(!ShellCmd.isValid(buf.constSlice())); // "l" is invalid again
}
