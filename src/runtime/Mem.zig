const mem = @import("std").mem;
const Math = @import("Math.zig");

pub const Alignment = mem.Alignment;
pub const Allocator = mem.Allocator;
pub const copyBackwards = mem.copyBackwards;
pub const doNotOptimizeAway = mem.doNotOptimizeAway;
pub const endsWith = mem.endsWith;
pub const eql = mem.eql;
pub const indexOf = mem.indexOf;
pub const lastIndexOf = mem.lastIndexOf;
pub const len = mem.len;
pub const span = mem.span;

const Debug = @import("Debug.zig");

pub fn fromByteUnits(n: usize) mem.Alignment {
    Debug.assert(Math.isPowerOfTwo(n));
    return @enumFromInt(@ctz(n));
}

pub inline fn of(comptime T: type) mem.Alignment {
    return comptime fromByteUnits(@alignOf(T));
}
