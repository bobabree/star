const unicode = @import("std").unicode;
const bufPrintZ = @import("std").fmt.bufPrintZ;

const Mem = @import("Mem.zig");
const Debug = @import("Debug.zig");
const FixedBuffer = @import("FixedBuffer.zig").FixedBuffer;

pub fn Utf8Buffer(comptime capacity: usize) type {
    comptime {
        if (capacity <= 0) @compileError("Utf8Buffer capacity must be > 0");
    }

    return struct {
        const Self = @This();
        _buffer: FixedBuffer(u8, capacity),

        pub fn init() Self {
            return Self{ ._buffer = FixedBuffer(u8, capacity).init(0) };
        }

        pub fn copy(text: []const u8) Self {
            Debug.assert(isValidUtf8(text));
            Debug.assert(text.len <= capacity);
            return Self{ ._buffer = FixedBuffer(u8, capacity).fromSlice(text) };
        }

        pub fn format(self: *Self, comptime fmt: []const u8, args: anytype) void {
            Debug.assert(isValidUtf8(fmt));
            Debug.assert(isValidUtf8(self.constSlice()));
            Debug.assert(self._buffer.len <= capacity);

            var temp_buf: [capacity]u8 = undefined;
            const formatted = bufPrintZ(&temp_buf, fmt, args) catch |err| {
                Debug.panic("format failed with error {}: formatted string exceeds capacity {}", .{ err, capacity });
            };

            Debug.assert(isValidUtf8(formatted));
            Debug.assert(formatted.len <= capacity);

            self.setSlice(formatted);
        }

        pub fn indexOf(self: *const Self, substring: []const u8) ?usize {
            Debug.assert(isValidUtf8(self.constSlice()));
            Debug.assert(isValidUtf8(substring));

            if (substring.len == 0) return 0;

            const text = self.constSlice();
            var char_index: usize = 0;
            var byte_pos: usize = 0;

            while (byte_pos + substring.len <= text.len) {
                if (Mem.eql(u8, text[byte_pos .. byte_pos + substring.len], substring)) {
                    return char_index;
                }

                const char_len = utf8CharLen(text[byte_pos]);
                byte_pos += char_len;
                char_index += 1;
            }

            return null;
        }

        pub fn contains(self: *const Self, substring: []const u8) bool {
            return self.indexOf(substring) != null;
        }

        // pub fn findPattern(self: *const Self, pattern: []const u8) ?usize {
        //     // Regex implementation
        // }

        pub fn replace(source: []const u8, substring: []const u8, replacement: []const u8) Self {
            Debug.assert(isValidUtf8(source));
            Debug.assert(isValidUtf8(substring));
            Debug.assert(isValidUtf8(replacement));

            if (substring.len == 0) {
                return Self.copy(source);
            }

            var temp_buf: [capacity]u8 = undefined;
            var temp_len: usize = 0;
            var byte_pos: usize = 0;

            while (byte_pos < source.len) {
                if (byte_pos + substring.len <= source.len and
                    Mem.eql(u8, source[byte_pos .. byte_pos + substring.len], substring))
                {
                    // Found match
                    Debug.panicAssert(temp_len + replacement.len <= capacity, "replace: result length {} exceeds capacity {}", .{ temp_len + replacement.len, capacity });
                    @memcpy(temp_buf[temp_len..][0..replacement.len], replacement);
                    temp_len += replacement.len;
                    byte_pos += substring.len;
                } else {
                    // Copy one UTF-8 character
                    const char_len = utf8CharLen(source[byte_pos]);
                    Debug.panicAssert(temp_len + char_len <= capacity, "replace: result length {} exceeds capacity {}", .{ temp_len + char_len, capacity });
                    @memcpy(temp_buf[temp_len..][0..char_len], source[byte_pos..][0..char_len]);
                    temp_len += char_len;
                    byte_pos += char_len;
                }
            }

            Debug.assert(isValidUtf8(temp_buf[0..temp_len]));
            Debug.assert(temp_len <= capacity);

            return Self.copy(temp_buf[0..temp_len]);
        }

        pub fn setSlice(self: *Self, text: []const u8) void {
            Debug.assert(isValidUtf8(text));
            Debug.assert(text.len <= capacity);
            self._buffer = FixedBuffer(u8, capacity).fromSlice(text);
        }

        pub fn appendSlice(self: *Self, text: []const u8) void {
            Debug.assert(isValidUtf8(text));
            Debug.assert(isValidUtf8(self.constSlice()));
            self._buffer.appendSlice(text);
        }

        pub fn constSlice(self: *const Self) []const u8 {
            const result = self._buffer.constSlice();
            Debug.assert(isValidUtf8(result));
            return result;
        }

        pub fn clear(self: *Self) void {
            self._buffer.clear();
        }

        pub fn len(self: *const Self) usize {
            return utf8CharCount(self.constSlice());
        }
        pub fn charAt(self: *const Self, pos: usize) u21 {
            Debug.assert(isValidUtf8(self.constSlice()));

            var char_index: usize = 0;
            var byte_pos: usize = 0;

            while (byte_pos < self._buffer.len) {
                if (char_index == pos) {
                    const char_len = utf8CharLen(self._buffer.slice()[byte_pos]);
                    const utf8_bytes = self._buffer.slice()[byte_pos .. byte_pos + char_len];
                    return unicode.utf8Decode(utf8_bytes) catch |err| {
                        Debug.panic("charAt: utf8Decode failed with error {}", .{err});
                    };
                }
                const char_len = utf8CharLen(self._buffer.slice()[byte_pos]);
                byte_pos += char_len;
                char_index += 1;
            }

            Debug.panic("charAt: index {} exceeds string length", .{pos});
        }

        pub fn insertAt(self: *Self, pos: usize, char: u21) void {
            Debug.assert(isValidUtf8(self.constSlice()));
            Debug.assert(pos <= self._buffer.len);

            // Convert character position to byte position
            var byte_pos: usize = 0;
            var char_index: usize = 0;

            while (char_index < pos and byte_pos < self._buffer.len) {
                const char_len = utf8CharLen(self._buffer.slice()[byte_pos]);
                byte_pos += char_len;
                char_index += 1;
            }

            Debug.panicAssert(byte_pos <= self._buffer.len, "insertAt: character position {} exceeds string length", .{pos});

            var utf8_bytes = zbuf(u8, 4);
            const utf_len = unicode.utf8Encode(char, &utf8_bytes) catch |err| {
                Debug.panic("utf8Encode failed with error {}: invalid char 0x{x}", .{ err, char });
            };
            self._buffer.insertSlice(byte_pos, utf8_bytes[0..utf_len]);

            Debug.assert(isValidUtf8(self.constSlice()));
        }

        pub fn removeAt(self: *Self, pos: usize) void {
            Debug.assert(isValidUtf8(self.constSlice()));

            // Convert character position to byte position
            var byte_pos: usize = 0;
            var char_index: usize = 0;

            while (char_index < pos and byte_pos < self._buffer.len) {
                const char_len = utf8CharLen(self._buffer.slice()[byte_pos]);
                byte_pos += char_len;
                char_index += 1;
            }

            Debug.panicAssert(byte_pos < self._buffer.len, "removeAt: character position {} exceeds string length", .{pos});

            const utf_len = utf8CharLen(self._buffer.slice()[byte_pos]);
            const bytes_to_remove = self._buffer.slice()[byte_pos .. byte_pos + utf_len];
            _ = unicode.utf8Decode(bytes_to_remove) catch |err| {
                Debug.panic("utf8Decode failed with error {}: invalid UTF-8 bytes", .{err});
            };
            self._buffer.replaceRange(byte_pos, utf_len, &[_]u8{});

            Debug.assert(isValidUtf8(self.constSlice()));
        }

        pub const Iterator = struct {
            buffer: *const Self,
            char_index: usize,

            pub fn next(self: *Iterator) ?u21 {
                if (self.char_index >= self.buffer.len()) return null;

                const char = self.buffer.charAt(self.char_index);
                self.char_index += 1;
                return char;
            }

            pub fn prev(self: *Iterator) ?u21 {
                if (self.char_index == 0) return null;

                self.char_index -= 1;
                return self.buffer.charAt(self.char_index);
            }
        };

        pub fn iterator(self: *const Self) Iterator {
            return Iterator{ .buffer = self, .char_index = 0 };
        }
    };
}

/// Zero-initialized buffer helper
pub inline fn zbuf(comptime T: type, comptime size: usize) [size]T {
    return [_]T{0} ** size;
}

/// UTF-8 utility functions
fn utf8CharLen(first_byte: u8) u3 {
    return unicode.utf8ByteSequenceLength(first_byte) catch |err| {
        Debug.panic("utf8CharLen failed with error {}: invalid UTF-8 start byte 0x{x}", .{ err, first_byte });
    };
}

fn utf8CharCount(text: []const u8) usize {
    Debug.assert(isValidUtf8(text));
    return unicode.utf8CountCodepoints(text) catch |err| {
        Debug.panic("utf8CharCount failed with error {}: invalid UTF-8 input", .{err});
    };
}

fn isValidUtf8(text: []const u8) bool {
    return unicode.utf8ValidateSlice(text);
}

const Testing = @import("Testing.zig");

test Utf8Buffer {
    // Test init
    var buf = Utf8Buffer(64).init();
    try Testing.expectEqual(buf.len(), 0);
    try Testing.expectEqualStrings("", buf.constSlice());

    // Test copy
    const test_text = "Hello, 世界! 🌟";
    buf = Utf8Buffer(64).copy(test_text);
    try Testing.expectEqual(buf.len(), 12);
    try Testing.expectEqualStrings(test_text, buf.constSlice());

    // Test copy of buf
    var buf2 = buf;
    try Testing.expectEqualStrings(buf.constSlice(), buf2.constSlice());

    // Test copies are independent
    buf2.clear();
    try Testing.expect(buf.len() != buf2.len());
    try Testing.expectEqual(buf2.len(), 0);

    // Test setSlice
    buf.setSlice("café");
    try Testing.expectEqual(buf.len(), 4);
    try Testing.expectEqualStrings("café", buf.constSlice());

    // Test appendSlice
    buf.appendSlice(" au lait");
    try Testing.expectEqual(buf.len(), 12);
    try Testing.expectEqualStrings("café au lait", buf.constSlice());

    // Test charAt

    //@import("std").Debug.print("Expected 'é': {d} (0x{x})\n", .{ 'é', 'é' });
    try Testing.expectEqual(buf.charAt(0), 'c');
    try Testing.expectEqual(buf.charAt(1), 'a');
    try Testing.expectEqual(buf.charAt(2), 'f');
    try Testing.expectEqual(buf.charAt(3), 'é');
    try Testing.expectEqual(buf.charAt(4), ' ');

    // Test insertAt
    buf.setSlice("test");
    buf.insertAt(2, 'X');
    try Testing.expectEqual(buf.len(), 5);
    try Testing.expectEqualStrings("teXst", buf.constSlice());

    // Test insertAt with UTF-8 character
    buf.setSlice("hello");
    buf.insertAt(2, '世');
    try Testing.expectEqualStrings("he世llo", buf.constSlice());
    try Testing.expectEqual(buf.len(), 6);

    // Test insertAt at 0
    buf.setSlice("world");
    buf.insertAt(0, '🌟');
    try Testing.expectEqualStrings("🌟world", buf.constSlice());

    // Test insertAt at end
    buf.setSlice("hello");
    buf.insertAt(5, '!');
    try Testing.expectEqualStrings("hello!", buf.constSlice());

    // Test removeAt
    buf.setSlice("testing");
    buf.removeAt(2);
    try Testing.expectEqualStrings("teting", buf.constSlice());
    try Testing.expectEqual(buf.len(), 6);

    // Test removeAt with UTF-8
    buf.setSlice("he世llo");
    buf.removeAt(2);
    try Testing.expectEqualStrings("hello", buf.constSlice());
    try Testing.expectEqual(buf.len(), 5);

    // Test removeAt at 0
    buf.setSlice("hello");
    buf.removeAt(0);
    try Testing.expectEqualStrings("ello", buf.constSlice());

    // Test removeAt last character
    buf.setSlice("hello");
    buf.removeAt(4);
    try Testing.expectEqualStrings("hell", buf.constSlice());

    // Test indexOf
    buf.setSlice("hello world");
    try Testing.expectEqual(buf.indexOf("hello"), 0);
    try Testing.expectEqual(buf.indexOf("world"), 6);
    try Testing.expectEqual(buf.indexOf("o"), 4);
    try Testing.expectEqual(buf.indexOf("xyz"), null);
    try Testing.expectEqual(buf.indexOf(""), 0);

    // Test indexOf - UTF-8 cases
    buf.setSlice("café 世界");
    try Testing.expectEqual(buf.indexOf("café"), 0);
    try Testing.expectEqual(buf.indexOf("é"), 3);
    try Testing.expectEqual(buf.indexOf("世"), 5);
    try Testing.expectEqual(buf.indexOf("界"), 6);
    try Testing.expectEqual(buf.indexOf("世界"), 5);

    // Test indexOf - overlapping patterns
    buf.setSlice("aaaa");
    try Testing.expectEqual(buf.indexOf("aa"), 0);
    buf.setSlice("ababa");
    try Testing.expectEqual(buf.indexOf("aba"), 0);

    // Test indexOf - nuull
    buf.setSlice("hello");
    try Testing.expectEqual(buf.indexOf("world"), null);
    try Testing.expectEqual(buf.indexOf("hellox"), null);

    // Test contains
    buf.setSlice("hello world");
    try Testing.expect(buf.contains("hello"));
    try Testing.expect(buf.contains("world"));
    try Testing.expect(buf.contains("o w"));
    try Testing.expect(!buf.contains("xyz"));

    // Test contains w/ UTF-8
    buf.setSlice("café 世界");
    try Testing.expect(buf.contains("café"));
    try Testing.expect(buf.contains("é"));
    try Testing.expect(buf.contains("世界"));
    try Testing.expect(!buf.contains("abc"));

    // Test format
    buf.format("Hello {s}!", .{"world"});
    try Testing.expectEqualStrings("Hello world!", buf.constSlice());

    // Test format - numbers
    buf.format("Value: {d}", .{42});
    try Testing.expectEqualStrings("Value: 42", buf.constSlice());

    // Test format - multiple args
    buf.format("{s} = {d}", .{ "answer", 42 });
    try Testing.expectEqualStrings("answer = 42", buf.constSlice());

    // Test format - UTF-8
    buf.format("Café #{d}: {s}", .{ 1, "世界" });
    try Testing.expectEqualStrings("Café #1: 世界", buf.constSlice());

    // Test format - empty
    buf.format("", .{});
    try Testing.expectEqualStrings("", buf.constSlice());

    // Test replace
    var result = Utf8Buffer(64).replace("hello world", "world", "zig");
    try Testing.expectEqualStrings("hello zig", result.constSlice());

    // Test replace - multiple occurrences
    result = Utf8Buffer(64).replace("foo bar foo", "foo", "baz");
    try Testing.expectEqualStrings("baz bar baz", result.constSlice());

    // Test replace - no match
    result = Utf8Buffer(64).replace("hello world", "xyz", "abc");
    try Testing.expectEqualStrings("hello world", result.constSlice());

    // Test replace - empty replacement
    result = Utf8Buffer(64).replace("hello world", "world", "");
    try Testing.expectEqualStrings("hello ", result.constSlice());

    // Test replace - replacement longer than original
    result = Utf8Buffer(64).replace("hi", "hi", "hello there");
    try Testing.expectEqualStrings("hello there", result.constSlice());

    // Test replace - UTF-8
    result = Utf8Buffer(64).replace("café world", "café", "tea");
    try Testing.expectEqualStrings("tea world", result.constSlice());

    result = Utf8Buffer(64).replace("hello 世界", "世界", "world");
    try Testing.expectEqualStrings("hello world", result.constSlice());

    // Test replace - empty substring (should return copy)
    result = Utf8Buffer(64).replace("hello", "", "x");
    try Testing.expectEqualStrings("hello", result.constSlice());

    // Test replace - whole string
    result = Utf8Buffer(64).replace("hello", "hello", "world");
    try Testing.expectEqualStrings("world", result.constSlice());

    // Test replace - overlapping
    result = Utf8Buffer(64).replace("aaa", "aa", "b");
    try Testing.expectEqualStrings("ba", result.constSlice());

    // Test iterator
    buf.setSlice("aé世🌟");
    var it = buf.iterator();
    try Testing.expectEqual(it.next(), 'a');
    try Testing.expectEqual(it.next(), 'é');
    try Testing.expectEqual(it.next(), '世');
    try Testing.expectEqual(it.next(), '🌟');
    try Testing.expectEqual(it.next(), null);

    // Test iterator prev
    try Testing.expectEqual(it.prev(), '🌟');
    try Testing.expectEqual(it.prev(), '世');
    try Testing.expectEqual(it.prev(), 'é');
    try Testing.expectEqual(it.prev(), 'a');
    try Testing.expectEqual(it.prev(), null);

    buf.clear();
    it = buf.iterator();
    try Testing.expectEqual(it.next(), null);
    try Testing.expectEqual(it.prev(), null);

    // Test clear
    buf.setSlice("some text");
    try Testing.expect(buf.len() > 0);
    buf.clear();
    try Testing.expectEqual(buf.len(), 0);
    try Testing.expectEqualStrings("", buf.constSlice());

    // Test empty strings
    buf.setSlice("");
    try Testing.expectEqual(buf.len(), 0);
    try Testing.expectEqual(buf.indexOf(""), 0);
    try Testing.expectEqual(buf.indexOf("x"), null);
    try Testing.expect(!buf.contains("x"));

    // Test single char operations
    buf.setSlice("x");
    try Testing.expectEqual(buf.len(), 1);
    try Testing.expectEqual(buf.charAt(0), 'x');
    buf.removeAt(0);
    try Testing.expectEqual(buf.len(), 0);

    // Test UTF-8
    buf.setSlice("🌟");
    try Testing.expectEqual(buf.len(), 1);
    try Testing.expectEqual(buf.charAt(0), '🌟');

    buf.insertAt(0, '🎉');
    try Testing.expectEqualStrings("🎉🌟", buf.constSlice());
    try Testing.expectEqual(buf.len(), 2);

    // Test mix ASCII and UTF-8
    buf.setSlice("a世b🌟c");
    try Testing.expectEqual(buf.len(), 5);
    try Testing.expectEqual(buf.charAt(0), 'a');
    try Testing.expectEqual(buf.charAt(1), '世');
    try Testing.expectEqual(buf.charAt(2), 'b');
    try Testing.expectEqual(buf.charAt(3), '🌟');
    try Testing.expectEqual(buf.charAt(4), 'c');

    // Test small buffer capacity
    const small_buf = Utf8Buffer(8).copy("test");
    try Testing.expectEqualStrings("test", small_buf.constSlice());

    // Test UTF-8 validity
    buf.setSlice("valid");
    buf.insertAt(2, '世');
    try Testing.expect(isValidUtf8(buf.constSlice()));

    buf.removeAt(2);
    try Testing.expect(isValidUtf8(buf.constSlice()));

    // Test format
    buf.setSlice("prefix");
    buf.format("new content: {d}", .{123});
    try Testing.expectEqualStrings("new content: 123", buf.constSlice());

    buf.setSlice("aé世🌟");
    var it2 = buf.iterator();

    // Test iterators, basic
    try Testing.expectEqual(it2.char_index, 0);
    try Testing.expectEqual(it2.buffer, &buf);

    _ = it2.next();
    _ = it2.next();
    _ = it2.next();
    _ = it2.next();
    try Testing.expectEqual(it2.next(), null);
    try Testing.expectEqual(it2.next(), null);

    // Test prev from end
    try Testing.expectEqual(it2.prev(), '🌟');
    try Testing.expectEqual(it2.prev(), '世');

    // Test mixed next/prev
    try Testing.expectEqual(it2.next(), '世');
    try Testing.expectEqual(it2.next(), '🌟');
    try Testing.expectEqual(it2.prev(), '🌟');

    // Test iterator on empty buf
    buf.clear();
    var empty_it = buf.iterator();
    try Testing.expectEqual(empty_it.char_index, 0);
    try Testing.expectEqual(empty_it.next(), null);
    try Testing.expectEqual(empty_it.prev(), null);

    // Test exact capacity
    const tiny_buf = Utf8Buffer(4);
    var small = tiny_buf.copy("test");
    try Testing.expectEqualStrings("test", small.constSlice());

    // Test capacity
    var emoji_buf = tiny_buf.copy("🌟");
    try Testing.expectEqualStrings("🌟", emoji_buf.constSlice());

    // Test format hitting capacity - must panic
    // small.format("toolong{}", .{123});

    // Test replace hitting capacity - panic
    // const overflow = tiny_buf.replace("test", "t", "toolong");

    // Test appendSlice
    small.setSlice("te");
    small.appendSlice("st");
    try Testing.expectEqualStrings("test", small.constSlice());

    // Error conditions that panic
    buf.setSlice("hello");

    // These should panic
    // buf.charAt(10);
    // buf.insertAt(10, 'x');
    // buf.removeAt(10);

    try Testing.expectEqual(buf.charAt(4), 'o');
    buf.insertAt(5, '!');
    try Testing.expectEqualStrings("hello!", buf.constSlice());
    buf.removeAt(5);
    try Testing.expectEqualStrings("hello", buf.constSlice());

    // Test maximum UTF-8 chars (4 bytes ea)
    buf.setSlice("🌟🎉🚀💖");
    try Testing.expectEqual(buf.len(), 4);
    try Testing.expectEqual(buf.charAt(0), '🌟');
    try Testing.expectEqual(buf.charAt(3), '💖');

    // Test indexOf
    buf.setSlice("世世界");
    try Testing.expectEqual(buf.indexOf("世"), 0);
    try Testing.expectEqual(buf.indexOf("世界"), 1);

    // Test replace
    result = Utf8Buffer(64).replace("a", "a", "🌟");
    try Testing.expectEqualStrings("🌟", result.constSlice());

    result = Utf8Buffer(64).replace("🌟", "🌟", "a");
    try Testing.expectEqualStrings("a", result.constSlice());

    // Test insertAt
    buf.setSlice("ab");
    buf.insertAt(1, '🌟');
    try Testing.expectEqualStrings("a🌟b", buf.constSlice());
    try Testing.expectEqual(buf.len(), 3);

    // Test removeAt
    buf.removeAt(1);
    try Testing.expectEqualStrings("ab", buf.constSlice());
    try Testing.expectEqual(buf.len(), 2);

    // Test format
    buf.format("{s}{s}{s}", .{ "🌟", "世", "界" });
    try Testing.expectEqualStrings("🌟世界", buf.constSlice());

    // Test contains
    buf.setSlice("🌟");
    try Testing.expect(buf.contains("🌟")); // Full valid emoji
    try Testing.expect(!buf.contains("x")); // Different valid character

    // Test indexOf
    buf.setSlice("ab🌟cd");
    try Testing.expectEqual(buf.indexOf("🌟"), 2);
    try Testing.expectEqual(buf.indexOf("b🌟"), 1);
    try Testing.expectEqual(buf.indexOf("🌟c"), 2);

    // Test iterator
    buf.setSlice("a🌟é");
    var mixed_it = buf.iterator();
    try Testing.expectEqual(mixed_it.next(), 'a');
    try Testing.expectEqual(mixed_it.next(), '🌟');
    try Testing.expectEqual(mixed_it.next(), 'é');
    try Testing.expectEqual(mixed_it.next(), null);

    try Testing.expectEqual(mixed_it.prev(), 'é');
    try Testing.expectEqual(mixed_it.prev(), '🌟');
    try Testing.expectEqual(mixed_it.prev(), 'a');
    try Testing.expectEqual(mixed_it.prev(), null);

    result = Utf8Buffer(64).replace("", "x", "y");
    try Testing.expectEqualStrings("", result.constSlice());

    result = Utf8Buffer(64).replace("hello", "hello", "");
    try Testing.expectEqualStrings("", result.constSlice());

    buf.setSlice("test");
    buf.insertAt(2, '世');
    buf.insertAt(0, '🌟');
    buf.removeAt(1); // "🌟e世st"
    buf.removeAt(2);
    try Testing.expect(isValidUtf8(buf.constSlice()));
    try Testing.expectEqualStrings("🌟est", buf.constSlice());

    buf.setSlice("🌟🌟🌟🌟");
    buf.format("a", .{});
    try Testing.expectEqualStrings("a", buf.constSlice());

    buf.format("🌟🌟", .{});
    try Testing.expectEqualStrings("🌟🌟", buf.constSlice());

    buf.setSlice("Hello, 世界! 🌟 café");
    it = buf.iterator();
    var char_count: usize = 0;

    while (it.next()) |_| {
        char_count += 1;
    }

    try Testing.expectEqual(char_count, 17);

    buf.setSlice("reverse 🔄 this");
    it = buf.iterator();

    var forward_count: usize = 0;
    while (it.next()) |_| {
        forward_count += 1;
    }
    try Testing.expectEqual(forward_count, 14);

    var reversed = Utf8Buffer(256).init();
    var backward_count: usize = 0;
    while (it.prev()) |char| {
        backward_count += 1;
        if (backward_count == 1) try Testing.expectEqual(char, 's');
        if (backward_count == 2) try Testing.expectEqual(char, 'i');
        if (backward_count == 6) try Testing.expectEqual(char, '🔄');
        if (backward_count == 14) try Testing.expectEqual(char, 'r');

        reversed.insertAt(reversed.len(), char);
    }
    try Testing.expectEqual(backward_count, 14);
    try Testing.expectEqualStrings("siht 🔄 esrever", reversed.constSlice());

    buf.setSlice("café 世界 🌟 test");
    it = buf.iterator();
    var cafe_result = Utf8Buffer(256).init();

    for (0..buf.len()) |i| {
        if (it.next()) |char| {
            const replacement = switch (char) {
                'a'...'z', 'A'...'Z' => char ^ 0x20,
                'é' => 'É',
                '🌟' => '⭐',
                '世' => '🌍',
                else => char,
            };

            if (i == 0) try Testing.expectEqual(replacement, 'C');
            if (i == 1) try Testing.expectEqual(replacement, 'A');
            if (i == 4) try Testing.expectEqual(replacement, ' ');
            if (i == 5) try Testing.expectEqual(replacement, '🌍');
            if (i == 8) try Testing.expectEqual(replacement, '⭐');
            if (i == 10) try Testing.expectEqual(replacement, 'T');

            cafe_result.insertAt(i, replacement);
        }
    }

    try Testing.expectEqualStrings("CAFÉ 🌍界 ⭐ TEST", cafe_result.constSlice());
}
