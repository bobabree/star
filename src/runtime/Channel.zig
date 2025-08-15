const Atomic = @import("Atomic.zig");
const Testing = @import("Testing.zig");
const Thread = @import("Thread.zig");

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

test "Channel data is thread-safe" {
    var test_channel = DefaultChannel{};

    // Spawn sender thread
    const thread = try Thread.spawn(.{}, struct {
        fn sender(ch: *DefaultChannel) void {
            const data = [_]u8{42};
            for (0..100) |_| {
                while (!ch.send(&data)) {
                    // Channel full, yield
                    Thread.sleep(1000); // Sleep 1 microsecond instead of yield
                }
            }
        }
    }.sender, .{&test_channel});

    // Receive messages while sender is running
    var received_count: usize = 0;
    while (received_count < 100) {
        if (test_channel.recv()) |_| {
            received_count += 1;
        } else {
            Thread.sleep(1000); // Give sender time to produce
        }
    }

    thread.join();

    try Testing.expect(received_count == 100);
}

test "Channel callbacks run in sender's thread" {
    const G = struct {
        var callback_thread_id: Thread.Id = undefined;
        var callback_fired: bool = false;
    };

    var test_channel = DefaultChannel{};
    const main_thread_id = Thread.getCurrentId();

    // Register callback
    test_channel.onSend(struct {
        fn callback() void {
            G.callback_thread_id = Thread.getCurrentId();
            G.callback_fired = true;
        }
    }.callback);

    // Send from another thread
    const thread = try Thread.spawn(.{}, struct {
        fn sendFromThread(ch: *DefaultChannel) void {
            const data = [_]u8{42};
            _ = ch.send(&data);
        }
    }.sendFromThread, .{&test_channel});

    thread.join();

    // Verify callback fired and check thread
    try Testing.expect(G.callback_fired);
    try Testing.expect(G.callback_thread_id != main_thread_id);
}
