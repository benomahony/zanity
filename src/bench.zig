//! `zig build bench`: how far `zanity check` is from the fastest it could be on this machine.
//! Parsing every file once with tree-sitter is the work no check can skip, so that parse, spread
//! over every core, is the ceiling. The report puts zanity's time beside it, and beside the parse
//! on one core, so a slowdown shows whether the checks or the scheduling lost the time.

const std = @import("std");
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
const corpus_bytes = 1 << 28;

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
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3 or args.len > 4) assert.panic("bench takes the zanity binary, the compiler and an optional corpus directory, but got {d} arguments; run it with zig build bench", .{args.len - 1});
    const limits: memory.Limits = .{};
    var corpus = try Corpus.initCorpus(arena, if (args.len == 4) args[3] else try stdDir(arena, io, args[2]), limits);
    var scratch = try check.FileScratch.initCheckScratch(arena, limits);
    var text = try memory.Text.initText(arena, limits.text_bytes);
    var facts = try Facts.initFacts(arena, limits, &text);
    // zanity runs from inside the corpus, so a path relative to here would no longer find it.
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, args[1], arena);

    var timer: Timer = .{ .io = io, .started = Io.Timestamp.now(io, .awake) };
    try corpus.read(io);
    const read = timer.lap();
    const parse = try fastest(io, parseAll, .{&corpus});
    const checked = try fastest(io, checkAll, .{ arena, &corpus, check.Work{ .scratch = &scratch, .text = &text, .facts = &facts } });
    const wall = try fastest(io, runZanity, .{ io, zanity, corpus.dir });
    if (corpus.paths.len == 0) assert.panic("timed a corpus of no files; Corpus.read() rejects an empty corpus", .{});
    try printTimings(io, &corpus, .{ .read = read, .parse = parse, .check = checked, .wall = wall, .cores = try std.Thread.getCpuCount() });
}

const Timings = struct { read: u64, parse: u64, check: u64, wall: u64, cores: usize };

fn printTimings(io: Io, corpus: *const Corpus, t: Timings) !void {
    if (t.parse == 0 or t.cores == 0) assert.panic("the parse took {d} ns over {d} cores; the clock can't resolve the work, so use a larger corpus", .{ t.parse, t.cores });
    if (corpus.used == 0) assert.panic("reporting on a corpus of {d} files and no bytes; read() rejects an empty corpus", .{corpus.paths.len});
    const ns: f64 = std.time.ns_per_s;
    const mb = @as(f64, @floatFromInt(corpus.used)) / 1e6;
    const parse = @as(f64, @floatFromInt(t.parse)) / ns;
    const ceiling = parse / @as(f64, @floatFromInt(t.cores));
    const check_s = @as(f64, @floatFromInt(t.check)) / ns;
    const wall = @as(f64, @floatFromInt(t.wall)) / ns;
    var buffer: [4096]u8 = undefined;
    var writer: Io.File.Writer = .initStreaming(.stdout(), io, &buffer);
    const out = &writer.interface;
    try out.print("corpus   {s}: {d} files, {d:.1} MB\n", .{ corpus.dir, corpus.paths.len, mb });
    try out.print("read     {d:>7.3} s\n", .{@as(f64, @floatFromInt(t.read)) / ns});
    try out.print("parse    {d:>7.3} s   {d:.1} MB/s on one core: the work no check can skip\n", .{ parse, mb / parse });
    try out.print("check    {d:>7.3} s   {d:.1}x the parse, on one core, without the cross-file rules\n", .{ check_s, check_s / parse });
    try out.print("ceiling  {d:>7.3} s   the parse spread over {d} cores\n", .{ ceiling, t.cores });
    try out.print("zanity   {d:>7.3} s   {d:.1}x the ceiling: zanity check --rules all, end to end\n", .{ wall, wall / ceiling });
    try out.flush();
}

/// Nanoseconds since the last lap, on the clock that never runs backwards.
const Timer = struct {
    io: Io,
    started: Io.Timestamp,

    fn lap(self: *Timer) u64 {
        const now = Io.Timestamp.now(self.io, .awake);
        const elapsed: i64 = @intCast(self.started.durationTo(now).toNanoseconds());
        if (elapsed < 0) assert.panic("the .awake clock ran {d} ns backwards; it is monotonic, so the timestamps came from different clocks", .{-elapsed});
        self.started = now;
        if (self.started.toNanoseconds() < elapsed) assert.panic("a lap of {d} ns ended before the clock had run that long; lap() must measure from the previous lap", .{elapsed});
        return @intCast(elapsed);
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
fn checkAll(arena: Allocator, corpus: *const Corpus, work: check.Work) !void {
    if (corpus.paths.len != corpus.sources.len) assert.panic("{d} paths but {d} sources; Corpus.read() adds one source per path", .{ corpus.paths.len, corpus.sources.len });
    var selected: rules.Set = .{};
    if (!selected.includeNamed("all")) assert.panic("rules.Set has no 'all'; bench runs every rule, so includeNamed() must accept it", .{});
    var checkers: [language.count]?check.Checker = @splat(null);
    for (corpus.paths.items(), corpus.sources.items()) |path, source| {
        const adapter = language.forPath(path) orelse unreachable;
        const slot = &checkers[language.indexOf(adapter)];
        if (slot.* == null) slot.* = try check.Checker.initChecker(arena, try language.load(adapter), selected);
        work.text.used = 0;
        inline for (.{ "definitions", "functions", "calls", "units" }) |field| @field(work.facts, field).clear();
        work.facts.path = path;
        work.facts.language = adapter.name;
        _ = try slot.*.?.check(work, source);
    }
}

fn runZanity(io: Io, zanity: []const u8, dir: []const u8) !void {
    if (!std.fs.path.isAbsolute(zanity)) assert.panic("running zanity from '{s}', a relative path, inside {s}; resolve it before changing directory", .{ zanity, dir });
    if (dir.len == 0) assert.panic("running zanity on an empty corpus path; Corpus.initCorpus() rejects one", .{});
    var child = try std.process.spawn(io, .{
        .argv = &.{ zanity, "check", "--quiet", "--no-color", "--rules", "all", "." },
        .cwd = .{ .path = dir },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    switch (try child.wait(io)) {
        .exited => |code| if (code > 1) return error.ZanityFailed,
        else => return error.ZanityFailed,
    }
}
