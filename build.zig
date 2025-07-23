const builtin = @import("builtin");
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
        // TODO: .{ .target = .{ .cpu_arch = .wasm32, .os_tag = .wasi, .abi = .musl }, .folder_name = "star-wasi" },
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
    // zig build test -j1                # Single-threaded testing

    // # Direct file testing
    // zig test runtime/server.zig       # Test specific file before commit (broken for some reason)
    // zig test runtime/runtime.zig      # Test runtime module before commit

    //
    // const runtime_module = b.createModule(.{
    //     .root_source_file = b.path("src/runtime.zig"),
    //     .target = target,
    //     .optimize = optimize,
    //     .sanitize_c = true, // AddressSanitizer + UBSan + LeakSanitizer
    //     .stack_protector = true, // TODO: Window needs libc for this. WASM does not need stack protector. Stack canaries to detect buffer overflows
    //     .error_tracing = true, // Enhanced error stack traces
    //     .single_threaded = false, // no single-threaded
    //     .strip = false, // Keep debug symbols
    //     .unwind_tables = .sync, // Exception handling tables
    //     .linkage = .static if platform.use_static
    // });
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
    // Create runtime module (no dependencies)
    const runtime_module = b.createModule(.{
        .root_source_file = b.path("src/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = optimize == .Debug,
        .error_tracing = optimize == .Debug,
        .single_threaded = false,
        .strip = optimize != .Debug, // Strip for release builds
        .unwind_tables = .sync,
    });

    const web_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = optimize == .Debug,
        .error_tracing = optimize == .Debug,
        .single_threaded = false,
        .strip = optimize != .Debug,
        .unwind_tables = .sync,
        .imports = &.{
            .{ .name = "runtime", .module = runtime_module },
        },
    });

    const wasm_module = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
            .cpu_features_add = std.Target.wasm.featureSet(&[_]std.Target.wasm.Feature{
                .reference_types,
                .bulk_memory,
            }),
        }),
        .optimize = optimize,
        .sanitize_c = optimize == .Debug, // Only for debug
        .error_tracing = optimize == .Debug,
        .single_threaded = false,
        .strip = optimize != .Debug,
        .unwind_tables = .sync,
        .imports = &.{
            .{ .name = "runtime", .module = runtime_module },
        },
    });

    const web_exe = b.addExecutable(.{ .name = "star", .root_module = web_module });
    const web_wasm = b.addExecutable(.{ .name = "star", .root_module = wasm_module });

    const is_current_platform = target.result.os.tag == builtin.target.os.tag;
    // and target.result.cpu.arch == builtin.target.cpu.arch;
    // apparently zig can run tests on different CPU architectures 🤷🏻‍♀️
    // const is_wasm = target.result.cpu.arch != .wasm32;

    if (is_current_platform) {
        // Only create tests for CURRENT platform
        const test_exe = b.addTest(.{ .root_module = runtime_module });
        if (target.result.os.tag == .windows) {
            const libs = &[_][]const u8{ "ws2_32", "kernel32", "ntdll", "crypt32", "advapi32" };
            for (libs) |lib| {
                web_exe.linkSystemLibrary(lib);
                test_exe.linkSystemLibrary(lib);
            }
        }
        const test_install = b.addRunArtifact(test_exe);
        test_step.dependOn(&test_install.step);
    } else {
        if (platform.target.os_tag == .windows) {
            const libs = &[_][]const u8{ "ws2_32", "kernel32", "ntdll", "crypt32", "advapi32" };
            for (libs) |lib| {
                web_exe.linkSystemLibrary(lib);
            }
        }
    }

    // WASM-specific setup
    web_wasm.rdynamic = true;
    web_wasm.addCSourceFile(.{ .file = b.path("src/c_bridge.c"), .flags = &[_][]const u8{ "-mreference-types", "-mbulk-memory" } });

    if (platform.use_static) {
        web_exe.linkage = .static;
        web_wasm.linkage = .static;
    }

    // Install artifacts
    const web_install = b.addInstallArtifact(web_exe, .{ .dest_dir = .{ .override = .{ .custom = folder_name } } });
    const wasm_install = b.addInstallArtifact(web_wasm, .{ .dest_dir = .{ .override = .{ .custom = folder_name } } });

    if (install_step) |step| {
        step.dependOn(&web_install.step);
        step.dependOn(&wasm_install.step);
    }
}
