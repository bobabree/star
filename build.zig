const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
        .{ .target = .{ .cpu_arch = .wasm32, .os_tag = .freestanding }, .folder_name = "star-wasm" },
        .{ .target = .{ .cpu_arch = .wasm32, .os_tag = .wasi, .abi = .musl }, .folder_name = "star-wasi" },
    };

    // Create runtime module (no dependencies)
    const runtime_module = b.createModule(.{
        .root_source_file = b.path("src/runtime.zig"),
        .target = target,
    });

    // Set debug as default install path
    b.install_path = "debug";

    for (platforms) |platform| {
        const resolved_target = b.resolveTargetQuery(platform.target);
        if (target.result.cpu.arch == resolved_target.result.cpu.arch and
            target.result.os.tag == resolved_target.result.os.tag)
        {
            const exe = b.addExecutable(.{
                .name = "star",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/main.zig"),
                    .target = target,
                    .optimize = optimize,
                }),
            });

            exe.root_module.addImport("runtime", runtime_module);

            // Add Windows libraries
            if (platform.target.os_tag == .windows) {
                exe.linkSystemLibrary("ws2_32"); // Sockets
                exe.linkSystemLibrary("kernel32"); // Core Windows API
                exe.linkSystemLibrary("ntdll"); // NT system calls
                exe.linkSystemLibrary("crypt32"); // Certificate store
                exe.linkSystemLibrary("advapi32"); // Advanced Windows API (includes RtlGenRandom)
            }

            exe.root_module.sanitize_c = true; // AddressSanitizer + UBSan + LeakSanitizer
            //exe.root_module.stack_protector = true; // TODO: Window needs libc. Stack canaries to detect buffer overflows
            exe.root_module.error_tracing = true; // Enhanced error stack traces
            exe.root_module.single_threaded = false; // Single-threaded optimizations
            exe.root_module.strip = true; // Keep debug symbols
            exe.root_module.unwind_tables = .sync; // Exception handling tables
            if (platform.use_static) {
                exe.linkage = .static;
            }

            const debug_install = b.addInstallArtifact(exe, .{
                .dest_dir = .{ .override = .{ .custom = b.fmt("./{s}", .{platform.folder_name}) } },
            });

            // Add WASM build for debug
            const debug_wasm_target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
                .cpu_features_add = std.Target.wasm.featureSet(&[_]std.Target.wasm.Feature{
                    .reference_types,
                    .bulk_memory,
                }),
            });

            const debug_wasm = b.addExecutable(.{
                .name = "star",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/wasm.zig"),
                    .target = debug_wasm_target,
                    .optimize = optimize,
                }),
            });

            debug_wasm.rdynamic = true;
            debug_wasm.root_module.addImport("runtime", runtime_module);
            debug_wasm.addCSourceFile(.{ .file = b.path("src/c_bridge.c"), .flags = &[_][]const u8{ "-mreference-types", "-mbulk-memory" } });

            const debug_wasm_install = b.addInstallArtifact(debug_wasm, .{
                .dest_dir = .{ .override = .{ .custom = b.fmt("./{s}", .{platform.folder_name}) } },
            });

            // const debug_star_json_install = b.addInstallFile(b.pfsath("star.json"), b.fmt("{s}/workspace/star/star.json", .{platform.folder_name}));
            // debug_star_json_install.step.dependOn(&debug_install.step);

            // Only copy star.global.json, not the entire runtime directory
            // const debug_star_global_json_install = b.addInstallFile(b.path("runtime/star.global.json"), b.fmt("{s}/workspace/runtime/star.global.json", .{platform.folder_name}));
            // debug_star_global_json_install.step.dependOn(&debug_install.step);

            b.getInstallStep().dependOn(&debug_install.step);
            b.getInstallStep().dependOn(&debug_wasm_install.step);
            //b.getInstallStep().dependOn(&debug_star_json_install.step);
            //b.getInstallStep().dependOn(&debug_star_global_json_install.step);
            break;
        }
    }

    // Release step for all platforms
    const release_step = b.step("release", "Build for all platforms");
    const release_install_step = b.step("release-install", "Install release artifacts");

    for (platforms) |platform| {
        const platform_target = b.resolveTargetQuery(platform.target);

        const platform_exe = b.addExecutable(.{
            .name = "star",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = platform_target,
                .optimize = .ReleaseSmall,
            }),
        });

        platform_exe.root_module.addImport("runtime", runtime_module);

        // Add Windows libraries
        if (platform.target.os_tag == .windows) {
            platform_exe.linkSystemLibrary("ws2_32"); // Sockets
            platform_exe.linkSystemLibrary("kernel32"); // Core Windows API
            platform_exe.linkSystemLibrary("ntdll"); // NT system calls
            platform_exe.linkSystemLibrary("crypt32"); // Certificate store
            platform_exe.linkSystemLibrary("advapi32"); // Advanced Windows API (includes RtlGenRandom)
        }

        platform_exe.root_module.strip = true; // Smaller binaries

        if (platform.use_static) {
            platform_exe.linkage = .static;
        }

        const release_install = b.addInstallArtifact(platform_exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("../release/{s}", .{platform.folder_name}) } },
        });

        // Add WASM build for release
        const release_wasm_target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
            .cpu_features_add = std.Target.wasm.featureSet(&[_]std.Target.wasm.Feature{
                .reference_types,
                .bulk_memory,
            }),
        });

        const release_wasm = b.addExecutable(.{
            .name = "star",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/wasm.zig"),
                .target = release_wasm_target,
                .optimize = .ReleaseSmall,
            }),
        });

        release_wasm.rdynamic = true;
        release_wasm.root_module.addImport("runtime", runtime_module);
        release_wasm.addCSourceFile(.{ .file = b.path("src/c_bridge.c"), .flags = &[_][]const u8{ "-mreference-types", "-mbulk-memory" } });

        const release_wasm_install = b.addInstallArtifact(release_wasm, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("../release/{s}", .{platform.folder_name}) } },
        });

        // const release_star_json_install = b.addInstallFile(b.path("star.json"), b.fmt("../release/{s}/workspace/star/star.json", .{platform.folder_name}));
        // release_star_json_install.step.dependOn(&release_install.step);

        // // Only copy star.global.json
        // const release_star_global_json_install = b.addInstallFile(b.path("runtime/star.global.json"), b.fmt("../release/{s}/workspace/runtime/star.global.json", .{platform.folder_name}));
        // release_star_global_json_install.step.dependOn(&release_install.step);

        release_install_step.dependOn(&release_install.step);
        release_install_step.dependOn(&release_wasm_install.step);
        // release_install_step.dependOn(&release_star_json_install.step);
        // release_install_step.dependOn(&release_star_global_json_install.step);
    }

    release_step.dependOn(release_install_step);

    // # Build system testing
    // zig build test                    # Run all tests before
    // zig build test --summary all      # Detailed build info
    // zig build test --summary failures # Only show failures
    // zig build test -j1                # Single-threaded testing

    // # Direct file testing
    // zig test runtime/server.zig       # Test specific file before commit
    // zig test runtime/runtime.zig      # Test runtime module before commit

    const test_step = b.step("test", "Run unit tests");

    const test_modules = [_]struct {
        path: []const u8,
        imports: []const struct { name: []const u8, module: *std.Build.Module } = &.{},
    }{
        .{ .path = "src/runtime.zig" },
    };

    for (test_modules) |test_mod| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_mod.path),
                .target = target,
                .optimize = optimize,
            }),
        });

        // Add imports
        for (test_mod.imports) |import| {
            unit_tests.root_module.addImport(import.name, import.module);
        }

        const run_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_tests.step);
    }
}
