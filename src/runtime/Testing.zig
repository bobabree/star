const testing = @import("std").testing;

pub const expect = testing.expect;
pub const expectEqual = testing.expectEqual;
pub const expectEqualSlices = testing.expectEqualSlices;
pub const expectEqualStrings = testing.expectEqualStrings;
pub const refAllDeclsRecursive = testing.refAllDeclsRecursive;
pub const refAllDecls = testing.refAllDecls;

const builtin = @import("builtin");
const Debug = @import("Debug.zig");
const Heap = @import("Heap.zig");
const Mem = @import("Mem.zig");
const Time = @import("Time.zig");
const Builtin = @import("Builtin.zig");
const SourceLocation = Builtin.SourceLocation;

pub const ProfiledTest = struct {
    name: []const u8,
    timer: Time.Timer,
    start_time: u64,

    // Memory tracking
    start_memory: ?usize = null,
    fba: ?*Heap.FixedBufferAllocator = null,

    pub fn start(src: SourceLocation) !ProfiledTest {
        const name = src.fn_name[5..];
        var timer = try Time.Timer.start();
        const start_time = timer.read();

        return ProfiledTest{
            .name = name,
            .timer = timer,
            .start_time = start_time,
        };
    }

    pub fn startWithMemory(src: SourceLocation, fba: *Heap.FixedBufferAllocator) !ProfiledTest {
        const name = src.fn_name[5..];
        var timer = try Time.Timer.start();
        const start_time = timer.read();
        const start_memory = fba.end_index;

        return ProfiledTest{
            .name = name,
            .timer = timer,
            .start_time = start_time,
            .start_memory = start_memory,
            .fba = fba,
        };
    }

    pub fn endWithResult(self: *ProfiledTest, result: anytype) @TypeOf(result) {
        Mem.doNotOptimizeAway(result);
        self.end();
        return result;
    }

    pub fn endWith(self: *ProfiledTest, result: anytype) void {
        Mem.doNotOptimizeAway(result);
        self.end();
    }

    pub fn end(self: *ProfiledTest) void {
        var min_time = self.timer.read();
        for (0..3) |_| { // warming
            const t = self.timer.read();
            if (t < min_time) min_time = t;
        }

        const elapsed_ns = min_time - self.start_time;

        if (self.fba) |fba| {
            const memory_used = fba.end_index - (self.start_memory orelse 0);
            Debug.default.info("\n[{s}]", .{self.name});
            printTimeBreakdown(" ⏱️ Time: ", elapsed_ns);
            printMemoryBreakdown(" 💾 Memory: ", memory_used);
        } else {
            Debug.default.info("\n[{s}]", .{self.name});
            printTimeBreakdown(" ⏱️ Time: ", elapsed_ns);
        }
    }

    pub fn printTimeBreakdown(prefix: []const u8, total_ns: u64) void {
        const ms = total_ns / 1_000_000;
        const remaining_after_ms = total_ns % 1_000_000;
        const us = remaining_after_ms / 1_000;
        const ns = remaining_after_ms % 1_000;

        // TODO: Thresholds for info/warn/err/success
        Debug.default.debug("{s:<15}{d:>3}ms {d:>3}μs {d:>3}ns", .{ prefix, ms, us, ns });
    }

    pub fn printMemoryBreakdown(prefix: []const u8, total_bytes: usize) void {
        const mb = total_bytes / (1024 * 1024);
        const remaining_after_mb = total_bytes % (1024 * 1024);
        const kb = remaining_after_mb / 1024;
        const bytes = remaining_after_mb % 1024;

        // TODO: Thresholds for info/warn/err/success
        Debug.default.debug("{s:<15}{d:>3}MB {d:>3}KB {d:>3}B", .{ prefix, mb, kb, bytes });
    }
};
