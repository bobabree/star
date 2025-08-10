/// ./web/server.zig
const runtime = @import("runtime.zig");

const builtin = runtime.builtin;
const Atomic = runtime.Atomic;
const Debug = runtime.Debug;
const Fs = runtime.Fs;
const FsPath = runtime.FsPath;
const Http = runtime.Http;
const Heap = runtime.Heap;
const Mem = runtime.Mem;
const Net = runtime.Net;
const Process = runtime.Process;
const Thread = runtime.Thread;
const Time = runtime.Time;

// Embed HTML
const html_content = @embedFile("web/index.min.html");

pub const HotReloader = struct {
    allocator: Mem.Allocator,
    watch_dirs: []const []const u8,
    rebuild_cmd: []const []const u8,
    should_stop: Atomic.Value(bool),
    last_server_mtime: i128,

    pub fn init(allocator: Mem.Allocator) HotReloader {
        const initial_mtime = blk: {
            const file = Fs.cwd().openFile("src/server.zig", .{}) catch |err| {
                Debug.server.warn("Cannot check server.zig initially: {}", .{err});
                break :blk 0;
            };
            defer file.close();
            const stat = file.stat() catch |err| {
                Debug.server.warn("Cannot stat server.zig initially: {}", .{err});
                break :blk 0;
            };
            break :blk stat.mtime;
        };

        return HotReloader{
            .allocator = allocator,
            .watch_dirs = &.{"src"},
            .rebuild_cmd = &.{ "zig", "build" },
            .should_stop = Atomic.Value(bool).init(false),
            .last_server_mtime = initial_mtime,
        };
    }

    pub fn start(self: *HotReloader) !void {
        const thread = try Thread.spawn(.{}, watchLoop, .{self});
        thread.detach();
    }

    pub fn stop(self: *HotReloader) void {
        self.should_stop.store(true, .release);
    }

    fn watchLoop(self: *HotReloader) void {
        var last_mtime: i128 = 0;

        while (!self.should_stop.load(.acquire)) {
            const current_mtime = self.getLatestMtime();
            if (current_mtime > last_mtime) {
                self.rebuild();
                last_mtime = current_mtime;
            }
            Thread.sleep(Time.ns_per_s / 4);
        }
    }

    fn getLatestMtime(self: *HotReloader) i128 {
        var latest: i128 = 0;

        for (self.watch_dirs) |dir_name| {
            self.scanDir(dir_name, &latest) catch |err| {
                Debug.server.warn("Failed to scan {s}: {}", .{ dir_name, err });
            };
        }
        return latest;
    }
    fn scanDir(self: *HotReloader, dir_path: []const u8, latest: *i128) !void {
        var dir = Fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            Debug.server.warn("Cannot open dir {s}: {}", .{ dir_path, err });
            return;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file) {
                // Skip generated files
                if (Mem.eql(u8, entry.name, "index.min.html") or
                    Mem.eql(u8, entry.name, "js.lib")) continue;

                // Watch all other files
                const file = dir.openFile(entry.name, .{}) catch |err| {
                    Debug.server.warn("Cannot open file {s}: {}", .{ entry.name, err });
                    continue;
                };
                defer file.close();

                const stat = file.stat() catch |err| {
                    Debug.server.warn("Cannot stat {s}: {}", .{ entry.name, err });
                    continue;
                };
                if (stat.mtime > latest.*) {
                    latest.* = stat.mtime;
                }
            } else if (entry.kind == .directory) {
                var path_buf: [Fs.max_path_bytes]u8 = undefined;
                const sub_path = FsPath.join(&path_buf, &.{ dir_path, entry.name }) catch |err| {
                    Debug.server.warn("Path too long for {s}/{s}: {}", .{ dir_path, entry.name, err });
                    continue;
                };

                self.scanDir(sub_path, latest) catch |err| {
                    Debug.server.warn("Failed to scan subdir {s}: {}", .{ sub_path, err });
                };
            }
        }
    }
    fn rebuild(self: *HotReloader) void {
        Debug.server.info("🔄 Rebuilding...", .{});

        const result = Process.Child.run(.{
            .allocator = self.allocator,
            .argv = self.rebuild_cmd,
        }) catch {
            Debug.server.err("❌ Build failed", .{});
            return;
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term == .Exited and result.term.Exited == 0) {
            Debug.server.success("✅ Build completed", .{});

            // Only check for server restart if build succeeded
            const server_stat = blk: {
                const file = Fs.cwd().openFile("src/server.zig", .{}) catch |err| {
                    Debug.server.warn("Cannot check server.zig: {}", .{err});
                    break :blk null;
                };
                defer file.close();
                break :blk file.stat() catch |err| {
                    Debug.server.warn("Cannot stat server.zig: {}", .{err});
                    break :blk null;
                };
            };

            if (server_stat) |stat| {
                if (comptime builtin.target.os.tag == .windows or builtin.target.cpu.arch.isWasm()) {
                    Debug.server.warn("TODO: Auto-restart not supported on this platform", .{});
                } else {
                    if (stat.mtime > self.last_server_mtime) {
                        Debug.server.info("🔄 Server changed, restarting...", .{});

                        // Get the actual executable path
                        var exe_path_buf: [Fs.max_path_bytes]u8 = undefined;
                        const exe_path = Fs.selfExePath(&exe_path_buf) catch |err| {
                            Debug.server.err("❌ Cannot get exe path: {}", .{err});
                            return;
                        };

                        const argv_buffers = Process.argsMaybeAlloc(self.allocator);

                        // Convert Utf8Buffer array to string array
                        // TODO: generalize this
                        var argv_strings: [32][]const u8 = undefined;
                        argv_strings[0] = exe_path;
                        for (argv_buffers.constSlice()[1..], 1..) |arg, i| {
                            argv_strings[i] = arg.constSlice();
                        }
                        const argv = argv_strings[0..argv_buffers.len];

                        const err = Process.execve(self.allocator, argv, null);
                        Debug.server.err("❌ Failed to restart: {}", .{err});
                    }
                    // Only update mtime after successful build
                    self.last_server_mtime = stat.mtime;
                }
            }
        } else {
            Debug.server.err("❌ Build failed: {s}", .{result.stderr});
            // Don't update mtime or restart on build failure
        }
    }
};

pub const Server = struct {
    const HOST = "127.0.0.1";
    const PORT = 8080;
    const URL = "http://127.0.0.1:8080";

    allocator: Mem.Allocator,
    is_dev: bool,
    hot_reloader: ?HotReloader = null,

    pub fn init(allocator: Mem.Allocator, is_dev: bool) Server {
        return Server{ .allocator = allocator, .is_dev = is_dev };
    }

    pub fn run(self: *Server) !void {
        if (self.is_dev) {
            self.hot_reloader = HotReloader.init(self.allocator);
            try self.hot_reloader.?.start();
        }

        const address = try Net.Address.parseIp4(HOST, PORT);
        var server = try address.listen(.{ .reuse_address = true });

        Debug.server.info("🚀 Zig HTTP Server running at {s}", .{URL});
        Debug.server.info("📁 Serving files from current directory", .{});
        Debug.server.info("🛑 Press Ctrl+C to stop", .{});

        const open_cmd = switch (builtin.target.os.tag) {
            .macos => &[_][]const u8{ "open", URL },
            .linux => &[_][]const u8{ "xdg-open", URL },
            .windows => &[_][]const u8{ "cmd", "/c", "start", URL },
            else => unreachable,
        };
        _ = try Process.Child.run(.{ .allocator = self.allocator, .argv = open_cmd });

        while (true) {
            const connection = server.accept() catch |err| {
                Debug.server.err("❌ Error accepting connection: {}", .{err});
                continue;
            };

            self.handleConnection(connection) catch |err| {
                Debug.server.err("❌ Error handling connection: {}", .{err});
            };
        }

        server.deinit();
    }

    fn handleConnection(self: Server, connection: Net.Server.Connection) !void {
        defer connection.stream.close();

        var buffer: [4096]u8 = undefined;
        var http_server = Http.Server.init(connection, &buffer);

        var request = http_server.receiveHead() catch |err| {
            Debug.server.err("❌ Error receiving request head: {}", .{err});
            return;
        };

        var target = request.head.target;

        // Strip query parameters for file serving
        // TODO: implement an UrlBuffer?
        if (Mem.indexOf(u8, target, "?")) |query_start| {
            target = target[0..query_start];
        }

        // Only log non-HEAD requests
        if (request.head.method != .HEAD) {
            Debug.server.info("📨 {any} {s}", .{ request.head.method, target });
        }

        // Route handling with cleaned target
        if (Mem.eql(u8, target, "/")) {
            try serveHTML(&request);
        } else if (Mem.endsWith(u8, target, ".wasm")) {
            try serveWasm(self.allocator, &request);
        } else {
            try serve404(&request);
        }
    }

    fn serveHTML(request: *Http.Server.Request) !void {
        try request.respond(html_content, .{
            .extra_headers = &[_]Http.Header{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    fn serveWasm(allocator: Mem.Allocator, request: *Http.Server.Request) !void {
        var exe_dir_path_buf: [Fs.max_path_bytes]u8 = undefined;
        const exe_dir_path = Fs.selfExeDirPath(&exe_dir_path_buf) catch {
            Debug.server.err("❌ Failed to get executable directory", .{});
            try serve404(request);
            return;
        };

        var wasm_path_buf: [Fs.max_path_bytes]u8 = undefined;
        const wasm_path = try FsPath.join(&wasm_path_buf, &.{ exe_dir_path, "star.wasm" });

        const wasm_data = Fs.cwd().readFileAlloc(allocator, wasm_path, 10_000_000) catch |err| {
            Debug.server.err("❌ Failed to read WASM file: {}", .{err});
            try serve404(request);
            return;
        };
        defer allocator.free(wasm_data);

        const size_mb = @as(f64, @floatFromInt(wasm_data.len)) / (1024.0 * 1024.0);
        const size_kb = @as(f64, @floatFromInt(wasm_data.len)) / 1024.0;

        try request.respond(wasm_data, .{
            .status = .ok,
            .extra_headers = &[_]Http.Header{
                .{ .name = "content-type", .value = "application/wasm" },
                .{ .name = "cross-origin-embedder-policy", .value = "require-corp" },
                .{ .name = "cross-origin-opener-policy", .value = "same-origin" },
            },
        });

        if (request.head.method != .HEAD) {
            Debug.server.info("Served WASM ({d:.2} MB / {d:.0} KB)", .{ size_mb, size_kb });
        }
    }
    fn serve404(request: *Http.Server.Request) !void {
        const content = "404 - File not found";
        try request.respond(content, .{
            .status = .not_found,
            .extra_headers = &[_]Http.Header{
                .{ .name = "content-type", .value = "text/plain" },
            },
        });
    }
};

const Testing = runtime.Testing;
const ProfiledTest = Testing.ProfiledTest;

test "test" {
    try Testing.expect(1 + 1 == 2);
}

test "server initialization" {
    var buffer: [1024]u8 = undefined;
    var fba = Heap.FixedBufferAllocator.init(&buffer);

    var profile = try ProfiledTest.start(@src());

    const server = profile.endWithResult(Server.init(fba.allocator(), false));

    try Testing.expect(!server.is_dev);
}

test "server initialization with memory" {
    var buffer: [1024]u8 = undefined;
    var fba = Heap.FixedBufferAllocator.init(&buffer);

    var profile = try ProfiledTest.startWithMemory(@src(), &fba);

    const server = profile.endWithResult(Server.init(fba.allocator(), false));

    try Testing.expect(!server.is_dev);
}

test "server file reading with memory" {
    var buffer: [1024 * 1024]u8 = undefined;
    var fba = Heap.FixedBufferAllocator.init(&buffer);

    var profile = try ProfiledTest.startWithMemory(@src(), &fba);

    const wasm_data = Fs.cwd().readFileAlloc(fba.allocator(), "../../debug/star-mac/star.wasm", 10_000_000) catch |err| switch (err) {
        error.FileNotFound => {
            profile.end();
            return;
        },
        else => return err,
    };
    defer fba.allocator().free(wasm_data);

    profile.endWith(wasm_data);

    try Testing.expect(wasm_data.len > 0);
}

test "server http buffer allocation" {
    var buffer: [8192]u8 = undefined;
    var fba = Heap.FixedBufferAllocator.init(&buffer);

    var profile = try ProfiledTest.startWithMemory(@src(), &fba);

    var http_buffer = try fba.allocator().alloc(u8, 4096);
    defer fba.allocator().free(http_buffer);

    const sample_request = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    @memcpy(http_buffer[0..sample_request.len], sample_request);

    profile.endWith(http_buffer);

    try Testing.expect(http_buffer.len == 4096);
}

test "hot reloader file scanning with memory" {
    var buffer: [8192]u8 = undefined;
    var fba = Heap.FixedBufferAllocator.init(&buffer);

    var profile = try ProfiledTest.startWithMemory(@src(), &fba);

    var reloader = HotReloader.init(fba.allocator());
    const latest_mtime = profile.endWithResult(reloader.getLatestMtime());

    try Testing.expect(latest_mtime >= 0);
}

test "hot reloader directory scanning" {
    var buffer: [4096]u8 = undefined;
    var fba = Heap.FixedBufferAllocator.init(&buffer);

    var profile = try ProfiledTest.startWithMemory(@src(), &fba);

    var reloader = HotReloader.init(fba.allocator());
    var latest: i128 = 0;
    profile.endWith(reloader.scanDir("src", &latest));

    try Testing.expect(latest >= 0);
}
