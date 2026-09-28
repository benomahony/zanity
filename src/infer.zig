//! The inference tier. For each function that reports an error, `check --infer` asks TypeSafe
//! the questions of the rules that no deterministic check can settle, skipping any a
//! deterministic check already answered there. Answers are cached by model, function and
//! question in `.zanity/judgements.tsv`, so unchanged code is never asked about twice.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const tai = @import("tai");
const rules = @import("rules.zig");
const memory = @import("memory.zig");
const facts_module = @import("facts.zig");
const Unit = facts_module.Unit;
const Finding = facts_module.Finding;

/// How sure the model must be before a judgement becomes a finding, as in nouls.
pub const threshold = 0.8;
const concurrency = 8;
const cache_dir = ".zanity";
const cache_path = ".zanity/judgements.tsv";
const max_questions = 8;
const Hash = [32]u8;

const Judgement = struct { unit: Hash, question: Hash, probability: f64 };

const Job = struct {
    unit: *const Unit,
    unit_hash: Hash,
    rules: [max_questions]*const rules.Rule = undefined,
    answers: [max_questions]?f64 = @splat(null),
    count: usize = 0,
    state: []const u8 = "",
    failed: ?anyerror = null,
    diagnostics: tai.Client.Diagnostics = .{},
};

/// Why the last `judge` failed, with the detail TypeSafe returned.
pub var failure: []const u8 = "";

pub const Inference = struct {
    client: tai.Client,
    io: Io,
    cache: memory.Bounded(Judgement),
    cached: usize = 0,
    jobs: memory.Bounded(Job),
    json: memory.Text,
    file: []u8,

    /// Fails with `error.MissingApiKey` when `TYPESAFE_API_KEY` is not set.
    pub fn initInference(gpa: Allocator, io: Io, environ: *const std.process.Environ.Map, limits: memory.Limits) !Inference {
        if (limits.judgements == 0 or limits.judgement_bytes == 0) std.debug.panic("memory.Limits allows {d} cached judgements in {d} bytes; both must be above 0 for --infer", .{ limits.judgements, limits.judgement_bytes });
        var inference: Inference = .{
            .client = try tai.Client.init(gpa, io, .{ .environ_map = environ }),
            .io = io,
            .cache = try .initBounded(gpa, limits.judgements, "cached --infer judgements"),
            .jobs = try .initBounded(gpa, limits.functions, "functions to ask TypeSafe about"),
            .json = try .initText(gpa, limits.judgement_bytes),
            .file = try gpa.alloc(u8, limits.judgement_bytes),
        };
        try inference.loadCache();
        if (inference.cached != inference.cache.len) std.debug.panic("loaded {d} cached judgements but counted {d}", .{ inference.cache.len, inference.cached });
        return inference;
    }

    /// Asks about every unit, then adds a finding for each rule the model is sure of.
    pub fn judge(self: *Inference, units: []const Unit, findings: *memory.Bounded(Finding), enabled: rules.Set) !void {
        if (enabled.len == 0) std.debug.panic("--infer ran with no rules enabled; runCheck always enables at least one", .{});
        const before = findings.len;
        self.jobs.clear();
        self.json.used = 0;
        for (units) |*unit| try self.plan(unit, findings.items()[0..before], enabled);
        try self.askAll();
        for (self.jobs.items()) |*job| try self.record(job, findings);
        try self.saveCache();
        if (findings.len < before) std.debug.panic("--infer removed findings: {d} before, {d} after", .{ before, findings.len });
    }

    /// Queues the questions a unit still needs, answering what it can from the cache.
    fn plan(self: *Inference, unit: *const Unit, settled: []const Finding, enabled: rules.Set) !void {
        if (unit.source.len == 0) std.debug.panic("{s}: function '{s}' has no source to ask about", .{ unit.path, unit.name });
        var job: Job = .{ .unit = unit, .unit_hash = self.unitHash(unit) };
        for (&rules.all) |*rule| {
            if (rule.question.len == 0 or !enabled.enabled(rule.name) or decided(settled, unit, rule.name)) continue;
            if (job.count == max_questions) break;
            job.rules[job.count] = rule;
            job.answers[job.count] = self.cachedAnswer(job.unit_hash, questionHash(rule.question));
            job.count += 1;
        }
        if (job.count == 0) return;
        job.state = try self.stateOf(unit);
        try self.jobs.add(job);
        if (job.count > max_questions) std.debug.panic("{s}: queued {d} questions about '{s}', more than {d}", .{ unit.path, job.count, unit.name, max_questions });
    }

    fn askAll(self: *Inference) !void {
        if (self.jobs.len > self.jobs.buffer.len) std.debug.panic("{d} functions queued in room for {d}", .{ self.jobs.len, self.jobs.buffer.len });
        var pending: usize = 0;
        for (self.jobs.items()) |job| {
            for (job.answers[0..job.count]) |a| pending += @intFromBool(a == null);
        }
        if (pending == 0) return;
        var semaphore: Io.Semaphore = .{ .permits = concurrency };
        var group: Io.Group = .init;
        for (self.jobs.items()) |*job| group.async(self.io, askOne, .{ self, job, &semaphore });
        try group.await(self.io);
        for (self.jobs.items()) |*job| {
            defer job.diagnostics.deinit();
            const err = job.failed orelse continue;
            failure = try self.describe(job, err);
            return error.AskFailed;
        }
        if (pending > self.jobs.len * max_questions) std.debug.panic("{d} unanswered questions across {d} functions", .{ pending, self.jobs.len });
    }

    fn askOne(self: *Inference, job: *Job, semaphore: *Io.Semaphore) void {
        if (job.count == 0) std.debug.panic("{s}: queued '{s}' with no questions; plan() only queues functions with some", .{ job.unit.path, job.unit.name });
        if (job.failed != null) std.debug.panic("{s}: asking about '{s}' again after it failed", .{ job.unit.path, job.unit.name });
        self.ask(job, semaphore) catch |err| {
            job.failed = err;
        };
    }

    fn ask(self: *Inference, job: *Job, semaphore: *Io.Semaphore) !void {
        if (job.count > max_questions) std.debug.panic("{s}: '{s}' has {d} questions queued, more than {d}", .{ job.unit.path, job.unit.name, job.count, max_questions });
        var questions: [max_questions]tai.NamedQuestion = undefined;
        var count: usize = 0;
        for (job.rules[0..job.count], job.answers[0..job.count]) |rule, answer| {
            if (answer != null) continue;
            questions[count] = .{ .name = rule.name, .question = .{ .noul = .{ .instructions = .{ .text = rule.question } } } };
            count += 1;
        }
        if (count == 0) return;
        semaphore.waitUncancelable(self.io);
        defer semaphore.post(self.io);
        var response = try self.client.systemOne(.{ .state = .{ .raw = job.state }, .questions = questions[0..count] }, .{ .diagnostics = &job.diagnostics });
        defer response.deinit();
        for (response.value.answers) |named| {
            const p = switch (named.answer) {
                .noul => |n| n.noul,
                else => continue,
            };
            for (job.rules[0..job.count], job.answers[0..job.count]) |rule, *answer| {
                if (std.mem.eql(u8, rule.name, named.name)) answer.* = p;
            }
        }
        if (count > job.count) std.debug.panic("{s}: asked {d} questions about '{s}' but only {d} were queued", .{ job.unit.path, count, job.unit.name, job.count });
    }

    /// Adds findings for the confident answers and caches the fresh ones.
    fn record(self: *Inference, job: *const Job, findings: *memory.Bounded(Finding)) !void {
        const unit = job.unit;
        if (job.failed) |err| std.debug.panic("{s}: recording answers about '{s}' after the request failed with {t}", .{ unit.path, unit.name, err });
        for (job.rules[0..job.count], job.answers[0..job.count]) |rule, answer| {
            const p = answer orelse continue;
            const question = questionHash(rule.question);
            if (self.cachedAnswer(job.unit_hash, question) == null) try self.cache.add(.{ .unit = job.unit_hash, .question = question, .probability = p });
            if (p < threshold) continue;
            const message = try self.json.format("'{s}' {s} (TypeSafe is {d:.0}% sure).", .{ unit.name, rule.judgement, p * 100 });
            try findings.add(.{ .path = unit.path, .line = unit.line, .column = unit.column, .rule = rule.name, .message = message });
        }
        if (self.cache.len < self.cached) std.debug.panic("the judgement cache shrank from {d} to {d}", .{ self.cached, self.cache.len });
    }

    fn cachedAnswer(self: *const Inference, unit: Hash, question: Hash) ?f64 {
        if (self.cache.len > self.cache.buffer.len) std.debug.panic("{d} cached judgements in room for {d}", .{ self.cache.len, self.cache.buffer.len });
        for (self.cache.items()) |j| {
            if (std.mem.eql(u8, &j.unit, &unit) and std.mem.eql(u8, &j.question, &question)) return j.probability;
        }
        if (self.cached > self.cache.len) std.debug.panic("counted {d} loaded judgements but hold {d}", .{ self.cached, self.cache.len });
        return null;
    }

    /// The model, language and source identify what was asked about; any change asks again.
    fn unitHash(self: *const Inference, unit: *const Unit) Hash {
        if (self.client.model.len == 0) std.debug.panic("the TypeSafe client has no model name; tai falls back to jev-latest, so this is a broken client", .{});
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        for ([_][]const u8{ self.client.model, unit.language, unit.source }) |part| {
            h.update(part);
            h.update(&.{0});
        }
        const out = h.finalResult();
        if (unit.language.len == 0) std.debug.panic("{s}: unit '{s}' has no language", .{ unit.path, unit.name });
        return out;
    }

    /// The request state: the language and the function's source, as JSON.
    fn stateOf(self: *Inference, unit: *const Unit) ![]const u8 {
        if (unit.language.len == 0) std.debug.panic("{s}: '{s}' has no language to tell TypeSafe", .{ unit.path, unit.name });
        const start = self.json.used;
        var writer: Io.Writer = .fixed(self.json.buffer[start..]);
        var json: std.json.Stringify = .{ .writer = &writer };
        json.write(.{ .language = unit.language, .function = unit.source }) catch {
            memory.exceeded = "bytes of --infer requests; raise memory.Limits.judgement_bytes";
            return error.LimitExceeded;
        };
        self.json.used += writer.end;
        if (writer.end <= unit.source.len) std.debug.panic("{s}: the request for '{s}' is {d} bytes, no longer than its {d}-byte source", .{ unit.path, unit.name, writer.end, unit.source.len });
        return self.json.buffer[start..self.json.used];
    }

    fn describe(self: *Inference, job: *const Job, err: anyerror) ![]const u8 {
        if (job.failed == null) std.debug.panic("{s}: describing a failure ({t}) for '{s}', whose request succeeded", .{ job.unit.path, err, job.unit.name });
        const d = job.diagnostics;
        const status: u32 = if (d.status) |s| @intFromEnum(s) else 0;
        const detail = std.mem.trim(u8, d.body[0..@min(d.body.len, 300)], " \t\r\n");
        const text = try self.json.format("TypeSafe could not judge '{s}' in {s}: {t} (HTTP {d}, {d} attempts){s}{s}", .{ job.unit.name, job.unit.path, err, status, d.attempts, if (detail.len > 0) ": " else "", detail });
        if (text.len == 0) std.debug.panic("describing a failed TypeSafe call produced no text", .{});
        return text;
    }

    /// Reads cached judgements; a missing or unreadable cache just means asking again.
    fn loadCache(self: *Inference) !void {
        if (self.cache.len != 0) std.debug.panic("loading {s} into a cache that already holds {d} judgements", .{ cache_path, self.cache.len });
        const bytes = Io.Dir.cwd().readFile(self.io, cache_path, self.file) catch return;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.splitScalar(u8, line, '\t');
            var j: Judgement = undefined;
            _ = std.fmt.hexToBytes(&j.unit, fields.next() orelse continue) catch continue;
            _ = std.fmt.hexToBytes(&j.question, fields.next() orelse continue) catch continue;
            j.probability = std.fmt.parseFloat(f64, fields.next() orelse continue) catch continue;
            if (j.probability < 0 or j.probability > 1) continue;
            try self.cache.add(j);
        }
        self.cached = self.cache.len;
        if (bytes.len == self.file.len) std.debug.panic("{s} filled all {d} bytes of its buffer; raise memory.Limits.judgement_bytes or delete the file", .{ cache_path, self.file.len });
    }

    fn saveCache(self: *Inference) !void {
        if (self.cached > self.cache.len) std.debug.panic("{d} judgements were loaded but only {d} are held", .{ self.cached, self.cache.len });
        if (self.cache.len == self.cached) return;
        var writer: Io.Writer = .fixed(self.file);
        for (self.cache.items()) |j| {
            writer.print("{x}\t{x}\t{d}\n", .{ j.unit, j.question, j.probability }) catch {
                memory.exceeded = "bytes of cached --infer judgements; raise memory.Limits.judgement_bytes";
                return error.LimitExceeded;
            };
        }
        const cwd = Io.Dir.cwd();
        cwd.createDirPath(self.io, cache_dir) catch |e| return e;
        cwd.writeFile(self.io, .{ .sub_path = cache_path, .data = writer.buffered() }) catch |e| return e;
        self.cached = self.cache.len;
        if (writer.end == 0) std.debug.panic("wrote an empty {s} for {d} judgements", .{ cache_path, self.cache.len });
    }
};

fn questionHash(question: []const u8) Hash {
    if (question.len == 0) std.debug.panic("hashing an empty question; only rules with a .question are asked", .{});
    var out: Hash = undefined;
    std.crypto.hash.sha2.Sha256.hash(question, &out, .{});
    if (std.mem.allEqual(u8, &out, 0)) std.debug.panic("the hash of '{s}' is all zeros", .{question});
    return out;
}

/// Whether a deterministic check already reported `rule` inside the unit, so asking is wasted.
fn decided(settled: []const Finding, unit: *const Unit, rule: []const u8) bool {
    if (unit.end_line < unit.line) std.debug.panic("{s}: '{s}' ends on line {d}, before it starts on {d}", .{ unit.path, unit.name, unit.end_line + 1, unit.line + 1 });
    const found = for (settled) |f| {
        if (std.mem.eql(u8, f.rule, rule) and std.mem.eql(u8, f.path, unit.path) and f.line >= unit.line and f.line <= unit.end_line) break true;
    } else false;
    if (found and settled.len == 0) std.debug.panic("found a {s} finding among no findings", .{rule});
    return found;
}

test "judgements round-trip through the cache format" {
    var buffer: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    const j: Judgement = .{ .unit = questionHash("unit"), .question = questionHash("question"), .probability = 0.875 };
    try writer.print("{x}\t{x}\t{d}\n", .{ j.unit, j.question, j.probability });
    var fields = std.mem.splitScalar(u8, std.mem.trimEnd(u8, writer.buffered(), "\n"), '\t');
    var back: Judgement = undefined;
    _ = try std.fmt.hexToBytes(&back.unit, fields.next().?);
    _ = try std.fmt.hexToBytes(&back.question, fields.next().?);
    back.probability = try std.fmt.parseFloat(f64, fields.next().?);
    try std.testing.expectEqualSlices(u8, &j.unit, &back.unit);
    try std.testing.expectEqualSlices(u8, &j.question, &back.question);
    try std.testing.expectEqual(j.probability, back.probability);
}
