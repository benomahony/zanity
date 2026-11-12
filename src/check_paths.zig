//! Checking the paths a `zanity check` run names: reading its settings, choosing its rules,
//! checking each file and then the project, and applying fixes. A one-shot check and --watch
//! both run it.
const std = @import("std");
const collect = @import("collect.zig").collect;
const assert = @import("assert.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zclig = @import("zclig");
const strings = @import("strings.zig");
const batch = @import("batch.zig");
const rules = @import("rules.zig");
const report = @import("report.zig");
const naming = @import("naming.zig");
const graph = @import("graph.zig");
const parameters = @import("parameters.zig");
const structure = @import("structure.zig");
const vocabulary = @import("vocabulary.zig");
const project = @import("project.zig");
const memory = @import("memory.zig");
const infer = @import("infer.zig");
const store = @import("store.zig");
const sqlite = @import("sqlite.zig");
const Live = @import("live.zig").Live;
const config = @import("config.zig");
const config_file = @import("config_file.zig");
const fix_file = @import("fix_file.zig");
const CheckOptions = triage.CheckOptions;
const triage = @import("triage.zig");
const baseline = @import("baseline.zig");
const workspace = @import("workspace.zig");
const Workspace = workspace.Workspace;
const console = workspace.console;

/// Reads zanity.toml, opens the cache, and applies the file's excludes to the walk.
pub fn loadSettings(ctx: *zclig.Context, ws: *Workspace, gpa: Allocator) !config.Config {
    const settings = config_file.initConfig(gpa, ws.io) catch |e| switch (e) {
        error.InvalidConfig => return ctx.fail(.usage, config.problem[0..config.problem_len], "Fix that line of zanity.toml, or remove the setting to use zanity's default."),
        else => return e,
    };
    if (ws.environ) |environ| {
        if (ws.source_cache == null) ws.source_cache = store.Store.initStore(std.heap.page_allocator, ws.io, environ, ws.limits.store_bytes) catch null;
    }
    const before = ws.ignore.mark();
    for (settings.excludes()) |glob| try ws.ignore.exclude(settings.dir, glob);
    const after = ws.ignore.mark();
    if (after.patterns < before.patterns + settings.excludes().len) assert.panic("{d} excludes in zanity.toml added {d} ignore patterns; exclude() adds one per pattern", .{ settings.excludes().len, after.patterns - before.patterns });
    if (settings.rules) |chosen| if (chosen.len == 0) assert.panic("zanity.toml selected no rules; the reader must reject an empty select", .{});
    if (settings.strict_line > 0) try deprecated(ctx, try ws.text.format("{s}:{d}: 'strict' is deprecated and runs every rule, as \"all\" does; write \"all\" instead.", .{ config.file_name, settings.strict_line }));
    return settings;
}

pub fn parseRules(ctx: *zclig.Context, ws: *Workspace, list: []const u8) !rules.Set {
    var set: rules.Set = .{};
    var it = std.mem.tokenizeScalar(u8, list, ',');
    while (it.next()) |raw| {
        const code = std.mem.trim(u8, raw, " ");
        if (code.len == 0) continue;
        const strict = std.mem.eql(u8, code, "strict");
        if (strict) try deprecated(ctx, "zanity: --rules strict is deprecated and runs every rule; write --production or --rules all instead.");
        if (!set.includeNamed(if (strict) "all" else code)) {
            const start = ws.text.used;
            _ = try ws.text.copy("The rules are: all (every rule, as --production runs)");
            for (rules.all) |r| _ = try ws.text.format(" {s}", .{r.name});
            const hint = ws.text.buffer[start..ws.text.used];
            return ctx.fail(.usage, try ws.text.format("Unknown rule '{s}'.", .{code}), hint);
        }
    }
    if (set.len == 0) return ctx.fail(.usage, "--rules needs at least one rule.", "Pass a comma-separated list, such as --rules unbounded-loop,long-function, or --rules all.");
    if (set.len > std.mem.count(u8, list, ",") + 1 and std.mem.indexOf(u8, list, "all") == null) assert.panic("--rules '{s}' enabled {d} rules from {d} names; each name other than 'all' enables one rule, so check includeNamed()", .{ list, set.len, std.mem.count(u8, list, ",") + 1 });
    if (rules.find(set.names()[0]) == null) assert.panic("--rules '{s}' enabled '{s}', which is not a rule; parseRules() must add only rules that includeNamed() found", .{ list, set.names()[0] });
    return set;
}

fn checkTimings(ctx: *zclig.Context, ws: *Workspace, options: CheckOptions, selected: rules.Set) !void {
    if (ws.source.len == 0) assert.panic("timing reports require the workspace source buffer", .{});
    if (selected.len == 0) assert.panic("timing checks require a rule selection", .{});
    const path = options.junit orelse return;
    const bytes = std.Io.Dir.cwd().readFile(ws.io, path, ws.source) catch |e|
        return ctx.fail(.io, try ws.text.format("Could not read JUnit report {s}: {t}.", .{ path, e }), "Generate a JUnit XML report with your test runner, then pass its path with --junit.");
    if (selected.enabled("slow-test")) @import("test_timings.zig").check(bytes, .{ .path = path, .threshold_ms = options.@"slow-test-ms" }, &ws.text, &ws.findings) catch |e|
        return ctx.fail(.usage, try ws.text.format("Could not parse JUnit report {s}: {t}.", .{ path, e }), "Use a JUnit XML report with finite, nonnegative testcase time attributes in seconds; DTDs are unsupported.");
}

pub fn checkPaths(ctx: *zclig.Context, ws: *Workspace, options: CheckOptions, selected: rules.Set) !report.Counts {
    const paths = options.paths;
    if (paths.len == 0) assert.panic("check ran with no paths; zclig supplies '.' when none are given", .{});
    if (selected.len == 0) assert.panic("check ran with no rules selected; runCheck always selects at least one", .{});
    for (paths) |path| try collect(ctx, ws, path);
    std.mem.sort([]const u8, ws.files.items(), {}, strings.lessThan);
    try ws.initCheckers(std.heap.page_allocator, selected);
    try checkFiles(ctx, ws, selected);
    std.mem.sort([]const u8, ws.project_files.items(), {}, strings.lessThan);
    try project.checkProjectFiles(.{ .io = ws.io, .buffer = ws.source, .facts = &ws.facts, .enabled = selected, .findings = &ws.findings }, ws.project_files.items());
    try checkTimings(ctx, ws, options, selected);
    if (ws.inference) |*inference| if (ws.live) |live| {
        inference.reporter = .{ .state = live, .report = reportInference };
    };
    const units = ws.facts.units;
    if (ws.inference) |*inference| inference.judge(units.items(), &ws.findings, selected) catch |e| switch (e) {
        error.AskFailed => return ctx.fail(.io, infer.failure, infer.advice),
        error.StoreUnavailable => return ctx.fail(.io, try storeProblem(ws), "Check that the cache directory is writable and not full, then run again."),
        else => return e,
    };
    if (ws.inference) |*inference| try inference.summarise(ctx);
    try dropDisabled(ws);
    report.sortFindings(ws.findings.items());
    if (options.fix) try fixFiles(ctx, ws);
    const findings = ws.findings.items();
    ws.rows.clear();
    for (findings) |f| {
        const rule = rules.find(f.rule) orelse unreachable;
        try ws.rows.add(.{
            .path = f.path,
            .line = f.line + 1,
            .column = f.column + 1,
            .severity = @tagName(rule.severity),
            .rule = rule.name,
            .message = f.message,
            .fix = f.advice(),
            .edit_start = if (f.edit) |e| e.start else null,
            .edit_end = if (f.edit) |e| e.end else null,
            .edit_text = if (f.edit) |e| e.replacement else null,
        });
    }
    try baseline.prepare(ctx, ws, options);
    return report.count(findings, ws.checked + ws.project_files.len, ws.skipped);
}

fn checkFiles(ctx: *zclig.Context, ws: *Workspace, selected: rules.Set) !void {
    if (selected.len == 0) assert.panic("checking files with no rules selected; runCheck always selects at least one", .{});
    if (ws.findings.len != 0) assert.panic("{d} findings are left from an earlier run; checkFiles expects a fresh workspace", .{ws.findings.len});
    if (ws.files.len > 0) {
        var run: batch.Batch = .{
            .io = ws.io,
            .files = ws.files.items(),
            .order = ws.order,
            .checkers = &ws.checkers,
            .file_bytes = ws.limits.file_bytes,
            .text = &ws.text,
            .facts = &ws.facts,
            .findings = &ws.findings,
            .cache = if (ws.source_cache) |*source_cache| source_cache else null,
            .cache_buffer = ws.analysis,
            .live = ws.live,
        };
        if (try run.run(try ws.checkWorkers(std.heap.page_allocator, ws.files.len))) |failure| {
            const path = ws.files.items()[failure.index];
            if (failure.unreadable) return ctx.fail(.io, try ws.text.format("Could not read {s}: {t}.", .{ path, failure.err }), "Check the file exists and is readable.");
            memory.exceeded = failure.exceeded;
            return failure.err;
        }
        ws.checked = run.checked;
        ws.cache_hits = run.cached;
    }
    if (ws.live) |live| live.restart();
    const anchor = try anchorOf(ws);
    if (anchor) |a| {
        vocabulary.assignScopes(a, &ws.facts);
        if (a.config.directional_len > 0) ws.naming.directional = a.config.directional[0..a.config.directional_len];
    }
    try naming.crossCheck(&ws.naming, &ws.facts, selected, &ws.findings);
    if (anchor) |a| try vocabulary.checkVocabulary(.{ .anchor = a, .text = ws.facts.text, .enabled = selected, .findings = &ws.findings, .reading = .{ .io = ws.io, .buffer = ws.source }, .renames = &ws.renames }, &ws.facts, ws.files.items());
    if (selected.enabled("recursion")) try graph.recursion(&ws.graph, &ws.facts, &ws.findings);
    if (selected.enabled("dead-parameter")) parameters.dropPassed(&ws.facts, &ws.findings);
    const sources: structure.Sources = .{ .io = ws.io, .mine = ws.source, .theirs = ws.fixed };
    try structure.checkStructure(&ws.facts, selected, &ws.findings, .{ .sources = sources, .live = &ws.liveness, .cycles = &ws.cycles });
    if (ws.facts.collect_units and selected.enabled("repeated-mechanics")) try structure.clusterUnits(&ws.facts, sources);
    if (ws.checked > ws.files.len) assert.panic("checked {d} files out of {d} collected; count a file as checked only once per file collected", .{ ws.checked, ws.files.len });
}

fn reportInference(state: *anyopaque, done: usize, total: usize) void {
    const live: *Live = @ptrCast(@alignCast(state));
    if (done > total) assert.panic("--infer reported {d} of {d} functions done; Inference.watch() must report no more answered functions than it queued", .{ done, total });
    if (total == 0) assert.panic("--infer reported progress over no functions; askAll() must start the watcher only when functions are queued", .{});
    live.update("Asking the model", done, total);
}

/// Says why the answer store could not be used, in SQLite's words when it gave some.
pub fn storeProblem(ws: *Workspace) ![]const u8 {
    if (sqlite.failure_len > sqlite.failure.len) assert.panic("the store kept {d} bytes of failure message in room for {d}; the store must cut its message to fit its buffer", .{ sqlite.failure_len, sqlite.failure.len });
    const reason = sqlite.failure[0..sqlite.failure_len];
    const text = try ws.text.format("--infer could not use its answer store{s}{s}.", .{ if (reason.len > 0) ": " else "", reason });
    if (text.len == 0) assert.panic("describing a store failure produced no text; storeProblem() must write the store's message, so check its format call", .{});
    return text;
}

/// Applies each file's edits, then drops the findings they fixed and moves the rest to their new lines.
fn fixFiles(ctx: *zclig.Context, ws: *Workspace) !void {
    try fix_file.mergeRenames(ws);
    const findings = ws.findings.items();
    var edited: usize = 0;
    var files: usize = 0;
    var start: usize = 0;
    while (start < findings.len) {
        var end = start + 1;
        while (end < findings.len and std.mem.eql(u8, findings[end].path, findings[start].path)) end += 1;
        const applied = try fix_file.fixFile(ctx, ws, findings[start..end]);
        edited += applied;
        files += @intFromBool(applied > 0);
        start = end;
    }
    if (files > edited) assert.panic("expected every fixed file to have an applied edit, got {d} files and {d} edits; fixFile() must mark a finding fixed for each edit it applies", .{ files, edited });
    fix_file.settleRenames(findings);
    var kept: usize = 0;
    var fixed: usize = 0;
    var uses: usize = 0;
    for (findings) |f| {
        uses += @intFromBool(f.companion);
        fixed += @intFromBool(f.fixed and !f.companion);
        if (f.fixed or f.companion) continue;
        findings[kept] = f;
        kept += 1;
    }
    ws.findings.len = kept;
    if (kept + fixed + uses != findings.len) assert.panic("--fix lost track of findings: {d} fixed, {d} kept and {d} rename edits out of {d}; a finding was marked fixed without its edit being applied, so fixFile() must set fixed only after it writes the edit", .{ fixed, kept, uses, findings.len });
    if (fixed > 0) {
        const line = try ws.text.format("zanity: fixed {d} {s} in {d} {s}", .{ fixed, if (fixed == 1) "finding" else "findings", files, if (files == 1) "file" else "files" });
        const err = console(ctx, ctx.runtime.err);
        try err.styled(line, .{ .fg = .{ .named = .green } });
        try err.writer.writeByte('\n');
    }
}

/// Where the working directory sits under the zanity.toml in use; null when there is none.
fn anchorOf(ws: *Workspace) !?config.Anchor {
    const settings = ws.settings orelse return null;
    if (settings.dir.len == 0) return null;
    if (!std.fs.path.isAbsolute(settings.dir)) assert.panic("zanity.toml's folder '{s}' is relative; initConfig() records the real path", .{settings.dir});
    const cwd = try Io.Dir.cwd().realPathFileAlloc(ws.io, ".", std.heap.page_allocator);
    defer std.heap.page_allocator.free(cwd);
    if (!std.mem.startsWith(u8, cwd, settings.dir)) assert.panic("zanity.toml was found in {s}, which is not at or above the working directory {s}; initConfig() must search only the working directory and the folders above it", .{ settings.dir, cwd });
    return .{ .config = settings, .below = try ws.text.copy(std.mem.trimStart(u8, cwd[settings.dir.len..], "/")) };
}

/// Drops the findings of rules that a [paths] section of zanity.toml turns off for their file,
/// before they are reported or fixed.
fn dropDisabled(ws: *Workspace) !void {
    const settings = ws.settings orelse return;
    if (settings.pathRules().len == 0) return;
    const anchor = (try anchorOf(ws)) orelse return;
    if (anchor.config != settings) assert.panic("the anchor holds the config from {s}, not the one in use from {s}; anchorOf() must anchor ws.settings", .{ anchor.config.dir, settings.dir });
    const findings = ws.findings.items();
    var kept: usize = 0;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    for (findings) |f| {
        const relative = anchor.relative(f.path, &buffer);
        if (relative.len > 0 and settings.disabledAt(relative, f.rule)) continue;
        findings[kept] = f;
        kept += 1;
    }
    if (kept > findings.len) assert.panic("kept {d} of {d} findings; dropping findings in place can only shrink the list, so the loop wrote past what it read", .{ kept, findings.len });
    ws.findings.len = kept;
}

/// Warns that a deprecated spelling was used, saying what to write instead; the run goes on.
pub fn deprecated(ctx: *zclig.Context, warning: []const u8) !void {
    if (warning.len == 0) assert.panic("warning of a deprecation without saying what replaces it", .{});
    const err = console(ctx, ctx.runtime.err);
    try err.styled(warning, .{ .fg = .{ .named = .yellow } });
    try err.writer.writeByte('\n');
    if (err.writer.buffered().len == 0 and !std.mem.endsWith(u8, warning, ".")) assert.panic("the deprecation '{s}' should end in a full stop", .{warning});
}
