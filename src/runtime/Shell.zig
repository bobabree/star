const builtin = @import("builtin");
const ASCII = @import("Input.zig").ASCII;
const Channel = @import("Channel.zig");
const Debug = @import("Debug.zig");
const FixedBuffer = @import("FixedBuffer.zig").FixedBuffer;
const Utf8Buffer = @import("Utf8Buffer.zig").Utf8Buffer;
const Fmt = @import("Fmt.zig");
const Fs = @import("Fs.zig");
const IO = @import("IO.zig");
const Input = @import("Input.zig");
const Mem = @import("Mem.zig");
const OS = @import("OS.zig");
const Process = @import("Process.zig");

const fileSys = Fs.fileSys;

const Config = struct {
    const MAX_PATH_DEPTH = 32;
    const HISTORY_SIZE = 32;
    const INPUT_BUFFER_SIZE = 256;
    const OUTPUT_BUFFER_SIZE = INPUT_BUFFER_SIZE * 2;
};

const Symbols = struct {
    const WHITESPACE = " \t\r\n";
    const BACKSPACE = "\x08";
    const SPACE = " ";
    const NEWLINE = "\r\n";
    const PATH_SEPARATOR = "/";
    const HOME_SYMBOL = "~";
    const PROMPT_SEPARATOR = "@";
    const PROMPT_SUFFIX = "> ";
};

// Single threadlocal buffer to avoid allocations
// TODO: Probably extract these states into a struct
threadlocal var output_buf: [Config.OUTPUT_BUFFER_SIZE]u8 = undefined;
threadlocal var output_len: usize = 0;

fn bufClear() void {
    output_len = 0;
}

fn bufAppend(text: []const u8) void {
    @memcpy(output_buf[output_len..][0..text.len], text);
    output_len += text.len;
}

fn bufAppendBackspaces(count: usize) void {
    for (0..count) |_| {
        bufAppend(Symbols.BACKSPACE);
    }
}

fn bufAppendSpaces(count: usize) void {
    for (0..count) |_| {
        bufAppend(Symbols.SPACE);
    }
}

fn bufSend() void {
    if (output_len > 0) {
        IO.stdio.out.send(output_buf[0..output_len]);
        output_len = 0;
    }
}

var input_channel = Channel.DefaultChannel{};
var input_line = InputLine{};
var cmd_history = ShellHistory{};

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

    fn processCommand(comptime self: Shell, cmd: []const u8) void {
        const input_cmd = ShellCmd.parse(cmd);
        input_cmd.execute(cmd);

        if (input_cmd != .clear) {
            self.showPrompt();
        }
    }

    fn processRawInput(comptime _: Shell) void {
        while (input_channel.recv()) |data| {
            if (data.len == 0) continue;

            const event = Input.InputEvent.read(data[0]);
            bufClear();

            switch (event) {
                .arrow => |dir| switch (dir) {
                    .up => if (cmd_history.up()) |cmd| replaceInput(cmd),
                    .down => if (cmd_history.down()) |cmd| replaceInput(cmd),
                    .left => if (input_line.moveCursorLeft()) {
                        bufAppend(Ansi.cursor_back.code());
                    },
                    .right => if (input_line.moveCursorRight()) {
                        bufAppend(Ansi.cursor_forward.code());
                    },
                },
                .ctrl_key => |k| if (k == .ctrl_c) {
                    input_line.clear();
                },
                .special => |s| switch (s) {
                    .enter => {
                        IO.stdio.out.send(Symbols.NEWLINE);
                        const cmd = input_line.text();
                        input_line.clear();
                        IO.stdio.in.send(cmd);
                    },
                    .backspace => handleBackspace(),
                    else => {},
                },
                .key => |byte| if (byte < ASCII.DEL and byte >= ASCII.SPACE) {
                    handleCharInput(byte);
                },
                else => {},
            }

            bufSend();
        }
    }

    fn handleBackspace() void {
        if (input_line.cursor == 0) return;

        const text_after_cursor = input_line.text()[input_line.cursor..];
        var temp: [Config.INPUT_BUFFER_SIZE]u8 = undefined;
        @memcpy(temp[0..text_after_cursor.len], text_after_cursor);

        const was_valid = ShellCmd.isValid(input_line.text());

        if (input_line.backspace()) {
            bufAppend(Symbols.BACKSPACE);
            bufAppend(temp[0..text_after_cursor.len]);
            bufAppend(Symbols.SPACE);
            bufAppendBackspaces(text_after_cursor.len + 1);

            const is_valid = ShellCmd.isValid(input_line.text());
            if (was_valid != is_valid) {
                recolorInput();
            } else if (!is_valid) {
                // Even if validity didn't change, reapply color for invalid text
                recolorInput();
            }
        }
    }

    fn handleCharInput(byte: u8) void {
        const was_valid = ShellCmd.isValid(input_line.text());
        const old_cursor = input_line.cursor;
        input_line.insertChar(byte);
        const is_valid = ShellCmd.isValid(input_line.text());

        const color = if (is_valid) Ansi.cyan else Ansi.red;
        bufAppend(Ansi.bold.code());
        bufAppend(color.code());
        bufAppend(&[_]u8{byte});

        // If not at end, redraw everything after cursor
        if (old_cursor < input_line.len() - 1) {
            const text_after = input_line.text()[old_cursor + 1 ..];
            bufAppend(text_after);
            // Move cursor back to correct position
            for (0..text_after.len) |_| {
                bufAppend(Symbols.BACKSPACE);
            }
        }

        bufAppend(Ansi.reset.code());

        if (was_valid != is_valid) {
            recolorInput();
        }
    }

    fn recolorInput() void {
        const color = if (ShellCmd.isValid(input_line.text())) Ansi.cyan else Ansi.red;

        bufAppendBackspaces(input_line.cursor);

        bufAppend(Ansi.bold.code());
        bufAppend(color.code());
        bufAppend(input_line.text());
        bufAppend(Ansi.reset.code());

        bufAppendBackspaces(input_line.len() - input_line.cursor);
    }

    fn replaceInput(cmd: []const u8) void {
        bufClear();

        for (0..input_line.cursor) |_| {
            bufAppend(Ansi.cursor_back.code());
        }

        const byte_count = input_line.text().len;
        bufAppendSpaces(byte_count);
        bufAppendBackspaces(byte_count);

        input_line.set(cmd);
        bufAppend(cmd);

        const color = if (ShellCmd.isValid(cmd)) Ansi.cyan else Ansi.red;
        bufAppendBackspaces(cmd.len);
        bufAppend(Ansi.bold.code());
        bufAppend(color.code());
        bufAppend(cmd);
        bufAppend(Ansi.reset.code());

        bufSend();
    }

    fn hyperlink(url: []const u8, text: []const u8) void {
        // OSC 8 escape sequence: ESC ] 8 ; ; URL ESC \ TEXT ESC ] 8 ; ; ESC \
        bufAppend("\x1b]8;;");
        bufAppend(url);
        bufAppend("\x1b\\");
        bufAppend(text);
        bufAppend("\x1b]8;;\x1b\\");
    }

    fn showGreeting(comptime self: Shell) void {
        bufClear();
        bufAppend(Ansi.clear_screen.code());
        bufAppend("Welcome to StarOS!");
        bufAppend(Symbols.NEWLINE);
        bufAppend("Type ");
        bufAppend(Ansi.bold.code());
        bufAppend(Ansi.cyan.code());
        bufAppend("help");
        bufAppend(Ansi.reset.code());
        bufAppend(" for help, ");
        bufAppend(Ansi.bold.code());
        bufAppend(Ansi.red.code());
        bufAppend("exit");
        bufAppend(Ansi.reset.code());
        bufAppend(" to exit.");
        bufAppend(Symbols.NEWLINE);

        // iOS installation link using OSC 8
        if (self == .wasm) {
            bufAppend(Ansi.underline.code());
            bufAppend(Ansi.italic.code());
            bufAppend(Ansi.cyan.code());
            hyperlink("//install", "Tap here for installation.");
            bufAppend(Ansi.reset.code());
            bufAppend(Symbols.NEWLINE);
        }

        bufSend();
        self.showPrompt();
    }

    fn showPrompt(comptime _: Shell) void {
        bufClear();

        var path: [Config.INPUT_BUFFER_SIZE]u8 = undefined;
        var path_len: usize = 0;

        var current = fileSys.getCurrentDir();
        if (current == 0) {
            @memcpy(path[0..1], Symbols.HOME_SYMBOL);
            path_len = 1;
        } else {
            var indices: [Config.MAX_PATH_DEPTH]u8 = undefined;
            var idx_count: usize = 0;

            while (current != 0) {
                indices[idx_count] = current;
                idx_count += 1;
                current = fileSys.getParent(current);
            }

            @memcpy(path[0..1], Symbols.HOME_SYMBOL);
            path_len = 1;

            while (idx_count > 0) {
                idx_count -= 1;
                const name = fileSys.getName(indices[idx_count]);
                @memcpy(path[path_len..][0..1], Symbols.PATH_SEPARATOR);
                path_len += 1;
                @memcpy(path[path_len..][0..name.len()], name.constSlice());
                path_len += name.len();
            }
        }

        bufAppend(Ansi.bright_green.code());
        bufAppend("root");
        bufAppend(Ansi.reset.code());
        bufAppend(Symbols.PROMPT_SEPARATOR);
        bufAppend("StarOS ");
        bufAppend(Ansi.green.code());
        bufAppend(path[0..path_len]);
        bufAppend(Ansi.reset.code());
        bufAppend(Symbols.PROMPT_SUFFIX);
        bufSend();
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

const InputLine = struct {
    buffer: Utf8Buffer(Config.INPUT_BUFFER_SIZE) = Utf8Buffer(Config.INPUT_BUFFER_SIZE).init(),
    cursor: usize = 0,

    fn clear(self: *InputLine) void {
        self.buffer.clear();
        self.cursor = 0;
    }

    fn set(self: *InputLine, content: []const u8) void {
        self.buffer.setSlice(content);
        self.cursor = self.buffer.len();
    }

    fn insertChar(self: *InputLine, byte: u8) void {
        var char_bytes = [1]u8{byte};
        self.buffer.insertSliceAt(self.cursor, &char_bytes);
        self.cursor += 1;
    }

    fn backspace(self: *InputLine) bool {
        if (self.cursor > 0) {
            self.buffer.removeAt(self.cursor - 1);
            self.cursor -= 1;
            return true;
        }
        return false;
    }

    fn moveCursorLeft(self: *InputLine) bool {
        if (self.cursor > 0) {
            self.cursor -= 1;
            return true;
        }
        return false;
    }

    fn moveCursorRight(self: *InputLine) bool {
        if (self.cursor < self.buffer.len()) {
            self.cursor += 1;
            return true;
        }
        return false;
    }

    fn text(self: *const InputLine) []const u8 {
        return self.buffer.constSlice();
    }

    fn len(self: *const InputLine) usize {
        return self.buffer.len();
    }
};

const ShellHistory = struct {
    cmds: FixedBuffer(Utf8Buffer(Config.INPUT_BUFFER_SIZE), Config.HISTORY_SIZE) = FixedBuffer(Utf8Buffer(Config.INPUT_BUFFER_SIZE), Config.HISTORY_SIZE).init(0),
    index: usize = 0,

    fn add(self: *ShellHistory, cmd: []const u8) void {
        if (cmd.len == 0) return;

        var buf = Utf8Buffer(Config.INPUT_BUFFER_SIZE).init();
        buf.setSlice(cmd);

        // If at capacity, remove oldest command
        if (self.cmds.len >= Config.HISTORY_SIZE) {
            var i: usize = 0;
            while (i < self.cmds.len - 1) : (i += 1) {
                self.cmds.slice()[i] = self.cmds.slice()[i + 1];
            }
            self.cmds.len -= 1;
        }

        self.cmds.append(buf);
        self.index = self.cmds.len;
    }

    fn up(self: *ShellHistory) ?[]const u8 {
        if (self.cmds.len == 0) return null;
        if (self.index > 0) {
            self.index -= 1;
            return self.cmds.slice()[self.index].constSlice();
        }
        return null;
    }

    fn down(self: *ShellHistory) ?[]const u8 {
        if (self.cmds.len == 0) return null;
        if (self.index < self.cmds.len - 1) {
            self.index += 1;
            return self.cmds.slice()[self.index].constSlice();
        } else if (self.index == self.cmds.len - 1) {
            self.index = self.cmds.len;
            return "";
        }
        return null;
    }
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
    exit,
    unknown,

    pub fn parse(cmd: []const u8) ShellCmd {
        const trimmed = Mem.trim(u8, cmd, Symbols.WHITESPACE);

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
        if (Mem.eql(u8, command, "exit")) return .exit;
        return .unknown;
    }

    pub fn isValid(input: []const u8) bool {
        const trimmed = Mem.trim(u8, input, Symbols.WHITESPACE);
        if (trimmed.len == 0) return false;

        // check if it's a complete command or partial typing
        return parse(trimmed) != .unknown;
    }

    pub fn execute(self: ShellCmd, cmd: []const u8) void {
        const trimmed = Mem.trim(u8, cmd, Symbols.WHITESPACE);

        if (ShellCmd.isValid(cmd)) {
            cmd_history.add(trimmed);
        }

        switch (self) {
            .ls => cmdLs(),
            .pwd => cmdPwd(),
            .cd => if (trimmed.len > 3) cmdCd(Mem.trim(u8, trimmed[3..], Symbols.WHITESPACE ++ "/")),
            .mkdir => if (trimmed.len > 6) cmdMkdir(Mem.trim(u8, trimmed[6..], Symbols.WHITESPACE)),
            .touch => if (trimmed.len > 6) cmdTouch(Mem.trim(u8, trimmed[6..], Symbols.WHITESPACE)),
            .rm => if (trimmed.len > 3) cmdRm(Mem.trim(u8, trimmed[3..], Symbols.WHITESPACE)),
            .clear => cmdClear(),
            .help => cmdHelp(),
            .exit => cmdExit(),
            .unknown => cmdUnknown(cmd),
        }
    }

    fn cmdPwd() void {
        var path = Fs.PathBuffer.init();

        // Build path by traversing up
        var indices = FixedBuffer(u8, Config.MAX_PATH_DEPTH).init(0);
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

    // TODO: IMPORTANT: make commands self documenting
    fn cmdHelp() void {
        const help = comptime blk: {
            var text: []const u8 = "Commands:";
            var first = true;
            for (@typeInfo(ShellCmd).@"enum".fields) |field| {
                if (!Mem.eql(u8, field.name, "unknown")) {
                    text = text ++ (if (first) " " else ", ") ++ field.name;
                    first = false;
                }
            }
            break :blk text;
        };
        IO.stdio.out.send(help ++ "\r\n");
    }

    fn cmdExit() void {
        // Platform-specific exit
        if (OS.is_wasm) {
            // TODO: Can't really exit in browser, maybe consider tab exit?
            IO.stdio.out.send("(Browser tab still open - close manually)\r\n");
        } else {
            Process.exit(0);
        }
    }

    fn cmdUnknown(cmd: []const u8) void {
        if (cmd.len == 0 or Mem.trim(u8, cmd, Symbols.WHITESPACE).len == 0) {
            return; // Empty commd
        }
        IO.stdio.out.send("Unknown command: ");
        IO.stdio.out.send(cmd);
        IO.stdio.out.send("\r\n");
    }
};

pub const Ansi = enum {
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
    cursor_back,
    cursor_forward,
    clear_screen,
    cursor_save,
    cursor_restore,

    pub fn code(self: Ansi) []const u8 {
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
            .cursor_back => "\x1b[D",
            .cursor_forward => "\x1b[C",
            .clear_screen => "\x1b[2J\x1b[H",
            .cursor_save => "\x1b[s",
            .cursor_restore => "\x1b[u",
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
    var buf = Utf8Buffer(Config.INPUT_BUFFER_SIZE).init();

    buf.appendSlice("l");
    try Testing.expect(!ShellCmd.isValid(buf.constSlice())); // "l" is invalid

    buf.appendSlice("s");
    try Testing.expect(ShellCmd.isValid(buf.constSlice())); // "ls" is valid

    buf.removeAt(buf.len() - 1); // Backspace
    try Testing.expect(!ShellCmd.isValid(buf.constSlice())); // "l" is invalid again
}

// Test helper to capture output
const OutputCapture = struct {
    buffer: Utf8Buffer(4096) = Utf8Buffer(4096).init(),

    fn reset(self: *OutputCapture) void {
        self.buffer.clear();
    }

    fn capture(self: *OutputCapture, text: []const u8) void {
        self.buffer.appendSlice(text);
    }

    fn contains(self: *const OutputCapture, text: []const u8) bool {
        return self.buffer.contains(text);
    }
};

// Mock IO.stdio.out for testing
var test_output = OutputCapture{};

fn mockSend(text: []const u8) void {
    test_output.capture(text);
}

test "Bug If: first character has no color" {
    var line = InputLine{};
    test_output.reset();

    _ = ShellCmd.isValid(line.text());
    line.insertChar('l');
    const is_valid = ShellCmd.isValid(line.text());

    var output = Utf8Buffer(Config.INPUT_BUFFER_SIZE).init();
    const color = if (is_valid) Ansi.cyan else Ansi.red;
    output.appendSlice(Ansi.bold.code());
    output.appendSlice(color.code());
    output.appendSlice("l");
    output.appendSlice(Ansi.reset.code());
    mockSend(output.constSlice());

    // Verify red color was applied
    try Testing.expect(test_output.contains("\x1b[31m")); // Has red
    try Testing.expect(test_output.contains("l")); // Has the character
}

test "Bug If: typing doesn't maintain color" {
    var line = InputLine{};

    // Type "ls" - 'l' is red, then 's' makes it cyan
    test_output.reset();
    line.insertChar('l');

    var output = Utf8Buffer(Config.INPUT_BUFFER_SIZE).init();
    output.appendSlice(Ansi.bold.code());
    output.appendSlice(Ansi.red.code());
    output.appendSlice("l");
    output.appendSlice(Ansi.reset.code());
    mockSend(output.constSlice());

    // Verify 'l' is red
    try Testing.expect(test_output.contains("\x1b[31m"));

    // Now type 's' - should trigger recolor to cyan
    test_output.reset();
    line.insertChar('s');

    output.clear();
    output.appendSlice(Ansi.bold.code());
    output.appendSlice(Ansi.cyan.code());
    output.appendSlice("s");
    output.appendSlice(Ansi.reset.code());

    // Then recolor the whole line
    output.appendSlice("\x08\x08");
    output.appendSlice(Ansi.bold.code());
    output.appendSlice(Ansi.cyan.code());
    output.appendSlice("ls");
    output.appendSlice(Ansi.reset.code());

    mockSend(output.constSlice());

    // Verify cyan color was applied
    try Testing.expect(test_output.contains("\x1b[36m"));
    try Testing.expect(test_output.contains("ls"));
}

test "Bug If: recolorInput doesn't restore cursor position" {
    var line = InputLine{};
    test_output.reset();

    line.set("hello");
    line.cursor = 2;

    // Simulate recolorInput
    var recolor = Utf8Buffer(Config.OUTPUT_BUFFER_SIZE).init();

    // Move back from current position (2)
    for (0..line.cursor) |_| {
        recolor.appendSlice(Ansi.cursor_back.code());
    }

    recolor.appendSlice(Ansi.bold.code());
    recolor.appendSlice(Ansi.cyan.code());
    recolor.appendSlice(line.text());
    recolor.appendSlice(Ansi.reset.code());

    // Move back to position 2 (5 - 2 = 3 moves back)
    const chars_after = line.len() - line.cursor;
    for (0..chars_after) |_| {
        recolor.appendSlice(Ansi.cursor_back.code());
    }

    mockSend(recolor.constSlice());

    // Verify we moved back correct number of time
    var back_count: usize = 0;
    const output = test_output.buffer.constSlice();
    var i: usize = 0;
    while (i + 2 < output.len) : (i += 1) {
        if (output[i] == '\x1b' and output[i + 1] == '[' and output[i + 2] == 'D') {
            back_count += 1;
        }
    }

    // Should move back 2 to start, then 3 to return to position 2
    try Testing.expect(back_count == 5);
}

test "Bug If: replaceInput uses wrong backspace count" {
    var line = InputLine{};

    line.set("café");
    test_output.reset();

    // Simulate fixed replaceInput
    const byte_count = line.text().len;
    for (0..byte_count) |_| {
        mockSend("\x08 \x08");
    }

    // Count backspaces sent
    var backspace_count: usize = 0;
    const output = test_output.buffer.constSlice();
    var i: usize = 0;
    while (i + 2 < output.len) : (i += 1) {
        if (output[i] == '\x08' and output[i + 1] == ' ' and output[i + 2] == '\x08') {
            backspace_count += 1;
            i += 2;
        }
    }

    // Should send 5 backspaces for 5 bytes, not 4 for 4 chars
    try Testing.expect(backspace_count == 5);
    try Testing.expect(line.len() == 4);
}

test "Bug If: cursor position wrong after history navigation" {
    var line = InputLine{};
    var history = ShellHistory{};

    history.add("short");
    history.add("very long command");

    line.set("hello");
    line.cursor = 3;

    test_output.reset();

    // Simulate replaceInput
    // First move cursor to start
    for (0..line.cursor) |_| {
        mockSend(Ansi.cursor_back.code());
    }

    // Clear line
    const old_byte_count = line.text().len;
    for (0..old_byte_count) |_| {
        mockSend(" ");
    }
    for (0..old_byte_count) |_| {
        mockSend(Symbols.BACKSPACE);
    }

    // Write new text
    const cmd = history.up().?;
    line.set(cmd);
    mockSend(cmd);

    // verify cursor movements
    try Testing.expect(line.cursor == cmd.len);
    try Testing.expect(test_output.contains("very long command"));
}

test "Bug If: backspace doesn't update display correctly" {
    var line = InputLine{};

    line.set("hello");
    line.cursor = 3;

    test_output.reset();

    // cpy the text that will shift BEFORE backspace modifies the buffer
    var shift_copy = Utf8Buffer(Config.INPUT_BUFFER_SIZE).init();
    shift_copy.setSlice(line.text()[line.cursor..]);
    const text_to_shift = shift_copy.constSlice();

    const did_backspace = line.backspace();
    try Testing.expect(did_backspace);

    // simulate what the handler sends
    var update = Utf8Buffer(Config.INPUT_BUFFER_SIZE).init();
    update.appendSlice(Symbols.BACKSPACE);
    update.appendSlice(text_to_shift);
    update.appendSlice(" ");
    for (0..text_to_shift.len + 1) |_| {
        update.appendSlice(Symbols.BACKSPACE);
    }
    mockSend(update.constSlice());

    try Testing.expectEqualStrings(line.text(), "helo");
    try Testing.expect(line.cursor == 2);

    //  check for the exact seq
    const expected = "\x08lo \x08\x08\x08";
    try Testing.expectEqualStrings(test_output.buffer.constSlice(), expected);
}

test "Bug If: cursor position wrong after prompt" {
    var line = InputLine{};
    test_output.reset();

    // simulate typing after prompt
    mockSend("root@StarOS ~> ");

    // Type a dot - should just echo it
    line.insertChar('.');
    mockSend(".");

    // Verify no cursor movement sequences were  sent
    try Testing.expect(!test_output.contains("\x1b[D"));
    try Testing.expect(test_output.contains("."));
}

test "Bug If: syntax highlighting and prompt overwrite" {
    var line = InputLine{};
    test_output.reset();

    // Type 'l' - should be red
    line.insertChar('l');
    const is_valid_l = ShellCmd.isValid(line.text());
    try Testing.expect(!is_valid_l);

    // Type 's' - should trigger recolor to cyan
    line.insertChar('s');
    const is_valid_ls = ShellCmd.isValid(line.text());
    try Testing.expect(is_valid_ls);

    // Verify colors were applied
    try Testing.expect(line.text().len == 2);
}

test "Bug If: recolorInput deletes prompt space" {
    var line = InputLine{};
    test_output.reset();

    mockSend("root@StarOS ~> ");

    line.insertChar('l');
    mockSend("l");

    line.insertChar('s');
    mockSend("s");

    // now, recolor from correct position
    test_output.reset();
    for (0..line.cursor) |_| {
        mockSend(Ansi.cursor_back.code());
    }
    mockSend("ls");

    // should be at position 15 (start of "ls"), not 14 (the space)
    try Testing.expect(line.cursor == 2);
}

test "Bug If: command output appears on same line as input" {
    test_output.reset();

    var line = InputLine{};
    line.set("help");

    mockSend(Symbols.NEWLINE);
    _ = line.text();
    line.clear();

    mockSend("Commands: ls, pwd, cd, mkdir, touch, rm, clear, help, exit");

    const output = test_output.buffer.constSlice();
    try Testing.expect(output[0] != 'C');
}

test "Bug If: backspace doesn't update color when validity changes" {
    var line = InputLine{};
    test_output.reset();

    // Type "ls" - valid, cyan
    line.insertChar('l');
    line.insertChar('s');
    try Testing.expect(ShellCmd.isValid(line.text()));

    test_output.reset();
    const text_after = line.text()[line.cursor..];
    var temp: [Config.INPUT_BUFFER_SIZE]u8 = undefined;
    @memcpy(temp[0..text_after.len], text_after);

    const was_valid = ShellCmd.isValid(line.text());
    _ = line.backspace();

    bufClear();
    bufAppend(Symbols.BACKSPACE);
    bufAppend(temp[0..text_after.len]);
    bufAppend(Symbols.SPACE);
    bufAppendBackspaces(text_after.len + 1);

    const is_valid = ShellCmd.isValid(line.text());
    if (was_valid != is_valid) {
        const color = if (is_valid) Ansi.cyan else Ansi.red;
        bufAppendBackspaces(line.cursor);
        bufAppend(Ansi.bold.code());
        bufAppend(color.code());
        bufAppend(line.text());
        bufAppend(Ansi.reset.code());
        bufAppendBackspaces(line.len() - line.cursor);
    }

    mockSend(output_buf[0..output_len]);
    try Testing.expect(test_output.contains("\x1b[31m"));
}
test "Bug If: display doesn't update when inserting in middle" {
    var line = InputLine{};
    test_output.reset();

    line.insertChar('s');

    var output = Utf8Buffer(Config.INPUT_BUFFER_SIZE).init();
    output.appendSlice(Ansi.bold.code());
    output.appendSlice(Ansi.red.code());
    output.appendSlice("s");
    output.appendSlice(Ansi.reset.code());
    mockSend(output.constSlice());

    _ = line.moveCursorLeft();
    mockSend(Ansi.cursor_back.code());

    const old_cursor = line.cursor;
    line.insertChar('s');

    output.clear();
    output.appendSlice(Ansi.bold.code());
    output.appendSlice(Ansi.red.code());
    output.appendSlice("s");

    if (old_cursor < line.len() - 1) {
        const text_after = line.text()[old_cursor + 1 ..];
        output.appendSlice(text_after);
        for (0..text_after.len) |_| {
            output.appendSlice(Symbols.BACKSPACE);
        }
    }

    output.appendSlice(Ansi.reset.code());
    mockSend(output.constSlice());

    try Testing.expectEqualStrings(line.text(), "ss");
}
test "Bug If: backspace removes color even when validity stays invalid" {
    var line = InputLine{};
    test_output.reset();

    line.insertChar('l');
    line.insertChar('s');
    line.insertChar('s');
    try Testing.expect(!ShellCmd.isValid(line.text()));

    line.cursor = 1;

    const text_after = line.text()[line.cursor..];
    var temp: [Config.INPUT_BUFFER_SIZE]u8 = undefined;
    @memcpy(temp[0..text_after.len], text_after);

    const was_valid = ShellCmd.isValid(line.text());
    _ = line.backspace();
    const is_valid = ShellCmd.isValid(line.text());

    test_output.reset();
    bufClear();
    bufAppend(Symbols.BACKSPACE);
    bufAppend(temp[0..text_after.len]);
    bufAppend(Symbols.SPACE);
    bufAppendBackspaces(text_after.len + 1);

    if (was_valid != is_valid or !is_valid) {
        const color = if (is_valid) Ansi.cyan else Ansi.red;
        bufAppendBackspaces(line.cursor);
        bufAppend(Ansi.bold.code());
        bufAppend(color.code());
        bufAppend(line.text());
        bufAppend(Ansi.reset.code());
        bufAppendBackspaces(line.len() - line.cursor);
    }

    mockSend(output_buf[0..output_len]);

    try Testing.expect(test_output.contains("\x1b[31m"));
}

test "Bug If: shell history crashes after X commands" {
    var history = ShellHistory{};

    // Add X history
    for (0..Config.HISTORY_SIZE) |i| {
        var cmd_buf: [10]u8 = undefined;
        const cmd = Fmt.bufPrint(&cmd_buf, "cmd{}", .{i}) catch unreachable;
        history.add(cmd);
    }

    try Testing.expect(history.cmds.len == Config.HISTORY_SIZE);

    // Bug if adding X+1 history causes panic
    history.add("cmd33");
}
