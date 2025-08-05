const std = @import("std");

/// lock-free MPSC queue using atomics
pub fn MpscChannel(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buffer: [capacity]T = undefined,
        write_pos: usize = 0,
        read_pos: usize = 0,

        pub fn trySend(self: *Self, value: T) bool {
            const current = @atomicLoad(usize, &self.write_pos, .acquire);
            const next = (current + 1) % capacity;

            // Check if full
            if (next == @atomicLoad(usize, &self.read_pos, .acquire)) {
                return false;
            }

            // Try to claim this slot
            if (@cmpxchgWeak(usize, &self.write_pos, current, next, .release, .acquire)) |_| {
                return false;
            }

            self.buffer[current] = value;
            return true;
        }

        pub fn tryRecv(self: *Self) ?T {
            const current = @atomicLoad(usize, &self.read_pos, .acquire);
            const write = @atomicLoad(usize, &self.write_pos, .acquire);

            if (current == write) {
                return null; // Empty
            }

            const value = self.buffer[current];
            @atomicStore(usize, &self.read_pos, (current + 1) % capacity, .release);
            return value;
        }
    };
}

const Testing = @import("Testing.zig");

test "simple mpsc tests" {
    const Channel = MpscChannel(i32, 4);
    var channel = Channel{};

    try Testing.expect(channel.tryRecv() == null);

    // Test send and receive
    try Testing.expect(channel.trySend(42) == true);
    try Testing.expect(channel.tryRecv() == 42);
    try Testing.expect(channel.trySend(1) == true);
    try Testing.expect(channel.trySend(2) == true);
    try Testing.expect(channel.trySend(3) == true);
    try Testing.expect(channel.trySend(4) == false);
    try Testing.expect(channel.tryRecv() == 1);
    try Testing.expect(channel.tryRecv() == 2);
    try Testing.expect(channel.tryRecv() == 3);
    try Testing.expect(channel.tryRecv() == null);

    // Test wrap-around
    try Testing.expect(channel.trySend(10) == true);
    try Testing.expect(channel.trySend(20) == true);
    try Testing.expect(channel.tryRecv() == 10);
    try Testing.expect(channel.tryRecv() == 20);
}
