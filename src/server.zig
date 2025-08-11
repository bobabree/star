/// ./web/server.zig
const runtime = @import("runtime.zig");

const builtin = runtime.builtin;
const Atomic = runtime.Atomic;
const Debug = runtime.Debug;
const Fmt = runtime.Fmt;
const Fs = runtime.Fs;
const FsPath = runtime.FsPath;
const Http = runtime.Http;
const Heap = runtime.Heap;
const Mem = runtime.Mem;
const Net = runtime.Net;
const OS = runtime.OS;
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
    file_hashes: @import("std").StringHashMap(u64),

    pub fn init(allocator: Mem.Allocator) HotReloader {
        const files_requiring_restart = [_][]const u8{
            "src/server.zig",
            "src/web/index.html",
            "src/web/js.o",
        };

        var initial_mtime: i128 = 0;
        for (files_requiring_restart) |path| {
            const file = Fs.cwd().openFile(path, .{}) catch continue;
            defer file.close();
            const stat = file.stat() catch continue;
            if (stat.mtime > initial_mtime) {
                initial_mtime = stat.mtime;
            }
        }

        // Determine rebuild command based on build mode
        const rebuild_cmd = if (builtin.mode == .Debug)
            &[_][]const u8{ "zig", "build" }
        else
            &[_][]const u8{ "zig", "build", "release" };

        return HotReloader{
            .allocator = allocator,
            .watch_dirs = &.{"src"},
            .rebuild_cmd = rebuild_cmd,
            .should_stop = Atomic.Value(bool).init(false),
            .last_server_mtime = initial_mtime,
            .file_hashes = @import("std").StringHashMap(u64).init(allocator),
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
        while (!self.should_stop.load(.acquire)) {
            var changed = false;
            for (self.watch_dirs) |dir_name| {
                self.scanDir(dir_name, &changed) catch |err| {
                    Debug.server.warn("Failed to scan {s}: {}", .{ dir_name, err });
                };
            }

            if (changed) {
                self.rebuild();
            }

            Thread.sleep(Time.ns_per_s / 2);
        }
    }

    fn hasChanges(self: *HotReloader) bool {
        var changed = false;

        for (self.watch_dirs) |dir_name| {
            self.scanDir(dir_name, &changed) catch |err| {
                Debug.server.warn("Failed to scan {s}: {}", .{ dir_name, err });
            };
        }

        return changed;
    }

    fn scanDir(self: *HotReloader, dir_path: []const u8, changed: *bool) !void {
        var dir = Fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            Debug.server.warn("Cannot open dir {s}: {}", .{ dir_path, err });
            return;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file) {
                // Skip generated files first
                if (Mem.endsWith(u8, entry.name, ".lib") or
                    Mem.endsWith(u8, entry.name, ".min.html")) continue;

                // Then check extensions
                if (!Mem.endsWith(u8, entry.name, ".zig") and
                    !Mem.endsWith(u8, entry.name, ".cpp") and
                    !Mem.endsWith(u8, entry.name, ".c") and
                    !Mem.endsWith(u8, entry.name, ".html") and
                    !Mem.endsWith(u8, entry.name, ".o")) continue;

                const file = dir.openFile(entry.name, .{}) catch |err| {
                    Debug.server.warn("Cannot open file {s}: {}", .{ entry.name, err });
                    continue;
                };
                defer file.close();

                // Read and hash content
                const content = file.readToEndAlloc(self.allocator, 10_000_000) catch |err| {
                    Debug.server.warn("Cannot read {s}: {}", .{ entry.name, err });
                    continue;
                };
                defer self.allocator.free(content);

                const hash = @import("std").hash.Wyhash.hash(0, content);

                // Build full path for hash map key
                var path_buf: [Fs.max_path_bytes]u8 = undefined;
                const full_path = Fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch |err| {
                    Debug.server.warn("Path format failed {s}/{s}: {}", .{ dir_path, entry.name, err });
                    continue;
                };

                // Check if hash changed
                if (self.file_hashes.get(full_path)) |old_hash| {
                    if (old_hash != hash) {
                        Debug.server.info("📝 Content changed: {s}", .{full_path});
                        const key = self.allocator.dupe(u8, full_path) catch continue;
                        self.file_hashes.put(key, hash) catch continue;
                        changed.* = true;
                    }
                } else {
                    // New file or first scan
                    const key = self.allocator.dupe(u8, full_path) catch continue;
                    self.file_hashes.put(key, hash) catch continue;
                    changed.* = true;
                }
            } else if (entry.kind == .directory) {
                var path_buf: [Fs.max_path_bytes]u8 = undefined;
                const sub_path = FsPath.join(&path_buf, &.{ dir_path, entry.name }) catch |err| {
                    Debug.server.warn("Path too long for {s}/{s}: {}", .{ dir_path, entry.name, err });
                    continue;
                };

                self.scanDir(sub_path, changed) catch |err| {
                    Debug.server.warn("Failed to scan subdir {s}: {}", .{ sub_path, err });
                };
            }
        }
    }

    fn rebuild(self: *HotReloader) void {
        Debug.server.info("🔄 Rebuilding...", .{});

        var child = Process.Child.init(self.rebuild_cmd, self.allocator);

        const term = child.spawnAndWait() catch |err| {
            Debug.server.err("❌ Build failed: {}", .{err});
            return;
        };

        if (term == .Exited and term.Exited == 0) {
            Debug.server.success("✅ Build completed", .{});

            // Check if any file requiring restart was modified
            const files_requiring_restart = [_][]const u8{
                "src/server.zig",
                "src/web/index.html",
                "src/web/js.o",
            };

            var needs_restart = false;
            for (files_requiring_restart) |path| {
                const file = Fs.cwd().openFile(path, .{}) catch continue;
                defer file.close();
                const stat = file.stat() catch continue;

                if (stat.mtime > self.last_server_mtime) {
                    Debug.server.info("📝 {s} changed", .{path});
                    needs_restart = true;
                    break;
                }
            }

            if (needs_restart) {
                Debug.server.info("🔄 Restarting server...", .{});
                Process.restartSelf(self.allocator) catch |err| {
                    Debug.server.err("❌ Failed to restart: {}", .{err});
                };
                self.last_server_mtime = Time.timestamp(); // Update to current time
            }
        } else {
            Debug.server.err("❌ Build failed with exit code: {}", .{term.Exited});
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
