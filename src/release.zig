//! Release gates: a GitHub Actions job that publishes a release must not run unless the tests
//! passed, either earlier in the same job or in a job it needs, through every job between.
const std = @import("std");
const release_checks = @import("release_checks.zig");
const checkingAction = release_checks.checkingAction;
const isCheck = release_checks.isCheck;
const Calls = @import("release_calls.zig").Calls;
const release_steps = @import("release_steps.zig");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const strings = @import("strings.zig");
const Finding = @import("facts.zig").Finding;

/// The most jobs one workflow may define for its release gates to be checked.
const max_jobs = 64;
/// The most jobs one job may need.
const max_needs = 16;
/// How much of a command line is inspected for check and release commands.
pub const command_window_bytes = 512;

/// Words in the path of a reusable workflow zanity cannot read that say it runs the checks.
const check_workflow_words = [_][]const u8{ "test", "tests", "check", "checks", "ci", "lint", "verify" };
/// Status functions that let a job run after a job it needs has failed.
const failure_tolerant = [_][]const u8{ "always()", "failure()", "cancelled()" };

const Job = struct {
    id: []const u8,
    /// The line of the job's key.
    row: u32,
    key_indent: ?usize = null,
    needs: [max_needs][]const u8 = undefined,
    needs_len: u8 = 0,
    condition: []const u8 = "",
    /// Whether the job calls a reusable workflow that runs the checks.
    calls_checks: bool = false,
    first_check: ?u32 = null,
    release: ?Release = null,
    /// The image_action step still being read, which releases once its `with:` sets `push`, and
    /// the indent of its first line, where the next step starts.
    image_step: ?Release = null,
    image_indent: usize = 0,

    fn needed(self: *const Job) []const []const u8 {
        if (self.id.len == 0) assert.panic("listing the needs of a job with no id; addJob() names every job", .{});
        if (self.needs_len > max_needs) assert.panic("job '{s}' records {d} needs past its {d} slots; addNeed() must refuse the extra", .{ self.id, self.needs_len, max_needs });
        return self.needs[0..self.needs_len];
    }

    fn addNeed(self: *Job, name: []const u8) !void {
        if (self.id.len == 0) assert.panic("adding need '{s}' to a job with no id; addJob() names every job", .{name});
        const id = std.mem.trim(u8, name, " \t\"'");
        if (id.len == 0) return;
        if (self.needs_len == max_needs) {
            memory.exceeded = "jobs one GitHub Actions job needs";
            return error.LimitExceeded;
        }
        self.needs[self.needs_len] = id;
        self.needs_len += 1;
        if (!std.mem.eql(u8, self.needed()[self.needs_len - 1], id)) assert.panic("job '{s}' added need '{s}' but its last need is '{s}'", .{ self.id, id, self.needed()[self.needs_len - 1] });
    }

    fn checks(self: *const Job) bool {
        if (self.id.len == 0) assert.panic("asked whether a job with no id runs the checks; parse() names every job", .{});
        if (self.first_check) |row| if (row < self.row) assert.panic("job '{s}' at line {d} records a check at line {d}, before the job starts", .{ self.id, self.row + 1, row + 1 });
        return self.calls_checks or self.first_check != null;
    }
};

const Release = struct { row: u32, column: u32, text: []const u8 };

/// The parse of one workflow: its jobs, and the block a multi-line value is still being read for.
const Workflow = struct {
    /// What the project's workflows do, for the jobs that call them.
    calls: *const Calls,
    jobs: [max_jobs]Job = undefined,
    len: usize = 0,
    in_jobs: bool = false,
    in_on: bool = false,
    on_indent: ?usize = null,
    /// Whether `on:` lists workflow_call, and whether it lists any other event.
    called: bool = false,
    triggered: bool = false,
    job_indent: ?usize = null,
    /// The indent of the `run:` or `if:` key whose block scalar the following lines continue.
    block_indent: ?usize = null,
    block_is_condition: bool = false,
    needs_indent: ?usize = null,

    fn current(self: *Workflow) ?*Job {
        if (self.len > max_jobs) assert.panic("parsed {d} jobs past the {d} slots; addJob() must refuse the extra", .{ self.len, max_jobs });
        if (self.len == 0) return null;
        if (self.jobs[self.len - 1].id.len == 0) assert.panic("job {d} of the workflow has no id; addJob() names every job", .{self.len});
        return &self.jobs[self.len - 1];
    }

    fn addJob(self: *Workflow, id: []const u8, row: u32) !void {
        if (id.len == 0) assert.panic("a job key at line {d} has no name; line() passes only keys before a colon", .{row + 1});
        if (self.len == max_jobs) {
            memory.exceeded = "jobs in one GitHub Actions workflow";
            return error.LimitExceeded;
        }
        self.jobs[self.len] = .{ .id = std.mem.trim(u8, id, "\"'"), .row = row };
        self.len += 1;
        self.block_indent = null;
        self.needs_indent = null;
        if (self.current() == null) assert.panic("added job '{s}' but the workflow has no current job", .{id});
    }

    fn find(self: *const Workflow, id: []const u8) ?usize {
        if (id.len == 0) assert.panic("looking up a job with an empty id; addNeed() drops empty names", .{});
        if (self.len > max_jobs) assert.panic("looking up '{s}' among {d} jobs past the {d} slots", .{ id, self.len, max_jobs });
        for (self.jobs[0..self.len], 0..) |job, i| if (std.mem.eql(u8, job.id, id)) return i;
        return null;
    }
};

/// Whether `path` is a GitHub Actions workflow, whose release jobs this module checks.
pub fn isWorkflow(path: []const u8) bool {
    if (path.len == 0) assert.panic("asked whether an empty path is a workflow; checkProjectFiles passes each file read", .{});
    const extension = std.fs.path.extension(path);
    if (extension.len > path.len) assert.panic("'{s}' has a longer extension than itself", .{path});
    return std.mem.indexOf(u8, path, ".github/workflows/") != null and (std.mem.eql(u8, extension, ".yml") or std.mem.eql(u8, extension, ".yaml"));
}

/// How a workflow's releases are gated, for the workflows that call it.
pub const Gating = struct { checks: bool, call_only: bool, releases: bool };

/// Where a workflow's findings go: none are kept without `findings`, and `text` holds their messages.
pub const Report = struct { findings: ?*memory.Bounded(Finding), text: *memory.Text };

/// Reports each step in the workflow `source` that releases without the tests having passed,
/// unless the workflow only runs when called; `calls` says what the workflows it calls do.
pub fn checkWorkflow(report: Report, path: []const u8, source: []const u8, calls: *const Calls) !Gating {
    if (!isWorkflow(path)) assert.panic("'{s}' is not a GitHub Actions workflow; call checkWorkflow() only when isWorkflow() holds", .{path});
    const text = report.text;
    var workflow: Workflow = .{ .calls = calls };
    var lines = std.mem.splitScalar(u8, source, '\n');
    var row: u32 = 0;
    while (lines.next()) |raw| : (row += 1) try line(&workflow, std.mem.trimEnd(u8, raw, "\r"), row);
    var gated: [max_jobs]bool = @splat(false);
    settle(&workflow, &gated);
    var gating: Gating = .{ .checks = false, .call_only = workflow.called and !workflow.triggered, .releases = false };
    for (workflow.jobs[0..workflow.len], 0..) |*job, i| {
        gating.checks = gating.checks or job.checks();
        const release = job.release orelse continue;
        const checked_first = if (job.first_check) |at| at < release.row else false;
        if (checked_first or gated[i]) continue;
        gating.releases = true;
        if (gating.call_only) continue;
        const into = report.findings orelse continue;
        try into.add(.{ .path = path, .line = release.row, .column = release.column, .rule = "ungated-release", .message = try text.format("Job '{s}' releases with '{s}' without the tests having passed, so a commit that fails them is still released.", .{ job.id, release.text }), .fix = try fix(text, &workflow, job) });
    }
    if (row == 0 and source.len > 0) assert.panic("{s}: read {d} bytes as no lines; splitting on newlines always gives at least one", .{ path, source.len });
    return gating;
}

/// Marks each job that runs only once the checks passed: itself, or through a job it needs that
/// cannot fail without stopping it. Repeats until nothing changes, at most once per job.
fn settle(workflow: *const Workflow, gated: *[max_jobs]bool) void {
    if (workflow.len > max_jobs) assert.panic("settling {d} jobs past the {d} slots", .{ workflow.len, max_jobs });
    for (gated[workflow.len..], workflow.len..) |marked, i| if (marked) assert.panic("job slot {d} is gated but the workflow has only {d} jobs; checkWorkflow() must start with no job gated", .{ i, workflow.len });
    var pass: usize = 0;
    while (pass <= workflow.len) : (pass += 1) {
        var changed = false;
        for (workflow.jobs[0..workflow.len], 0..) |*job, i| {
            if (gated[i]) continue;
            if (!passedWorkflowRun(job.condition) and !gatedByNeeds(workflow, gated, job)) continue;
            gated[i] = true;
            changed = true;
        }
        if (!changed) return;
    }
    assert.panic("release gates over {d} jobs still changed after {d} passes; each pass must gate a new job or stop", .{ workflow.len, pass });
}

fn gatedByNeeds(workflow: *const Workflow, gated: *const [max_jobs]bool, job: *const Job) bool {
    if (job.id.len == 0) assert.panic("checking the needs of a job with no id; parse() names every job", .{});
    if (job.needs_len > max_needs) assert.panic("job '{s}' lists {d} needs past {d}", .{ job.id, job.needs_len, max_needs });
    for (job.needed()) |need| {
        const k = workflow.find(need) orelse continue;
        if (!holds(job.condition, need)) continue;
        if (workflow.jobs[k].checks() or gated[k]) return true;
    }
    return false;
}

/// Whether the job runs only when the workflow that triggered it succeeded.
fn passedWorkflowRun(condition: []const u8) bool {
    var buffer: [command_window_bytes]u8 = undefined;
    const squeezed = squeeze(&buffer, condition);
    if (squeezed.len > condition.len) assert.panic("squeezing '{s}' made it longer", .{condition});
    const passed = std.mem.indexOf(u8, squeezed, "workflow_run.conclusion=='success'") != null;
    if (passed and std.mem.indexOf(u8, condition, "success") == null) assert.panic("'{s}' was read as requiring a successful workflow run but never says success", .{condition});
    return passed;
}

/// Whether a job with `condition` stops when `need` fails: it does unless a status function lets
/// it run after a failure without also requiring that need, or every need, to have succeeded.
fn holds(condition: []const u8, need: []const u8) bool {
    if (need.len == 0) assert.panic("checking a condition against a need with no name; addNeed() drops empty names", .{});
    var buffer: [command_window_bytes]u8 = undefined;
    const squeezed = squeeze(&buffer, condition);
    var tolerant = false;
    for (failure_tolerant) |status| tolerant = tolerant or std.mem.indexOf(u8, squeezed, status) != null;
    if (!tolerant) return true;
    var wanted: [command_window_bytes]u8 = undefined;
    const required = std.fmt.bufPrint(&wanted, "needs.{s}.result=='success'", .{need}) catch return false;
    if (required.len <= need.len) assert.panic("the requirement for '{s}' came out shorter than the name", .{need});
    return std.mem.indexOf(u8, squeezed, required) != null or std.mem.indexOf(u8, squeezed, "!contains(needs.*.result,'failure')") != null;
}

/// `text` lowercased without spaces, newlines or double quotes, so conditions compare by content.
fn squeeze(buffer: *[command_window_bytes]u8, text: []const u8) []const u8 {
    var len: usize = 0;
    for (text) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;
        if (len == buffer.len) break;
        buffer[len] = if (c == '"') '\'' else std.ascii.toLower(c);
        len += 1;
    }
    if (len > text.len) assert.panic("squeezed {d} bytes into {d}; squeezing only drops bytes", .{ text.len, len });
    if (std.mem.indexOfAny(u8, buffer[0..len], " \t\r\n\"") != null) assert.panic("squeezing '{s}' left whitespace or a double quote in '{s}'", .{ text, buffer[0..len] });
    return buffer[0..len];
}

/// The finding's own fix: which need to add, or which condition lets the release past a failure.
fn fix(text: *memory.Text, workflow: *const Workflow, job: *const Job) ![]const u8 {
    if (job.release == null) assert.panic("writing a release fix for job '{s}', which releases nothing", .{job.id});
    for (job.needed()) |need| {
        if (workflow.find(need) == null or holds(job.condition, need)) continue;
        return text.format("Its 'if: {s}' runs it after '{s}' fails; add '&& needs.{s}.result == 'success'' to it.", .{ strings.header(job.condition), need, need });
    }
    for (workflow.jobs[0..workflow.len]) |*other| if (other != job and other.checks()) {
        return text.format("Add 'needs: {s}' to job '{s}', so it runs only after '{s}' passes.", .{ other.id, job.id, other.id });
    };
    if (workflow.len == 0) assert.panic("writing a release fix for job '{s}' in a workflow with no jobs", .{job.id});
    return text.format("Run the tests in a job of this workflow, such as one calling the CI workflow with 'uses: ./.github/workflows/<ci>.yml', and add 'needs: <that job>' to job '{s}'.", .{job.id});
}

/// One line of a workflow: the whole line, the part after its indent, and where it is.
const SourceLine = struct { raw: []const u8, content: []const u8, indent: usize, row: u32 };

/// Reads one line of the workflow into the jobs parsed so far.
fn line(workflow: *Workflow, raw: []const u8, row: u32) !void {
    const indent = std.mem.indexOfNone(u8, raw, " ") orelse return;
    const content = raw[indent..];
    if (content[0] == '#') return;
    if (indent > raw.len) assert.panic("line {d} is indented {d} past its {d} bytes", .{ row + 1, indent, raw.len });
    if (indent == 0) {
        workflow.in_jobs = std.mem.eql(u8, std.mem.trimEnd(u8, content, " "), "jobs:");
        workflow.block_indent = null;
        workflow.in_on = std.mem.startsWith(u8, content, "on:");
        if (workflow.in_on) {
            var events = std.mem.tokenizeScalar(u8, withoutComment(content["on:".len..]), ',');
            while (events.next()) |event| trigger(workflow, event);
        }
        return;
    }
    if (workflow.in_on) {
        const on_indent = workflow.on_indent orelse indent;
        workflow.on_indent = on_indent;
        if (indent == on_indent) trigger(workflow, content[0 .. std.mem.indexOfScalar(u8, content, ':') orelse content.len]);
        return;
    }
    if (!workflow.in_jobs) return;
    const job_indent = workflow.job_indent orelse indent;
    workflow.job_indent = job_indent;
    if (indent == job_indent) return workflow.addJob(content[0 .. std.mem.indexOfScalar(u8, content, ':') orelse content.len], row);
    const job = workflow.current() orelse return;
    const at: SourceLine = .{ .raw = raw, .content = content, .indent = indent, .row = row };
    if (indent < job_indent) assert.panic("line {d} is indented {d}, less than the jobs' {d}, yet still read as a job's", .{ row + 1, indent, job_indent });
    if (workflow.block_indent) |block| {
        if (indent > block) return blockLine(workflow, job, at);
        workflow.block_indent = null;
    }
    if (workflow.needs_indent) |needs| {
        if (indent > needs and std.mem.startsWith(u8, content, "- ")) return job.addNeed(withoutComment(content[2..]));
        workflow.needs_indent = null;
    }
    const key_indent = job.key_indent orelse indent;
    job.key_indent = key_indent;
    if (indent == key_indent) return setting(workflow, job, at);
    return step(workflow, job, at);
}

/// Records one event the workflow's `on:` lists, given as a name, a list entry or an inline list item.
fn trigger(workflow: *Workflow, listed: []const u8) void {
    if (!workflow.in_on) assert.panic("recording the event '{s}' outside the workflow's on: block", .{listed});
    const event = std.mem.trim(u8, listed, " -[]\"'");
    if (event.len == 0) return;
    if (std.mem.eql(u8, event, "workflow_call")) workflow.called = true else workflow.triggered = true;
    if (!workflow.called and !workflow.triggered) assert.panic("recorded the event '{s}' as neither a call nor another trigger", .{event});
}

fn blockLine(workflow: *Workflow, job: *Job, at: SourceLine) !void {
    const content = at.content;
    const row = at.row;
    if (content.len == 0) assert.panic("a block line at {d} is empty; line() skips blank lines", .{row + 1});
    if (workflow.block_indent == null) assert.panic("line {d} continues a block that was not opened", .{row + 1});
    if (!workflow.block_is_condition) return command(job, at.raw, content, row);
    const start = @intFromPtr(job.condition.ptr);
    if (job.condition.len == 0) {
        job.condition = content;
        return;
    }
    const end = @intFromPtr(content.ptr) + content.len;
    if (end < start) assert.panic("the condition of job '{s}' continues at line {d}, before it starts", .{ job.id, row + 1 });
    job.condition = job.condition.ptr[0 .. end - start];
}

/// A job's own setting, such as `needs:`, `if:` or `uses:`.
fn setting(workflow: *Workflow, job: *Job, at: SourceLine) !void {
    const content = at.content;
    const indent = at.indent;
    if (indent == 0) assert.panic("job '{s}' has a setting at indent 0; line() treats those as top-level keys", .{job.id});
    if (workflow.current() != job) assert.panic("reading a setting of job '{s}', which is not the job being parsed", .{job.id});
    const value = std.mem.trim(u8, withoutComment(afterKey(content) orelse return), " ");
    if (std.mem.startsWith(u8, content, "needs:")) {
        if (value.len == 0) {
            workflow.needs_indent = indent;
            return;
        }
        var names = std.mem.tokenizeAny(u8, std.mem.trim(u8, value, "[]"), ",");
        while (names.next()) |name| try job.addNeed(name);
    } else if (std.mem.startsWith(u8, content, "if:")) {
        job.condition = "";
        if (blockScalar(value)) return openBlock(workflow, indent, true);
        job.condition = value;
    } else if (std.mem.startsWith(u8, content, "uses:")) {
        calling(workflow, job, at, std.mem.trim(u8, value, "\"'"));
    }
}

/// Records what job `job` gets from the reusable workflow its `uses:` names: whether it runs the
/// checks, by what its jobs do when it is one of the project's own and by its name when it is not,
/// and the release it makes ungated when it only runs when called.
fn calling(workflow: *Workflow, job: *Job, at: SourceLine, uses: []const u8) void {
    if (workflow.current() != job) assert.panic("reading the uses: of job '{s}', which is not the job being parsed", .{job.id});
    if (at.indent == 0) assert.panic("job '{s}' calls '{s}' from indent 0", .{ job.id, uses });
    const callee = workflow.calls.find(uses) orelse {
        job.calls_checks = namesChecks(uses);
        return;
    };
    job.calls_checks = workflow.calls.checks[callee];
    if (job.release != null or !workflow.calls.call_only[callee] or !workflow.calls.releases[callee]) return;
    job.release = .{ .row = at.row, .column = @intCast(at.indent), .text = uses };
}

/// A line inside a job's steps: a `run:` command, a step's `uses:` action, or anything else.
fn step(workflow: *Workflow, job: *Job, at: SourceLine) !void {
    const content = at.content;
    const raw = at.raw;
    const row = at.row;
    if (at.indent == 0) assert.panic("job '{s}' has a step at indent 0", .{job.id});
    if (workflow.current() != job) assert.panic("reading a step of job '{s}', which is not the job being parsed", .{job.id});
    const bare = if (std.mem.startsWith(u8, content, "- ")) content[2..] else content;
    if (bare.len < content.len and at.indent <= job.image_indent) job.image_step = null;
    if (std.mem.startsWith(u8, bare, "push:")) return imagePush(job, withoutComment(bare["push:".len..]));
    if (std.mem.startsWith(u8, bare, "run:")) {
        const value = std.mem.trim(u8, bare["run:".len..], " ");
        if (blockScalar(withoutComment(value))) return openBlock(workflow, at.indent + (content.len - bare.len), false);
        if (value.len > 0) return command(job, raw, value, row);
    }
    if (std.mem.startsWith(u8, bare, "uses:") and job.release == null) {
        const value = std.mem.trim(u8, withoutComment(bare["uses:".len..]), " \"'");
        const action = value[0 .. std.mem.indexOfScalar(u8, value, '@') orelse value.len];
        var lower: [command_window_bytes]u8 = undefined;
        const lowered = std.ascii.lowerString(lower[0..@min(action.len, lower.len)], action[0..@min(action.len, lower.len)]);
        const found: Release = .{ .row = row, .column = @intCast(raw.len - content.len), .text = value };
        if (release_steps.releaseAction(lowered)) job.release = found;
        if (std.mem.eql(u8, lowered, release_steps.image_action)) {
            job.image_step = found;
            job.image_indent = at.indent;
        }
    }
    if (std.mem.startsWith(u8, bare, "uses:") and job.first_check == null and checkingAction(bare["uses:".len..])) job.first_check = row;
}

/// Reads the `push:` of the image_action step being read: anything but `false`, such as `true` or
/// an expression that is true on a release event, publishes the image.
fn imagePush(job: *Job, value: []const u8) void {
    if (std.mem.indexOfScalar(u8, value, '\n') != null) assert.panic("job '{s}' has a push: setting spanning lines, but settings are read one line at a time", .{job.id});
    const pending = job.image_step orelse return;
    if (job.release != null) return;
    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \"'"), "false")) return;
    job.release = pending;
    if (job.release.?.row != pending.row) assert.panic("job '{s}' recorded its image release at line {d}, not its step's line {d}", .{ job.id, job.release.?.row + 1, pending.row + 1 });
}

fn openBlock(workflow: *Workflow, indent: usize, condition: bool) void {
    if (indent == 0) assert.panic("opening a block at indent 0; only job settings and steps open blocks", .{});
    workflow.block_indent = indent;
    workflow.block_is_condition = condition;
    if (workflow.block_indent != indent) assert.panic("opened a block at indent {d} but recorded a different one; openBlock() must store the indent it opens", .{indent});
}

/// Records whether one command line of `job` runs the checks or releases.
fn command(job: *Job, raw: []const u8, text: []const u8, row: u32) !void {
    if (text.len == 0) assert.panic("reading an empty command at line {d}; callers skip empty values", .{row + 1});
    var buffer: [command_window_bytes]u8 = undefined;
    const unquoted = unquote(&buffer, text);
    if (unquoted.len > buffer.len) assert.panic("unquoted a command into {d} bytes past its buffer", .{unquoted.len});
    if (job.first_check == null and isCheck(unquoted)) job.first_check = row;
    if (job.release != null) return;
    if (release_steps.releaseCommand(unquoted)) job.release = .{ .row = row, .column = @intCast(@intFromPtr(text.ptr) - @intFromPtr(raw.ptr)), .text = strings.header(text) };
}

/// `text` lowercased, with quoted strings and comments blanked, so words in messages don't count.
fn unquote(buffer: *[command_window_bytes]u8, text: []const u8) []const u8 {
    const kept = @min(text.len, buffer.len);
    var quote: ?u8 = null;
    for (text[0..kept], 0..) |c, i| {
        if (quote) |q| {
            if (c == q) quote = null;
            buffer[i] = ' ';
            continue;
        }
        if (c == '#' and (i == 0 or text[i - 1] == ' ')) {
            @memset(buffer[i..kept], ' ');
            break;
        }
        if (c == '"' or c == '\'') quote = c;
        buffer[i] = if (quote != null) ' ' else std.ascii.toLower(c);
    }
    if (kept > text.len) assert.panic("kept {d} bytes of a {d}-byte command", .{ kept, text.len });
    if (std.mem.indexOfAny(u8, buffer[0..kept], "\"'") != null) assert.panic("unquoting '{s}' left a quote in '{s}'", .{ text, buffer[0..kept] });
    return buffer[0..kept];
}

fn hasWord(text: []const u8, words: []const []const u8) bool {
    if (words.len == 0) assert.panic("looking for none of no words in '{s}'; pass a word list", .{text});
    for (words) |word| if (word.len == 0) assert.panic("looking for an empty word in '{s}'; every listed word must have letters", .{text});
    var tokens = std.mem.tokenizeAny(u8, text, " \t-_./:;&|()=$,[]{}<>!");
    while (tokens.next()) |token| if (strings.contains(words, token)) return true;
    return false;
}

fn namesChecks(workflow: []const u8) bool {
    if (std.mem.indexOfScalar(u8, workflow, '\n') != null) assert.panic("'{s}' spans lines, but a job's uses: value is one line", .{workflow});
    if (workflow.len == 0) return false;
    var buffer: [command_window_bytes]u8 = undefined;
    const lowered = unquote(&buffer, std.fs.path.stem(workflow));
    if (lowered.len > workflow.len) assert.panic("lowercased '{s}' into more bytes", .{workflow});
    return hasWord(lowered, &check_workflow_words);
}

fn afterKey(content: []const u8) ?[]const u8 {
    if (content.len == 0) assert.panic("reading the value of an empty setting; line() skips blank lines", .{});
    const colon = std.mem.indexOfScalar(u8, content, ':') orelse return null;
    if (colon >= content.len) assert.panic("found a colon at {d} in a {d}-byte setting", .{ colon, content.len });
    return content[colon + 1 ..];
}

fn blockScalar(value: []const u8) bool {
    if (std.mem.indexOfScalar(u8, value, '\n') != null) assert.panic("'{s}' spans lines, but a setting's value is read one line at a time", .{value});
    const indicator = std.mem.trim(u8, value, " ");
    if (indicator.len > value.len) assert.panic("trimming '{s}' made it longer", .{value});
    if (indicator.len > 3) return false;
    return indicator.len > 0 and (indicator[0] == '|' or indicator[0] == '>');
}

pub fn withoutComment(value: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, value, '\n') != null) assert.panic("'{s}' spans lines, but comments are stripped one line at a time", .{value});
    const comment = std.mem.indexOf(u8, value, " #") orelse value.len;
    if (comment > value.len) assert.panic("found a comment past the end of '{s}'", .{value});
    return std.mem.trimEnd(u8, value[0..comment], " ");
}
