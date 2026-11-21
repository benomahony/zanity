//! `zig build bench`: how far `zanity check` is from the fastest it could be on this machine.
//! Parsing every file once with tree-sitter is the work no check can skip, so that parse, spread
//! over every core, is the ceiling. The report puts zanity's time beside it, and beside the parse
//! on one core, so a slowdown shows whether the checks or the scheduling lost the time. zanity
//! runs end to end twice: cold, with its store deleted before every run, and warm, reusing it,
//! and each run reports its peak memory. `--compare=REF` builds zanity at that commit and runs it
//! the same way, so the report shows what a change did to its time and memory.

const std = @import("std");
const analysis = @import("analysis.zig");
const assert = @import("assert.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ts = @import("ts.zig");
const language = @import("language.zig");
const check = @import("check.zig");
const rules = @import("rules.zig");
const memory = @import("memory.zig");
const Facts = @import("facts.zig").Facts;

/// Each measurement keeps its fastest run, so a busy moment on the machine doesn't count.
const runs = 3;
/// More entries than this in the corpus means it was pointed at the wrong directory.
const max_entries = 1 << 20;
/// Room for every source in the corpus at once; Zig's standard library needs about 18 MB.
const corpus_bytes = 1 << 30;

/// Every file in the corpus zanity has a language for, read before any timing starts.
const Corpus = struct {
    dir: []const u8,
    paths: memory.Bounded([]const u8),
    sources: memory.Bounded([]const u8),
    names: memory.Text,
    bytes: []u8,
    used: usize = 0,

    fn initCorpus(gpa: Allocator, dir: []const u8, limits: memory.Limits) Allocator.Error!Corpus {
        if (dir.len == 0) assert.panic("the corpus directory is empty; pass -Dcorpus=DIR or let bench ask zig env for its standard library", .{});
        if (limits.files == 0) assert.panic("memory.Limits.files is 0, so the corpus could hold no file", .{});
        return .{
            .dir = dir,
            .paths = try .initBounded(gpa, limits.files, "files in the corpus"),
            .sources = try .initBounded(gpa, limits.files, "files in the corpus"),
            .names = try .initText(gpa, limits.text_bytes),
            .bytes = try gpa.alloc(u8, corpus_bytes),
        };
    }

    fn read(self: *Corpus, io: Io) !void {
        if (self.paths.len != 0) assert.panic("reading the corpus into {d} files already read; read() fills a fresh corpus once", .{self.paths.len});
        var dir = try Io.Dir.cwd().openDir(io, self.dir, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(std.heap.page_allocator);
        defer walker.deinit();
        for (0..max_entries) |_| {
            const entry = try walker.next(io) orelse break;
            if (entry.kind != .file or language.forPath(entry.basename) == null) continue;
            const source = try dir.readFile(io, entry.path, self.bytes[self.used..]);
            if (self.used + source.len == self.bytes.len) return error.CorpusTooLarge;
            if (source.len > (memory.Limits{}).file_bytes) continue;
            self.used += source.len;
            try self.paths.add(try self.names.copy(entry.path));
            try self.sources.add(source);
        } else return error.CorpusTooLarge;
        if (self.paths.len == 0) return error.EmptyCorpus;
        if (self.paths.len != self.sources.len) assert.panic("read {d} paths but {d} sources; read() must add one source per path", .{ self.paths.len, self.sources.len });
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const minimal = init.minimal;
    const args = try minimal.args.toSlice(arena);
    if (args.len < 3 or args.len > 5) std.process.fatal("bench takes the zanity binary, the compiler, and optional --corpus=DIR and --compare=REF, but got {d} arguments; run it with zig build bench", .{args.len - 1});
    const limits: memory.Limits = .{};
    if (limits.files == 0 or limits.file_bytes == 0) assert.panic("the default limits allow {d} files of {d} bytes, so bench could check nothing; restore them in memory.Limits", .{ limits.files, limits.file_bytes });
    const corpus_dir = option(args[3..], "--corpus=") orelse try stdDir(arena, io, args[2]);
    var corpus = try Corpus.initCorpus(arena, corpus_dir, limits);
    var scratch = try check.FileScratch.initCheckScratch(arena, limits);
    var text = try memory.Text.initText(arena, limits.text_bytes);
    var facts = try Facts.initFacts(arena, limits, &text);
    // zanity runs from inside the corpus, so a path relative to here would no longer find it.
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, args[1], arena);
    const compared = if (option(args[3..], "--compare=")) |ref| try buildRef(arena, io, args[2], ref) else null;

    var timer: Timer = .{ .io = io, .started = Io.Timestamp.now(io, .awake) };
    corpus.read(io) catch |e| {
        if (e == error.LimitExceeded) std.debug.print("bench: the corpus has more {s} than bench can hold\n", .{memory.exceeded});
        return e;
    };
    const read = timer.lap();
    const parse = try fastest(io, parseAll, .{&corpus});
    var oversized: usize = 0;
    const checked = try fastest(io, checkAll, .{ arena, &corpus, check.Work{ .scratch = &scratch, .text = &text, .facts = &facts }, &oversized });
    const here: Target = .{ .zanity = zanity, .dir = corpus.dir, .environ = init.environ_map, .store = try std.fmt.allocPrint(arena, "{s}.bench.db", .{zanity}) };
    try init.environ_map.put("ZANITY_STORE", here.store);
    const this = try measureZanity(io, here);
    if (corpus.paths.len == 0) assert.panic("timed a corpus of no files; Corpus.read() rejects an empty corpus", .{});
    try printTimings(io, &corpus, .{ .read = read, .parse = parse, .check = checked, .oversized = oversized, .cold = this.cold.ns, .warm = this.warm.ns, .cores = try std.Thread.getCpuCount() });
    const c = compared orelse return printMemory(io, this, null);
    const there: Target = .{ .zanity = c.zanity, .dir = corpus.dir, .environ = init.environ_map, .store = try std.fmt.allocPrint(arena, "{s}.bench.db", .{c.zanity}) };
    try init.environ_map.put("ZANITY_STORE", there.store);
    try printMemory(io, this, .{ .label = c.label, .runs = try measureZanity(io, there) });
}

const Timings = struct { read: u64, parse: u64, check: u64, oversized: usize, cold: u64, warm: u64, cores: usize };

/// One way of running zanity, measured: the fastest of its runs and the most memory any used.
const Run = struct { ns: u64, peak: usize };

/// A zanity measured cold and warm.
const Runs = struct { cold: Run, warm: Run };

/// The zanity built at the commit `--compare` names, and how to name it in the report.
const Compared = struct { zanity: []const u8, label: []const u8 };

/// A zanity to run, the corpus it checks, and the store of its own that ZANITY_STORE names.
const Target = struct { zanity: []const u8, dir: []const u8, environ: *const std.process.Environ.Map, store: []const u8 };

/// Another commit's runs beside this one's, for the comparison table.
const Other = struct { label: []const u8, runs: Runs };

/// One line of the comparison table: a figure for this zanity and for the compared one.
const Figure = struct { name: []const u8, unit: []const u8, this: f64, other: f64 };

/// The value of the flag that starts with `prefix`, such as `--corpus=`, among `args`.
fn option(args: []const []const u8, prefix: []const u8) ?[]const u8 {
    if (prefix.len == 0 or prefix[prefix.len - 1] != '=') assert.panic("looking for the flag '{s}', which doesn't end with '='; name flags as --name=", .{prefix});
    if (args.len > 2) assert.panic("bench got {d} flags, but it takes only --corpus= and --compare=; main() checks the count", .{args.len});
    for (args) |arg| if (std.mem.startsWith(u8, arg, prefix)) return arg[prefix.len..];
    for (args) |arg| if (!std.mem.startsWith(u8, arg, "--corpus=") and !std.mem.startsWith(u8, arg, "--compare=")) std.process.fatal("bench doesn't know the argument '{s}'; it takes --corpus=DIR and --compare=REF", .{arg});
    return null;
}

/// Runs a zanity cold and then warm, then deletes the store it used.
fn measureZanity(io: Io, target: Target) !Runs {
    if (!std.fs.path.isAbsolute(target.zanity)) assert.panic("measuring zanity at '{s}', a relative path; resolve it before measuring", .{target.zanity});
    const named = target.environ.get("ZANITY_STORE") orelse "";
    if (!std.mem.eql(u8, named, target.store)) assert.panic("measuring {s} with ZANITY_STORE at '{s}', not its own '{s}'; main() sets it for each zanity", .{ target.zanity, named, target.store });
    const cold = try timeZanity(io, target, true);
    const warm = try timeZanity(io, target, false);
    try forget(io, target.store);
    return .{ .cold = cold, .warm = warm };
}

/// Builds zanity at `ref` in its own directory under `.zig-cache/bench-compare`, named by the
/// commit, so a second bench of the same commit reuses the build. It shares this checkout's
/// fetched packages, which are named by their hashes, rather than fetching them again.
fn buildRef(arena: Allocator, io: Io, compiler: []const u8, ref: []const u8) !Compared {
    if (ref.len == 0) std.process.fatal("--compare was given no branch, tag or commit", .{});
    if (compiler.len == 0) assert.panic("building {s} with an empty compiler path; build.zig passes b.graph.zig_exe", .{ref});
    const resolved = try std.process.run(arena, io, .{ .argv = &.{ "git", "rev-parse", "--verify", "--short", try std.fmt.allocPrint(arena, "{s}^{{commit}}", .{ref}) } });
    const commit = std.mem.trim(u8, resolved.stdout, " \n");
    if (commit.len == 0) std.process.fatal("git can't find the commit '{s}' to compare with: {s}", .{ ref, resolved.stderr });
    for (commit) |c| if (!std.ascii.isHex(c)) assert.panic("git rev-parse --short gave '{s}' for {s}, which isn't a commit hash; it prints only hex digits", .{ commit, ref });
    const cwd = Io.Dir.cwd();
    const dir = try cwd.realPathFileAlloc(io, ".", arena);
    const root = try std.fs.path.join(arena, &.{ dir, ".zig-cache", "bench-compare", commit });
    const label = if (std.mem.startsWith(u8, commit, ref)) commit else try std.fmt.allocPrint(arena, "{s} ({s})", .{ ref, commit });
    const built: Compared = .{ .zanity = try std.fs.path.join(arena, &.{ root, "zig-out", "bin", "zanity" }), .label = label };
    if (exists(io, built.zanity)) return built;
    try cwd.createDirPath(io, root);
    const archive = try std.fmt.allocPrint(arena, "{s}.tar", .{root});
    try runOrFail(arena, io, &.{ "git", "archive", "--format=tar", "-o", archive, commit }, null);
    try runOrFail(arena, io, &.{ "tar", "-xf", archive, "-C", root }, null);
    try cwd.deleteFile(io, archive);
    const packages = try std.fs.path.join(arena, &.{ dir, "zig-pkg" });
    if (exists(io, packages)) try cwd.symLink(io, packages, try std.fs.path.join(arena, &.{ root, "zig-pkg" }), .{ .is_directory = true });
    try runOrFail(arena, io, &.{ compiler, "build", "-Doptimize=ReleaseFast" }, root);
    if (!exists(io, built.zanity)) std.process.fatal("bench built {s} but found no zanity at {s}", .{ commit, built.zanity });
    return built;
}

/// Whether something is at `path`.
fn exists(io: Io, path: []const u8) bool {
    if (path.len == 0) assert.panic("asked whether an empty path exists; pass the path bench built", .{});
    if (!std.fs.path.isAbsolute(path)) assert.panic("asked whether '{s}' exists, a relative path; buildRef() works from absolute paths", .{path});
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Runs `argv`, in `cwd` when given, and stops bench saying what failed if it doesn't succeed.
fn runOrFail(arena: Allocator, io: Io, argv: []const []const u8, cwd: ?[]const u8) !void {
    if (argv.len == 0) assert.panic("running no command; pass the program and its arguments", .{});
    if (argv[0].len == 0) assert.panic("running a command with an empty program name", .{});
    const result = try std.process.run(arena, io, .{ .argv = argv, .cwd = if (cwd) |path| .{ .path = path } else .inherit });
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    std.process.fatal("bench: '{s}' failed while building the commit to compare with: {s}", .{ argv[0], result.stderr });
}

/// The peak memory of each run, and with `--compare`, a table of both commits and the change.
fn printMemory(io: Io, this: Runs, other: ?Other) !void {
    if (this.cold.ns == 0 or this.warm.ns == 0) assert.panic("a run of zanity took no time; the clock can't resolve the work, so use a larger corpus", .{});
    if (other) |o| if (o.label.len == 0) assert.panic("comparing with a commit that has no name; buildRef() names it by ref and commit", .{});
    var buffer: [4096]u8 = undefined;
    var writer: Io.File.Writer = .initStreaming(.stdout(), io, &buffer);
    const out = &writer.interface;
    const mb: f64 = 1e6;
    const ns: f64 = std.time.ns_per_s;
    try out.print("memory   {d:>7.1} MB peak cold, {d:.1} MB peak warm\n", .{ @as(f64, @floatFromInt(this.cold.peak)) / mb, @as(f64, @floatFromInt(this.warm.peak)) / mb });
    const o = other orelse return out.flush();
    const theirs = o.runs;
    try out.print("\ncompared with {s}, which runs its own --rules all\n", .{o.label});
    try out.print("{s:<12} {s:>12} {s:>12} {s:>8}\n", .{ "", "this", "compared", "change" });
    const figures = [_]Figure{
        .{ .name = "cold time", .unit = "s", .this = @as(f64, @floatFromInt(this.cold.ns)) / ns, .other = @as(f64, @floatFromInt(theirs.cold.ns)) / ns },
        .{ .name = "warm time", .unit = "s", .this = @as(f64, @floatFromInt(this.warm.ns)) / ns, .other = @as(f64, @floatFromInt(theirs.warm.ns)) / ns },
        .{ .name = "cold memory", .unit = "MB", .this = @as(f64, @floatFromInt(this.cold.peak)) / mb, .other = @as(f64, @floatFromInt(theirs.cold.peak)) / mb },
        .{ .name = "warm memory", .unit = "MB", .this = @as(f64, @floatFromInt(this.warm.peak)) / mb, .other = @as(f64, @floatFromInt(theirs.warm.peak)) / mb },
    };
    for (figures) |figure| try row(out, figure);
    try out.flush();
}

/// One line of the comparison: this zanity's figure, the compared one's, and the change.
fn row(out: *Io.Writer, figure: Figure) !void {
    if (figure.name.len == 0 or figure.unit.len == 0) assert.panic("a comparison row with no name or unit; printMemory() names each", .{});
    if (figure.this < 0 or figure.other < 0) assert.panic("{s} came out negative, {d} against {d}; times and sizes are never below zero", .{ figure.name, figure.this, figure.other });
    const change = if (figure.other == 0) 0 else (figure.this - figure.other) / figure.other * 100;
    try out.print("{s:<12} {d:>9.3} {s:<2} {d:>9.3} {s:<2} {s}{d:.1}%\n", .{ figure.name, figure.this, figure.unit, figure.other, figure.unit, if (change >= 0) "  +" else "  ", change });
}

fn printTimings(io: Io, corpus: *const Corpus, t: Timings) !void {
    if (t.parse == 0 or t.cores == 0) assert.panic("the parse took {d} ns over {d} cores; the clock can't resolve the work, so use a larger corpus", .{ t.parse, t.cores });
    if (corpus.used == 0) assert.panic("reporting on a corpus of {d} files and no bytes; read() rejects an empty corpus", .{corpus.paths.len});
    const ns: f64 = std.time.ns_per_s;
    const mb = @as(f64, @floatFromInt(corpus.used)) / 1e6;
    const parse = @as(f64, @floatFromInt(t.parse)) / ns;
    const ceiling = parse / @as(f64, @floatFromInt(t.cores));
    const check_s = @as(f64, @floatFromInt(t.check)) / ns;
    const cold = @as(f64, @floatFromInt(t.cold)) / ns;
    const warm = @as(f64, @floatFromInt(t.warm)) / ns;
    var buffer: [4096]u8 = undefined;
    var writer: Io.File.Writer = .initStreaming(.stdout(), io, &buffer);
    const out = &writer.interface;
    try out.print("corpus   {s}: {d} files, {d:.1} MB\n", .{ corpus.dir, corpus.paths.len, mb });
    try out.print("read     {d:>7.3} s\n", .{@as(f64, @floatFromInt(t.read)) / ns});
    try out.print("parse    {d:>7.3} s   {d:.1} MB/s on one core: the work no check can skip\n", .{ parse, mb / parse });
    try out.print("check    {d:>7.3} s   {d:.1}x the parse, on one core, without the cross-file rules; {d} oversized files unchecked\n", .{ check_s, check_s / parse, t.oversized });
    try out.print("ceiling  {d:>7.3} s   the parse spread over {d} cores\n", .{ ceiling, t.cores });
    try out.print("cold     {d:>7.3} s   {d:.1}x the ceiling, {d:.1} MB/s: zanity check --rules all from an empty store\n", .{ cold, cold / ceiling, mb / cold });
    try out.print("warm     {d:>7.3} s   {d:.1}x the ceiling, {d:.1}x faster than cold: the same check, nothing changed\n", .{ warm, warm / ceiling, cold / warm });
    try out.flush();
}

/// Nanoseconds since the last lap, on the clock that never runs backwards.
const Timer = struct {
    io: Io,
    started: Io.Timestamp,

    fn lap(self: *Timer) u64 {
        const now = Io.Timestamp.now(self.io, .awake);
        const before = self.started;
        const nanoseconds = before.durationTo(now).toNanoseconds();
        const elapsed = std.math.cast(u64, nanoseconds) orelse assert.panic("a lap of {d} s is negative or past 584 years; the .awake clock is monotonic, so the timestamps came from different clocks", .{before.durationTo(now).toSeconds()});
        self.started = now;
        if (self.started.toNanoseconds() < elapsed) assert.panic("a lap of {d} ns ended before the clock had run that long; lap() must measure from the previous lap", .{elapsed});
        if (before.toNanoseconds() + elapsed != now.toNanoseconds()) assert.panic("a lap of {d} ns doesn't end at now; lap() must measure from the previous lap to now", .{elapsed});
        return elapsed;
    }
};

/// The fastest of `runs` calls to `measure`.
fn fastest(io: Io, comptime measure: anytype, args: anytype) !u64 {
    comptime if (runs == 0) @compileError("runs is 0, so nothing would be measured; set it to at least 1");
    var best: u64 = std.math.maxInt(u64);
    var timer: Timer = .{ .io = io, .started = Io.Timestamp.now(io, .awake) };
    for (0..runs) |_| {
        _ = timer.lap();
        try @call(.auto, measure, args);
        best = @min(best, timer.lap());
    }
    if (best == std.math.maxInt(u64)) assert.panic("none of the {d} runs finished; the loop must time each run", .{runs});
    return best;
}

/// The fastest of `runs` full checks and the most memory any of them used: each from an empty
/// store when `cold`, or reusing what the run before kept.
fn timeZanity(io: Io, target: Target, cold: bool) !Run {
    comptime if (runs == 0) @compileError("runs is 0, so nothing would be measured; set it to at least 1");
    if (target.store.len == 0) assert.panic("timing {s} without a store of its own; main() names one beside it so bench never deletes the user's own", .{target.zanity});
    var best: Run = .{ .ns = std.math.maxInt(u64), .peak = 0 };
    for (0..runs) |_| {
        if (cold) try forget(io, target.store);
        var timer: Timer = .{ .io = io, .started = Io.Timestamp.now(io, .awake) };
        const peak = try runZanity(io, target.zanity, target.dir, target.environ);
        best = .{ .ns = @min(best.ns, timer.lap()), .peak = @max(best.peak, peak) };
    }
    if (best.ns == std.math.maxInt(u64)) assert.panic("none of the {d} runs finished; the loop must time each run", .{runs});
    return best;
}

/// Deletes the store and the files SQLite's WAL mode keeps beside it.
fn forget(io: Io, store: []const u8) !void {
    if (!std.fs.path.isAbsolute(store)) assert.panic("deleting the store at '{s}', a relative path; main() builds it from zanity's absolute path", .{store});
    if (!std.mem.endsWith(u8, store, ".bench.db")) assert.panic("deleting '{s}', which is not bench's own store; only main()'s <zanity>.bench.db may be deleted", .{store});
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "", "-wal", "-shm" }) |suffix| {
        const path = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ store, suffix });
        Io.Dir.cwd().deleteFile(io, path) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
    }
}

/// Asks `zig env` where its standard library is: a large corpus every toolchain ships.
fn stdDir(arena: Allocator, io: Io, compiler: []const u8) ![]const u8 {
    if (compiler.len == 0) assert.panic("bench was given an empty compiler path; build.zig passes b.graph.zig_exe", .{});
    const result = try std.process.run(arena, io, .{ .argv = &.{ compiler, "env" } });
    const key = ".std_dir = \"";
    const start = (std.mem.indexOf(u8, result.stdout, key) orelse return error.NoStdDir) + key.len;
    const end = std.mem.indexOfScalarPos(u8, result.stdout, start, '"') orelse return error.NoStdDir;
    if (end < start) assert.panic("std_dir ends at byte {d}, before it starts at {d}; the search for its closing quote must start after the opening one", .{ end, start });
    return result.stdout[start..end];
}

fn parseAll(corpus: *const Corpus) !void {
    if (corpus.paths.len != corpus.sources.len) assert.panic("{d} paths but {d} sources; Corpus.read() adds one source per path", .{ corpus.paths.len, corpus.sources.len });
    for (corpus.paths.items(), corpus.sources.items()) |path, source| {
        const adapter = language.forPath(path) orelse unreachable;
        const parser = ts.ts_parser_new() orelse return error.OutOfMemory;
        defer ts.ts_parser_delete(parser);
        if (!ts.ts_parser_set_language(parser, @ptrCast(adapter.grammar()))) assert.panic("tree-sitter rejected {s}'s grammar; its ABI version is outside what vendor/tree-sitter accepts", .{adapter.name});
        const tree = ts.ts_parser_parse_string(parser, null, source.ptr, @intCast(source.len)) orelse return error.ParseFailed;
        ts.ts_tree_delete(tree);
    }
}

/// Runs every rule on each file, as `zanity check --rules all` does before its cross-file rules.
/// A file past one of a file's limits counts in `oversized` and the rest are still checked, as
/// `zanity check` reports it as oversized-file and goes on.
fn checkAll(arena: Allocator, corpus: *const Corpus, work: check.Work, oversized: *usize) !void {
    oversized.* = 0;
    if (corpus.paths.len != corpus.sources.len) assert.panic("{d} paths but {d} sources; Corpus.read() adds one source per path", .{ corpus.paths.len, corpus.sources.len });
    var selected: rules.Set = .{};
    if (!selected.includeNamed("all")) assert.panic("rules.Set has no 'all'; bench runs every rule, so includeNamed() must accept it", .{});
    var checkers: [language.count]?check.Checker = @splat(null);
    for (corpus.paths.items(), corpus.sources.items()) |path, source| {
        const adapter = language.forPath(path) orelse unreachable;
        const slot = &checkers[language.indexOf(adapter)];
        if (slot.* == null) slot.* = try check.Checker.initChecker(arena, try language.load(adapter), selected);
        work.text.used = 0;
        work.facts.reset();
        work.facts.path = path;
        work.facts.language = adapter.name;
        _ = analysis.checkFile(&slot.*.?, work, source) catch |e| switch (e) {
            error.LimitExceeded => oversized.* += 1,
            else => return e,
        };
    }
}

/// Runs one full check of `dir` and returns the most memory it held, in bytes. Exit 1 means
/// zanity found something, which is a finished run here; a higher code or a signal is a failure.
fn runZanity(io: Io, zanity: []const u8, dir: []const u8, environ: *const std.process.Environ.Map) !usize {
    if (!std.fs.path.isAbsolute(zanity)) assert.panic("running zanity from '{s}', a relative path, inside {s}; resolve it before changing directory", .{ zanity, dir });
    if (dir.len == 0) assert.panic("running zanity on an empty corpus path; Corpus.initCorpus() rejects one", .{});
    var child = try std.process.spawn(io, .{
        .argv = &.{ zanity, "check", "--quiet", "--no-color", "--rules", "all", "." },
        .cwd = .{ .path = dir },
        .environ_map = environ,
        .stdout = .ignore,
        // --quiet leaves stderr empty on a finished run, so anything there says why zanity failed.
        .stderr = .inherit,
        .request_resource_usage_statistics = true,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code <= 1) return child.resource_usage_statistics.getMaxRss() orelse 0,
        else => {},
    }
    std.debug.print("bench: zanity check in {s} ended with {any}\n", .{ dir, term });
    return error.ZanityFailed;
}
