const path = @import("std").fs.path;

const sep = path.sep;
const sep_posix = path.sep_posix;
const sep_windows = path.sep_windows;
const isSep = path.isSep;
const Debug = @import("Debug.zig");
const Fs = @import("Fs.zig");
const Testing = @import("Testing.zig");

/// Joins paths into the provided buffer, returning a slice of the used portion
fn joinSepMaybeZ(buffer: []u8, separator: u8, comptime sepPredicate: fn (u8) bool, paths: []const []const u8, zero: bool) ![]u8 {
    if (paths.len == 0) {
        if (zero) {
            Debug.panicAssert(buffer.len >= 1, "Buffer too small for null terminator", .{});
            buffer[0] = 0;
            return buffer[0..1];
        }
        return buffer[0..0];
    }

    // find first non-empty path index.
    const first_path_index = blk: {
        for (paths, 0..) |p, index| {
            if (p.len == 0) continue else break :blk index;
        }

        // All paths provided were empty
        if (zero) {
            Debug.panicAssert(buffer.len >= 1, "Buffer too small for null terminator", .{});
            buffer[0] = 0;
            return buffer[0..1];
        }
        return buffer[0..0];
    };

    // Calculate length needed for resulting joined path buffer.
    const total_len = blk: {
        var sum: usize = paths[first_path_index].len;
        var prev_path = paths[first_path_index];
        Debug.assert(prev_path.len > 0);
        var i: usize = first_path_index + 1;
        while (i < paths.len) : (i += 1) {
            const this_path = paths[i];
            if (this_path.len == 0) continue;
            const prev_sep = sepPredicate(prev_path[prev_path.len - 1]);
            const this_sep = sepPredicate(this_path[0]);
            sum += @intFromBool(!prev_sep and !this_sep);
            sum += if (prev_sep and this_sep) this_path.len - 1 else this_path.len;
            prev_path = this_path;
        }

        if (zero) sum += 1;
        break :blk sum;
    };

    Debug.panicAssert(buffer.len >= total_len, "Buffer too small: need {} but have {}", .{ total_len, buffer.len });

    @memcpy(buffer[0..paths[first_path_index].len], paths[first_path_index]);
    var buf_index: usize = paths[first_path_index].len;
    var prev_path = paths[first_path_index];
    Debug.assert(prev_path.len > 0);
    var i: usize = first_path_index + 1;
    while (i < paths.len) : (i += 1) {
        const this_path = paths[i];
        if (this_path.len == 0) continue;
        const prev_sep = sepPredicate(prev_path[prev_path.len - 1]);
        const this_sep = sepPredicate(this_path[0]);
        if (!prev_sep and !this_sep) {
            buffer[buf_index] = separator;
            buf_index += 1;
        }
        const adjusted_path = if (prev_sep and this_sep) this_path[1..] else this_path;
        @memcpy(buffer[buf_index..][0..adjusted_path.len], adjusted_path);
        buf_index += adjusted_path.len;
        prev_path = this_path;
    }

    if (zero) buffer[total_len - 1] = 0;

    return buffer[0..total_len];
}

/// Joins paths into the provided buffer, returning a slice of the used portion
pub fn join(buffer: []u8, paths: []const []const u8) ![]u8 {
    return joinSepMaybeZ(buffer, sep, isSep, paths, false);
}

fn testJoinMaybeZUefi(paths: []const []const u8, expected: []const u8, zero: bool) !void {
    const uefiIsSep = struct {
        fn isSep(byte: u8) bool {
            return byte == '\\';
        }
    }.isSep;
    var buffer: [Fs.max_path_bytes]u8 = undefined;
    const actual = try joinSepMaybeZ(&buffer, sep_windows, uefiIsSep, paths, zero);
    try Testing.expectEqualSlices(u8, expected, if (zero) actual[0 .. actual.len - 1 :0] else actual);
}

fn testJoinMaybeZWindows(paths: []const []const u8, expected: []const u8, zero: bool) !void {
    const windowsIsSep = struct {
        fn isSep(byte: u8) bool {
            return byte == '/' or byte == '\\';
        }
    }.isSep;
    var buffer: [Fs.max_path_bytes]u8 = undefined;
    const actual = try joinSepMaybeZ(&buffer, sep_windows, windowsIsSep, paths, zero);
    try Testing.expectEqualSlices(u8, expected, if (zero) actual[0 .. actual.len - 1 :0] else actual);
}

fn testJoinMaybeZPosix(paths: []const []const u8, expected: []const u8, zero: bool) !void {
    const posixIsSep = struct {
        fn isSep(byte: u8) bool {
            return byte == '/';
        }
    }.isSep;
    var buffer: [Fs.max_path_bytes]u8 = undefined;
    const actual = try joinSepMaybeZ(&buffer, sep_posix, posixIsSep, paths, zero);
    try Testing.expectEqualSlices(u8, expected, if (zero) actual[0 .. actual.len - 1 :0] else actual);
}

test "join" {
    {
        var buffer: [Fs.max_path_bytes]u8 = undefined;
        const actual = try join(&buffer, &[_][]const u8{});
        try Testing.expectEqualSlices(u8, "", actual);
    }
    for (&[_]bool{ false, true }) |zero| {
        try testJoinMaybeZWindows(&[_][]const u8{}, "", zero);
        try testJoinMaybeZWindows(&[_][]const u8{ "c:\\a\\b", "c" }, "c:\\a\\b\\c", zero);
        try testJoinMaybeZWindows(&[_][]const u8{ "c:\\a\\b", "c" }, "c:\\a\\b\\c", zero);
        try testJoinMaybeZWindows(&[_][]const u8{ "c:\\a\\b\\", "c" }, "c:\\a\\b\\c", zero);

        try testJoinMaybeZWindows(&[_][]const u8{ "c:\\", "a", "b\\", "c" }, "c:\\a\\b\\c", zero);
        try testJoinMaybeZWindows(&[_][]const u8{ "c:\\a\\", "b\\", "c" }, "c:\\a\\b\\c", zero);

        try testJoinMaybeZWindows(
            &[_][]const u8{ "c:\\home\\andy\\dev\\zig\\build\\lib\\zig\\std", "ab.zig" },
            "c:\\home\\andy\\dev\\zig\\build\\lib\\zig\\std\\ab.zig",
            zero,
        );

        try testJoinMaybeZUefi(&[_][]const u8{ "EFI", "Boot", "bootx64.efi" }, "EFI\\Boot\\bootx64.efi", zero);
        try testJoinMaybeZUefi(&[_][]const u8{ "EFI\\Boot", "bootx64.efi" }, "EFI\\Boot\\bootx64.efi", zero);
        try testJoinMaybeZUefi(&[_][]const u8{ "EFI\\", "\\Boot", "bootx64.efi" }, "EFI\\Boot\\bootx64.efi", zero);
        try testJoinMaybeZUefi(&[_][]const u8{ "EFI\\", "\\Boot\\", "\\bootx64.efi" }, "EFI\\Boot\\bootx64.efi", zero);

        try testJoinMaybeZWindows(&[_][]const u8{ "c:\\", "a", "b/", "c" }, "c:\\a\\b/c", zero);
        try testJoinMaybeZWindows(&[_][]const u8{ "c:\\a/", "b\\", "/c" }, "c:\\a/b\\c", zero);

        try testJoinMaybeZWindows(&[_][]const u8{ "", "c:\\", "", "", "a", "b\\", "c", "" }, "c:\\a\\b\\c", zero);
        try testJoinMaybeZWindows(&[_][]const u8{ "c:\\a/", "", "b\\", "", "/c" }, "c:\\a/b\\c", zero);
        try testJoinMaybeZWindows(&[_][]const u8{ "", "" }, "", zero);

        try testJoinMaybeZPosix(&[_][]const u8{}, "", zero);
        try testJoinMaybeZPosix(&[_][]const u8{ "/a/b", "c" }, "/a/b/c", zero);
        try testJoinMaybeZPosix(&[_][]const u8{ "/a/b/", "c" }, "/a/b/c", zero);

        try testJoinMaybeZPosix(&[_][]const u8{ "/", "a", "b/", "c" }, "/a/b/c", zero);
        try testJoinMaybeZPosix(&[_][]const u8{ "/a/", "b/", "c" }, "/a/b/c", zero);

        try testJoinMaybeZPosix(
            &[_][]const u8{ "/home/andy/dev/zig/build/lib/zig/std", "ab.zig" },
            "/home/andy/dev/zig/build/lib/zig/std/ab.zig",
            zero,
        );

        try testJoinMaybeZPosix(&[_][]const u8{ "a", "/c" }, "a/c", zero);
        try testJoinMaybeZPosix(&[_][]const u8{ "a/", "/c" }, "a/c", zero);

        try testJoinMaybeZPosix(&[_][]const u8{ "", "/", "a", "", "b/", "c", "" }, "/a/b/c", zero);
        try testJoinMaybeZPosix(&[_][]const u8{ "/a/", "", "", "b/", "c" }, "/a/b/c", zero);
        try testJoinMaybeZPosix(&[_][]const u8{ "", "" }, "", zero);
    }
}
