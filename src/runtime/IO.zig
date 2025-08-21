const io = @import("std").io;
const Channel = @import("Channel.zig");
const Debug = @import("Debug.zig");
const Fmt = @import("Fmt.zig");

pub const fixedBufferStream = io.fixedBufferStream;
pub const GenericWriter = io.GenericWriter;
pub const poll = io.poll;

// stdio channels
var stdin_channel = Channel.DefaultChannel{};
var stdout_channel = Channel.DefaultChannel{};
var stderr_channel = Channel.DefaultChannel{};

pub const stdio = enum {
    in,
    out,
    err,

    pub fn channel(comptime self: stdio) *Channel.DefaultChannel {
        return switch (self) {
            .in => &stdin_channel,
            .out => &stdout_channel,
            .err => &stderr_channel,
        };
    }

    pub fn send(comptime self: stdio, data: []const u8) void {
        if (!self.channel().send(data)) {
            Debug.default.warn("stdio.{s}: channel full, dropped message", .{@tagName(self)});
        }
    }

    pub fn sendErr(comptime self: stdio, comptime prefix: []const u8, error_value: anyerror) void {
        var msg: [256]u8 = undefined;
        const text = Fmt.bufPrint(&msg, prefix ++ ": {}\r\n", .{error_value}) catch prefix ++ "\r\n";
        self.send(text);
    }

    pub fn recv(comptime self: stdio) ?[]const u8 {
        return self.channel().recv();
    }
};
