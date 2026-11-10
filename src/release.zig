//! Release gates: a GitHub Actions job that publishes a release must not run unless the tests
//! passed, either earlier in the same job or in a job it needs, through every job between.
const std = @import("std");
const release_checks = @import("release_checks.zig");
const checkingAction = release_checks.checkingAction;
const isCheck = release_checks.isCheck;
const Calls = @import("workflow_calls.zig").Calls;
const release_steps = @import("release_steps.zig");
const release_fix = @import("release_fix.zig");
const release_text = @import("release_text.zig");
const command_window_bytes = release_text.command_window_bytes;
const unquote = release_text.unquote;
const squeeze = release_text.squeeze;
const namesChecks = release_text.namesChecks;
const afterKey = release_text.afterKey;
const blockScalar = release_text.blockScalar;
const withoutComment = release_text.withoutComment;
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const strings = @import("strings.zig");
const Finding = @import("facts.zig").Finding;
const max_jobs = @import("workflow.zig").max_jobs;
const max_needs = @import("workflow.zig").max_needs;
const Shipment = @import("workflow.zig").Shipment;
const Job = @import("workflow.zig").Job;
const Workflow = @import("workflow.zig").Workflow;
const holds = @import("workflow.zig").holds;

/// Whether `path` is a GitHub Actions workflow, whose release jobs this module checks.
pub fn isWorkflow(path: []const u8) bool {
    if (path.len == 0) assert.panic("asked whether an empty path is a workflow; checkProjectFiles passes each file read", .{});
    const extension = std.fs.path.extension(path);
    if (extension.len > path.len) assert.panic("'{s}' has a longer extension than itself", .{path});
    return std.mem.indexOf(u8, path, ".github/workflows/") != null and (std.mem.eql(u8, extension, ".yml") or std.mem.eql(u8, extension, ".yaml"));
}

/// How a workflow's releases are gated, for the workflows that call it.
pub const Gating = struct { checks: bool, call_only: bool, releases: bool, deploys: bool };

/// Where a workflow's findings go: none are kept without `findings`, and `text` holds their
/// messages; `releases` and `deploys` say which of ungated-release and ungated-deployment run.
pub const Report = struct { findings: ?*memory.Bounded(Finding), text: *memory.Text, releases: bool = true, deploys: bool = true };

/// Reports each step in the workflow `source` that releases or deploys without the tests having
/// passed, unless the workflow only runs when called; `calls` says what the workflows it calls do.
pub fn checkWorkflow(report: Report, path: []const u8, source: []const u8, calls: *const Calls) !Gating {
    if (!isWorkflow(path)) assert.panic("'{s}' is not a GitHub Actions workflow; call checkWorkflow() only when isWorkflow() holds", .{path});
    var workflow: Workflow = .{ .path = path, .source = source, .calls = calls };
    var lines = std.mem.splitScalar(u8, source, '\n');
    var row: u32 = 0;
    while (lines.next()) |raw| : (row += 1) try line(&workflow, std.mem.trimEnd(u8, raw, "\r"), row);
    var gated: [max_jobs]bool = @splat(false);
    settle(&workflow, &gated);
    var gating: Gating = .{ .checks = false, .call_only = workflow.called and !workflow.triggered, .releases = false, .deploys = false };
    for (workflow.jobs[0..workflow.len], 0..) |*job, i| {
        gating.checks = gating.checks or job.checks();
        if (gated[i]) continue;
        const release = ungated(job, job.release);
        const deploy = ungated(job, job.deploy);
        gating.releases = gating.releases or release != null;
        gating.deploys = gating.deploys or deploy != null;
        if (!gating.call_only) try reportJob(report, &workflow, job, .{ .release = if (report.releases) release else null, .deploy = if (report.deploys) deploy else null });
    }
    if (row == 0 and source.len > 0) assert.panic("{s}: read {d} bytes as no lines; splitting on newlines always gives at least one", .{ path, source.len });
    return gating;
}

/// What a job ships without the tests having passed, among the rules that run.
const Ungated = struct { release: ?Shipment, deploy: ?Shipment };

/// Reports what `job` ships ungated. Both findings name the same fix, and only the first carries
/// its edit, so --fix makes it once.
fn reportJob(report: Report, workflow: *const Workflow, job: *const Job, shipped: Ungated) !void {
    if (shipped.release != null and job.release == null) assert.panic("job '{s}' is reported for a release it does not make", .{job.id});
    if (shipped.deploy != null and job.deploy == null) assert.panic("job '{s}' is reported for a deploy it does not make", .{job.id});
    const into = report.findings orelse return;
    if (shipped.release == null and shipped.deploy == null) return;
    var fixed = try release_fix.fix(report.text, workflow, job);
    if (shipped.release) |at| {
        try into.add(.{ .path = workflow.path, .line = at.row, .column = at.column, .rule = "ungated-release", .message = try report.text.format("Job '{s}' releases with '{s}' without the tests having passed, so a commit that fails them is still released.", .{ job.id, at.text }), .fix = fixed.text, .edit = fixed.edit });
        fixed.edit = null;
    }
    if (shipped.deploy) |at| try into.add(.{ .path = workflow.path, .line = at.row, .column = at.column, .rule = "ungated-deployment", .message = try deployMessage(report.text, job, at), .fix = fixed.text, .edit = fixed.edit });
}

/// `shipped`, unless the job ran the checks before it: before the step that ships, or anywhere in
/// the job for a deploy to a production environment, since its steps all run in that environment.
fn ungated(job: *const Job, shipped: ?Shipment) ?Shipment {
    const at = shipped orelse return null;
    if (at.row < job.row) assert.panic("job '{s}' at line {d} ships at line {d}, before the job starts", .{ job.id, job.row + 1, at.row + 1 });
    const checked = job.first_check orelse return at;
    if (checked < job.row) assert.panic("job '{s}' at line {d} checks at line {d}, before the job starts", .{ job.id, job.row + 1, checked + 1 });
    return if (at.environment or checked < at.row) null else at;
}

fn deployMessage(text: *memory.Text, job: *const Job, deploy: Shipment) ![]const u8 {
    if (job.deploy == null) assert.panic("describing a deploy of job '{s}', which deploys nothing", .{job.id});
    if (deploy.text.len == 0) assert.panic("job '{s}' deploys at line {d} with nothing named", .{ job.id, deploy.row + 1 });
    if (deploy.environment) return text.format("Job '{s}' deploys to the '{s}' environment without the tests having passed, so a commit that fails them is still deployed.", .{ job.id, deploy.text });
    return text.format("Job '{s}' deploys with '{s}' without the tests having passed, so a commit that fails them is still deployed.", .{ job.id, deploy.text });
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
    if (indent == job_indent) return workflow.addJob(content[0 .. std.mem.indexOfScalar(u8, content, ':') orelse content.len], raw, row);
    const job = workflow.current() orelse return;
    const at: SourceLine = .{ .raw = raw, .content = content, .indent = indent, .row = row };
    if (indent < job_indent) assert.panic("line {d} is indented {d}, less than the jobs' {d}, yet still read as a job's", .{ row + 1, indent, job_indent });
    if (try continued(workflow, job, at)) return;
    const key_indent = job.key_indent orelse indent;
    job.key_indent = key_indent;
    if (indent == key_indent) return setting(workflow, job, at);
    return step(workflow, job, at);
}

/// Reads `at` into the block, `needs:` list or `environment:` it continues, if any, and says
/// whether it did; a line indented no deeper than the key ends that key's block.
fn continued(workflow: *Workflow, job: *Job, at: SourceLine) !bool {
    if (workflow.current() != job) assert.panic("continuing a block of job '{s}', which is not the job being parsed", .{job.id});
    if (at.indent == 0) assert.panic("line {d} continues a job's block from indent 0", .{at.row + 1});
    if (workflow.block_indent) |block| {
        if (at.indent > block) {
            try blockLine(workflow, job, at);
            return true;
        }
        workflow.block_indent = null;
    }
    if (workflow.needs_indent) |needs| {
        if (at.indent > needs and std.mem.startsWith(u8, at.content, "- ")) {
            try job.addNeed(withoutComment(at.content[2..]));
            job.needs_last = at.raw;
            return true;
        }
        workflow.needs_indent = null;
    }
    const environment_key = workflow.environment_indent orelse return false;
    if (at.indent <= environment_key) {
        workflow.environment_indent = null;
        return false;
    }
    if (!std.mem.startsWith(u8, at.content, "name:")) return false;
    environment(job, at, at.content["name:".len..]);
    return true;
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
        job.needs_value = value;
        var names = std.mem.tokenizeAny(u8, std.mem.trim(u8, value, "[]"), ",");
        while (names.next()) |name| try job.addNeed(name);
    } else if (std.mem.startsWith(u8, content, "if:")) {
        job.condition = "";
        job.condition_block = blockScalar(value);
        if (job.condition_block) return openBlock(workflow, indent, true);
        job.condition = value;
    } else if (std.mem.startsWith(u8, content, "uses:")) {
        calling(workflow, job, at, std.mem.trim(u8, value, "\"'"));
    } else if (std.mem.startsWith(u8, content, "environment:")) {
        if (value.len == 0) workflow.environment_indent = indent else environment(job, at, value);
    }
}

/// Records a deploy at `at` when the job's environment, named by `value`, is production.
fn environment(job: *Job, at: SourceLine, value: []const u8) void {
    if (at.indent == 0) assert.panic("job '{s}' names an environment at indent 0", .{job.id});
    if (std.mem.indexOfScalar(u8, value, '\n') != null) assert.panic("job '{s}' names an environment spanning lines, but settings are read one line at a time", .{job.id});
    const name = std.mem.trim(u8, withoutComment(value), " \"'");
    if (job.deploy != null or !release_steps.productionEnvironment(name)) return;
    job.deploy = .{ .row = at.row, .column = @intCast(at.indent), .text = name, .environment = true };
}

/// Records what job `job` gets from the reusable workflow its `uses:` names: whether it runs the
/// checks, by what its jobs do when it is one of the project's own and by its name when it is not,
/// and the release or deploy it makes ungated when it only runs when called.
fn calling(workflow: *Workflow, job: *Job, at: SourceLine, uses: []const u8) void {
    if (workflow.current() != job) assert.panic("reading the uses: of job '{s}', which is not the job being parsed", .{job.id});
    if (at.indent == 0) assert.panic("job '{s}' calls '{s}' from indent 0", .{ job.id, uses });
    const callee = workflow.calls.find(uses) orelse {
        job.calls_checks = namesChecks(uses);
        return;
    };
    job.calls_checks = workflow.calls.checks[callee];
    if (!workflow.calls.call_only[callee]) return;
    const called: Shipment = .{ .row = at.row, .column = @intCast(at.indent), .text = uses };
    if (job.release == null and workflow.calls.releases[callee]) job.release = called;
    if (job.deploy == null and workflow.calls.deploys[callee]) job.deploy = called;
}

/// A line inside a job's steps: a `run:` command, a step's `uses:` action, or anything else.
fn step(workflow: *Workflow, job: *Job, at: SourceLine) !void {
    const content = at.content;
    if (at.indent == 0) assert.panic("job '{s}' has a step at indent 0", .{job.id});
    if (workflow.current() != job) assert.panic("reading a step of job '{s}', which is not the job being parsed", .{job.id});
    const bare = if (std.mem.startsWith(u8, content, "- ")) content[2..] else content;
    if (bare.len < content.len and at.indent <= job.image_indent) job.image_step = null;
    if (std.mem.startsWith(u8, bare, "push:")) return imagePush(job, withoutComment(bare["push:".len..]));
    if (std.mem.startsWith(u8, bare, "run:")) {
        const value = std.mem.trim(u8, bare["run:".len..], " ");
        if (blockScalar(withoutComment(value))) return openBlock(workflow, at.indent + (content.len - bare.len), false);
        if (value.len > 0) return command(job, at.raw, value, at.row);
    }
    if (std.mem.startsWith(u8, bare, "uses:")) action(job, at, bare["uses:".len..]);
}

/// Records what the action a step's `uses:` names does: run the checks, release, deploy, or
/// build an image that releases once its `with:` sets `push`.
fn action(job: *Job, at: SourceLine, uses: []const u8) void {
    if (at.indent == 0) assert.panic("job '{s}' uses an action at indent 0", .{job.id});
    if (std.mem.indexOfScalar(u8, uses, '\n') != null) assert.panic("job '{s}' has a uses: spanning lines, but steps are read one line at a time", .{job.id});
    if (job.first_check == null and checkingAction(uses)) job.first_check = at.row;
    const value = std.mem.trim(u8, withoutComment(uses), " \"'");
    const name = value[0 .. std.mem.indexOfScalar(u8, value, '@') orelse value.len];
    var lower: [command_window_bytes]u8 = undefined;
    const lowered = std.ascii.lowerString(lower[0..@min(name.len, lower.len)], name[0..@min(name.len, lower.len)]);
    const found: Shipment = .{ .row = at.row, .column = @intCast(at.raw.len - at.content.len), .text = value };
    if (job.release == null and release_steps.shipsAction(.release, lowered)) job.release = found;
    if (job.deploy == null and release_steps.shipsAction(.deployment, lowered)) job.deploy = found;
    if (job.release != null or !std.mem.eql(u8, lowered, release_steps.image_action)) return;
    job.image_step = found;
    job.image_indent = at.indent;
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

/// Records whether one command line of `job` runs the checks, releases or deploys.
fn command(job: *Job, raw: []const u8, text: []const u8, row: u32) !void {
    if (text.len == 0) assert.panic("reading an empty command at line {d}; callers skip empty values", .{row + 1});
    var buffer: [command_window_bytes]u8 = undefined;
    const unquoted = unquote(&buffer, text);
    if (unquoted.len > buffer.len) assert.panic("unquoted a command into {d} bytes past its buffer", .{unquoted.len});
    if (job.first_check == null and isCheck(unquoted)) job.first_check = row;
    const found: Shipment = .{ .row = row, .column = @intCast(@intFromPtr(text.ptr) - @intFromPtr(raw.ptr)), .text = strings.header(text) };
    if (job.release == null and release_steps.shipsCommand(.release, unquoted)) job.release = found;
    if (job.deploy == null and release_steps.shipsCommand(.deployment, unquoted)) job.deploy = found;
}
