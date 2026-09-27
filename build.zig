const std = @import("std");
const assert = std.debug.assert;
const manifest = @import("languages/manifest.zig");

pub fn build(b: *std.Build) void {
    assert(manifest.entries.len > 0);
    assert(manifest.tables.len > 0);
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{ .name = "zanity", .root_module = module(b, "src/main.zig", target, optimize) });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run zanity").dependOn(&run.step);

    const test_module = module(b, "src/tests.zig", target, optimize);
    const options = b.addOptions();
    options.addOptionPath("zanity", exe.getEmittedBin());
    test_module.addOptions("paths", options);
    const tests = b.addRunArtifact(b.addTest(.{ .root_module = test_module }));
    tests.setCwd(b.path("."));
    tests.has_side_effects = true;
    b.step("test", "Run tests").dependOn(&tests.step);
}

const no_coverage = "-fno-sanitize-coverage=trace-pc-guard,trace-cmp,inline-8bit-counters,pc-table,trace-div,trace-gep,trace-loads,trace-stores";

fn module(b: *std.Build, root: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const adapters = b.createModule(.{
        .root_source_file = b.path("languages/adapters.zig"),
        .target = target,
        .optimize = optimize,
    });
    const mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "adapters", .module = adapters },
            .{ .name = "zrich", .module = b.dependency("zrich", .{ .target = target, .optimize = optimize }).module("zrich") },
            .{ .name = "zcli", .module = b.dependency("zcli", .{ .target = target, .optimize = optimize }).module("zcli") },
        },
    });
    assert(std.mem.endsWith(u8, root, ".zig"));
    assert(std.mem.startsWith(u8, root, "src/"));
    mod.addCSourceFile(.{
        .file = b.path("vendor/tree-sitter/src/lib.c"),
        .flags = &.{ "-std=c11", "-D_POSIX_C_SOURCE=200112L", "-D_DEFAULT_SOURCE", "-D_DARWIN_C_SOURCE", no_coverage },
    });
    mod.addIncludePath(b.path("vendor/tree-sitter/include"));
    mod.addIncludePath(b.path("vendor/tree-sitter/src"));
    for (manifest.entries) |entry| {
        const dir = b.fmt("languages/{s}/grammar", .{entry.name});
        const flags: []const []const u8 = &.{ "-std=c11", "-fno-sanitize=undefined", no_coverage };
        mod.addCSourceFile(.{ .file = b.path(b.fmt("{s}/parser.c", .{dir})), .flags = flags });
        if (entry.scanner) mod.addCSourceFile(.{ .file = b.path(b.fmt("{s}/scanner.c", .{dir})), .flags = flags });
        mod.addIncludePath(b.path(dir));
    }
    return mod;
}
