//! Checks files on every core. A worker checks one file at a time with its own scratch, then,
//! holding the lock, commits what it found to the run's facts and findings, copying the text they
//! point to so it can reuse its buffers for the next file. The largest files are handed out first,
//! so no worker starts a long file just as the others run out of work. Files are committed in the
//! order they finish; everything read afterwards is sorted first, so the report doesn't depend on it.

const std = @import("std");
const analysis = @import("analysis.zig");
const assert = @import("assert.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const check = @import("check.zig");
const language = @import("language.zig");
const memory = @import("memory.zig");
const facts_module = @import("facts.zig");
const Facts = facts_module.Facts;
const Finding = facts_module.Finding;
const Live = @import("live.zig").Live;
const cache_module = @import("cache.zig");
const store = @import("store.zig");
const Store = store.Store;
const adapters = @import("adapters");
const sqlite = @import("sqlite.zig");
/// What a file's cached analysis ran out of, when it doesn't fit the room the cache keeps for one.
const analysis_room = "bytes in one file's cached analysis";

/// More workers than this would each wait on the lock more than they check.
pub const max_workers = 64;

/// One thread's buffers, cleared for each file it checks.
pub const Worker = struct {
    scratch: check.FileScratch,
    text: memory.Text,
    facts: Facts,
    source: []u8,
    /// A cached analysis read from the store, then the arena it is parsed into.
    analysis: []u8,

    /// Fills in `worker` where it lies: its facts keep a pointer to its own text, so a worker must
    /// stay where it was made.
    pub fn initWorker(worker: *Worker, gpa: Allocator, limits: memory.Limits) Allocator.Error!void {
        if (limits.file_bytes == 0) assert.panic("memory.Limits.file_bytes is 0, so a worker could read no file", .{});
        if (limits.text_bytes == 0) assert.panic("memory.Limits.text_bytes is 0, so a worker could keep no message", .{});
        worker.* = .{
            .scratch = try .initCheckScratch(gpa, limits),
            .text = try .initText(gpa, limits.text_bytes),
            .facts = undefined,
            .source = try memory.reserveUninitialized(gpa, u8, std.math.add(usize, limits.file_bytes, 1) catch return error.OutOfMemory),
            .analysis = try memory.reserveUninitialized(gpa, u8, limits.analysis_bytes),
        };
        worker.facts = try .initFacts(gpa, limits, &worker.text);
    }

    fn startFile(self: *Worker, path: []const u8, name: []const u8, collect_units: bool) void {
        if (path.len == 0 or name.len == 0) assert.panic("starting a worker on path '{s}' in language '{s}'; both must be known before checking", .{ path, name });
        self.text.used = 0;
        self.facts.reset();
        self.facts.path = path;
        self.facts.language = name;
        self.facts.collect_units = collect_units;
        if (self.facts.functions.len != 0 or self.text.used != 0) assert.panic("a worker starting a file still holds {d} functions and {d} bytes of text; startFile() must empty both", .{ self.facts.functions.len, self.text.used });
    }

    /// `bytes` itself when it outlives the file, or a copy in `text` when it is in this worker's text.
    fn retain(self: *const Worker, text: *memory.Text, bytes: []const u8) error{LimitExceeded}![]const u8 {
        const start = @intFromPtr(self.text.buffer.ptr);
        const at = @intFromPtr(bytes.ptr);
        if (bytes.len == 0 or at < start or at >= start + self.text.buffer.len) return bytes;
        if (at + bytes.len > start + self.text.used) assert.panic("{d} bytes at offset {d} of a worker's text run past the {d} it has written; retain() only copies text written for this file", .{ bytes.len, at - start, self.text.used });
        const copied = try text.copy(bytes);
        if (copied.ptr == bytes.ptr) assert.panic("retained {d} bytes in place in a worker's text; retain() must copy them into the run's text, which outlives the file", .{bytes.len});
        return copied;
    }
};

/// A file to check and its size, for handing out the largest first.
pub const Sized = struct {
    index: u32,
    bytes: u64,

    fn largestFirst(files: usize, a: Sized, b: Sized) bool {
        if (a.index >= files) assert.panic("ordering file {d} of a run of {d}; Batch.run() lists only the run's files", .{ a.index, files });
        if (b.index >= files) assert.panic("ordering file {d} of a run of {d}; Batch.run() lists only the run's files", .{ b.index, files });
        if (a.bytes != b.bytes) return a.bytes > b.bytes;
        return a.index < b.index;
    }
};

/// The first file that stopped the run, and why.
pub const Failure = struct {
    index: usize,
    err: anyerror,
    /// Which limit ran out, when `err` is error.LimitExceeded.
    exceeded: []const u8,
    unreadable: bool,
    /// Why SQLite refused, when `err` is error.StoreUnavailable.
    reason: []const u8 = "",
};

const CachedFile = struct {
    key: @import("store.zig").Digest,
    context: @import("store.zig").Digest,
    source: @import("store.zig").Digest,
    path: []const u8,
    language: []const u8,
};

pub const Batch = struct {
    io: Io,
    files: []const []const u8,
    /// Room for one entry per file: the order files are handed out in.
    order: []Sized,
    checkers: []const ?check.Checker,
    file_bytes: u32,
    /// Shared by every worker; only touched while holding `mutex`.
    text: *memory.Text,
    facts: *Facts,
    findings: *memory.Bounded(Finding),
    cache: ?*Store = null,
    /// Whether the run has a store, set before the workers start so they read it without the lock.
    caching: bool = false,
    live: ?*Live,
    mutex: Io.Mutex = .init,
    checked: usize = 0,
    cached: usize = 0,
    failure: ?Failure = null,
    /// SQLite's words for the kept failure, copied from the worker thread that saw them.
    reason: [sqlite.failure.len]u8 = undefined,
    next: std.atomic.Value(usize) = .init(0),

    /// Checks every file, then returns the first failure in file order, if any. A failure doesn't
    /// stop the others, so the same files fail the same way however they were scheduled.
    pub fn run(self: *Batch, workers: []Worker) Io.Cancelable!?Failure {
        if (workers.len == 0 or workers.len > max_workers) assert.panic("checking with {d} workers; checkWorkers() makes between 1 and {d}", .{ workers.len, max_workers });
        if (self.order.len < self.files.len) assert.panic("room to order {d} files, but the run has {d}; size Batch.order from memory.Limits.files", .{ self.order.len, self.files.len });
        for (self.files, 0..) |path, index| {
            // A file that can't be read is checked last; reading it then reports why.
            const stat = Io.Dir.cwd().statFile(self.io, path, .{}) catch null;
            self.order[index] = .{ .index = @intCast(index), .bytes = if (stat) |s| s.size else 0 };
        }
        std.mem.sort(Sized, self.order[0..self.files.len], self.files.len, Sized.largestFirst);
        self.caching = self.cache != null;
        var group: Io.Group = .init;
        for (workers) |*worker| group.async(self.io, work, .{ self, worker });
        try group.await(self.io);
        if (self.failure == null and self.checked > self.files.len) assert.panic("checked {d} of {d} files; each index is handed to one worker once", .{ self.checked, self.files.len });
        return self.failure;
    }

    /// The analysis context of each language the run has a checker for, which the store marks
    /// used once the run is done.
    pub fn contexts(self: *const Batch, out: *[language.count]store.Digest) []const store.Digest {
        if (self.checkers.len != adapters.all.len) assert.panic("{d} checker slots for {d} languages; the workspace makes one slot per adapter", .{ self.checkers.len, adapters.all.len });
        var count: usize = 0;
        for (self.checkers, adapters.all) |slot, *adapter| {
            const checker = slot orelse continue;
            out[count] = cache_module.contextOf(.{ .language = adapter.name, .query = adapter.query, .revision = adapter.revision, .enabled = checker.enabled, .collect_units = self.facts.collect_units });
            count += 1;
        }
        if (count > out.len) assert.panic("{d} contexts in room for {d}; there is one checker slot per language", .{ count, out.len });
        return out[0..count];
    }

    fn work(self: *Batch, worker: *Worker) void {
        if (worker.source.len <= self.file_bytes) assert.panic("a worker's source buffer holds {d} bytes, but files may have {d}; it needs one more to see a file is too long", .{ worker.source.len, self.file_bytes });
        for (0..self.files.len) |_| {
            const next = self.next.fetchAdd(1, .monotonic);
            if (next >= self.files.len) return;
            const index = self.order[next].index;
            const source = Io.Dir.cwd().readFile(self.io, self.files[index], worker.source) catch |err| {
                self.recordFailure(.{ .index = index, .err = err, .exceeded = "", .unreadable = true });
                continue;
            };
            self.checkFile(worker, index, source) catch |err| self.recordFailure(.{ .index = index, .err = err, .exceeded = memory.exceeded, .unreadable = false });
        }
        if (self.next.load(.monotonic) < self.files.len) assert.panic("a worker stopped with file {d} of {d} still to hand out; it may only stop once every file is taken", .{ self.next.load(.monotonic), self.files.len });
    }

    fn checkFile(self: *Batch, worker: *Worker, index: usize, source: []const u8) !void {
        if (index >= self.files.len) assert.panic("checking file {d} of {d}; work() hands out indexes below the file count", .{ index, self.files.len });
        const path = self.files[index];
        const adapter = language.forPath(path) orelse return;
        const checker = &(self.checkers[language.indexOf(adapter)] orelse unreachable);
        if (source.len > self.file_bytes) {
            memory.exceeded = "bytes in one file";
            return self.commitOversized(worker, path, checker);
        }
        const cache_context: cache_module.AnalysisContext = .{ .language = adapter.name, .query = adapter.query, .revision = adapter.revision, .enabled = checker.enabled, .collect_units = self.facts.collect_units };
        const context = cache_module.contextOf(cache_context);
        const cached_file: CachedFile = .{ .key = cache_module.key(context, path), .context = context, .source = @import("store.zig").digest(&.{source}), .path = path, .language = adapter.name };
        if (try self.replayCached(worker, cached_file)) return;
        worker.startFile(path, adapter.name, self.facts.collect_units);
        const result = analysis.checkFile(checker, .{ .scratch = &worker.scratch, .text = &worker.text, .facts = &worker.facts }, source) catch |e| switch (e) {
            error.LimitExceeded => return self.commitOversized(worker, path, checker),
            else => return e,
        };
        const encoded: ?[]const u8 = if (self.caching) cache_module.encode(worker.analysis, cache_context, &worker.facts, result.diagnostics) catch |err| switch (err) {
            error.WriteFailed => {
                memory.exceeded = analysis_room;
                return error.LimitExceeded;
            },
        } else null;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.keepEncoded(cached_file, encoded);
        try self.commit(worker, path, result.diagnostics);
        if (self.checked > self.files.len) assert.panic("committed {d} of {d} files; each file is committed once", .{ self.checked, self.files.len });
    }

    /// Keeps a checked file's encoded analysis; the caller holds `mutex`. A store that fails
    /// stops the run.
    fn keepEncoded(self: *Batch, file: CachedFile, encoded: ?[]const u8) error{StoreUnavailable}!void {
        if (file.path.len == 0 or file.language.len == 0) assert.panic("keeping an analysis without its path or language; checkFile supplies both", .{});
        if (encoded) |payload| if (payload.len == 0) assert.panic("{s} encoded as no bytes; JSON always holds the snapshot's fields", .{file.path});
        const source_cache = self.cache orelse return;
        const payload = encoded orelse assert.panic("{s} wasn't encoded, though the run keeps analyses; checkFile() encodes whenever Batch.caching is set", .{file.path});
        try source_cache.keepAnalysis(.{ .key = file.key, .context = file.context, .source = file.source, .path = file.path, .language = file.language, .result = payload });
    }

    /// Replays one valid cache row into the worker, as checking the file would fill it, then
    /// commits it as a checked file is. Only reading the row and the commit hold the lock, so
    /// workers parse rows in parallel. A missing or malformed row is a miss for that file; a store
    /// that fails, or a row too large to parse, stops the run.
    fn replayCached(self: *Batch, worker: *Worker, file: CachedFile) !bool {
        if (worker.analysis.len < 2) assert.panic("replaying cached files with {d} bytes; reserve memory.Limits.analysis_bytes for each worker", .{worker.analysis.len});
        if (file.path.len == 0 or file.language.len == 0) assert.panic("replaying a cached file without its path or language; checkFile supplies both", .{});
        const middle = worker.analysis.len / 2;
        const json = (try self.cachedRow(worker.analysis[0..middle], file)) orelse return false;
        worker.startFile(file.path, file.language, self.facts.collect_units);
        const diagnostics = &worker.scratch.diagnostics;
        diagnostics.clear();
        cache_module.replay(.{ .payload = json, .scratch = worker.analysis[middle..], .path = file.path, .language = file.language, .text = &worker.text, .facts = &worker.facts, .diagnostics = diagnostics }) catch |err| switch (err) {
            error.InvalidCache => return false,
            error.OutOfMemory => {
                memory.exceeded = analysis_room;
                return error.LimitExceeded;
            },
            error.LimitExceeded => return error.LimitExceeded,
        };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.commit(worker, file.path, diagnostics.items());
        self.cached += 1;
        return true;
    }

    /// Copies the file's cache row into `buffer` while holding the lock that protects SQLite's
    /// prepared statements; null when there is none. A store that can't be read stops the run.
    fn cachedRow(self: *Batch, buffer: []u8, file: CachedFile) !?[]const u8 {
        if (buffer.len == 0) assert.panic("reading a cache row into no memory; reserve memory.Limits.analysis_bytes for each worker", .{});
        if (std.mem.eql(u8, &file.key, &file.source)) assert.panic("{s}'s cache key and source digest are both {s}; one was passed as the other", .{ file.path, &file.key });
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const source_cache = self.cache orelse return null;
        return try source_cache.cachedAnalysis(buffer, file.key, file.source);
    }

    /// Reports a file that ran past one of a file's limits, `memory.exceeded`, as oversized-file,
    /// unless that rule is off, and keeps nothing else from it, so one generated or copied file
    /// doesn't stop the run.
    fn commitOversized(self: *Batch, worker: *Worker, path: []const u8, checker: *const check.Checker) !void {
        const adapter = language.forPath(path) orelse assert.panic("{s} is too large to check but has no language; checkFile() returns before then", .{path});
        const exceeded = memory.exceeded;
        if (exceeded.len == 0) assert.panic("{s} ran out of room, but memory.exceeded doesn't say which limit; every Bounded and Text sets it before returning error.LimitExceeded", .{path});
        worker.startFile(path, adapter.name, self.facts.collect_units);
        if (!std.mem.eql(u8, worker.facts.path, path)) assert.panic("starting {s} left the worker on {s}; startFile() sets the path it is given", .{ path, worker.facts.path });
        const message = try worker.text.format("This file is too large for zanity to check: it has more {s} than zanity can hold, so no rule checked it.", .{exceeded});
        const found = [_]check.Diagnostic{.{ .line = 0, .column = 0, .rule = "oversized-file", .message = message }};
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.commit(worker, path, if (checker.enabled.enabled("oversized-file")) &found else &.{});
    }

    /// Adds one file's handlers, routes and tracing calls to the run's, for untraced-entry-point.
    fn commitTracing(self: *Batch, worker: *const Worker) error{LimitExceeded}!void {
        const recorded = worker.facts;
        if (recorded.path.len == 0) assert.panic("committing tracing facts for no file; startFile() sets the path of the file being checked", .{});
        const before = self.facts.untraced.len + self.facts.routes.len + self.facts.tracing.len;
        inline for (.{ "untraced", "routes", "tracing" }) |field| {
            for (@field(recorded, field).items()) |d| {
                var kept = d;
                kept.name = try worker.retain(self.text, d.name);
                try @field(self.facts, field).add(kept);
            }
        }
        const added = self.facts.untraced.len + self.facts.routes.len + self.facts.tracing.len - before;
        if (added != recorded.untraced.len + recorded.routes.len + recorded.tracing.len) assert.panic("{s}: committed {d} tracing facts of {d} recorded; each is added once", .{ recorded.path, added, recorded.untraced.len + recorded.routes.len + recorded.tracing.len });
    }

    /// Adds one file's facts and findings to the run's; the caller holds `mutex`.
    fn commit(self: *Batch, worker: *const Worker, path: []const u8, diagnostics: []const check.Diagnostic) !void {
        if (!std.mem.eql(u8, worker.facts.path, path)) assert.panic("committing {s} with facts recorded for {s}; startFile() must set the path of the file being checked", .{ path, worker.facts.path });
        const first = try self.commitFacts(worker);
        for (diagnostics) |d| {
            const edit: ?facts_module.Edit = if (d.edit) |e| .{ .start = e.start, .end = e.end, .replacement = try worker.retain(self.text, e.replacement) } else null;
            try self.findings.add(.{ .path = path, .line = d.line, .column = d.column, .rule = d.rule, .message = try worker.retain(self.text, d.message), .fix = try worker.retain(self.text, d.fix), .edit = edit, .subject = d.subject });
        }
        self.checked += 1;
        if (self.live) |live| live.update("Checking files", self.checked, self.files.len);
        const facts = self.facts;
        const recorded = worker.facts;
        if (facts.functions.len != first + recorded.functions.len) assert.panic("committed {d} functions from a file that recorded {d}; commit() must add each once", .{ facts.functions.len - first, recorded.functions.len });
    }

    /// Adds one file's facts to the run's, copying the text they point to out of the worker's,
    /// and returns where its functions start, which its calls and shapes count from.
    fn commitFacts(self: *Batch, worker: *const Worker) !usize {
        const facts = self.facts;
        const recorded = worker.facts;
        if (recorded.path.len == 0) assert.panic("committing facts for no file; startFile() sets the path of the file being checked", .{});
        const first = facts.functions.len;
        const defined = facts.definitions.len;
        for (recorded.definitions.items()) |d| {
            var kept = d;
            kept.name = try worker.retain(self.text, d.name);
            kept.kind = try worker.retain(self.text, d.kind);
            kept.scope = try worker.retain(self.text, d.scope);
            kept.unmarked = try worker.retain(self.text, d.unmarked);
            try facts.definitions.add(kept);
        }
        for (recorded.functions.items()) |f| {
            var kept = f;
            kept.name = try worker.retain(self.text, f.name);
            kept.types = try worker.retain(self.text, f.types);
            try facts.functions.add(kept);
        }
        for (recorded.calls.items()) |c| {
            try facts.calls.add(.{ .caller = @intCast(first + c.caller), .callee = try worker.retain(self.text, c.callee), .reach = c.reach, .arguments = c.arguments, .types = try worker.retain(self.text, c.types) });
        }
        for (recorded.shapes.items()) |shape| {
            var kept = shape;
            kept.function = @intCast(first + shape.function);
            try facts.shapes.add(kept);
        }
        for (recorded.abstractions.items()) |a| {
            var kept = a;
            kept.name = try worker.retain(self.text, a.name);
            kept.kind = try worker.retain(self.text, a.kind);
            kept.scope = try worker.retain(self.text, a.scope);
            kept.unmarked = try worker.retain(self.text, a.unmarked);
            try facts.abstractions.add(kept);
        }
        for (recorded.imports.items()) |i| {
            var kept = i;
            kept.spec = try worker.retain(self.text, i.spec);
            kept.shown = try worker.retain(self.text, i.shown);
            try facts.imports.add(kept);
        }
        try self.commitTracing(worker);
        for (recorded.implemented.items()) |hash| try facts.implemented.add(hash);
        for (recorded.passed.items()) |hash| try facts.passed.add(hash);
        try facts.addReferences(recorded.references.items());
        for (recorded.units.items()) |u| {
            var kept = u;
            kept.name = try worker.retain(self.text, u.name);
            kept.source = try worker.retain(self.text, u.source);
            kept.fix = try worker.retain(self.text, u.fix);
            try facts.units.add(kept);
        }
        if (facts.definitions.len != defined + recorded.definitions.len) assert.panic("{s}: committed {d} definitions of {d} recorded; each is added once", .{ recorded.path, facts.definitions.len - defined, recorded.definitions.len });
        return first;
    }

    /// Keeps the failure of the earliest file, so the same run fails the same way however it was scheduled.
    fn recordFailure(self: *Batch, failure: Failure) void {
        if (failure.index >= self.files.len) assert.panic("file {d} failed, but the run has {d}; only handed-out indexes can fail", .{ failure.index, self.files.len });
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.failure == null or failure.index < self.failure.?.index) {
            self.failure = failure;
            // SQLite's message is the worker thread's own, so copy it while still on that thread.
            if (failure.err == error.StoreUnavailable) {
                const said = sqlite.failure[0..sqlite.failure_len];
                @memcpy(self.reason[0..said.len], said);
                self.failure.?.reason = self.reason[0..said.len];
            }
        }
        if (self.failure.?.index > failure.index) assert.panic("kept the failure of file {d} over the earlier file {d}; recordFailure() keeps the earliest", .{ self.failure.?.index, failure.index });
    }
};
