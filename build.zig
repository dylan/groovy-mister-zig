const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // LZ4 dependency
    const lz4_dep = b.dependency("lz4", .{ .target = target, .optimize = optimize });

    // Build options (version string from build.zig.zon)
    const options = b.addOptions();
    options.addOption([]const u8, "version", "0.1.0");

    // Library module (static)
    // Disable stack probing so external (non-Zig) linkers don't need __zig_probe_stack.
    const mod = b.addModule("groovy_mister", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .stack_check = false,
    });
    mod.addImport("lz4", lz4_dep.module("lz4"));
    mod.addOptions("build_options", options);

    // Static library
    const lib = b.addLibrary(.{
        .name = "groovy-mister-zig",
        .linkage = .static,
        .root_module = mod,
    });
    b.installArtifact(lib);

    // Shared library (for dynamic loading / Swift)
    const shared_mod = b.addModule("groovy_mister_shared", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .stack_check = false,
    });
    shared_mod.addImport("lz4", lz4_dep.module("lz4"));
    shared_mod.addOptions("build_options", options);
    const shared_lib = b.addLibrary(.{
        .name = "groovy-mister-zig-shared",
        .linkage = .dynamic,
        .root_module = shared_mod,
    });
    b.installArtifact(shared_lib);

    // Documentation
    const docs = lib.getEmittedDocs();
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs,
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate library documentation");
    docs_step.dependOn(&install_docs.step);

    // Tests
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Cross-compilation targets
    const cross_targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    };

    const cross_step = b.step("cross", "Build for all cross-compilation targets");

    for (cross_targets) |query| {
        const cross_target = b.resolveTargetQuery(query);
        const cross_lz4 = b.dependency("lz4", .{ .target = cross_target, .optimize = optimize });

        const arch = switch (query.cpu_arch.?) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            else => unreachable,
        };
        const os = switch (query.os_tag.?) {
            .linux => "linux",
            .macos => "macos",
            .windows => "windows",
            else => unreachable,
        };
        const prefix = b.fmt("{s}-{s}", .{ arch, os });

        // Static library
        const cross_mod = b.addModule(b.fmt("{s}-static", .{prefix}), .{
            .root_source_file = b.path("src/root.zig"),
            .target = cross_target,
            .optimize = optimize,
            .link_libc = true,
            .stack_check = false,
        });
        cross_mod.addImport("lz4", cross_lz4.module("lz4"));
        cross_mod.addOptions("build_options", options);
        const cross_static = b.addLibrary(.{
            .name = "groovy-mister-zig",
            .linkage = .static,
            .root_module = cross_mod,
        });
        const install_static = b.addInstallArtifact(cross_static, .{
            .dest_sub_path = b.fmt("{s}/lib/libgroovy-mister-zig.a", .{prefix}),
        });
        cross_step.dependOn(&install_static.step);

        // Shared library
        const cross_shared_mod = b.addModule(b.fmt("{s}-shared", .{prefix}), .{
            .root_source_file = b.path("src/root.zig"),
            .target = cross_target,
            .optimize = optimize,
            .link_libc = true,
            .stack_check = false,
        });
        cross_shared_mod.addImport("lz4", cross_lz4.module("lz4"));
        cross_shared_mod.addOptions("build_options", options);
        const cross_shared = b.addLibrary(.{
            .name = "groovy-mister-zig-shared",
            .linkage = .dynamic,
            .root_module = cross_shared_mod,
        });
        const shared_filename = switch (query.os_tag.?) {
            .linux => "libgroovy-mister-zig-shared.so",
            .macos => "libgroovy-mister-zig-shared.dylib",
            .windows => "groovy-mister-zig-shared.dll",
            else => unreachable,
        };
        const is_windows = query.os_tag.? == .windows;
        const install_shared = b.addInstallArtifact(cross_shared, .{
            .dest_dir = .{ .override = .lib },
            .dest_sub_path = b.fmt("{s}/lib/{s}", .{ prefix, shared_filename }),
            .implib_dir = if (is_windows) .{ .override = .{ .custom = b.fmt("lib/{s}/lib", .{prefix}) } } else .default,
            .pdb_dir = if (is_windows) .{ .override = .{ .custom = b.fmt("lib/{s}/lib", .{prefix}) } } else .disabled,
        });
        cross_step.dependOn(&install_shared.step);
    }
}
