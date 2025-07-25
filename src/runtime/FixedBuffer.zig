const IO = @import("IO.zig");
const Mem = @import("Mem.zig");
const Debug = @import("Debug.zig");

/// Based from zig's std.BoundedArray but adjusted for custom use
pub fn FixedBuffer(comptime T: type, comptime buffer_capacity: usize) type {
    return FixedBufferAligned(T, Mem.of(T), buffer_capacity);
}

pub fn FixedBufferAligned(
    comptime T: type,
    comptime alignment: Mem.Alignment,
    comptime buffer_capacity: usize,
) type {
    return struct {
        const Self = @This();
        buffer: [buffer_capacity]T align(alignment.toByteUnits()) = undefined,
        len: usize = 0,

        /// Set the actual length of the slice.
        /// Panics if it exceeds the length of the backing array.
        pub fn init(len: usize) Self {
            Debug.panicAssert(len <= buffer_capacity, "FixedBuffer: len {} exceeds capacity {}", .{ len, buffer_capacity });
            return Self{ .len = len };
        }

        /// View the internal array as a slice whose size was previously set.
        pub fn slice(self: anytype) switch (@TypeOf(&self.buffer)) {
            *align(alignment.toByteUnits()) [buffer_capacity]T => []align(alignment.toByteUnits()) T,
            *align(alignment.toByteUnits()) const [buffer_capacity]T => []align(alignment.toByteUnits()) const T,
            else => unreachable,
        } {
            return self.buffer[0..self.len];
        }

        /// View the internal array as a constant slice whose size was previously set.
        pub fn constSlice(self: *const Self) []align(alignment.toByteUnits()) const T {
            return self.slice();
        }

        /// Adjust the slice's length to `len`.
        /// Does not initialize added items if any.
        pub fn resize(self: *Self, len: usize) void {
            Debug.panicAssert(len <= buffer_capacity, "FixedBuffer.resize: len {} exceeds capacity {}", .{ len, buffer_capacity });
            self.len = len;
        }

        /// Remove all elements from the slice.
        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        /// Copy the content of an existing slice.
        pub fn fromSlice(m: []const T) Self {
            var list = init(m.len);
            @memcpy(list.slice(), m);
            return list;
        }

        /// Return the element at index `i` of the slice.
        pub fn get(self: Self, i: usize) T {
            return self.constSlice()[i];
        }

        /// Set the value of the element at index `i` of the slice.
        pub fn set(self: *Self, i: usize, item: T) void {
            self.slice()[i] = item;
        }

        /// Return the maximum length of a slice.
        pub fn capacity(self: Self) usize {
            return self.buffer.len;
        }

        /// Check that the slice can hold at least `additional_count` items.
        pub fn ensureUnusedCapacity(self: Self, additional_count: usize) void {
            Debug.panicAssert(self.len + additional_count <= buffer_capacity, "FixedBuffer.ensureUnusedCapacity: {} + {} exceeds capacity {}", .{ self.len, additional_count, buffer_capacity });
        }

        /// Increase length by 1, returning a pointer to the new item.
        pub fn addOne(self: *Self) *T {
            self.ensureUnusedCapacity(1);
            return self.addOneAssumeCapacity();
        }

        /// Increase length by 1, returning pointer to the new item.
        /// Asserts that there is space for the new item.
        pub fn addOneAssumeCapacity(self: *Self) *T {
            Debug.assert(self.len < buffer_capacity);
            self.len += 1;
            return &self.slice()[self.len - 1];
        }

        /// Resize the slice, adding `n` new elements, which have `undefined` values.
        /// The return value is a pointer to the array of uninitialized elements.
        pub fn addManyAsArray(self: *Self, comptime n: usize) *align(alignment.toByteUnits()) [n]T {
            const prev_len = self.len;
            self.resize(self.len + n);
            return self.slice()[prev_len..][0..n];
        }

        /// Resize the slice, adding `n` new elements, which have `undefined` values.
        /// The return value is a slice pointing to the uninitialized elements.
        pub fn addManyAsSlice(self: *Self, n: usize) []align(alignment.toByteUnits()) T {
            const prev_len = self.len;
            self.resize(self.len + n);
            return self.slice()[prev_len..][0..n];
        }

        /// Remove and return the last element from the slice, or return `null` if the slice is empty.
        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            const item = self.get(self.len - 1);
            self.len -= 1;
            return item;
        }

        /// Return a slice of only the extra capacity after items.
        /// This can be useful for writing directly into it.
        /// Note that such an operation must be followed up with a
        /// call to `resize()`
        pub fn unusedCapacitySlice(self: *Self) []align(alignment.toByteUnits()) T {
            return self.buffer[self.len..];
        }

        /// Insert `item` at index `i` by moving `slice[n .. slice.len]` to make room.
        /// This operation is O(N).
        pub fn insert(
            self: *Self,
            i: usize,
            item: T,
        ) void {
            Debug.panicAssert(i <= self.len, "FixedBuffer.insert: index {} exceeds length {}", .{ i, self.len });

            _ = self.addOne();
            var s = self.slice();
            Mem.copyBackwards(T, s[i + 1 .. s.len], s[i .. s.len - 1]);
            self.buffer[i] = item;
        }

        /// Insert slice `items` at index `i` by moving `slice[i .. slice.len]` to make room.
        /// This operation is O(N).
        pub fn insertSlice(self: *Self, i: usize, items: []const T) void {
            self.ensureUnusedCapacity(items.len);
            self.len += items.len;
            Mem.copyBackwards(T, self.slice()[i + items.len .. self.len], self.constSlice()[i .. self.len - items.len]);
            @memcpy(self.slice()[i..][0..items.len], items);
        }

        /// Replace range of elements `slice[start..][0..len]` with `new_items`.
        /// Grows slice if `len < new_items.len`.
        /// Shrinks slice if `len > new_items.len`.
        pub fn replaceRange(
            self: *Self,
            start: usize,
            len: usize,
            new_items: []const T,
        ) void {
            const after_range = start + len;
            var range = self.slice()[start..after_range];

            if (range.len == new_items.len) {
                @memcpy(range[0..new_items.len], new_items);
            } else if (range.len < new_items.len) {
                const first = new_items[0..range.len];
                const rest = new_items[range.len..];
                @memcpy(range[0..first.len], first);
                self.insertSlice(after_range, rest);
            } else {
                @memcpy(range[0..new_items.len], new_items);
                const after_subrange = start + new_items.len;
                for (self.constSlice()[after_range..], 0..) |item, i| {
                    self.slice()[after_subrange..][i] = item;
                }
                self.len -= len - new_items.len;
            }
        }

        /// Extend the slice by 1 element.
        pub fn append(self: *Self, item: T) void {
            const new_item_ptr = self.addOne();
            new_item_ptr.* = item;
        }

        /// Extend the slice by 1 element, asserting the capacity is already
        /// enough to store the new item.
        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            const new_item_ptr = self.addOneAssumeCapacity();
            new_item_ptr.* = item;
        }

        /// Remove the element at index `i`, shift elements after index
        /// `i` forward, and return the removed element.
        /// Asserts the slice has at least one item.
        /// This operation is O(N).
        pub fn orderedRemove(self: *Self, i: usize) T {
            const newlen = self.len - 1;
            if (newlen == i) return self.pop().?;
            const old_item = self.get(i);
            for (self.slice()[i..newlen], 0..) |*b, j| b.* = self.get(i + 1 + j);
            self.set(newlen, undefined);
            self.len = newlen;
            return old_item;
        }

        /// Remove the element at the specified index and return it.
        /// The empty slot is filled from the end of the slice.
        /// This operation is O(1).
        pub fn swapRemove(self: *Self, i: usize) T {
            if (self.len - 1 == i) return self.pop().?;
            const old_item = self.get(i);
            self.set(i, self.pop().?);
            return old_item;
        }

        /// Append the slice of items to the slice.
        pub fn appendSlice(self: *Self, items: []const T) void {
            self.ensureUnusedCapacity(items.len);
            self.appendSliceAssumeCapacity(items);
        }

        /// Append the slice of items to the slice, asserting the capacity is already
        /// enough to store the new items.
        pub fn appendSliceAssumeCapacity(self: *Self, items: []const T) void {
            const old_len = self.len;
            self.len += items.len;
            @memcpy(self.slice()[old_len..][0..items.len], items);
        }

        /// Append a value to the slice `n` times.
        /// Allocates more memory as necessary.
        pub fn appendNTimes(self: *Self, value: T, n: usize) void {
            const old_len = self.len;
            self.resize(old_len + n);
            @memset(self.slice()[old_len..self.len], value);
        }

        /// Append a value to the slice `n` times.
        /// Asserts the capacity is enough.
        pub fn appendNTimesAssumeCapacity(self: *Self, value: T, n: usize) void {
            const old_len = self.len;
            self.len += n;
            Debug.assert(self.len <= buffer_capacity);
            @memset(self.slice()[old_len..self.len], value);
        }

        pub const Writer = if (T != u8)
            @compileError("The Writer interface is only defined for FixedBuffer(u8, ...) " ++
                "but the given type is FixedBuffer(" ++ @typeName(T) ++ ", ...)")
        else
            IO.GenericWriter(*Self, error{}, appendWrite);

        /// Initializes a writer which will write into the array.
        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }

        /// Same as `appendSlice` except it returns the number of bytes written, which is always the same
        /// as `m.len`. The purpose of this function existing is to match `std.IO.GenericWriter` API.
        fn appendWrite(self: *Self, m: []const u8) error{}!usize {
            self.appendSlice(m);
            return m.len;
        }
    };
}

const Testing = @import("Testing.zig");

test FixedBuffer {
    var a = FixedBuffer(u8, 64).init(32);

    try Testing.expectEqual(a.capacity(), 64);
    try Testing.expectEqual(a.slice().len, 32);
    try Testing.expectEqual(a.constSlice().len, 32);

    // TODO: does zig have a expect panic?
    // a.resize(48);
    // try Testing.expectEqual(a.len, 48);

    const x = [_]u8{1} ** 10;
    a = FixedBuffer(u8, 64).fromSlice(&x);
    try Testing.expectEqualSlices(u8, &x, a.constSlice());

    var a2 = a;
    try Testing.expectEqualSlices(u8, a.constSlice(), a2.constSlice());
    a2.set(0, 0);
    try Testing.expect(a.get(0) != a2.get(0));

    // a.resize(100);
    //     try Testing.expectError(error.Overflow, FixedBuffer(u8, x.len - 1).fromSlice(&x));

    a.resize(0);
    a.ensureUnusedCapacity(a.capacity());
    a.addOne().* = 0;
    a.ensureUnusedCapacity(a.capacity() - 1);
    try Testing.expectEqual(a.len, 1);

    const uninitialized = a.addManyAsArray(4);
    try Testing.expectEqual(uninitialized.len, 4);
    try Testing.expectEqual(a.len, 5);

    a.append(0xff);
    try Testing.expectEqual(a.len, 6);
    try Testing.expectEqual(a.pop(), 0xff);

    a.appendAssumeCapacity(0xff);
    try Testing.expectEqual(a.len, 6);
    try Testing.expectEqual(a.pop(), 0xff);

    a.resize(1);
    try Testing.expectEqual(a.pop(), 0);
    try Testing.expectEqual(a.pop(), null);
    var unused = a.unusedCapacitySlice();
    @memset(unused[0..8], 2);
    unused[8] = 3;
    unused[9] = 4;
    try Testing.expectEqual(unused.len, a.capacity());
    a.resize(10);

    a.insert(5, 0xaa);
    try Testing.expectEqual(a.len, 11);
    try Testing.expectEqual(a.get(5), 0xaa);
    try Testing.expectEqual(a.get(9), 3);
    try Testing.expectEqual(a.get(10), 4);

    a.insert(11, 0xbb);
    try Testing.expectEqual(a.len, 12);
    try Testing.expectEqual(a.pop(), 0xbb);

    a.appendSlice(&x);
    try Testing.expectEqual(a.len, 11 + x.len);

    a.appendNTimes(0xbb, 5);
    try Testing.expectEqual(a.len, 11 + x.len + 5);
    try Testing.expectEqual(a.pop(), 0xbb);

    a.appendNTimesAssumeCapacity(0xcc, 5);
    try Testing.expectEqual(a.len, 11 + x.len + 5 - 1 + 5);
    try Testing.expectEqual(a.pop(), 0xcc);

    try Testing.expectEqual(a.len, 29);
    a.replaceRange(1, 20, &x);
    try Testing.expectEqual(a.len, 29 + x.len - 20);

    a.insertSlice(0, &x);
    try Testing.expectEqual(a.len, 29 + x.len - 20 + x.len);

    a.replaceRange(1, 5, &x);
    try Testing.expectEqual(a.len, 29 + x.len - 20 + x.len + x.len - 5);

    a.append(10);
    try Testing.expectEqual(a.pop(), 10);

    a.append(20);
    const removed = a.orderedRemove(5);
    try Testing.expectEqual(removed, 1);
    try Testing.expectEqual(a.len, 34);

    a.set(0, 0xdd);
    a.set(a.len - 1, 0xee);
    const swapped = a.swapRemove(0);
    try Testing.expectEqual(swapped, 0xdd);
    try Testing.expectEqual(a.get(0), 0xee);

    const added_slice = a.addManyAsSlice(3);
    try Testing.expectEqual(added_slice.len, 3);
    try Testing.expectEqual(a.len, 36);

    while (a.pop()) |_| {}
    const w = a.writer();
    const s = "hello, this is a test string";
    try w.writeAll(s);
    try Testing.expectEqualStrings(s, a.constSlice());
}

test FixedBufferAligned {
    var a = FixedBufferAligned(u8, .@"16", 4).init(0);
    a.append(0);
    a.append(0);
    a.append(255);
    a.append(255);

    const b = @as(*const [2]u16, @ptrCast(a.constSlice().ptr));
    try Testing.expectEqual(@as(u16, 0), b[0]);
    try Testing.expectEqual(@as(u16, 65535), b[1]);
}
