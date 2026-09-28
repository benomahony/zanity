const std = @import("std");
const manifest = @import("languages/manifest.zig");

pub fn build(b: *std.Build) void {
    if (manifest.entries.len == 0) std.debug.panic("languages/manifest.zon lists no languages; zanity needs at least one grammar", .{});
    if (manifest.tables.len == 0) std.debug.panic("languages/tables.zon has no name tables; every ecosystem in manifest.zon needs one", .{});
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

/// Vendored C (tree-sitter and the grammars) is built optimised and without UBSan in every mode:
/// in a Debug build, compiling the queries alone took over a second per language.
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
            .{ .name = "tai", .module = b.dependency("tai", .{ .target = target, .optimize = optimize }).module("tai") },
        },
    });
    if (!std.mem.endsWith(u8, root, ".zig")) std.debug.panic("module root '{s}' is not a .zig file", .{root});
    if (!std.mem.startsWith(u8, root, "src/")) std.debug.panic("module root '{s}' is outside src/; zanity's modules live there", .{root});
    mod.addCSourceFile(.{
        .file = b.path("vendor/tree-sitter/src/lib.c"),
        .flags = &.{ "-std=c11", "-O2", "-fno-sanitize=undefined", "-D_POSIX_C_SOURCE=200112L", "-D_DEFAULT_SOURCE", "-D_DARWIN_C_SOURCE", no_coverage },
    });
    const sqlite = b.dependency("sqlite", .{});
    mod.addCSourceFile(.{
        .file = sqlite.path("sqlite3.c"),
        .flags = &.{ "-O2", "-fno-sanitize=undefined", "-DSQLITE_THREADSAFE=1", "-DSQLITE_ENABLE_MEMSYS5", "-DSQLITE_DEFAULT_MEMSTATUS=0", "-DSQLITE_DQS=0", "-DSQLITE_OMIT_LOAD_EXTENSION", no_coverage },
    });
    mod.addIncludePath(sqlite.path("."));
    mod.addIncludePath(b.path("vendor/tree-sitter/include"));
    mod.addIncludePath(b.path("vendor/tree-sitter/src"));
    for (manifest.entries) |entry| {
        const dir = b.fmt("languages/{s}/grammar", .{entry.name});
        const flags: []const []const u8 = &.{ "-std=c11", "-O2", "-fno-sanitize=undefined", no_coverage };
        mod.addCSourceFile(.{ .file = b.path(b.fmt("{s}/parser.c", .{dir})), .flags = flags });
        if (entry.scanner) mod.addCSourceFile(.{ .file = b.path(b.fmt("{s}/scanner.c", .{dir})), .flags = flags });
        mod.addIncludePath(b.path(dir));
    }
    return mod;
}
