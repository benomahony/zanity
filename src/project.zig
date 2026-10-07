//! Project files: the build, lint, type-check, test and CI configuration that decides how strictly
//! the code is checked. Settings that let a check pass when it should fail are reported from their
//! text; with `--infer`, each setting line and the files as a whole are also asked about.
const std = @import("std");
const assert = @import("assert.zig");
const Io = std.Io;
const memory = @import("memory.zig");
const rules = @import("rules.zig");
const ignore = @import("ignore.zig");
const strings = @import("strings.zig");
const facts_module = @import("facts.zig");
const Facts = facts_module.Facts;
const Finding = facts_module.Finding;

/// The files that configure how a project is built and checked, in .gitignore syntax.
pub const patterns = [_][]const u8{
    "pyproject.toml",     "setup.cfg",          "tox.ini",                 "ruff.toml",                ".ruff.toml",       "mypy.ini",
    ".mypy.ini",          "pyrightconfig.json", "package.json",            "tsconfig.json",            "tsconfig.*.json",  "eslint.config.*",
    ".eslintrc*",         "biome.json",         "biome.jsonc",             "Cargo.toml",               "clippy.toml",      ".clippy.toml",
    ".cargo/config.toml", "go.mod",             ".golangci.y*ml",          ".golangci.toml",           "staticcheck.conf", "build.zig",
    "build.zig.zon",      "CMakeLists.txt",     "Makefile",                "meson.build",              ".clang-tidy",      "build.gradle",
    "build.gradle.kts",   "pom.xml",            ".pre-commit-config.yaml", "Justfile",                 "justfile",         "Taskfile.y*ml",
    "noxfile.py",         ".gitlab-ci.yml",     ".circleci/config.yml",    ".github/workflows/*.y*ml",
};

/// Hidden directories that hold project files, which the walk otherwise skips.
pub const hidden_dirs = [_][]const u8{ ".github", ".circleci", ".cargo" };

/// Setting text that lets a check pass when it should fail, lowercased, and what it does.
const relaxations = [_]struct { []const u8, []const u8 }{
    .{ "continue-on-error: true", "lets this CI step fail without failing the build" },
    .{ "allow_failure: true", "lets this CI job fail without failing the pipeline" },
    .{ "|| true", "turns a failing command into a passing one" },
    .{ "|| exit 0", "turns a failing command into a passing one" },
    .{ "--exit-zero", "makes the linter pass whatever it finds" },
    .{ "--no-" ++ "verify", "skips the hooks that check a commit" },
    .{ "ignore_missing_imports = true", "stops the type checker reporting imports it can't resolve" },
    .{ "ignore_errors = true", "stops the type checker reporting errors" },
    .{ "\"strict\": false", "turns the type checker's strict mode off" },
    .{ "strict = false", "turns the type checker's strict mode off" },
    .{ "\"skiplibcheck\": true", "skips type-checking declaration files" },
    .{ "\"noimplicitany\": false", "lets values go untyped" },
    .{ "\"strictnullchecks\": false", "lets null and undefined go unchecked" },
    .{ "warnings = \"allow\"", "allows every compiler warning" },
    .{ "-wno-error", "lets warnings that should stop the build through" },
};

/// Whether the file at `relative`, a path from the checked directory, configures the project.
pub fn isProjectFile(relative: []const u8) bool {
    if (relative.len == 0) assert.panic("asked whether an empty path is a project file; collect() passes each entry's path", .{});
    var buffer: [256]u8 = undefined;
    for (patterns) |pattern| {
        const glob = if (std.mem.indexOfScalar(u8, pattern, '/') == null) std.fmt.bufPrint(&buffer, "**/{s}", .{pattern}) catch continue else pattern;
        if (ignore.matchPath(glob, relative)) return true;
    }
    if (patterns.len == 0) assert.panic("no project file patterns, so no project file could be found; list them in project.patterns", .{});
    return false;
}

/// What checking the project files needs: where to read them and where to report.
pub const ProjectRun = struct {
    io: Io,
    buffer: []u8,
    facts: *Facts,
    enabled: rules.Set,
    findings: *memory.Bounded(Finding),
};

/// Reports each relaxing setting in `paths`; with units collected, records each setting line and
/// the files as a whole for --infer.
pub fn checkProjectFiles(run: ProjectRun, paths: []const []const u8) !void {
    if (run.buffer.len == 0) assert.panic("reading project files into an empty buffer; size it from memory.Limits.file_bytes", .{});
    const facts = run.facts;
    const project_start = facts.text.used;
    var first: ?[]const u8 = null;
    for (paths) |path| {
        const source = Io.Dir.cwd().readFile(run.io, path, run.buffer) catch continue;
        if (first == null) first = path;
        try checkProjectFile(run, path, source);
        if (facts.collect_units) _ = try facts.text.format("=== {s} ===\n{s}\n", .{ path, source });
    }
    const whole = facts.text.buffer[project_start..facts.text.used];
    if (facts.collect_units) if (first) |path| {
        facts.path = path;
        facts.language = "config";
        try facts.unit("the project's build and CI files", whole, .{ .kind = .project, .reports_error = false, .at = .{ 0, 0, 0 } });
    };
    if (first == null and whole.len > 0) assert.panic("wrote {d} bytes of project files without reading one; only files read are added", .{whole.len});
}

fn checkProjectFile(run: ProjectRun, path: []const u8, source: []const u8) !void {
    if (path.len == 0) assert.panic("checking a project file with no path; collect() records each path", .{});
    const facts = run.facts;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var row: u32 = 0;
    while (lines.next()) |raw| : (row += 1) {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or std.mem.startsWith(u8, line, "//")) continue;
        const column: u32 = @intCast(std.mem.indexOfNone(u8, raw, " \t") orelse 0);
        var lower: [512]u8 = undefined;
        const kept = @min(line.len, lower.len);
        const lowered = std.ascii.lowerString(lower[0..kept], line[0..kept]);
        for (relaxations) |r| {
            if (std.mem.indexOf(u8, lowered, r[0]) == null) continue;
            if (!run.enabled.enabled("relaxed-check")) break;
            try run.findings.add(.{ .path = path, .line = row, .column = column, .rule = "relaxed-check", .message = try facts.text.format("'{s}' {s}, so a problem it should catch passes.", .{ strings.header(line), r[1] }) });
            break;
        }
        const name = strings.header(line);
        if (!facts.collect_units or name.len == 0) continue;
        facts.path = path;
        facts.language = "config";
        try facts.unit(name, line, .{ .kind = .setting, .reports_error = false, .at = .{ row, column, row } });
    }
    if (row == 0 and source.len > 0) assert.panic("{s}: read {d} bytes as no lines; splitting on newlines always gives at least one", .{ path, source.len });
}
