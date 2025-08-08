const Mem = @import("Mem.zig");
const Wasm = @import("Wasm.zig");

var input_buffer: [256]u8 = undefined;
var input_len: usize = 0;

pub fn init() void {
    input_len = 0;
    @memset(&input_buffer, 0);
}

export fn terminal_key(char: u8) void {
    if (char == 13) { // Enter key
        // Process command
        const cmd = input_buffer[0..input_len];
        processCommand(cmd);

        // Clear buffer
        input_len = 0;

        // Show prompt
        Wasm.terminalWrite("$ ");
    } else if (char == 8) { // Backspace
        if (input_len > 0) {
            input_len -= 1;
            Wasm.terminalWrite("\x08 \x08"); // Move back, space, move back
        }
    } else if (input_len < 255) {
        input_buffer[input_len] = char;
        input_len += 1;

        // Echo character
        var echo: [1]u8 = .{char};
        Wasm.terminalWrite(&echo);
    }
}

fn processCommand(cmd: []const u8) void {
    if (Mem.eql(u8, cmd, "ls")) {
        Wasm.terminalWrite("star.wasm  index.html\r\n");
    } else if (Mem.eql(u8, cmd, "clear")) {
        Wasm.terminalWrite("\x1b[2J\x1b[H"); // Clear screen, move to top
    } else if (Mem.eql(u8, cmd, "help")) {
        Wasm.terminalWrite("Commands: ls, clear, help\r\n");
    } else if (cmd.len > 0) {
        Wasm.terminalWrite("Unknown command: ");
        Wasm.terminalWrite(cmd);
        Wasm.terminalWrite("\r\n");
    }
}
