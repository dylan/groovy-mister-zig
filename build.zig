const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module (static)
    const mod = b.addModule("groovy_mister", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Static library
    const lib = b.addLibrary(.{
        .name = "groovy-mister",
        .linkage = .static,
        .root_module = mod,
    });
    b.installArtifact(lib);

    // Shared library (for dynamic loading / Swift)
    const shared_mod = b.addModule("groovy_mister_shared", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const shared_lib = b.addLibrary(.{
        .name = "groovy-mister-shared",
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
}
