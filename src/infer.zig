//! The inference tier. For each function and test, `check --infer` asks a decision model the
//! questions of the rules that no deterministic check can settle, skipping any a deterministic
//! check already answered there. The model is TypeSafe's Jev unless [infer] in zanity.toml names
//! another System One server, such as a local Kev. Answers are kept in a store by model, function
//! and question, so unchanged code is never asked about twice.
const std = @import("std");
const assert = @import("assert.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const tai = @import("tai");
const rules = @import("rules.zig");
const memory = @import("memory.zig");
const facts_module = @import("facts.zig");
const Unit = facts_module.Unit;
const Finding = facts_module.Finding;
const store = @import("store.zig");
const strings = @import("strings.zig");

/// How sure the model must be before a judgement becomes a finding.
pub const default_threshold = 0.8;
/// Requests to the model at once when zanity.toml doesn't say.
pub const default_concurrency = 8;
const max_questions = 16;

const Job = struct {
    unit: *const Unit,
    unit_hash: store.Digest,
    rules: [max_questions]*const rules.Rule = undefined,
    answers: [max_questions]?f64 = @splat(null),
    known: [max_questions]bool = @splat(false),
    count: usize = 0,
    state: []const u8 = "",
    failed: ?anyerror = null,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    diagnostics: tai.Client.Diagnostics = .{},
};

/// Reports how many functions the model has answered for, while the answers arrive.
pub const Reporter = struct {
    state: *anyopaque,
    report: *const fn (state: *anyopaque, done: usize, total: usize) void,
};

/// What the last `judge` did: functions it had questions about, how many needed the model, and how long it took.
pub const Stats = struct { functions: usize = 0, asked: usize = 0, seconds: i64 = 0 };

/// Why the last `judge` failed, with the detail the server returned.
pub var failure: []const u8 = "";

/// Which System One server to ask, from [infer] in zanity.toml. Each unset field falls back to
/// TypeSafe's variable in `environ`, then to TypeSafe's API and model.
pub const Server = struct {
    environ: *const std.process.Environ.Map,
    url: ?[]const u8 = null,
    model: ?[]const u8 = null,
    /// The variable holding the key; only this one is read, so another server never gets TypeSafe's key.
    api_key_env: ?[]const u8 = null,

    pub fn keyVariable(server: Server) []const u8 {
        const name = server.api_key_env orelse tai.Client.env.api_key;
        if (name.len == 0) assert.panic("[infer] api_key_env is empty; config refuses an empty name", .{});
        if (server.api_key_env != null and !std.mem.eql(u8, name, server.api_key_env.?)) assert.panic("reading the key from {s} instead of api_key_env", .{name});
        return name;
    }
};

pub const Inference = struct {
    client: tai.Client,
    /// What answers are stored under: the model, and the server when it isn't TypeSafe's.
    model: []const u8,
    io: Io,
    store: store.Store,
    jobs: memory.Bounded(Job),
    json: memory.Text,
    reporter: ?Reporter = null,
    concurrency: usize = default_concurrency,
    /// How sure the model must be for a judgement to become a finding; [infer] threshold sets it.
    threshold: f64 = default_threshold,
    answered: std.atomic.Value(usize) = .init(0),
    stats: Stats = .{},

    /// Fails with `error.MissingApiKey` when asking TypeSafe's API and the key variable is not set.
    pub fn initInference(gpa: Allocator, io: Io, limits: memory.Limits, server: Server) !Inference {
        const environ = server.environ;
        if (limits.judgement_bytes == 0 or limits.store_bytes == 0) assert.panic("memory.Limits allows {d} bytes of --infer requests and a {d}-byte store; both must be above 0", .{ limits.judgement_bytes, limits.store_bytes });
        const client = try tai.Client.init(gpa, io, .{
            .api_key = present(environ, server.keyVariable()),
            .base_url = server.url orelse present(environ, tai.Client.env.base_url),
            .model = server.model orelse present(environ, tai.Client.env.default_model),
        });
        const remote = !std.mem.eql(u8, client.base_url, tai.Client.default_base_url);
        const inference: Inference = .{
            .client = client,
            .model = if (remote) try std.fmt.allocPrint(gpa, "{s}@{s}", .{ client.model, client.base_url }) else client.model,
            .io = io,
            .store = try .initStore(gpa, io, environ, limits.store_bytes),
            .jobs = try .initBounded(gpa, limits.functions, "functions to ask TypeSafe about"),
            .json = try .initText(gpa, limits.judgement_bytes),
        };
        if (inference.model.len < client.model.len) assert.panic("answers are stored under '{s}', shorter than the model '{s}'", .{ inference.model, client.model });
        if (client.model.len == 0) assert.panic("the System One client has no model name; answers are stored by model", .{});
        return inference;
    }

    /// Asks about every unit, then adds a finding for each rule the model is sure of.
    pub fn judge(self: *Inference, units: []const Unit, findings: *memory.Bounded(Finding), enabled: rules.Set) !void {
        if (enabled.len == 0) assert.panic("--infer ran with no rules enabled; runCheck always enables at least one", .{});
        const before = findings.len;
        self.jobs.clear();
        self.json.used = 0;
        const started = Io.Timestamp.now(self.io, .awake);
        for (units) |*unit| try self.plan(unit, findings.items()[0..before], enabled);
        try self.askAll();
        self.stats.seconds = started.durationTo(Io.Timestamp.now(self.io, .awake)).toSeconds();
        for (self.jobs.items()) |*job| try self.record(job, findings);
        try self.recordRun();
        if (findings.len < before) assert.panic("--infer removed findings: {d} before, {d} after; judge() must only add findings", .{ before, findings.len });
    }

    /// Queues the questions a unit still needs, answering what it can from the cache.
    fn plan(self: *Inference, unit: *const Unit, settled: []const Finding, enabled: rules.Set) !void {
        if (unit.source.len == 0) assert.panic("{s}: function '{s}' has no source to ask about; facts.unit() must store the function's source when it records the unit", .{ unit.path, unit.name });
        var job: Job = .{ .unit = unit, .unit_hash = self.unitHash(unit) };
        for (&rules.all) |*rule| {
            if (rule.question.len == 0 or !enabled.enabled(rule.name) or !asked(rule.asks, unit) or decided(settled, unit, rule)) continue;
            if (job.count == max_questions) break;
            job.rules[job.count] = rule;
            job.answers[job.count] = try self.store.cached(self.model, store.digest(&.{rule.question}), job.unit_hash);
            job.known[job.count] = job.answers[job.count] != null;
            job.count += 1;
        }
        if (job.count == 0) return;
        job.state = try self.stateOf(unit);
        try self.jobs.add(job);
        if (job.count > max_questions) assert.panic("{s}: queued {d} questions about '{s}', more than {d}; raise max_questions to the number of judgement rules in rules.all", .{ unit.path, job.count, unit.name, max_questions });
    }

    fn askAll(self: *Inference) !void {
        if (self.jobs.len > self.jobs.capacity()) assert.panic("{d} functions queued in room for {d}; raise memory.Limits for --infer functions, or check fewer files at once", .{ self.jobs.len, self.jobs.capacity() });
        var pending: usize = 0;
        var waiting: usize = 0;
        for (self.jobs.items()) |job| {
            var missing: usize = 0;
            for (job.answers[0..job.count]) |a| missing += @intFromBool(a == null);
            pending += missing;
            waiting += @intFromBool(missing > 0);
        }
        self.stats = .{ .functions = self.jobs.len, .asked = waiting };
        if (pending == 0) return;
        self.answered.store(0, .monotonic);
        if (self.concurrency == 0) assert.panic("--infer would ask the model with no requests allowed at once; set [infer] concurrency in zanity.toml to at least 1", .{});
        var semaphore: Io.Semaphore = .{ .permits = self.concurrency };
        var group: Io.Group = .init;
        // The watcher needs its own thread from the start: `async` may defer a task until `await`,
        // which would show no progress until the requests queued ahead of it were done. Without a
        // spare thread it still runs, just late.
        if (self.reporter != null) group.concurrent(self.io, watch, .{ self, self.jobs.len }) catch
            group.async(self.io, watch, .{ self, self.jobs.len });
        for (self.jobs.items()) |*job| group.async(self.io, askOne, .{ self, job, &semaphore });
        try group.await(self.io);
        for (self.jobs.items()) |*job| {
            defer job.diagnostics.deinit();
            const err = job.failed orelse continue;
            failure = try self.describe(job, err);
            return error.AskFailed;
        }
        if (pending > self.jobs.len * max_questions) assert.panic("{d} unanswered questions across {d} functions; plan() must queue at most max_questions per function", .{ pending, self.jobs.len });
    }

    /// Reports progress every 100 ms until every function is answered; the reporter decides what to redraw.
    fn watch(self: *Inference, total: usize) void {
        const reporter = self.reporter orelse assert.panic("watching --infer progress with no reporter; askAll only watches when one is set", .{});
        if (total == 0) assert.panic("watching progress over no functions; askAll() must start the watcher only when functions are queued", .{});
        if (total > self.jobs.len) assert.panic("watching {d} functions, but only {d} are queued; askAll() must pass the number of functions it queued", .{ total, self.jobs.len });
        for (0..24 * 60 * 60 * 10) |_| {
            const done = self.answered.load(.monotonic);
            reporter.report(reporter.state, done, total);
            if (done == total) return;
            self.io.sleep(.fromMilliseconds(100), .awake) catch return;
        }
    }

    fn askOne(self: *Inference, job: *Job, semaphore: *Io.Semaphore) void {
        if (job.count == 0) assert.panic("{s}: queued '{s}' with no questions; plan() only queues functions with some", .{ job.unit.path, job.unit.name });
        if (job.failed != null) assert.panic("{s}: asking about '{s}' again after it failed; askAll() must ask about each function once", .{ job.unit.path, job.unit.name });
        defer _ = self.answered.fetchAdd(1, .monotonic);
        self.ask(job, semaphore) catch |err| {
            job.failed = err;
        };
    }

    fn ask(self: *Inference, job: *Job, semaphore: *Io.Semaphore) !void {
        if (job.count > max_questions) assert.panic("{s}: '{s}' has {d} questions queued, more than {d}; raise max_questions to the number of judgement rules in rules.all", .{ job.unit.path, job.unit.name, job.count, max_questions });
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
        const usage = response.value.usage;
        job.input_tokens = usage.input_tokens;
        job.output_tokens = usage.output_tokens;
        for (response.value.answers) |named| {
            const p = switch (named.answer) {
                .noul => |n| n.noul,
                else => continue,
            };
            for (job.rules[0..job.count], job.answers[0..job.count]) |rule, *answer| {
                if (std.mem.eql(u8, rule.name, named.name)) answer.* = p;
            }
        }
        if (count > job.count) assert.panic("{s}: asked {d} questions about '{s}' but only {d} were queued; ask() must ask only the unanswered questions in job.rules", .{ job.unit.path, count, job.unit.name, job.count });
    }

    /// Adds findings for the confident answers and caches the fresh ones.
    fn record(self: *Inference, job: *const Job, findings: *memory.Bounded(Finding)) !void {
        const unit = job.unit;
        if (job.failed) |err| assert.panic("{s}: recording answers about '{s}' after the request failed with {t}; askOne() must skip record() when the job failed", .{ unit.path, unit.name, err });
        for (job.rules[0..job.count], job.answers[0..job.count], job.known[0..job.count]) |rule, answer, known| {
            const p = answer orelse continue;
            const question = store.digest(&.{rule.question});
            if (!known) try self.store.keepAnswer(.{ .model = self.model, .question = question, .unit = job.unit_hash, .language = unit.language, .source = unit.source, .probability = p });
            const fired = p >= self.threshold;
            try self.store.observe(.{ .path = unit.path, .rule = rule.name, .unit = job.unit_hash, .unit_name = unit.name, .line = unit.line + 1, .language = unit.language, .model = self.model, .question = question, .probability = p, .threshold = self.threshold, .fired = fired });
            if (!fired) continue;
            const message = try self.json.format("'{s}' {s} ({s} is {d:.0}% sure).", .{ unit.name, rule.judgement, self.client.model, p * 100 });
            try findings.add(.{ .path = unit.path, .line = unit.line, .column = unit.column, .rule = rule.name, .message = message, .fix = unit.fix });
        }
        if (job.count > max_questions) assert.panic("{s}: recorded {d} answers about '{s}', more than {d}; record() must keep at most one answer per queued question", .{ unit.path, job.count, unit.name, max_questions });
    }

    /// Keeps a row for this run in the store, with the directory it ran in and the tokens it used.
    fn recordRun(self: *Inference) !void {
        var input: u64 = 0;
        var output: u64 = 0;
        for (self.jobs.items()) |job| {
            input += job.input_tokens;
            output += job.output_tokens;
        }
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const length = try Io.Dir.cwd().realPathFile(self.io, ".", &buffer);
        if (length == 0) assert.panic("the directory zanity runs in resolved to an empty path; realPath() must return at least '/'", .{});
        const s = self.stats;
        if (s.asked > s.functions) assert.panic("--infer asked about {d} of {d} functions; askAll() must count only queued functions as asked", .{ s.asked, s.functions });
        if (s.asked == 0 and input + output > 0) assert.panic("{d} tokens used with no function asked about; ask() must record usage only for a request it made", .{input + output});
        try self.store.keepRun(.{ .path = buffer[0..length], .units = s.functions, .asked = s.asked, .cached = s.functions - s.asked, .input_tokens = input, .output_tokens = output });
    }

    /// The language and source identify a function; the model is kept alongside.
    fn unitHash(self: *const Inference, unit: *const Unit) store.Digest {
        if (self.model.len == 0) assert.panic("answers are stored under no model; initInference() names it", .{});
        if (unit.language.len == 0) assert.panic("{s}: unit '{s}' has no language; facts.unit() must record the file's language with each function", .{ unit.path, unit.name });
        return store.digest(&.{ unit.language, unit.source });
    }

    /// The request state: the language and the function's source, as JSON.
    fn stateOf(self: *Inference, unit: *const Unit) ![]const u8 {
        if (unit.language.len == 0) assert.panic("{s}: '{s}' has no language to tell the model; facts.unit() must record the file's language with each function", .{ unit.path, unit.name });
        const start = self.json.used;
        var writer: Io.Writer = .fixed(self.json.buffer[start..]);
        var json: std.json.Stringify = .{ .writer = &writer };
        const written = switch (unit.kind) {
            .function, .@"test" => json.write(.{ .language = unit.language, .function = unit.source }),
            .setting => json.write(.{ .file = unit.path, .line = unit.source }),
            .project => json.write(.{ .files = unit.source }),
            .cluster => json.write(.{ .language = unit.language, .repeated = unit.source }),
        };
        written catch {
            memory.exceeded = "bytes of --infer requests; raise memory.Limits.judgement_bytes";
            return error.LimitExceeded;
        };
        self.json.used += writer.end;
        if (writer.end <= unit.source.len) assert.panic("{s}: the request for '{s}' is {d} bytes, no longer than its {d}-byte source; stateOf() must include the whole source in the request", .{ unit.path, unit.name, writer.end, unit.source.len });
        return self.json.buffer[start..self.json.used];
    }

    fn describe(self: *Inference, job: *const Job, err: anyerror) ![]const u8 {
        if (job.failed == null) assert.panic("{s}: describing a failure ({t}) for '{s}', whose request succeeded; call describe() only for a job whose failed is set", .{ job.unit.path, err, job.unit.name });
        const d = job.diagnostics;
        const status: u32 = if (d.status) |s| @backingInt(s) else 0;
        const detail = std.mem.trim(u8, d.body[0..@min(d.body.len, 300)], " \t\r\n");
        const text = try self.json.format("{s} at {s} could not judge '{s}' in {s}: {t} (HTTP {d}, {d} attempts){s}{s}", .{ self.client.model, self.client.base_url, job.unit.name, job.unit.path, err, status, d.attempts, if (detail.len > 0) ": " else "", detail });
        if (text.len == 0) assert.panic("describing a failed model call produced no text; describe() must write the error and the function, so check its format call", .{});
        return text;
    }
};

/// The variable's value, or null when it is unset or blank, as tai treats the environment.
fn present(environ: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    if (name.len == 0) assert.panic("reading an unnamed environment variable; pass a name such as TYPESAFE_API_KEY", .{});
    const value = std.mem.trim(u8, environ.get(name) orelse return null, " \t\r\n");
    if (std.mem.indexOfAny(u8, value, "\r\n") != null) assert.panic("{s} still holds a line break after trimming", .{name});
    return if (value.len == 0) null else value;
}

/// Whether a question about `asks` applies to the unit: the error-message questions to functions
/// that report errors, the function questions to every function, and the test questions to tests.
fn asked(asks: rules.Asks, unit: *const Unit) bool {
    if (unit.name.len == 0) assert.panic("{s}: a unit has no name; facts.unit() records the function's or test's name", .{unit.path});
    const applies = switch (asks) {
        .errors => unit.kind == .function and unit.reports_error,
        .function => unit.kind == .function,
        .@"test" => unit.kind == .@"test",
        .setting => unit.kind == .setting,
        .project => unit.kind == .project,
        .cluster => unit.kind == .cluster,
    };
    if (applies and asks == .errors and !unit.reports_error) assert.panic("{s}: asking the error questions about '{s}', which reports no error", .{ unit.path, unit.name });
    return applies;
}

/// Whether a deterministic check already reported `rule`, or a rule that settles its question,
/// inside the unit, so asking is wasted.
fn decided(settled: []const Finding, unit: *const Unit, rule: *const rules.Rule) bool {
    if (unit.end_line < unit.line) assert.panic("{s}: '{s}' ends on line {d}, before it starts on {d}; facts.unit() must record the function's first line before its last", .{ unit.path, unit.name, unit.end_line + 1, unit.line + 1 });
    const found = for (settled) |f| {
        if (!std.mem.eql(u8, f.path, unit.path) or f.line < unit.line or f.line > unit.end_line) continue;
        if (std.mem.eql(u8, f.rule, rule.name) or strings.contains(rule.settled_by, f.rule)) break true;
    } else false;
    if (found and settled.len == 0) assert.panic("found a {s} finding among no findings; decided() must search only the findings added for this unit", .{rule.name});
    return found;
}
