const math = @import("std").math;
const mem = @import("std").mem;

pub const Alignment = mem.Alignment;
pub const Allocator = mem.Allocator;
pub const copyBackwards = mem.copyBackwards;
pub const doNotOptimizeAway = mem.doNotOptimizeAway;
pub const endsWith = mem.endsWith;
pub const eql = mem.eql;
pub const indexOf = mem.indexOf;
pub const lastIndexOf = mem.lastIndexOf;
pub const span = mem.span;

const Debug = @import("Debug.zig");

pub fn fromByteUnits(n: usize) mem.Alignment {
    Debug.assert(math.isPowerOfTwo(n));
    return @enumFromInt(@ctz(n));
}

pub inline fn of(comptime T: type) mem.Alignment {
    return comptime fromByteUnits(@alignOf(T));
}
