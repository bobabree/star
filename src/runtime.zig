pub const builtin = @import("builtin");

pub const Atomic = @import("runtime/Atomic.zig");
pub const Debug = @import("runtime/Debug.zig");
pub const FixedBuffer = @import("runtime/FixedBuffer.zig");
pub const Fs = @import("runtime/Fs.zig");
pub const Heap = @import("runtime/Heap.zig");
pub const Http = @import("runtime/Http.zig");
pub const IO = @import("runtime/IO.zig");
pub const Mem = @import("runtime/Mem.zig");
pub const MpscChannel = @import("runtime/MpscChannel.zig");
pub const Net = @import("runtime/Net.zig");
pub const Process = @import("runtime/Process.zig");
pub const Testing = @import("runtime/Testing.zig");
pub const Time = @import("runtime/Time.zig");
pub const Thread = @import("runtime/Thread.zig");
pub const UI = @import("runtime/UI.zig");
pub const Utf8Buffer = @import("runtime/Utf8Buffer.zig");

pub const wasm = @import("wasm.zig");
pub const server = @import("server.zig");

// Embed files
pub const html_content = @embedFile("web/index.html");

// Tests
test {
    // Must declare any new files above to get ref for testing
    Testing.refAllDecls(@This());
}

comptime {
    // TODO: why does @import("runtime") not work?
    Debug.assert(@import("runtime.zig") == @This()); // std lib tests require --zig-lib-dir
}
