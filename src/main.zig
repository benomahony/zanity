const std = @import("std");
const Io = std.Io;

const zclig = @import("zclig");

const assert = @import("assert.zig");
const baseline = @import("baseline.zig");
const Row = baseline.Row;
const calibrate = @import("calibrate.zig");
const cmd_check = @import("cmd_check.zig");
const runCheck = cmd_check.runCheck;
const renderHuman = cmd_check.renderHuman;
const cmd_init = @import("cmd_init.zig");
const InitOptions = cmd_init.InitOptions;
const InitRow = cmd_init.InitRow;
const runInit = cmd_init.runInit;
const renderInit = cmd_init.renderInit;
const cmd_lsp = @import("cmd_lsp.zig");
const LspOptions = cmd_lsp.LspOptions;
const LspRow = cmd_lsp.LspRow;
const runLsp = cmd_lsp.runLsp;
const cmd_upgrade = @import("cmd_upgrade.zig");
const UpgradeOptions = cmd_upgrade.UpgradeOptions;
const UpgradeRow = cmd_upgrade.UpgradeRow;
const runUpgrade = cmd_upgrade.runUpgrade;
const previewUpgrade = cmd_upgrade.previewUpgrade;
const renderUpgrade = cmd_upgrade.renderUpgrade;
const triage = @import("triage.zig");
const CheckOptions = triage.CheckOptions;
const workspace = @import("workspace.zig");
const Workspace = workspace.Workspace;
const workspace_init = @import("workspace_init.zig");

/// Buffered standard output, for a check's whole report.
const out_buffer_bytes = 64 * 1024;
/// Buffered standard error, for one failure.
const err_buffer_bytes = 4096;
/// The highest exit code allowed; codes above it collide with signals.
const max_exit_code = 130;
/// Each deprecated flag, which still works, and the flag that replaces it.
const renamed_flags = [_][2][:0]const u8{
    .{ "--strict", "--production" },
    .{ "--strict=true", "--production=true" },
    .{ "--strict=false", "--production=false" },
};

fn renamedFlag(arg: []const u8) ?[:0]const u8 {
    for (renamed_flags) |pair| if (std.mem.eql(u8, arg, pair[0])) {
        if (std.mem.eql(u8, pair[0], pair[1])) assert.panic("'{s}' is renamed to itself; renamed_flags must map each flag to a different one", .{pair[0]});
        if (!std.mem.startsWith(u8, pair[1], "--")) assert.panic("'{s}' is renamed to '{s}', which is not a flag; renamed_flags must map flags to flags", .{ pair[0], pair[1] });
        return pair[1];
    };
    return null;
}

pub const app: zclig.App = .{
    .name = "zanity",
    .version = @import("build_info").version,
    .description = "Fast, deterministic sanity checks for code written by people and agents.",
    .commands = &.{ zclig.command(CheckOptions, Row, .{
        .name = "check",
        .description = "Check files and directories. Exits 1 when an error-level rule fires, or with --fail-on warning when any rule does.",
        .examples = &.{ "zanity check .", "zanity check src tests --rules unbounded-loop,long-function", "zanity check . --json", "zanity check . --fix", "zanity check . --fail-on warning", "zanity check . --production", "zanity check . --watch" },
        .result_title = "Findings",
        .positional = .{ .name = "paths", .metavar = "PATH", .help = "Files or directories to check.", .default = &.{"."} },
        .options = triage.check_options,
    }, .{ .run = runCheck, .human = renderHuman }), zclig.command(InitOptions, InitRow, .{
        .name = "init",
        .description = "Write a zanity.toml with every setting and rule explained, ready to trim.",
        .examples = &.{ "zanity init", "zanity init --minimal", "zanity init path/to/project", "zanity init --force" },
        .result_title = "Written",
        .positional = .{ .name = "paths", .metavar = "DIR", .help = "The project's root, where zanity.toml goes.", .default = &.{"."} },
        .options = &.{
            .{ .name = "force", .help = "Replace an existing zanity.toml." },
            .{ .name = "minimal", .help = "Write only the settings, without the notes and the list of every rule." },
        },
    }, .{ .run = runInit, .human = renderInit }), zclig.command(UpgradeOptions, UpgradeRow, .{
        .name = "upgrade",
        .description = "Replace this zanity with the latest release, or the one --to names, after checking its SHA-256.",
        .aliases = &.{"update"},
        .examples = &.{ "zanity upgrade", "zanity upgrade --dry-run", "zanity upgrade --to 0.1.4" },
        .result_title = "Upgrade",
        .options = &.{
            .{ .name = "to", .metavar = "VERSION", .help = "Install this release instead of the latest, even if it is older.", .example = "0.1.4" },
        },
    }, .{ .run = runUpgrade, .dry_run = previewUpgrade, .human = renderUpgrade }), zclig.command(LspOptions, LspRow, .{
        .name = "lsp",
        .description = "Serve the language server protocol on stdin and stdout: findings as diagnostics, refreshed on save, and zanity's fixes as code actions.",
        .examples = &.{ "zanity lsp", "zanity lsp --infer", "zanity lsp --production" },
        .result_title = "Language server",
        .options = &.{
            .{ .name = "infer", .help = "Also ask the model on every check, as zanity check --infer does; answers are cached, so only edited code is asked again." },
            .{ .name = "production", .help = "Run every rule on every check, as zanity check --production does." },
        },
    }, .{ .run = runLsp }), zclig.command(calibrate.LabelOptions, calibrate.LabelRow, .{
        .name = "mark",
        .description = "Say whether a --infer finding is real: --confirm it, or mark it --not-a-problem, which stops it being reported for that function.",
        .examples = &.{ "zanity mark app.py:12 cwe-15 --not-a-problem", "zanity mark app.py:12 vague-error --confirm" },
        .result_title = "Marked",
        .positional = .{ .name = "finding", .metavar = "PATH:LINE RULE", .help = "Where the finding is, as check reports it, and its rule." },
        .options = &.{
            .{ .name = "confirm", .help = "The finding is real." },
            .{ .name = "not-a-problem", .help = "The finding is wrong for this function; don't report it there again." },
        },
    }, .{ .run = calibrate.runMark }), zclig.command(calibrate.ReviewOptions, calibrate.ReviewRow, .{
        .name = "review",
        .description = "List unlabelled answers to one --infer question to label, spread evenly from unsure to sure, so labels cover what the model missed as well as what it found.",
        .examples = &.{ "zanity review cwe-15", "zanity review vague-error --limit 50" },
        .result_title = "To label",
        .positional = .{ .name = "rules", .metavar = "RULE", .help = "The question to review." },
        .options = &.{
            .{ .name = "limit", .metavar = "N", .help = "List at most N answers.", .example = "50" },
        },
    }, .{ .run = calibrate.runReview }), zclig.command(calibrate.StatsOptions, calibrate.StatsRow, .{
        .name = "stats",
        .description = "Show how often each --infer question fires and how many of its answers are unsure; with --thresholds, its precision and recall at each threshold against your labels.",
        .examples = &.{ "zanity stats", "zanity stats --rule cwe-15", "zanity stats --thresholds" },
        .result_title = "Questions",
        .options = &.{
            .{ .name = "rule", .metavar = "RULE", .help = "Show only this question.", .example = "cwe-15" },
            .{ .name = "thresholds", .help = "Measure each labelled question's precision and recall at a range of thresholds." },
        },
    }, .{ .run = calibrate.runStats }) },
};

pub fn main(init: std.process.Init) !u8 {
    const minimal = init.minimal;
    const args = try minimal.args.toSlice(init.arena.allocator());
    if (args.len == 0) std.process.fatal("the process has no arguments, not even its own name; start zanity from a shell or exec, which always pass the program's name", .{});
    var out_buffer: [out_buffer_bytes]u8 = undefined;
    var out_writer: Io.File.Writer = .initStreaming(.stdout(), init.io, &out_buffer);
    var err_buffer: [err_buffer_bytes]u8 = undefined;
    var err_writer: Io.File.Writer = .initStreaming(.stderr(), init.io, &err_buffer);
    const ws = try workspace_init.initWorkspace(Workspace, std.heap.page_allocator, init.io, .{});
    ws.environ = init.environ_map;
    // A copy, so a deprecated flag can be swapped for the one that replaces it.
    const rest = try init.arena.allocator().dupe(@TypeOf(args[0]), args[1..]);
    ws.args = rest;
    if (ws.args.len + 1 != args.len) assert.panic("the workspace holds {d} of {d} arguments; main() must give it all but the program's name", .{ ws.args.len, args.len });
    for (rest) |arg| ws.chose_format = ws.chose_format or std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "--plain");
    for (rest) |*arg| if (renamedFlag(arg.*)) |current| {
        try err_writer.interface.print("zanity: {s} is deprecated and runs as {s}, which runs every rule; write {s} instead.\n", .{ arg.*, current, current });
        arg.* = current;
    };
    var runtime = zclig.native.runtime(init, &out_writer.interface, &err_writer.interface);
    runtime.user_data = ws;
    const code = app.run(init.gpa, rest, runtime);
    if (@backingInt(code) > max_exit_code) assert.panic("zclig returned exit code {d}; codes above 130 collide with signals", .{@backingInt(code)});
    return @backingInt(code);
}
