//! Calibrating --infer against what people say: `zanity mark` records that a finding is real or
//! not a problem, `zanity review` picks unlabelled answers to label across the range of how sure
//! the model was, and `zanity stats` shows how often each question fires and, against the labels,
//! how precise and complete it is at each threshold.
const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const store_module = @import("store.zig");
const Store = store_module.Store;
const Observed = store_module.Observed;
const zcli = @import("zcli");
const main = @import("main.zig");

/// What the calibration commands fail with: misuse, or the store or memory giving out.
pub const Error = error{ Usage, StoreUnavailable, LimitExceeded };

/// Where the answers are and where text for the rows goes.
pub const Calibration = struct { store: *const Store, text: *memory.Text };

pub const LabelOptions = struct {
    /// The finding's place, PATH:LINE, then its rule.
    finding: []const []const u8,
    confirm: bool = false,
    @"not-a-problem": bool = false,
};

/// A label `zanity mark` recorded, as `--json` and `--plain` publish it.
pub const LabelRow = struct { path: []const u8, line: u32, rule: []const u8, unit: []const u8, probability: f64, real: bool };

pub const ReviewOptions = struct {
    rules: []const []const u8,
    limit: u32 = 20,
};

/// An unlabelled answer to label, as `--json` and `--plain` publish it.
pub const ReviewRow = struct { path: []const u8, line: u32, rule: []const u8, unit: []const u8, probability: f64 };

pub const StatsOptions = struct {
    rule: ?[]const u8 = null,
    thresholds: bool = false,
};

/// One question's answers, or with --thresholds its precision and recall at one threshold.
pub const StatsRow = struct {
    rule: []const u8,
    answers: u32,
    fired: u32,
    /// Answers between 0.35 and 0.65, where the model is unsure; a well-posed question has few.
    unsure: u32,
    confirmed: u32,
    not_a_problem: u32,
    /// With --thresholds: the threshold, and how precise and complete the question is there
    /// against the labels; 0 otherwise.
    threshold: f64 = 0,
    precision: f64 = 0,
    recall: f64 = 0,
};

pub const max_rows = 4096;
var label_rows: [1]LabelRow = undefined;
var review_rows: [max_rows]ReviewRow = undefined;
var stats_rows: [max_rows]StatsRow = undefined;

/// The store of answers and labels, opened for the calibration commands.
fn calibration(ctx: *zcli.Context) !Calibration {
    const ws = main.workspaceOf(ctx);
    const environ = ws.environ orelse assert.panic("a calibration command ran without the environment; main() passes it to the workspace", .{});
    if (ws.source_cache == null) ws.source_cache = Store.initStore(std.heap.page_allocator, ws.io, environ, ws.limits.store_bytes) catch |e| {
        if (e == error.StoreUnavailable) return ctx.fail(.io, try ws.text.format("Could not open the store: {s}.", .{store_module.failure[0..store_module.failure_len]}), "Check ZANITY_STORE names a writable file.");
        return e;
    };
    if (ws.limits.text_bytes == 0) assert.panic("the workspace allows no text for calibration rows; initWorkspace() reserves it", .{});
    if (ws.source_cache == null) assert.panic("the store is still closed after opening it", .{});
    return .{ .store = &ws.source_cache.?, .text = &ws.text };
}

/// What to tell someone who called a calibration command wrongly: the problem and the fix.
const Misuse = struct { problem: []const u8, fix: []const u8 };

/// A calibration command's rows, or its misuse told as a usage error.
fn calibrated(comptime Row: type, ctx: *zcli.Context, result: Error![]const Row, misuse: Misuse) ![]const Row {
    if (misuse.problem.len == 0 or misuse.fix.len == 0) assert.panic("a calibration command has no words for being misused", .{});
    const rows = result catch |e| switch (e) {
        error.Usage => return ctx.fail(.usage, misuse.problem, misuse.fix),
        else => return e,
    };
    if (rows.len > max_rows) assert.panic("a calibration command returned {d} rows, past its {d}", .{ rows.len, max_rows });
    return rows;
}

pub fn runMark(ctx: *zcli.Context, options: LabelOptions) ![]const LabelRow {
    if (options.finding.len > 64) return ctx.fail(.usage, "zanity mark takes one finding at a time.", "Mark each finding with its own command.");
    const rows = try calibrated(LabelRow, ctx, label(try calibration(ctx), options), .{ .problem = "zanity mark takes a finding's PATH:LINE and rule, with --confirm or --not-a-problem, for a finding --infer reported there.", .fix = "Copy the place and rule from zanity check --infer, such as zanity mark app.py:12 cwe-15 --not-a-problem." });
    if (rows.len != 1) assert.panic("zanity mark labelled {d} findings; it labels exactly one", .{rows.len});
    if (rows[0].real != options.confirm) assert.panic("zanity mark --{s} recorded the opposite", .{if (options.confirm) "confirm" else "not-a-problem"});
    return rows;
}

pub fn runReview(ctx: *zcli.Context, options: ReviewOptions) ![]const ReviewRow {
    if (options.limit > max_rows) return ctx.fail(.usage, "zanity review lists at most 4096 answers at once.", "Pass a smaller --limit.");
    const rows = try calibrated(ReviewRow, ctx, review(try calibration(ctx), options), .{ .problem = "zanity review takes one --infer question's rule, and a --limit above 0.", .fix = "Name a question, such as zanity review cwe-15." });
    if (rows.len > options.limit) assert.panic("zanity review listed {d} answers past --limit {d}", .{ rows.len, options.limit });
    for (rows) |r| if (!std.mem.eql(u8, r.rule, options.rules[0])) assert.panic("zanity review {s} listed an answer to {s}", .{ options.rules[0], r.rule });
    return rows;
}

pub fn runStats(ctx: *zcli.Context, options: StatsOptions) ![]const StatsRow {
    const rows = try calibrated(StatsRow, ctx, stats(try calibration(ctx), options), .{ .problem = "zanity stats takes at most one --rule.", .fix = "Run zanity stats, or zanity stats --rule cwe-15." });
    for (rows) |r| if (r.fired > r.answers) assert.panic("'{s}' fired {d} times in {d} answers", .{ r.rule, r.fired, r.answers });
    if (!options.thresholds) for (rows) |r| if (r.threshold != 0) assert.panic("'{s}' has a threshold row without --thresholds", .{r.rule});
    return rows;
}

/// Labels the finding on `path:line` under `rule`, from the latest answer kept there.
pub fn label(c: Calibration, options: LabelOptions) Error![]const LabelRow {
    if (options.finding.len != 2) return error.Usage;
    if (options.confirm == options.@"not-a-problem") return error.Usage;
    const place = options.finding[0];
    const rule = options.finding[1];
    const colon = std.mem.lastIndexOfScalar(u8, place, ':') orelse return error.Usage;
    const line = std.fmt.parseInt(u32, place[colon + 1 ..], 10) catch return error.Usage;
    var found: ?Observed = null;
    var copy: Copy = .{ .text = c.text, .found = &found };
    c.store.eachObserved(.{ .rule = rule, .path = place[0..colon], .line = line }, &copy, Copy.first) catch |e| return mapped(e);
    const observed = found orelse return error.Usage;
    if (observed.line != line) assert.panic("asked for line {d} and found an answer on line {d}", .{ line, observed.line });
    c.store.label(observed.rule, observed.unit, options.confirm) catch |e| return mapped(e);
    label_rows[0] = .{ .path = observed.path, .line = observed.line, .rule = observed.rule, .unit = try c.text.copy(&observed.unit), .probability = observed.probability, .real = options.confirm };
    if (line == 0) assert.panic("labelled a finding on line 0; kept answers count lines from 1", .{});
    return label_rows[0..1];
}

/// Keeps the first answer `eachObserved` reads, copying its text out of the row.
const Copy = struct {
    text: *memory.Text,
    found: *?Observed,

    fn first(self: *Copy, observed: Observed) anyerror!bool {
        if (observed.rule.len == 0) assert.panic("a kept answer at {s}:{d} has no rule", .{ observed.path, observed.line });
        if (self.found.* != null) assert.panic("kept a second answer at {s}:{d}; first() stops after one", .{ observed.path, observed.line });
        var kept = observed;
        kept.rule = try self.text.copy(observed.rule);
        kept.path = try self.text.copy(observed.path);
        kept.unit_name = try self.text.copy(observed.unit_name);
        self.found.* = kept;
        return false;
    }
};

/// Probability bands review samples evenly, so labels cover what the model missed as well as found.
const bands = 5;

/// Unlabelled answers to `rule`'s question, at most `limit`, spread evenly over the bands.
pub fn review(c: Calibration, options: ReviewOptions) Error![]const ReviewRow {
    if (options.rules.len != 1 or options.limit == 0) return error.Usage;
    const limit = @min(options.limit, max_rows);
    if (options.rules[0].len == 0) return error.Usage;
    var sample: Sample = .{ .text = c.text, .per_band = (limit + bands - 1) / bands, .limit = limit };
    c.store.eachObserved(.{ .rule = options.rules[0] }, &sample, Sample.take) catch |e| return mapped(e);
    if (sample.count > limit) assert.panic("review kept {d} answers past its limit of {d}", .{ sample.count, limit });
    if (sample.per_band * bands < limit) assert.panic("{d} answers per band can't fill a limit of {d}", .{ sample.per_band, limit });
    return review_rows[0..sample.count];
}

const Sample = struct {
    text: *memory.Text,
    per_band: u32,
    limit: u32,
    taken: [bands]u32 = @splat(0),
    count: u32 = 0,

    fn take(self: *Sample, observed: Observed) anyerror!bool {
        if (observed.probability < 0 or observed.probability > 1) assert.panic("a kept answer has probability {d}", .{observed.probability});
        if (self.count >= self.limit) assert.panic("review took {d} answers past its limit of {d}", .{ self.count, self.limit });
        if (observed.real != null) return true;
        const band = @min(@as(usize, @intFromFloat(observed.probability * bands)), bands - 1);
        if (self.taken[band] >= self.per_band) return true;
        self.taken[band] += 1;
        review_rows[self.count] = .{ .path = try self.text.copy(observed.path), .line = observed.line, .rule = try self.text.copy(observed.rule), .unit = try self.text.copy(&observed.unit), .probability = observed.probability };
        self.count += 1;
        return self.count < self.limit;
    }
};

/// Thresholds --thresholds measures each labelled question at.
const thresholds = [_]f64{ 0.5, 0.6, 0.7, 0.8, 0.85, 0.9, 0.95 };
/// Labelled answers kept per question to measure thresholds against.
const max_labelled = 256;

/// Each question's answers; with --thresholds, also its precision and recall at each threshold.
pub fn stats(c: Calibration, options: StatsOptions) Error![]const StatsRow {
    if (options.rule) |rule| if (rule.len == 0) return error.Usage;
    var tally: Tally = .{ .text = c.text };
    c.store.eachObserved(.{ .rule = options.rule orelse "" }, &tally, Tally.add) catch |e| return mapped(e);
    if (tally.count > max_rows) assert.panic("tallied {d} questions in room for {d}", .{ tally.count, max_rows });
    if (!options.thresholds) {
        for (tally.rules[0..tally.count], 0..) |r, i| stats_rows[i] = r.row;
        return stats_rows[0..tally.count];
    }
    var count: usize = 0;
    for (tally.rules[0..tally.count]) |*r| {
        if (r.labelled == 0) continue;
        for (thresholds) |t| {
            if (count == max_rows) return stats_rows[0..count];
            stats_rows[count] = measured(r, t);
            count += 1;
        }
    }
    if (count > max_rows) assert.panic("wrote {d} threshold rows in room for {d}", .{ count, max_rows });
    return stats_rows[0..count];
}

/// One question's answers so far, with the probabilities of the labelled ones.
const Counts = struct {
    row: StatsRow,
    labelled: usize = 0,
    probabilities: [max_labelled]f64 = undefined,
    real: [max_labelled]bool = undefined,
};

const Tally = struct {
    text: *memory.Text,
    rules: [max_rows]Counts = undefined,
    count: usize = 0,

    fn add(self: *Tally, o: Observed) anyerror!bool {
        if (o.rule.len == 0) assert.panic("a kept answer at {s}:{d} has no rule", .{ o.path, o.line });
        const r = try self.of(o.rule);
        if (r.labelled > max_labelled) assert.panic("'{s}' kept {d} labels in room for {d}", .{ o.rule, r.labelled, max_labelled });
        r.row.answers += 1;
        r.row.fired += @intFromBool(o.probability >= o.threshold);
        r.row.unsure += @intFromBool(o.probability >= 0.35 and o.probability <= 0.65);
        const real = o.real orelse return true;
        if (real) r.row.confirmed += 1 else r.row.not_a_problem += 1;
        if (r.labelled < max_labelled) {
            r.probabilities[r.labelled] = o.probability;
            r.real[r.labelled] = real;
            r.labelled += 1;
        }
        return true;
    }

    fn of(self: *Tally, rule: []const u8) !*Counts {
        if (rule.len == 0) assert.panic("tallying an answer with no rule", .{});
        if (self.count > max_rows) assert.panic("tallied {d} questions in room for {d}", .{ self.count, max_rows });
        for (self.rules[0..self.count]) |*r| if (std.mem.eql(u8, r.row.rule, rule)) return r;
        if (self.count == max_rows) {
            memory.exceeded = "questions in the store";
            return error.LimitExceeded;
        }
        self.rules[self.count] = .{ .row = .{ .rule = try self.text.copy(rule), .answers = 0, .fired = 0, .unsure = 0, .confirmed = 0, .not_a_problem = 0 } };
        self.count += 1;
        return &self.rules[self.count - 1];
    }
};

/// The question's precision and recall at threshold `t`, against its labels.
fn measured(r: *const Counts, t: f64) StatsRow {
    if (r.labelled == 0) assert.panic("measuring '{s}' with no labels", .{r.row.rule});
    var true_positive: f64 = 0;
    var fired: f64 = 0;
    var real: f64 = 0;
    for (r.probabilities[0..r.labelled], r.real[0..r.labelled]) |p, is_real| {
        const fires = p >= t;
        fired += @floatFromInt(@intFromBool(fires));
        real += @floatFromInt(@intFromBool(is_real));
        true_positive += @floatFromInt(@intFromBool(fires and is_real));
    }
    if (true_positive > fired or true_positive > real) assert.panic("'{s}' has {d} true positives from {d} fired and {d} real", .{ r.row.rule, true_positive, fired, real });
    var row = r.row;
    row.threshold = t;
    row.precision = if (fired > 0) true_positive / fired else 0;
    row.recall = if (real > 0) true_positive / real else 0;
    return row;
}

/// The store's errors, and those a visitor raised, as the calibration commands report them.
fn mapped(err: anyerror) error{ StoreUnavailable, LimitExceeded } {
    if (err == error.Usage) assert.panic("the store raised a usage error; only the commands decide misuse", .{});
    const reported: error{ StoreUnavailable, LimitExceeded } = if (err == error.LimitExceeded) error.LimitExceeded else error.StoreUnavailable;
    if (reported == error.StoreUnavailable and store_module.failure_len == 0 and err == error.StoreUnavailable) assert.panic("the store failed without saying why", .{});
    return reported;
}
