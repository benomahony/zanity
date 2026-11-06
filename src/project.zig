//! Project files: the build, lint, type-check, test and CI configuration that decides how strictly
//! the code is checked. Settings that let a check pass when it should fail are reported from their
//! text; with `--infer`, each setting line and the files as a whole are also asked about.
const std = @import("std");
const assert = @import("assert.zig");
const Io = std.Io;
const memory = @import("memory.zig");
const rules = @import("rules.zig");
const ignore = @import("ignore.zig");
const suppress = @import("suppress.zig");
const strings = @import("strings.zig");
const facts_module = @import("facts.zig");
const release = @import("release.zig");
const artifacts = @import("artifacts.zig");
const Facts = facts_module.Facts;
const Finding = facts_module.Finding;

/// The files that configure how a project is built and checked, in .gitignore syntax.
pub const patterns = [_][]const u8{
    "pyproject.toml",          "setup.cfg",                "tox.ini",                 "ruff.toml",                ".ruff.toml",          "mypy.ini",
    ".mypy.ini",               "pyrightconfig.json",       "package.json",            "tsconfig.json",            "tsconfig.*.json",     "eslint.config.*",
    ".eslintrc*",              "biome.json",               "biome.jsonc",             "Cargo.toml",               "clippy.toml",         ".clippy.toml",
    ".cargo/config.toml",      "go.mod",                   ".golangci.y*ml",          ".golangci.toml",           "staticcheck.conf",    "build.zig",
    "build.zig.zon",           "CMakeLists.txt",           "Makefile",                "meson.build",              ".clang-tidy",         "build.gradle",
    "build.gradle.kts",        "pom.xml",                  ".pre-commit-config.yaml", "Justfile",                 "justfile",            "Taskfile.y*ml",
    "noxfile.py",              ".gitlab-ci.yml",           ".circleci/config.yml",    ".github/workflows/*.y*ml", "Dockerfile*",         "docker-compose*.y*ml",
    "compose*.y*ml",           "requirements*.txt",        "*.tf",                    "*.tfvars",                 ".terraform.lock.hcl", "Chart.yaml",
    "values.y*ml",             "*.bicep",                  "*.sh",                    ".env",                     ".env.*",              "*.properties",
    "application*.y*ml",       "config*.y*ml",             "*.conf",                  ".htaccess",                "*.csproj",            "Directory.Build.props",
    "Directory.Build.targets", "Directory.Packages.props", ".editorconfig",           "*.ruleset",                "global.json",         "nuget.config",
    "NuGet.Config",
};

/// Hidden directories that hold project files, which the walk otherwise skips.
pub const hidden_dirs = [_][]const u8{ ".github", ".circleci", ".cargo" };

/// Directories of dependencies and build output, which the walk never enters.
const skipped_dirs = [_][]const u8{ "node_modules", "zig-out", "__pycache__", "target", "dist", "build", "venv" };

/// Whether the walk leaves out a directory called `name`: dependencies, build output, and hidden
/// directories other than those holding project files.
pub fn skippedDir(name: []const u8) bool {
    if (name.len == 0) assert.panic("asked whether a directory with an empty name is skipped; skip empty names before calling skippedDir()", .{});
    if (std.mem.indexOfAny(u8, name, "/\\") != null) assert.panic("'{s}' is a path, but skippedDir() takes one directory name; pass the directory's base name", .{name});
    if (name[0] == '.') return !strings.contains(&hidden_dirs, name);
    for (skipped_dirs) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

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
    .{ "<nullable>disable</nullable>", "turns nullable reference checking off, so possible null dereferences go unreported" },
    .{ "<treatwarningsaserrors>false</treatwarningsaserrors>", "lets compiler warnings through" },
    .{ "<warninglevel>0</warninglevel>", "turns compiler warnings off" },
    .{ "<nowarn>", "silences these compiler and analyzer warnings" },
    .{ "<enablenetanalyzers>false</enablenetanalyzers>", "turns the .NET code analyzers off" },
    .{ "<runanalyzers>false</runanalyzers>", "turns the .NET code analyzers off" },
    .{ "<runanalyzersduringbuild>false</runanalyzersduringbuild>", "skips the .NET code analyzers during the build" },
    .{ "<analysismode>none</analysismode>", "turns the .NET code analyzers off" },
    .{ "<analysislevel>none</analysislevel>", "turns the .NET code analyzers off" },
    .{ "severity = none", "turns this analyzer rule off" },
    .{ "severity=none", "turns this analyzer rule off" },
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
    /// One extra byte beyond the largest accepted file, to detect truncated reads.
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
        const source = try Io.Dir.cwd().readFile(run.io, path, run.buffer);
        if (source.len == run.buffer.len) {
            memory.exceeded = "bytes in one project file";
            return error.LimitExceeded;
        }
        if (first == null) first = path;
        try checkProjectFile(run, path, source);
        if (run.enabled.enabled("ungated-release") and release.isWorkflow(path)) try release.checkWorkflow(run.findings, facts.text, path, source);
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

test "project files must be readable in full before the check succeeds" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const missing = try std.fs.path.join(arena, &.{ root, "missing.toml" });
    const invalid = try std.fs.path.join(arena, &.{ root, "file", "project.toml" });
    const large = try std.fs.path.join(arena, &.{ root, "large.toml" });
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "large.toml", .data = "allow_failure: true\n" });
    var text = try memory.Text.initText(arena, 1024);
    var facts = try Facts.initFacts(arena, .{ .definitions = 4, .functions = 4, .calls = 4, .references = 4 }, &text);
    var findings = try memory.Bounded(Finding).initBounded(arena, 4, "project findings");
    var buffer: [16]u8 = undefined;
    const run: ProjectRun = .{ .io = io, .buffer = &buffer, .facts = &facts, .enabled = .{}, .findings = &findings };
    try std.testing.expectError(error.FileNotFound, checkProjectFiles(run, &.{missing}));
    try std.testing.expectError(error.NotDir, checkProjectFiles(run, &.{invalid}));
    try std.testing.expectError(error.LimitExceeded, checkProjectFiles(run, &.{large}));
    try std.testing.expectEqualStrings("bytes in one project file", memory.exceeded);
}

fn checkProjectFile(run: ProjectRun, path: []const u8, source: []const u8) !void {
    if (path.len == 0) assert.panic("checking a project file with no path; collect() records each path", .{});
    const facts = run.facts;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var row: u32 = 0;
    while (lines.next()) |raw| : (row += 1) {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or std.mem.startsWith(u8, line, "//")) continue;
        if (onlyContradicted(line)) continue;
        const column: u32 = @intCast(std.mem.indexOfNone(u8, raw, " \t") orelse 0);
        var line_run = run;
        line_run.enabled = try unsuppressed(run.enabled, line);
        var lower: [artifacts.line_window_bytes]u8 = undefined;
        const kept = @min(line.len, lower.len);
        const lowered = std.ascii.lowerString(lower[0..kept], line[0..kept]);
        for (relaxations) |r| {
            if (std.mem.indexOf(u8, lowered, r[0]) == null) continue;
            if (!line_run.enabled.enabled("relaxed-check")) break;
            try run.findings.add(.{ .path = path, .line = row, .column = column, .rule = "relaxed-check", .message = try facts.text.format("'{s}' {s}, so a problem it should catch passes.", .{ strings.header(line), r[1] }) });
            break;
        }
        try artifacts.checkRepositoryArtifact(line_run, .{ .path = path, .text = line[0..kept], .lower = lowered, .row = row, .column = column });
        const name = strings.header(line);
        if (!facts.collect_units or name.len == 0) continue;
        facts.path = path;
        facts.language = "config";
        try facts.unit(name, line, .{ .kind = .setting, .reports_error = false, .at = .{ row, column, row } });
    }
    if (row == 0 and source.len > 0) assert.panic("{s}: read {d} bytes as no lines; splitting on newlines always gives at least one", .{ path, source.len });
}

/// The rules in `enabled` that a `zanity: ignore` comment on `line` leaves on.
fn unsuppressed(enabled: rules.Set, line: []const u8) !rules.Set {
    if (line.len == 0) assert.panic("reading suppressions from an empty setting; checkProjectFile() skips blank lines", .{});
    var slots: [16][]const u8 = undefined;
    var codes: memory.Bounded([]const u8) = .{ .buffer = &slots, .what = "suppressed rule names on one project file line" };
    if (!try suppress.parseIgnore(&codes, line)) return enabled;
    var kept: rules.Set = .{};
    if (codes.len == 0) return kept;
    for (enabled.names()) |name| {
        const rule = rules.find(name) orelse unreachable;
        for (codes.items()) |code| {
            if (rule.answers(code)) break;
        } else kept.include(name);
    }
    if (kept.len > enabled.len) assert.panic("suppressions on '{s}' left {d} of {d} rules on; they can only turn rules off", .{ line, kept.len, enabled.len });
    return kept;
}

test "a zanity: ignore comment on a project file line turns off only the rules it names" {
    var enabled: rules.Set = .{};
    enabled.include("plaintext-config-secret");
    enabled.include("relaxed-check");
    const kept = try unsuppressed(enabled, "api-token: hunter2 # zanity: ignore[plaintext-config-secret]");
    try std.testing.expect(!kept.enabled("plaintext-config-secret"));
    try std.testing.expect(kept.enabled("relaxed-check"));
    try std.testing.expectEqual(0, (try unsuppressed(enabled, "api-token: hunter2 # zanity: ignore")).len);
}

/// Whether every rule code the setting names, before any comment, is one that bans what zanity
/// requires, so the line turns off a check zanity's rules contradict and weakens nothing.
fn onlyContradicted(line: []const u8) bool {
    if (line.len == 0) assert.panic("checking an empty setting for rule codes; checkProjectFile() skips blank lines", .{});
    const setting = line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len];
    var named: u32 = 0;
    var i: usize = 0;
    while (i < setting.len) {
        const start = i;
        while (i < setting.len and std.ascii.isAlphanumeric(setting[i])) i += 1;
        const word = setting[start..i];
        if (i == start) i += 1;
        if (!ruleCode(word)) continue;
        if (!strings.contains(&rules.contradicted_codes, word)) return false;
        named += 1;
    }
    if (i < setting.len) assert.panic("reading '{s}' for rule codes stopped at byte {d}", .{ setting, i });
    if (named > setting.len / 2) assert.panic("counted {d} rule codes in the {d}-byte '{s}'; each takes at least two bytes", .{ named, setting.len, setting });
    return named > 0;
}

/// Whether `word` reads as a linter's rule code: capitals then digits, as in `S101` or `E501`.
fn ruleCode(word: []const u8) bool {
    if (std.mem.indexOfNone(u8, word, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789") != null) assert.panic("'{s}' is not one word; onlyContradicted() splits at every other byte", .{word});
    const capitals = std.mem.indexOfNone(u8, word, "ABCDEFGHIJKLMNOPQRSTUVWXYZ") orelse return false;
    if (capitals > word.len) assert.panic("found {d} leading capitals in the {d}-byte '{s}'; indexOfNone() returns a position inside the word", .{ capitals, word.len, word });
    return capitals > 0 and capitals < word.len and std.mem.indexOfNone(u8, word[capitals..], "0123456789") == null;
}

test "a setting that only turns off rules banning what zanity requires weakens nothing" {
    try std.testing.expect(onlyContradicted("ignore = [\"S101\"]  # assertion-density needs asserts"));
    try std.testing.expect(onlyContradicted("\"tests/*\" = [\"S101\", \"B101\"]"));
    try std.testing.expect(!onlyContradicted("ignore = [\"S101\", \"E501\"]"));
    try std.testing.expect(!onlyContradicted("line-length = 200"));
}
