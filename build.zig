const builtin = @import("builtin");
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    prepareHtml(b, "", "src/web/index.min.html", false);

    const platforms = [_]PlatformType{
        .linux_x64,
        .linux_arm64,
        .mac_intel,
        .mac_arm,
        .windows_x64,
        .windows_arm64,
        .wasm,
        .ios,
    };

    const test_step = b.step("test", "Run unit tests");
    b.install_path = "debug";

    inline for (platforms) |platform| {
        const resolved_target = platform.resolveTarget(b);
        if (target.result.cpu.arch == resolved_target.result.cpu.arch and
            target.result.os.tag == resolved_target.result.os.tag)
        {
            const options = platform.createBuildOptions(b, optimize, test_step, b.getInstallStep());
            platform.createPlatformArtifacts(options);
            break;
        }
    }

    // Release step for all platforms
    const release_step = b.step("release", "Build for all platforms");
    const release_install_step = b.step("release-install", "Install release artifacts");

    inline for (platforms) |platform| {
        const folder = b.fmt("../release/{s}", .{platform.folderName()});
        var options = platform.createBuildOptions(b, .ReleaseSmall, test_step, release_install_step);
        options.folder_name = folder;
        platform.createPlatformArtifacts(options);
    }

    release_step.dependOn(release_install_step);
}

const PlatformType = enum {
    linux_x64,
    linux_arm64,
    mac_intel,
    mac_arm,
    windows_x64,
    windows_arm64,
    wasm,
    ios,

    pub fn folderName(comptime self: PlatformType) []const u8 {
        return switch (self) {
            .linux_x64 => "star-linux",
            .linux_arm64 => "star-linux-arm64",
            .mac_intel => "star-mac-intel",
            .mac_arm => "star-mac",
            .windows_x64 => "star-win",
            .windows_arm64 => "star-win-arm64",
            .wasm => "star-web",
            .ios => "star-ios",
        };
    }

    pub fn target(comptime self: PlatformType) std.Target.Query {
        return switch (self) {
            .linux_x64 => .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
            .linux_arm64 => .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
            .mac_intel => .{ .cpu_arch = .x86_64, .os_tag = .macos },
            .mac_arm => .{ .cpu_arch = .aarch64, .os_tag = .macos },
            .windows_x64 => .{ .cpu_arch = .x86_64, .os_tag = .windows },
            .windows_arm64 => .{ .cpu_arch = .aarch64, .os_tag = .windows },
            .wasm => .{ .cpu_arch = .wasm32, .os_tag = .freestanding, .cpu_model = .{ .explicit = &std.Target.wasm.cpu.mvp } },
            .ios => .{ .cpu_arch = .aarch64, .os_tag = .ios },
        };
    }

    pub fn resolveTarget(comptime self: PlatformType, b: *std.Build) std.Build.ResolvedTarget {
        return b.resolveTargetQuery(self.target());
    }

    pub fn useStatic(comptime self: PlatformType) bool {
        return switch (self) {
            .linux_x64, .linux_arm64 => true,
            else => false,
        };
    }

    pub fn isWasm(comptime self: PlatformType) bool {
        return self == .wasm;
    }

    pub fn isWindows(comptime self: PlatformType) bool {
        return self == .windows_x64 or self == .windows_arm64;
    }

    pub fn isIOS(comptime self: PlatformType) bool {
        return self == .ios;
    }

    pub fn isCurrentPlatform(comptime self: PlatformType) bool {
        const query = self.target();
        return query.os_tag == builtin.target.os.tag; // Just need OS. Zig can test cross-architecture
    }

    pub fn createPlatformArtifacts(comptime self: PlatformType, options: BuildOptions) void {
        const runtime_module = self.createRuntimeModule(options);
        const wasm = self.createWasmArtifact(options, runtime_module);
        const server = self.createServerArtifact(options, runtime_module);

        self.setupPlatform(options, server, runtime_module);
        self.installArtifacts(options, server, wasm);
    }

    pub fn createModuleOptions(
        comptime self: PlatformType,
        b: *std.Build,
        root_source_file: std.Build.LazyPath,
        optimize: std.builtin.OptimizeMode,
    ) std.Build.Module.CreateOptions {
        const resolved = self.resolveTarget(b);
        const minimal = self.isWasm() or optimize != .Debug;

        return .{
            .root_source_file = root_source_file,
            .target = resolved,
            .optimize = optimize,
            .link_libc = if (minimal) false else null,
            .link_libcpp = false,
            .single_threaded = false,
            .strip = minimal,
            .unwind_tables = if (minimal) .none else .sync,
            .dwarf_format = if (minimal) null else .@"64",
            .code_model = if (minimal) .small else .default,
            .stack_protector = false,
            .stack_check = false,
            .sanitize_c = if (minimal) .off else .full,
            .sanitize_thread = false,
            .fuzz = false,
            .valgrind = false,
            .pic = if (self.isWasm()) false else null,
            .red_zone = if (minimal) false else null,
            .omit_frame_pointer = minimal,
            .error_tracing = !minimal,
            .no_builtin = false,
        };
    }

    pub fn createRuntimeModule(comptime self: PlatformType, options: BuildOptions) *std.Build.Module {
        return options.b.createModule(self.createModuleOptions(
            options.b,
            options.b.path("src/runtime.zig"),
            options.optimize,
        ));
    }

    const BuildOptions = struct {
        b: *std.Build,
        platform: PlatformType,
        optimize: std.builtin.OptimizeMode,
        test_step: *std.Build.Step,
        folder_name: []const u8,
        install_step: ?*std.Build.Step,
    };

    fn createBuildOptions(
        comptime self: PlatformType,
        b: *std.Build,
        optimize: std.builtin.OptimizeMode,
        test_step: *std.Build.Step,
        install_step: ?*std.Build.Step,
    ) BuildOptions {
        return .{
            .b = b,
            .platform = self,
            .optimize = optimize,
            .test_step = test_step,
            .folder_name = self.folderName(),
            .install_step = install_step,
        };
    }

    pub fn createServerArtifact(comptime self: PlatformType, options: BuildOptions, runtime_module: *std.Build.Module) *std.Build.Step.Compile {
        const exe_module = options.b.createModule(self.createModuleOptions(
            options.b,
            options.b.path("src/main.zig"),
            options.optimize,
        ));
        exe_module.addImport("runtime", runtime_module);
        const exe = options.b.addExecutable(.{ .name = "star", .root_module = exe_module });
        if (self.useStatic()) {
            exe.linkage = .static;
        }
        return exe;
    }

    pub fn createWasmArtifact(comptime self: PlatformType, options: BuildOptions, runtime_module: *std.Build.Module) *std.Build.Step.Compile {
        _ = self;

        const wasm_target = PlatformType.wasm;
        const wasm_module = options.b.createModule(wasm_target.createModuleOptions(
            options.b,
            options.b.path("src/wasm.zig"),
            options.optimize,
        ));
        wasm_module.addImport("runtime", runtime_module);
        const wasm = options.b.addExecutable(.{ .name = "star", .root_module = wasm_module });

        // Link-time optimizations
        wasm.link_function_sections = true;
        wasm.link_data_sections = true;
        wasm.link_gc_sections = true;
        wasm.lto = .full;
        wasm.want_lto = true;

        // Strip symbols
        wasm.discard_local_symbols = true;
        wasm.rdynamic = true;
        wasm.dll_export_fns = false;

        // bundlers
        wasm.bundle_compiler_rt = true;
        wasm.bundle_ubsan_rt = false;

        // WASM-specific memory settings
        wasm.import_memory = false;
        wasm.export_memory = false;
        wasm.import_symbols = false;
        wasm.import_table = false;
        wasm.export_table = false;
        wasm.shared_memory = false;
        wasm.initial_memory = 65536 * 34;
        wasm.max_memory = 65536 * 34;
        // wasm.global_base = 1024;

        // // Stack size
        // wasm.stack_size = 16384;

        // Entry point
        wasm.entry = .disabled;

        // Disable unnecessary features
        wasm.link_eh_frame_hdr = false;
        wasm.link_emit_relocs = false;
        wasm.link_z_relro = false;
        wasm.link_z_lazy = true;
        wasm.pie = false;

        // Compression
        wasm.compress_debug_sections = .zstd;

        if (wasm_target.useStatic()) {
            wasm.linkage = .static;
        }

        return wasm;
    }

    pub fn setupPlatform(comptime self: PlatformType, options: BuildOptions, server: *std.Build.Step.Compile, runtime_module: *std.Build.Module) void {
        if (self.isIOS()) {
            self.setupIOS(options, server);
            return;
        }

        if (self.isWindows()) {
            self.linkWindowsLibs(server);
        }

        if (self.isCurrentPlatform()) {
            self.setupTests(options, server, runtime_module);
        }
    }

    fn setupIOS(comptime self: PlatformType, options: BuildOptions, server: *std.Build.Step.Compile) void {
        _ = self;
        var sdk_path: []const u8 = undefined;
        if (options.b.sysroot) |sysroot| {
            sdk_path = sysroot;
        } else {
            const result = std.process.Child.run(.{
                .allocator = options.b.allocator,
                .argv = &.{ "xcrun", "--show-sdk-path", "--sdk", "iphoneos" },
            }) catch |err| {
                std.log.err("Failed to run xcrun: {}", .{err});
                @panic("iOS development requires Xcode Command Line Tools. Run: xcode-select --install");
            };

            if (result.term.Exited != 0) {
                std.log.err("xcrun failed: {s}", .{result.stderr});
                @panic("Could not find iOS SDK. Make sure Xcode Command Line Tools are installed.");
            }

            sdk_path = std.mem.trim(u8, result.stdout, " \n\r\t");
        }

        server.addSystemFrameworkPath(.{ .cwd_relative = options.b.fmt("{s}/System/Library/Frameworks", .{sdk_path}) });
        server.addSystemIncludePath(.{ .cwd_relative = options.b.fmt("{s}/usr/include", .{sdk_path}) });
        server.addLibraryPath(.{ .cwd_relative = options.b.fmt("{s}/usr/lib", .{sdk_path}) });

        server.linkLibC();
        server.linkFramework("Foundation");
        server.linkFramework("UIKit");

        const ios_install = options.b.addInstallArtifact(server, .{ .dest_dir = .{ .override = .{ .custom = options.b.fmt("{s}/StarApp.app", .{options.folder_name}) } } });
        const plist_install = options.b.addInstallFile(options.b.path("src/ios/Info.plist"), options.b.fmt("{s}/StarApp.app/Info.plist", .{options.folder_name}));

        plist_install.step.dependOn(&ios_install.step);

        if (options.install_step) |step| {
            step.dependOn(&plist_install.step);
        }
    }

    fn linkWindowsLibs(comptime self: PlatformType, server: *std.Build.Step.Compile) void {
        _ = self;
        const libs = &[_][]const u8{ "ws2_32", "kernel32", "ntdll", "crypt32", "advapi32" };
        for (libs) |lib| {
            server.linkSystemLibrary(lib);
        }
    }

    fn setupTests(comptime self: PlatformType, options: BuildOptions, server: *std.Build.Step.Compile, runtime_module: *std.Build.Module) void {
        const test_exe = options.b.addTest(.{ .root_module = runtime_module });
        if (self.isWindows()) {
            self.linkWindowsLibs(server);
            self.linkWindowsLibs(test_exe);
        }
        const test_install = options.b.addRunArtifact(test_exe);
        options.test_step.dependOn(&test_install.step);
    }

    pub fn installArtifacts(comptime self: PlatformType, options: BuildOptions, server: *std.Build.Step.Compile, wasm: *std.Build.Step.Compile) void {
        if (self.isIOS()) return; // iOS install handled in setupIOS

        // Install the primary artifact for this platform
        const primary_artifact = if (self.isWasm()) wasm else server;
        self.installNativePlatform(options, primary_artifact);

        // Process wasm
        self.installWasmPlatform(options, wasm, primary_artifact);
    }

    fn installNativePlatform(comptime self: PlatformType, options: BuildOptions, artifact: *std.Build.Step.Compile) void {
        _ = self;
        const install = options.b.addInstallArtifact(artifact, .{ .dest_dir = .{ .override = .{ .custom = options.folder_name } } });
        if (options.install_step) |step| {
            step.dependOn(&install.step);
        }
    }

    fn installWasmPlatform(comptime self: PlatformType, options: BuildOptions, wasm: *std.Build.Step.Compile, primary_artifact: *std.Build.Step.Compile) void {
        const wasm_install = if (self.isWasm())
            options.b.addInstallArtifact(primary_artifact, .{ .dest_dir = .{ .override = .{ .custom = options.folder_name } } })
        else
            options.b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = options.folder_name } } });

        const optimized_wasm = self.optimizeWasm(options, &wasm_install.step);

        if (options.install_step) |step| {
            step.dependOn(optimized_wasm);

            if (self.isWasm() or options.optimize == .Debug) {
                self.embedWasmInHtml(options, optimized_wasm);
            }
        }
    }

    fn optimizeWasm(comptime self: PlatformType, options: BuildOptions, wasm_install: *std.Build.Step) *std.Build.Step {
        _ = self;
        // Skip in debug mode
        if (options.optimize == .Debug) {
            return wasm_install;
        }

        const cmd = options.b.addSystemCommand(&.{
            "wasm-opt",
            options.b.getInstallPath(.{ .custom = options.folder_name }, "star.wasm"),
            "-Oz",
            "--converge",
            "--dce",
            "-o",
            options.b.getInstallPath(.{ .custom = options.folder_name }, "star.wasm"),
        });
        cmd.step.dependOn(wasm_install);
        cmd.failing_to_execute_foreign_is_an_error = false;
        return &cmd.step;
    }

    fn embedWasmInHtml(comptime self: PlatformType, options: BuildOptions, optimized_wasm: *std.Build.Step) void {
        _ = self;
        const EmbedStep = struct {
            step: std.Build.Step,
            wasm_path: []const u8,
            output_dir: []const u8,

            pub fn create(builder: *std.Build, wasm_path: []const u8, output_dir: []const u8) *@This() {
                const s = builder.allocator.create(@This()) catch @panic("OOM");
                s.* = .{
                    .step = std.Build.Step.init(.{
                        .id = .custom,
                        .name = "embed-wasm",
                        .owner = builder,
                        .makeFn = make,
                    }),
                    .wasm_path = builder.dupe(wasm_path),
                    .output_dir = builder.dupe(output_dir),
                };
                return s;
            }

            fn make(s: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
                const es: *@This() = @fieldParentPtr("step", s);
                // Verify file exists and has reasonable size
                const file = std.fs.cwd().openFile(es.wasm_path, .{}) catch |err| {
                    std.log.err("Cannot open WASM file: {}", .{err});
                    return err;
                };
                defer file.close();

                const stat = try file.stat();
                if (stat.size < 5000) { // IMPORTANT: WASM corruption
                    std.log.err("WASM file too small: {} bytes", .{stat.size});
                    return error.CorruptedWasm;
                }
                prepareHtml(s.owner, es.wasm_path, es.output_dir, true);
            }
        };

        const embed = EmbedStep.create(
            options.b,
            options.b.getInstallPath(.{ .custom = options.folder_name }, "star.wasm"),
            options.b.getInstallPath(.{ .custom = options.folder_name }, "index.html"),
        );
        embed.step.dependOn(optimized_wasm);

        if (options.optimize != .Debug) {
            const copy_to_docs = options.b.addSystemCommand(&.{
                "cp",
                options.b.getInstallPath(.{ .custom = options.folder_name }, "index.html"),
                "docs/index.html",
            });
            copy_to_docs.step.dependOn(&embed.step);
            options.install_step.?.dependOn(&copy_to_docs.step);
        } else {
            options.install_step.?.dependOn(&embed.step);
        }
    }
};

// Helper functions
fn readFile(allocator: std.mem.Allocator, path: []const u8, max_size: usize) ?[]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, max_size) catch |err| {
        std.log.err("Failed to read {s}: {}\n", .{ path, err });
        return null;
    };
}

fn replaceString(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ?[]u8 {
    return std.mem.replaceOwned(u8, allocator, haystack, needle, replacement) catch |err| {
        std.log.err("Failed to replace '{s}': {}\n", .{ needle, err });
        return null;
    };
}

fn formatString(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ?[]u8 {
    return std.fmt.allocPrint(allocator, fmt, args) catch |err| {
        std.log.err("Failed to format string: {}\n", .{err});
        return null;
    };
}

fn writeFile(path: []const u8, data: []const u8) void {
    const file = std.fs.cwd().createFile(path, .{}) catch |err| {
        std.log.err("Failed to create {s}: {}\n", .{ path, err });
        return;
    };
    defer file.close();

    file.writeAll(data) catch |err| {
        std.log.err("Failed to write {s}: {}\n", .{ path, err });
    };
}

fn pipeThrough(allocator: std.mem.Allocator, argv: []const []const u8, input: []const u8) ?[]u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;

    child.spawn() catch |err| {
        std.log.err("Failed to spawn {s}: {}\n", .{ argv[0], err });
        return null;
    };

    child.stdin.?.writeAll(input) catch |err| {
        std.log.err("Failed to write to {s}: {}\n", .{ argv[0], err });
    };
    child.stdin.?.close();

    const output = child.stdout.?.readToEndAlloc(allocator, 10_000_000) catch |err| {
        std.log.err("Failed to read from {s}: {}\n", .{ argv[0], err });
        return null;
    };

    return output;
}

fn compressLib(b: *std.Build, lib_content: []const u8) []const u8 {
    var compressed = std.ArrayList(u8).init(b.allocator);
    defer compressed.deinit();

    var stream = std.io.fixedBufferStream(lib_content);
    const reader = stream.reader();
    const writer = compressed.writer();

    std.compress.zlib.compress(reader, writer, .{ .level = .best }) catch @panic("Failed to compress");

    return b.allocator.dupe(u8, compressed.items) catch @panic("OOM");
}

fn prepareHtml(b: *std.Build, wasm_path: []const u8, output_path: []const u8, embed_wasm: bool) void {
    const html = @embedFile("src/web/index.html");
    const js_lib_obj = @embedFile("src/web/js.o");
    const encoder = std.base64.standard.Encoder;

    // Compress js and save to js.lib
    const js_lib = compressLib(b, js_lib_obj);
    writeFile("src/runtime/js.lib", js_lib);

    // <js.lib />
    var final = replaceString(b.allocator, html, "<js.lib />", "") orelse return;

    // <wasm.lib />
    if (embed_wasm) {
        const wasm_data = readFile(b.allocator, wasm_path, 10_000_000) orelse return;
        const wasm_encoded = b.allocator.alloc(u8, encoder.calcSize(wasm_data.len)) catch return;
        _ = encoder.encode(wasm_encoded, wasm_data);

        const wasm_embedded = formatString(b.allocator, "<script>const EMBEDDED_WASM='{s}';</script>", .{wasm_encoded}) orelse return;
        final = replaceString(b.allocator, final, "<wasm.lib />", wasm_embedded) orelse return;
    } else {
        final = replaceString(b.allocator, final, "<wasm.lib />", "") orelse return;
    }

    // Skip minification in debug
    if (builtin.mode == .Debug) {
        writeFile(output_path, final);
        return;
    }

    // Minify
    const minified = pipeThrough(b.allocator, &.{
        "html-minifier-terser",
        "--collapse-whitespace",
        "--remove-comments",
        "--minify-js",
        "--minify-css",
        "--remove-attribute-quotes",
        "--remove-redundant-attributes",
        "--remove-script-type-attributes",
        "--remove-style-link-type-attributes",
        "--use-short-doctype",
    }, final) orelse {
        writeFile(output_path, final);
        return;
    };
    writeFile(output_path, minified);
}
