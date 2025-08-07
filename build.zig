const builtin = @import("builtin");
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &[_][]const u8{
            "html-minifier-terser",
            "src/web/index.html",
            "--collapse-whitespace",
            "--remove-comments",
            "--minify-js",
            "--minify-css",
            "--remove-attribute-quotes",
            "--remove-redundant-attributes",
            "--remove-script-type-attributes",
            "--remove-style-link-type-attributes",
            "--use-short-doctype",
            "-o",
            "src/web/index.min.html",
        },
    }) catch {
        std.log.warn("HTML minification failed, using unminified version\n", .{});
        std.fs.cwd().copyFile("src/web/index.html", std.fs.cwd(), "src/web/index.min.html", .{}) catch {};
        return;
    };
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);

    // Platform definitions
    const platforms = [_]struct {
        target: std.Target.Query,
        folder_name: []const u8,
        use_static: bool = false,
    }{
        .{ .target = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl }, .folder_name = "star-linux", .use_static = true },
        .{ .target = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl }, .folder_name = "star-linux-arm64", .use_static = true },
        .{ .target = .{ .cpu_arch = .x86_64, .os_tag = .macos }, .folder_name = "star-mac-intel" },
        .{ .target = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .folder_name = "star-mac" },
        .{ .target = .{ .cpu_arch = .x86_64, .os_tag = .windows }, .folder_name = "star-win" },
        .{ .target = .{ .cpu_arch = .aarch64, .os_tag = .windows }, .folder_name = "star-win-arm64" },
        .{ .target = .{ .cpu_arch = .wasm32, .os_tag = .freestanding }, .folder_name = "star-web" },

        // iOS targets
        .{ .target = .{ .cpu_arch = .aarch64, .os_tag = .ios }, .folder_name = "star-ios" },
        //.{ .target = .{ .cpu_arch = .x86_64, .os_tag = .ios, .abi = .macabi }, .folder_name = "star-ios-sim-intel" },
        //.{ .target = .{ .cpu_arch = .aarch64, .os_tag = .ios, .abi = .simulator }, .folder_name = "star-ios-sim" },
    };

    const test_step = b.step("test", "Run unit tests");

    // Set debug as default install path
    b.install_path = "debug";

    for (platforms) |platform| {
        const resolved_target = b.resolveTargetQuery(platform.target);
        if (target.result.cpu.arch == resolved_target.result.cpu.arch and
            target.result.os.tag == resolved_target.result.os.tag)
        {
            createPlatformArtifacts(b, platform, target, optimize, test_step, platform.folder_name, b.getInstallStep());
            break;
        }
    }

    // Release step for all platforms
    const release_step = b.step("release", "Build for all platforms");
    const release_install_step = b.step("release-install", "Install release artifacts");

    for (platforms) |platform| {
        const platform_target = b.resolveTargetQuery(platform.target);
        createPlatformArtifacts(b, platform, platform_target, .ReleaseSmall, test_step, b.fmt("../release/{s}", .{platform.folder_name}), release_install_step);
    }

    release_step.dependOn(release_install_step);

    // # Build system testing
    // zig build test --summary all      # Run all tests before committing
    // zig build test --summary failures # Only show failures

    // # Direct file testing
    // zig test runtime/server.zig       # Test specific file before commit (broken for some reason)
    // zig test runtime/runtime.zig      # Test runtime module before commit
}

fn createPlatformArtifacts(
    b: *std.Build,
    platform: anytype,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
    folder_name: []const u8,
    install_step: ?*std.Build.Step,
) void {
    const runtime_module = b.createModule(createModuleOptions(b.path("src/runtime.zig"), target, optimize));

    const exe_module = b.createModule(createModuleOptions(b.path("src/main.zig"), target, optimize));
    exe_module.addImport("runtime", runtime_module);

    const wasm_module = b.createModule(createModuleOptions(b.path("src/wasm.zig"), b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_model = .{ .explicit = &std.Target.wasm.cpu.mvp },
    }), optimize));
    wasm_module.addImport("runtime", runtime_module);

    const exe = b.addExecutable(.{ .name = "star", .root_module = exe_module });
    const wasm = b.addExecutable(.{ .name = "star", .root_module = wasm_module });

    const is_current_platform = target.result.os.tag == builtin.target.os.tag;
    // apparently zig can run tests on different CPU architectures 🤷🏻‍♀️

    const is_ios = platform.target.os_tag == .ios;
    if (is_ios) {
        // Prerequisites:
        // brew install ios-deploy (for ios-sim)
        // brew install libimobiledevice ideviceinstaller (for device communication)

        // Get SDK path
        var sdk_path: []const u8 = undefined;
        if (b.sysroot) |sysroot| {
            sdk_path = sysroot;
        } else {
            const result = std.process.Child.run(.{
                .allocator = b.allocator,
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
            //std.log.info("Using iOS SDK: {s}", .{sdk_path});
        }

        exe.addSystemFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk_path}) });
        exe.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sdk_path}) });
        exe.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk_path}) });

        exe.linkLibC();
        exe.linkFramework("Foundation");
        exe.linkFramework("UIKit");

        const ios_install = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = b.fmt("{s}/StarApp.app", .{folder_name}) } } });

        // install Info.plist from source file
        // TODO: remove this and use embedFile like index.html instead
        const plist_install = b.addInstallFile(b.path("src/ios/Info.plist"), b.fmt("{s}/StarApp.app/Info.plist", .{folder_name}));

        plist_install.step.dependOn(&ios_install.step);

        if (install_step) |step| {
            step.dependOn(&plist_install.step);
        }

        return;
    } else if (is_current_platform) {
        // Only create tests for CURRENT platform
        const test_exe = b.addTest(.{ .root_module = runtime_module });
        if (target.result.os.tag == .windows) {
            const libs = &[_][]const u8{ "ws2_32", "kernel32", "ntdll", "crypt32", "advapi32" };
            for (libs) |lib| {
                exe.linkSystemLibrary(lib);
                test_exe.linkSystemLibrary(lib);
            }
        }
        const test_install = b.addRunArtifact(test_exe);
        test_step.dependOn(&test_install.step);
    } else {
        if (platform.target.os_tag == .windows) {
            const libs = &[_][]const u8{ "ws2_32", "kernel32", "ntdll", "crypt32", "advapi32" };
            for (libs) |lib| {
                exe.linkSystemLibrary(lib);
            }
        }
    }

    // Link-time optimizations
    wasm.link_function_sections = true;
    wasm.link_data_sections = true;
    wasm.link_gc_sections = true;
    wasm.lto = .full;
    wasm.want_lto = true;

    // Strip symbols
    wasm.discard_local_symbols = true;
    wasm.rdynamic = true; // TODO: Don't export all symbols
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
    wasm.initial_memory = 65536 * 1;
    wasm.max_memory = 65536 * 1;
    wasm.global_base = 1024;

    // Stack size
    wasm.stack_size = 16384; // 16KB stack

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

    // TODO: uncomment in the future if we need externref and refextern
    //wasm.addCSourceFile(.{ .file = b.path("src/web/c_bridge.c"), .flags = &[_][]const u8{ "-mreference-types", "-mbulk-memory" } });

    if (platform.use_static) {
        exe.linkage = .static;
        wasm.linkage = .static;
    }

    // Install artifacts
    const exe_install = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = folder_name } } });
    const wasm_install = b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = folder_name } } });

    // Install wasm-opt for automatic optimization:
    //  macOS:   brew install binaryen
    //  Linux:   sudo apt install binaryen
    //  Windows: github.com/WebAssembly/binaryen/releases
    const optimize_wasm = b.addSystemCommand(&.{
        "wasm-opt",
        b.getInstallPath(.{ .custom = folder_name }, "star.wasm"),
        "-Oz",
        "--converge",
        "--dce",
        "-o",
        b.getInstallPath(.{ .custom = folder_name }, "star.wasm"),
    });

    optimize_wasm.step.dependOn(&wasm_install.step);
    optimize_wasm.failing_to_execute_foreign_is_an_error = false;

    if (install_step) |step| {
        step.dependOn(&exe_install.step);
        step.dependOn(&optimize_wasm.step);

        if (platform.target.cpu_arch == .wasm32 or optimize == .Debug) {
            const EmbedStep = struct {
                step: std.Build.Step,
                wasm_path: []const u8,
                output_dir: []const u8,

                pub fn create(builder: *std.Build, wasm_path: []const u8, output_dir: []const u8) *@This() {
                    const self = builder.allocator.create(@This()) catch @panic("OOM");
                    self.* = .{
                        .step = std.Build.Step.init(.{
                            .id = .custom,
                            .name = "embed-wasm",
                            .owner = builder,
                            .makeFn = make,
                        }),
                        .wasm_path = builder.dupe(wasm_path),
                        .output_dir = builder.dupe(output_dir),
                    };
                    return self;
                }

                fn make(s: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
                    const self: *@This() = @fieldParentPtr("step", s);
                    embedWasmInHtml(s.owner, self.wasm_path, self.output_dir);
                }
            };

            const embed = EmbedStep.create(b, b.getInstallPath(.{ .custom = folder_name }, "star.wasm"), b.getInstallPath(.{ .custom = folder_name }, ""));
            embed.step.dependOn(&wasm_install.step);
            step.dependOn(&embed.step);
        }
    }
}

fn createModuleOptions(
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) std.Build.Module.CreateOptions {
    const is_wasm = target.result.cpu.arch.isWasm();
    const is_release = optimize != .Debug;
    const minimal = is_wasm or is_release;

    return .{
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
        .link_libc = if (minimal) false else null,
        .link_libcpp = false,
        .single_threaded = false,
        .strip = minimal,
        .unwind_tables = if (minimal) .none else .sync,
        .dwarf_format = if (minimal) null else .@"64",
        .code_model = if (minimal) .small else .default,
        .stack_protector = false, // Not supported on Mac/Windows
        .stack_check = false, // Not supported on Mac/Windows
        .sanitize_c = if (minimal) .off else .full,
        .sanitize_thread = false, // Not supported on Mac/Windows
        .fuzz = false,
        .valgrind = false,
        .pic = if (is_wasm) false else null,
        .red_zone = if (minimal) false else null,
        .omit_frame_pointer = minimal,
        .error_tracing = !minimal,
        .no_builtin = false,
    };
}

fn embedWasmInHtml(b: *std.Build, wasm_path: []const u8, output_dir: []const u8) void {
    const wasm_data = std.fs.cwd().readFileAlloc(b.allocator, wasm_path, 10_000_000) catch |err| {
        std.log.err("Failed to read WASM file: {}", .{err});
        return;
    };
    defer b.allocator.free(wasm_data);

    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(wasm_data.len);
    const encoded = b.allocator.alloc(u8, encoded_len) catch |err| {
        std.log.err("Failed to allocate for base64: {}", .{err});
        return;
    };
    defer b.allocator.free(encoded);
    _ = encoder.encode(encoded, wasm_data);

    const html = std.fs.cwd().readFileAlloc(b.allocator, "src/web/index.min.html", 10_000_000) catch |err| {
        std.log.err("Failed to read HTML file: {}", .{err});
        return;
    };
    defer b.allocator.free(html);

    const script_start = std.mem.indexOf(u8, html, "<script>") orelse {
        std.log.err("Could not find <script> tag", .{});
        return;
    };

    const new_html = std.fmt.allocPrint(b.allocator, "{s}<script>const EMBEDDED_WASM='{s}';{s}", .{ html[0..script_start], encoded, html[script_start + 8 ..] }) catch |err| {
        std.log.err("Failed to create embedded HTML: {}", .{err});
        return;
    };
    defer b.allocator.free(new_html);

    const output_path = std.fmt.allocPrint(b.allocator, "{s}/index.html", .{output_dir}) catch |err| {
        std.log.err("Failed to format output path: {}", .{err});
        return;
    };
    defer b.allocator.free(output_path);

    const file = std.fs.cwd().createFile(output_path, .{}) catch |err| {
        std.log.err("Failed to create file: {}", .{err});
        return;
    };
    defer file.close();

    file.writeAll(new_html) catch |err| {
        std.log.err("Failed to write embedded HTML: {}", .{err});
        return;
    };

    std.log.info("Created embedded HTML: {s}", .{output_path});
}
