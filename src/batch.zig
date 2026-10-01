//! Checks files on every core. A worker checks one file at a time with its own scratch, then,
//! holding the lock, commits what it found to the run's facts and findings, copying the text they
//! point to so it can reuse its buffers for the next file. The largest files are handed out first,
//! so no worker starts a long file just as the others run out of work. Files are committed in the
//! order they finish; everything read afterwards is sorted first, so the report doesn't depend on it.

const std = @import("std");
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

/// More workers than this would each wait on the lock more than they check.
pub const max_workers = 64;

/// One thread's buffers, cleared for each file it checks.
pub const Worker = struct {
    scratch: check.FileScratch,
    text: memory.Text,
    facts: Facts,
    source: []u8,

    pub fn initWorker(gpa: Allocator, limits: memory.Limits) Allocator.Error!*Worker {
        if (limits.file_bytes == 0) assert.panic("memory.Limits.file_bytes is 0, so a worker could read no file", .{});
        if (limits.text_bytes == 0) assert.panic("memory.Limits.text_bytes is 0, so a worker could keep no message", .{});
        const worker = try gpa.create(Worker);
        worker.* = .{
            .scratch = try .initCheckScratch(gpa, limits),
            .text = try .initText(gpa, limits.text_bytes),
            .facts = undefined,
            .source = try memory.reserve(gpa, u8, limits.file_bytes + 1),
        };
        worker.facts = try .initFacts(gpa, limits, &worker.text);
        return worker;
    }

    fn startFile(self: *Worker, path: []const u8, name: []const u8, collect_units: bool) void {
        if (path.len == 0 or name.len == 0) assert.panic("starting a worker on path '{s}' in language '{s}'; both must be known before checking", .{ path, name });
        self.text.used = 0;
        inline for (.{ "definitions", "functions", "calls", "units" }) |field| @field(self.facts, field).clear();
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
    live: ?*Live,
    mutex: Io.Mutex = .init,
    checked: usize = 0,
    failure: ?Failure = null,
    next: std.atomic.Value(usize) = .init(0),

    /// Checks every file, then returns the first failure in file order, if any. A failure doesn't
    /// stop the others, so the same files fail the same way however they were scheduled.
    pub fn run(self: *Batch, workers: []const *Worker) Io.Cancelable!?Failure {
        if (workers.len == 0 or workers.len > max_workers) assert.panic("checking with {d} workers; initWorkers() makes between 1 and {d}", .{ workers.len, max_workers });
        if (self.order.len < self.files.len) assert.panic("room to order {d} files, but the run has {d}; size Batch.order from memory.Limits.files", .{ self.order.len, self.files.len });
        for (self.files, 0..) |path, index| {
            // A file that can't be read is checked last; reading it then reports why.
            const stat = Io.Dir.cwd().statFile(self.io, path, .{}) catch null;
            self.order[index] = .{ .index = @intCast(index), .bytes = if (stat) |s| s.size else 0 };
        }
        std.mem.sort(Sized, self.order[0..self.files.len], self.files.len, Sized.largestFirst);
        var group: Io.Group = .init;
        for (workers) |worker| group.async(self.io, work, .{ self, worker });
        try group.await(self.io);
        if (self.failure == null and self.checked > self.files.len) assert.panic("checked {d} of {d} files; each index is handed to one worker once", .{ self.checked, self.files.len });
        return self.failure;
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
            return error.LimitExceeded;
        }
        worker.startFile(path, adapter.name, self.facts.collect_units);
        const result = try checker.check(.{ .scratch = &worker.scratch, .text = &worker.text, .facts = &worker.facts }, source);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.commit(worker, path, result.diagnostics);
        if (self.checked > self.files.len) assert.panic("committed {d} of {d} files; each file is committed once", .{ self.checked, self.files.len });
    }

    /// Adds one file's facts and findings to the run's; the caller holds `mutex`.
    fn commit(self: *Batch, worker: *const Worker, path: []const u8, diagnostics: []const check.Diagnostic) !void {
        if (!std.mem.eql(u8, worker.facts.path, path)) assert.panic("committing {s} with facts recorded for {s}; startFile() must set the path of the file being checked", .{ path, worker.facts.path });
        const facts = self.facts;
        const first = facts.functions.len;
        for (worker.facts.definitions.items()) |d| {
            var kept = d;
            kept.name = try worker.retain(self.text, d.name);
            try facts.definitions.add(kept);
        }
        for (worker.facts.functions.items()) |f| {
            var kept = f;
            kept.name = try worker.retain(self.text, f.name);
            try facts.functions.add(kept);
        }
        for (worker.facts.calls.items()) |c| {
            try facts.calls.add(.{ .caller = @intCast(first + c.caller), .callee = try worker.retain(self.text, c.callee), .reach = c.reach });
        }
        for (worker.facts.units.items()) |u| {
            var kept = u;
            kept.name = try worker.retain(self.text, u.name);
            kept.source = try worker.retain(self.text, u.source);
            try facts.units.add(kept);
        }
        for (diagnostics) |d| {
            const edit: ?facts_module.Edit = if (d.edit) |e| .{ .start = e.start, .end = e.end, .replacement = try worker.retain(self.text, e.replacement) } else null;
            try self.findings.add(.{ .path = path, .line = d.line, .column = d.column, .rule = d.rule, .message = try worker.retain(self.text, d.message), .fix = try worker.retain(self.text, d.fix), .edit = edit });
        }
        self.checked += 1;
        if (self.live) |live| live.update("Checking files", self.checked, self.files.len);
        if (facts.functions.len != first + worker.facts.functions.len) assert.panic("committed {d} functions from a file that recorded {d}; commit() must add each once", .{ facts.functions.len - first, worker.facts.functions.len });
    }

    /// Keeps the failure of the earliest file, so the same run fails the same way however it was scheduled.
    fn recordFailure(self: *Batch, failure: Failure) void {
        if (failure.index >= self.files.len) assert.panic("file {d} failed, but the run has {d}; only handed-out indexes can fail", .{ failure.index, self.files.len });
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.failure == null or failure.index < self.failure.?.index) self.failure = failure;
        if (self.failure.?.index > failure.index) assert.panic("kept the failure of file {d} over the earlier file {d}; recordFailure() keeps the earliest", .{ self.failure.?.index, failure.index });
    }
};

/// One worker per core, but no more than there are files to check.
pub fn initWorkers(gpa: Allocator, limits: memory.Limits, files: usize) Allocator.Error![]const *Worker {
    if (files == 0) assert.panic("making workers to check no files; checkFiles() returns early when there are none", .{});
    const cores = std.Thread.getCpuCount() catch 1;
    const count = @max(1, @min(cores, files, max_workers));
    const workers = try gpa.alloc(*Worker, count);
    for (workers) |*worker| worker.* = try .initWorker(gpa, limits);
    if (workers.len > files) assert.panic("made {d} workers for {d} files; a worker with no file only costs memory", .{ workers.len, files });
    return workers;
}
