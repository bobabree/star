/// ./web/server.zig
const runtime = @import("runtime.zig");

const builtin = runtime.builtin;
const Atomic = runtime.Atomic;
const Fs = runtime.Fs;
const Http = runtime.Http;
const Heap = runtime.Heap;
const Mem = runtime.Mem;
const Net = runtime.Net;
const Process = runtime.Process;
const Thread = runtime.Thread;
const Time = runtime.Time;
const server_log = runtime.Log.server_log;

// Embed HTML
const html_content = runtime.html_content;

pub const HotReloader = struct {
    allocator: Mem.Allocator,
    watch_dirs: []const []const u8,
    rebuild_cmd: []const []const u8,
    should_stop: Atomic.Value(bool),

    pub fn init(allocator: Mem.Allocator) HotReloader {
        return HotReloader{
            .allocator = allocator,
            .watch_dirs = &.{ "web", "src", "runtime" },
            .rebuild_cmd = &.{ "zig", "build" },
            .should_stop = Atomic.Value(bool).init(false),
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
            self.scanDir(dir_name, &latest) catch {};
        }
        return latest;
    }

    fn scanDir(_: *HotReloader, dir_path: []const u8, latest: *i128) !void {
        var dir = Fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and Mem.endsWith(u8, entry.name, ".zig")) {
                const file = dir.openFile(entry.name, .{}) catch continue;
                defer file.close();

                const stat = file.stat() catch continue;
                if (stat.mtime > latest.*) {
                    latest.* = stat.mtime;
                }
            }
        }
    }

    fn rebuild(self: *HotReloader) void {
        server_log.info("🔄 Rebuilding...\n", .{});

        const result = Process.Child.run(.{
            .allocator = self.allocator,
            .argv = self.rebuild_cmd,
        }) catch {
            server_log.err("❌ Build failed\n", .{});
            return;
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term == .Exited and result.term.Exited == 0) {
            server_log.success("✅ Build complete\n", .{});
        } else {
            server_log.err("❌ Build failed: {s}\n", .{result.stderr});
        }
    }
};

pub const Server = struct {
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

        const address = try Net.Address.parseIp4("127.0.0.1", 8080);
        var server = try address.listen(.{ .reuse_address = true });

        server_log.info("🚀 Zig HTTP Server running at http://127.0.0.1:8080\n", .{});
        server_log.info("📁 Serving files from current directory\n", .{});
        server_log.info("🛑 Press Ctrl+C to stop\n\n", .{});

        while (true) {
            const connection = server.accept() catch |err| {
                server_log.err("❌ Error accepting connection: {}\n", .{err});
                continue;
            };

            self.handleConnection(connection) catch |err| {
                server_log.err("❌ Error handling connection: {}\n", .{err});
            };
        }

        server.deinit();
    }

    fn handleConnection(self: Server, connection: Net.Server.Connection) !void {
        defer connection.stream.close();

        var buffer: [4096]u8 = undefined;
        var http_server = Http.Server.init(connection, &buffer);

        var request = http_server.receiveHead() catch |err| {
            server_log.err("❌ Error receiving request head: {}\n", .{err});
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
            server_log.info("📨 {any} {s}\n", .{ request.head.method, target });
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
            server_log.err("❌ Failed to get executable directory\n", .{});
            try serve404(request);
            return;
        };

        const wasm_path = try Fs.path.join(allocator, &.{ exe_dir_path, "star.wasm" });
        defer allocator.free(wasm_path);

        const wasm_data = Fs.cwd().readFileAlloc(allocator, wasm_path, 10_000_000) catch |err| {
            server_log.err("❌ Failed to read WASM file: {}\n", .{err});
            try serve404(request);
            return;
        };
        defer allocator.free(wasm_data);

        const size_mb = @as(f64, @floatFromInt(wasm_data.len)) / (1024.0 * 1024.0);

        try request.respond(wasm_data, .{
            .status = .ok,
            .extra_headers = &[_]Http.Header{
                .{ .name = "content-type", .value = "application/wasm" },
                .{ .name = "cross-origin-embedder-policy", .value = "require-corp" },
                .{ .name = "cross-origin-opener-policy", .value = "same-origin" },
            },
        });

        if (request.head.method != .HEAD) {
            server_log.info("Served WASM ({d:.2} MB)\n", .{size_mb});
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

test "hot reloader initialization with memory" {
    var buffer: [1024]u8 = undefined;
    var fba = Heap.FixedBufferAllocator.init(&buffer);

    var profile = try ProfiledTest.startWithMemory(@src(), &fba);

    const reloader = profile.endWithResult(HotReloader.init(fba.allocator()));

    try Testing.expect(reloader.watch_dirs.len == 3);
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
