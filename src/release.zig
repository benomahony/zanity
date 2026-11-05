//! Release gates: a GitHub Actions job that publishes a release must not run unless the tests
//! passed, either earlier in the same job or in a job it needs, through every job between.
const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const strings = @import("strings.zig");
const Finding = @import("facts.zig").Finding;

/// The most jobs one workflow may define for its release gates to be checked.
const max_jobs = 64;
/// The most jobs one job may need.
const max_needs = 16;
/// How much of a command line is inspected for check and release commands.
const command_window_bytes = 512;

/// Words in a command that run tests, a linter or a type checker.
const check_words = [_][]const u8{ "test", "tests", "check", "lint", "pytest", "tox", "nox", "mypy", "pyright", "clippy", "vet", "eslint", "ctest", "phpunit", "rspec", "jest", "vitest" };
/// Words in a reusable workflow's path that say it runs the checks.
const check_workflow_words = [_][]const u8{ "test", "tests", "check", "checks", "ci", "lint", "verify" };
/// Commands that publish a release or a package, lowercased.
const release_commands = [_][]const u8{ "gh release create", "npm publish", "pnpm publish", "yarn publish", "yarn npm publish", "cargo publish", "uv publish", "twine upload", "poetry publish", "flit publish", "hatch publish", "gem push", "docker push", "goreleaser release", "mvn deploy", "gradle publish", "gradlew publish", "dotnet nuget push", "nuget push", "semantic-release", "vsce publish", "helm push" };
/// Actions that publish a release or a package, lowercased, without the version.
const release_actions = [_][]const u8{ "softprops/action-gh-release", "ncipollo/release-action", "actions/create-release", "marvinpinto/action-automatic-releases", "goreleaser/goreleaser-action", "pypa/gh-action-pypi-publish", "js-devtools/npm-publish", "changesets/action", "katyo/publish-crates", "googleapis/release-please-action", "google-github-actions/release-please-action", "cycjimmy/semantic-release-action" };
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
    /// Whether the job calls a reusable workflow named for running the checks.
    calls_checks: bool = false,
    first_check: ?u32 = null,
    release: ?Release = null,

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
    jobs: [max_jobs]Job = undefined,
    len: usize = 0,
    in_jobs: bool = false,
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

/// Reports each step in the workflow `source` that releases without the tests having passed.
pub fn checkWorkflow(findings: *memory.Bounded(Finding), text: *memory.Text, path: []const u8, source: []const u8) !void {
    if (!isWorkflow(path)) assert.panic("'{s}' is not a GitHub Actions workflow; call checkWorkflow() only when isWorkflow() holds", .{path});
    var workflow: Workflow = .{};
    var lines = std.mem.splitScalar(u8, source, '\n');
    var row: u32 = 0;
    while (lines.next()) |raw| : (row += 1) try line(&workflow, std.mem.trimEnd(u8, raw, "\r"), row);
    var gated: [max_jobs]bool = @splat(false);
    settle(&workflow, &gated);
    for (workflow.jobs[0..workflow.len], 0..) |*job, i| {
        const release = job.release orelse continue;
        const checked_first = if (job.first_check) |at| at < release.row else false;
        if (checked_first or gated[i]) continue;
        try findings.add(.{ .path = path, .line = release.row, .column = release.column, .rule = "ungated-release", .message = try text.format("Job '{s}' releases with '{s}' without the tests having passed, so a commit that fails them is still released.", .{ job.id, release.text }), .fix = try fix(text, &workflow, job) });
    }
    if (row == 0 and source.len > 0) assert.panic("{s}: read {d} bytes as no lines; splitting on newlines always gives at least one", .{ path, source.len });
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
    if (indent == key_indent) return setting(workflow, job, content, indent);
    return step(workflow, job, at);
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
fn setting(workflow: *Workflow, job: *Job, content: []const u8, indent: usize) !void {
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
        job.calls_checks = namesChecks(value);
    }
}

/// A line inside a job's steps: a `run:` command, a step's `uses:` action, or anything else.
fn step(workflow: *Workflow, job: *Job, at: SourceLine) !void {
    const content = at.content;
    const raw = at.raw;
    const row = at.row;
    if (at.indent == 0) assert.panic("job '{s}' has a step at indent 0", .{job.id});
    if (workflow.current() != job) assert.panic("reading a step of job '{s}', which is not the job being parsed", .{job.id});
    const bare = if (std.mem.startsWith(u8, content, "- ")) content[2..] else content;
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
        if (strings.contains(&release_actions, lowered)) job.release = .{ .row = row, .column = @intCast(raw.len - content.len), .text = value };
    }
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
    if (job.first_check == null and hasWord(unquoted, &check_words)) job.first_check = row;
    if (job.release != null) return;
    for (release_commands) |release| if (startsCommand(unquoted, release)) {
        job.release = .{ .row = row, .column = @intCast(@intFromPtr(text.ptr) - @intFromPtr(raw.ptr)), .text = strings.header(text) };
        return;
    };
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

/// Whether `text` runs `release`: it appears at the start of a word, followed by the end or a space.
fn startsCommand(text: []const u8, release: []const u8) bool {
    if (release.len == 0) assert.panic("looking for an empty release command in '{s}'", .{text});
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, release)) |at| : (from = at + 1) {
        const before_ok = at == 0 or !(std.ascii.isAlphanumeric(text[at - 1]) or text[at - 1] == '-');
        const after = at + release.len;
        const after_ok = after == text.len or text[after] == ' ' or text[after] == '\t';
        if (before_ok and after_ok) return true;
    }
    if (from > text.len) assert.panic("searched past the end of a {d}-byte command", .{text.len});
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

fn withoutComment(value: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, value, '\n') != null) assert.panic("'{s}' spans lines, but comments are stripped one line at a time", .{value});
    const comment = std.mem.indexOf(u8, value, " #") orelse value.len;
    if (comment > value.len) assert.panic("found a comment past the end of '{s}'", .{value});
    return std.mem.trimEnd(u8, value[0..comment], " ");
}

fn expectFindings(source: []const u8, expected: []const []const u8) !void {
    if (source.len == 0) assert.panic("checking an empty workflow; give the test a workflow to check", .{});
    if (expected.len > 8) assert.panic("expecting {d} findings, past the 8 the test collects; raise its capacity", .{expected.len});
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var findings = try memory.Bounded(Finding).initBounded(arena, 8, "test findings");
    var text = try memory.Text.initText(arena, 1 << 16);
    try checkWorkflow(&findings, &text, ".github/workflows/release.yml", source);
    try std.testing.expectEqual(expected.len, findings.len);
    for (findings.items(), expected) |finding, job| try std.testing.expect(std.mem.indexOf(u8, finding.message, job) != null);
}

test "a release job that needs no job running the tests is reported" {
    try expectFindings(
        \\on: push
        \\jobs:
        \\  publish:
        \\    runs-on: ubuntu-latest
        \\    steps:
        \\      - run: npm publish
    , &.{"Job 'publish'"});
}

test "a release job that needs the tests, directly or through another job, is not reported" {
    try expectFindings(
        \\jobs:
        \\  test:
        \\    steps:
        \\      - run: zig build test
        \\  build:
        \\    needs: test
        \\    steps:
        \\      - run: zig build release
        \\  publish:
        \\    needs: [build]
        \\    steps:
        \\      - uses: softprops/action-gh-release@v2
    , &.{});
}

test "always() on a release job lets it run after the tests fail unless it requires their success" {
    try expectFindings(
        \\jobs:
        \\  test:
        \\    uses: ./.github/workflows/ci.yml
        \\  publish:
        \\    needs:
        \\      - test
        \\    if: always()
        \\    steps:
        \\      - run: |
        \\          echo "check nothing"
        \\          cargo publish
        \\  publish-checked:
        \\    needs: test
        \\    if: >-
        \\      always() &&
        \\      needs.test.result == 'success'
        \\    steps:
        \\      - run: cargo publish
    , &.{"Job 'publish'"});
}

test "a release after a successful workflow run, or after the tests in the same job, is not reported" {
    try expectFindings(
        \\on:
        \\  workflow_run:
        \\    workflows: [CI]
        \\jobs:
        \\  publish:
        \\    if: github.event.workflow_run.conclusion == 'success'
        \\    steps:
        \\      - run: gh release create v1
        \\  inline:
        \\    steps:
        \\      - run: pytest
        \\      - run: uv publish
        \\  untested:
        \\    if: github.event.workflow_run.conclusion != 'cancelled'
        \\    steps:
        \\      - uses: pypa/gh-action-pypi-publish@release/v1
    , &.{"Job 'untested'"});
}
