pub const builtin = @import("builtin");

pub const Atomic = @import("runtime/Atomic.zig");
pub const Builtin = @import("runtime/Builtin.zig");
pub const Channel = @import("runtime/Channel.zig");
pub const Compress = @import("runtime/Compress.zig");
pub const Debug = @import("runtime/Debug.zig");
pub const FixedBuffer = @import("runtime/FixedBuffer.zig");
pub const Fmt = @import("runtime/Fmt.zig");
pub const Fs = @import("runtime/Fs.zig");
pub const FsPath = @import("runtime/FsPath.zig");
pub const Heap = @import("runtime/Heap.zig");
pub const Http = @import("runtime/Http.zig");
pub const Input = @import("runtime/Input.zig");
pub const IO = @import("runtime/IO.zig");
pub const Math = @import("runtime/Math.zig");
pub const Mem = @import("runtime/Mem.zig");
pub const MpscChannel = @import("runtime/MpscChannel.zig");
pub const Net = @import("runtime/Net.zig");
pub const OS = @import("runtime/OS.zig");
pub const Process = @import("runtime/Process.zig");
pub const Terminal = @import("runtime/Terminal.zig");
pub const Testing = @import("runtime/Testing.zig");
pub const Time = @import("runtime/Time.zig");
pub const Thread = @import("runtime/Thread.zig");
pub const Shell = @import("runtime/Shell.zig");
pub const Unicode = @import("runtime/Unicode.zig");
pub const Utf8Buffer = @import("runtime/Utf8Buffer.zig");
pub const Wasm = @import("runtime/Wasm.zig");

pub const app = @import("app.zig");
pub const server = @import("server.zig");

// Tests
test {
    // Must declare any new files above to get ref for testing
    Testing.refAllDecls(@This());
}

comptime {
    // TODO: why does @import("runtime") not work?
    Debug.assert(@import("runtime.zig") == @This()); // std lib tests require --zig-lib-dir
}
