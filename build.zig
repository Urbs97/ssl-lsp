const std = @import("std");

const sslc_sources: []const []const u8 = &.{
    "compile.c",
    "parse.c",
    "parselib.c",
    "extra.c",
    "gencode.c",
    "lex.c",
    "parseext.c",
    "mcpp_main.c",
    "mcpp_directive.c",
    "mcpp_eval.c",
    "mcpp_expand.c",
    "mcpp_support.c",
    "mcpp_system.c",
    "optimize.c",
    "compat.c",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .x86,
            .os_tag = .linux,
            .abi = .gnu,
        },
    });
    const optimize = b.standardOptimizeOption(.{});

    // Build libparser as a static C library from the sslc submodule
    const libparser = b.addLibrary(.{
        .linkage = .static,
        .name = "parser",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    libparser.addCSourceFiles(.{
        .root = b.path("sslc"),
        .files = sslc_sources,
        .flags = &.{"-DBUILDING_DLL"},
    });
    libparser.addIncludePath(b.path("sslc"));

    const exe = b.addExecutable(.{
        .name = "ssl-lsp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.addIncludePath(b.path("sslc"));
    exe.linkLibrary(libparser);
    exe.linkLibC();

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe_tests.addIncludePath(b.path("sslc"));
    exe_tests.linkLibrary(libparser);
    exe_tests.linkLibC();

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
