const std = @import("std");
const manifest = @import("languages/manifest.zig");

pub fn build(b: *std.Build) void {
    if (manifest.entries.len == 0) std.debug.panic("languages/manifest.zon lists no languages; zanity needs at least one grammar", .{});
    if (manifest.tables.len == 0) std.debug.panic("languages/tables.zon has no name tables; every ecosystem in manifest.zon needs one", .{});
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(bool, "strip", "Leave debug info out of the binary, as release builds do") orelse false;
    // The release workflow passes the version it is about to tag; any other build is a dev build.
    const version = b.option([]const u8, "version", "The version zanity --version reports, as a release sets it") orelse "dev";

    const exe = b.addExecutable(.{ .name = "zanity", .root_module = module(b, "src/main.zig", target, optimize) });
    exe.root_module.strip = strip;
    const build_info = b.addOptions();
    build_info.addOption([]const u8, "version", version);
    exe.root_module.addOptions("build_info", build_info);
    b.installArtifact(exe);

    addRelease(b, build_info);

    // `zig build schema` writes zanity.schema.json from the rules and limits in the code.
    const schema = b.addExecutable(.{ .name = "schema", .root_module = module(b, "src/schema.zig", b.graph.host, .Debug) });
    const write_schema = b.addUpdateSourceFiles();
    write_schema.addCopyFileToSource(b.addRunArtifact(schema).captureStdOut(.{}), "zanity.schema.json");
    b.step("schema", "Write zanity.schema.json, the schema editors check zanity.toml against").dependOn(&write_schema.step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run zanity").dependOn(&run.step);

    // `zig build bench` always measures optimised builds: a Debug zanity fills its buffers and
    // keeps every safety check, so its timings say nothing about a release.
    const bench = b.addRunArtifact(b.addExecutable(.{ .name = "bench", .root_module = module(b, "src/bench.zig", b.graph.host, .ReleaseFast) }));
    const fast = b.addExecutable(.{ .name = "zanity", .root_module = module(b, "src/main.zig", b.graph.host, .ReleaseFast) });
    fast.root_module.addOptions("build_info", build_info);
    bench.addArtifactArg(fast);
    bench.addArg(b.graph.zig_exe);
    if (b.option([]const u8, "corpus", "The directory zig build bench checks; Zig's standard library by default")) |corpus| bench.addArg(corpus);
    bench.has_side_effects = true;
    b.step("bench", "Time zanity check against the fastest this machine could parse the corpus").dependOn(&bench.step);

    // `zig build test` is the fast loop: the code's own tests, with no zanity binary to build.
    const unit = b.addRunArtifact(b.addTest(.{ .root_module = module(b, "src/tests.zig", target, optimize) }));
    unit.setCwd(b.path("."));
    unit.has_side_effects = true;
    b.step("test", "Run the unit tests").dependOn(&unit.step);

    // `zig build test-integration` runs the built zanity: the golden fixtures, the CLI, and
    // zanity checking its own source, which must pass every rule.
    const integration_module = module(b, "src/golden_test.zig", target, optimize);
    const options = b.addOptions();
    options.addOptionPath("zanity", exe.getEmittedBin());
    integration_module.addOptions("paths", options);
    const integration = b.addRunArtifact(b.addTest(.{ .root_module = integration_module }));
    integration.setCwd(b.path("."));
    integration.has_side_effects = true;
    b.step("test-integration", "Run the built zanity end to end, on the golden fixtures and on its own source").dependOn(&integration.step);
}

/// The platforms a release ships for. Linux builds link musl statically, so one binary runs on
/// any distribution.
const release_targets = [_]struct { name: []const u8, query: std.Target.Query }{
    .{ .name = "linux-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl } },
    .{ .name = "linux-aarch64", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl } },
    .{ .name = "macos-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
    .{ .name = "macos-aarch64", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
    .{ .name = "windows-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows } },
};

/// `zig build release`: a stripped ReleaseSafe binary for every platform in release_targets, in
/// zig-out/release as zanity-<os>-<arch>. The names carry no version, so the latest release always
/// has the same download URLs. ReleaseSafe keeps bounds and overflow checks, so a bug stops with a
/// message instead of silently checking the wrong thing.
fn addRelease(b: *std.Build, build_info: *std.Build.Step.Options) void {
    const release = b.step("release", "Build every released platform into zig-out/release");
    for (release_targets) |platform| {
        const target = b.resolveTargetQuery(platform.query);
        const resolved = target.result;
        const os = @tagName(resolved.os.tag);
        if (!std.mem.startsWith(u8, platform.name, os)) std.debug.panic("the release platform '{s}' builds for {s}, so its download would be misnamed; start its name in release_targets with '{s}-'", .{ platform.name, os, os });
        const exe = b.addExecutable(.{ .name = "zanity", .root_module = module(b, "src/main.zig", target, .ReleaseSafe) });
        exe.root_module.strip = true;
        exe.root_module.addOptions("build_info", build_info);
        const install = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = "release" } },
            .dest_sub_path = b.fmt("zanity-{s}{s}", .{ platform.name, target.result.exeFileExt() }),
            .pdb_dir = .disabled,
        });
        release.dependOn(&install.step);
    }
    const installs = release.dependencies.items;
    if (installs.len != release_targets.len) std.debug.panic("the release step builds {d} binaries for {d} platforms; add each platform's install step once", .{ installs.len, release_targets.len });
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
