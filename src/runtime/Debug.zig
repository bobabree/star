const debug = @import("std").debug;

pub const assert = debug.assert;
pub const assertReadable = debug.assertReadable;
pub const panic = debug.panic;
pub const print = debug.print;

/// Like assert, but with a custom message and never optimized away.
/// Always crashes in all build modes when condition is false.
pub fn panicAssert(condition: bool, comptime format: []const u8, args: anytype) void {
    if (!condition) {
        @branchHint(.cold);
        debug.panicExtra(@returnAddress(), format, args);
    }
}
