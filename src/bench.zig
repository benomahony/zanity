//! `zig build bench`: how far `zanity check` is from the fastest it could be on this machine.
//! Parsing every file once with tree-sitter is the work no check can skip, so that parse, spread
//! over every core, is the ceiling. The report puts zanity's time beside it, and beside the parse
//! on one core, so a slowdown shows whether the checks or the scheduling lost the time. zanity
//! runs end to end twice: cold, with its store deleted before every run, and warm, reusing it.

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
    if (args.len < 3 or args.len > 4) std.process.fatal("bench takes the zanity binary, the compiler and an optional corpus directory, but got {d} arguments; run it with zig build bench", .{args.len - 1});
    const limits: memory.Limits = .{};
    if (limits.files == 0 or limits.file_bytes == 0) assert.panic("the default limits allow {d} files of {d} bytes, so bench could check nothing; restore them in memory.Limits", .{ limits.files, limits.file_bytes });
    var corpus = try Corpus.initCorpus(arena, if (args.len == 4) args[3] else try stdDir(arena, io, args[2]), limits);
    var scratch = try check.FileScratch.initCheckScratch(arena, limits);
    var text = try memory.Text.initText(arena, limits.text_bytes);
    var facts = try Facts.initFacts(arena, limits, &text);
    // zanity runs from inside the corpus, so a path relative to here would no longer find it.
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, args[1], arena);
    const store = try std.fmt.allocPrint(arena, "{s}.bench.db", .{zanity});
    try init.environ_map.put("ZANITY_STORE", store);

    var timer: Timer = .{ .io = io, .started = Io.Timestamp.now(io, .awake) };
    corpus.read(io) catch |e| {
        if (e == error.LimitExceeded) std.debug.print("bench: the corpus has more {s} than bench can hold\n", .{memory.exceeded});
        return e;
    };
    const read = timer.lap();
    const parse = try fastest(io, parseAll, .{&corpus});
    var oversized: usize = 0;
    const checked = try fastest(io, checkAll, .{ arena, &corpus, check.Work{ .scratch = &scratch, .text = &text, .facts = &facts }, &oversized });
    const cold = try coldest(io, zanity, corpus.dir, init.environ_map);
    const warm = try fastest(io, runZanity, .{ io, zanity, corpus.dir, init.environ_map });
    try forget(io, store);
    if (corpus.paths.len == 0) assert.panic("timed a corpus of no files; Corpus.read() rejects an empty corpus", .{});
    try printTimings(io, &corpus, .{ .read = read, .parse = parse, .check = checked, .oversized = oversized, .cold = cold, .warm = warm, .cores = try std.Thread.getCpuCount() });
}

const Timings = struct { read: u64, parse: u64, check: u64, oversized: usize, cold: u64, warm: u64, cores: usize };

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

/// The fastest of `runs` full checks, each from an empty store.
fn coldest(io: Io, zanity: []const u8, dir: []const u8, environ: *const std.process.Environ.Map) !u64 {
    comptime if (runs == 0) @compileError("runs is 0, so nothing would be measured; set it to at least 1");
    const store = environ.get("ZANITY_STORE") orelse assert.panic("timing cold runs without ZANITY_STORE; main() sets it so bench never deletes the user's own store", .{});
    var best: u64 = std.math.maxInt(u64);
    for (0..runs) |_| {
        try forget(io, store);
        var timer: Timer = .{ .io = io, .started = Io.Timestamp.now(io, .awake) };
        try runZanity(io, zanity, dir, environ);
        best = @min(best, timer.lap());
    }
    if (best == std.math.maxInt(u64)) assert.panic("none of the {d} cold runs finished; the loop must time each run", .{runs});
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

/// Runs one full check of `dir`. Exit 1 means zanity found something, which is a finished run
/// here; a higher code or a signal is a failure.
fn runZanity(io: Io, zanity: []const u8, dir: []const u8, environ: *const std.process.Environ.Map) !void {
    if (!std.fs.path.isAbsolute(zanity)) assert.panic("running zanity from '{s}', a relative path, inside {s}; resolve it before changing directory", .{ zanity, dir });
    if (dir.len == 0) assert.panic("running zanity on an empty corpus path; Corpus.initCorpus() rejects one", .{});
    var child = try std.process.spawn(io, .{
        .argv = &.{ zanity, "check", "--quiet", "--no-color", "--rules", "all", "." },
        .cwd = .{ .path = dir },
        .environ_map = environ,
        .stdout = .ignore,
        // --quiet leaves stderr empty on a finished run, so anything there says why zanity failed.
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code <= 1) return,
        else => {},
    }
    std.debug.print("bench: zanity check in {s} ended with {any}\n", .{ dir, term });
    return error.ZanityFailed;
}
