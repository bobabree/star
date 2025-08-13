const Atomic = @import("Atomic.zig");

pub const MESSAGE_SIZE = 256;
pub const QUEUE_SIZE = 32;

pub fn Channel(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buffer: [capacity][MESSAGE_SIZE]u8 = undefined,
        lengths: [capacity]u16 = undefined,
        write_pos: Atomic.Value(usize) align(64) = Atomic.Value(usize).init(0),
        read_pos: Atomic.Value(usize) align(64) = Atomic.Value(usize).init(0),
        on_send_callback: ?*const fn () void = null,

        pub fn send(self: *Self, data: []const u8) bool {
            const current = self.write_pos.load(.acquire);
            const next = (current + 1) % capacity;

            if (next == self.read_pos.load(.acquire)) {
                return false;
            }

            const len = @min(data.len, MESSAGE_SIZE);
            @memcpy(self.buffer[current][0..len], data[0..len]);
            self.lengths[current] = @intCast(len);

            self.write_pos.store(next, .release);

            // Trigger callback
            if (self.on_send_callback) |callback| {
                callback();
            }

            return true;
        }

        pub fn recv(self: *Self) ?[]const u8 {
            const current = self.read_pos.load(.acquire);
            const write = self.write_pos.load(.acquire);

            if (current == write) {
                return null;
            }

            const len = self.lengths[current];
            const data = self.buffer[current][0..len];

            self.read_pos.store((current + 1) % capacity, .release);
            return data;
        }

        pub fn onSend(self: *Self, callback: *const fn () void) void {
            self.on_send_callback = callback;
        }
    };
}

pub const DefaultChannel = Channel(QUEUE_SIZE);
