//! `zanity upgrade`: fetches a release, checks it, replaces this executable with it, and reports
//! what changed; with --dry-run, only what would.
const std = @import("std");
const assert = @import("assert.zig");
const zclig = @import("zclig");
const upgrade = @import("upgrade.zig");
const workspace = @import("workspace.zig");
const Workspace = workspace.Workspace;
const workspaceOf = workspace.workspaceOf;
const console = workspace.console;
/// This build's version, as `zanity --version` prints it.
const build_version = @import("build_info").version;

pub const UpgradeOptions = struct {
    to: ?[]const u8 = null,
};

pub const UpgradeRow = @import("rows.zig").UpgradeRow;

pub fn runUpgrade(ctx: *zclig.Context, options: UpgradeOptions) ![]const UpgradeRow {
    const rows = try upgradeTo(ctx, options, true);
    if (std.mem.eql(u8, rows[0].status, "available")) assert.panic("zanity upgrade left release {s} available instead of installing it; call upgradeTo() with install enabled", .{rows[0].to});
    if (rows.len != 1) assert.panic("zanity upgrade reported {d} executables; upgradeTo() replaces exactly one", .{rows.len});
    return rows;
}

pub fn previewUpgrade(ctx: *zclig.Context, options: UpgradeOptions) ![]const UpgradeRow {
    const rows = try upgradeTo(ctx, options, false);
    if (std.mem.eql(u8, rows[0].status, "upgraded")) assert.panic("zanity upgrade --dry-run installed release {s}; call upgradeTo() with install disabled", .{rows[0].to});
    if (rows.len != 1) assert.panic("zanity upgrade --dry-run reported {d} executables; upgradeTo() previews exactly one", .{rows.len});
    return rows;
}

/// The release a run of `zanity upgrade` fetches and installs, and what it reports failures through.
const Upgrader = struct {
    ctx: *zclig.Context,
    ws: *Workspace,
    client: std.http.Client,
};

/// Finds the release to install and, when `install` is set and it differs from this build, puts it
/// in place of the running executable.
fn upgradeTo(ctx: *zclig.Context, options: UpgradeOptions, install: bool) ![]const UpgradeRow {
    const ws = workspaceOf(ctx);
    const current = build_version;
    if (current.len == 0) assert.panic("this build reports an empty version; build.zig sets it to dev or the release's", .{});
    const path = std.process.executablePathAlloc(ws.io, ctx.allocator) catch |e| {
        return ctx.fail(.io, try ws.text.format("Could not find where this zanity is installed: {t}.", .{e}), "Reinstall it with install.sh, as the README describes.");
    };
    if (upgrade.manager(path)) |m| return ctx.fail(.usage, try ws.text.format("{s} was installed by {s}, which would undo an upgrade made behind its back.", .{ path, m.name }), try ws.text.format("Run `{s}` instead.", .{m.command}));
    if (options.to) |to| if (upgrade.versionOrder(to, to) == null) {
        return ctx.fail(.usage, try ws.text.format("--to '{s}' is not a release version.", .{to}), "Pass one such as --to 0.1.4; the releases are listed at " ++ upgrade.releases_url ++ ".");
    };
    if (options.to == null and upgrade.versionOrder(current, "0.0.0") == null) {
        return ctx.fail(.usage, try ws.text.format("This zanity is a {s} build from source, so no release is newer or older than it.", .{current}), "Rebuild it with `zig build`, or pass --to 0.1.4 to replace it with that release.");
    }
    var up: Upgrader = .{ .ctx = ctx, .ws = ws, .client = .{ .allocator = ctx.allocator, .io = ws.io } };
    defer up.client.deinit();
    const release = try fetchRelease(&up, options.to);
    const asset = release.assetFor(upgrade.asset_name) orelse {
        return ctx.fail(.usage, try ws.text.format("Release {s} has no {s}, the build for this machine.", .{ release.tag_name, upgrade.asset_name }), "Pick another release from " ++ upgrade.releases_url ++ ", or build from source as the README describes.");
    };
    const order = upgrade.versionOrder(current, release.tag_name);
    const wanted = if (options.to != null) order != .eq else order == .lt;
    ws.upgrade_row[0] = .{ .path = path, .from = current, .to = release.tag_name, .status = if (!wanted) "current" else if (install) "upgraded" else "available" };
    if (wanted and install) try replaceExecutable(&up, path, asset);
    if (wanted == std.mem.eql(u8, ws.upgrade_row[0].status, "current")) assert.panic("zanity upgrade reports {s} for release {s}, which it {s}", .{ ws.upgrade_row[0].status, release.tag_name, if (wanted) "wanted" else "did not want" });
    return &ws.upgrade_row;
}

/// Asks GitHub's API about the latest release, or `version`'s.
fn fetchRelease(up: *Upgrader, version: ?[]const u8) !upgrade.Release {
    const ctx = up.ctx;
    const ws = up.ws;
    if (version) |v| if (v.len == 0) assert.panic("zanity upgrade --to was given an empty version; upgradeTo() refuses one that is not a version", .{});
    const environ = ws.environ orelse assert.panic("zanity upgrade ran without the environment; main() passes it to the workspace", .{});
    const token = environ.get("GITHUB_TOKEN") orelse environ.get("GH_TOKEN");
    var url_buffer: [256]u8 = undefined;
    var url: std.Io.Writer = .fixed(&url_buffer);
    var body: std.Io.Writer.Allocating = .init(ctx.allocator);
    const status = upgrade.downloadInto(&up.client, try upgrade.releaseUrl(&url, version), &body, if (token) |t| (if (t.len == 0 or std.mem.indexOfAny(u8, t, "\r\n") != null) null else t) else null) catch |e| {
        return ctx.fail(.io, try ws.text.format("Could not reach GitHub to find the release: {t}.", .{e}), "Check the network connection, then run zanity upgrade again.");
    };
    switch (status) {
        .ok => {},
        .not_found => return ctx.fail(.usage, try ws.text.format("There is no release v{s}.", .{upgrade.trimV(version orelse "latest")}), "Pick a version from " ++ upgrade.releases_url ++ "."),
        .forbidden, .too_many_requests => return ctx.fail(.io, "GitHub refused the request, most likely by its rate limit for unauthenticated clients.", "Set GITHUB_TOKEN to a GitHub token, or wait an hour and run zanity upgrade again."),
        else => return ctx.fail(.io, try ws.text.format("GitHub answered {d} when asked for the release.", .{@backingInt(status)}), "Run zanity upgrade again; if it persists, check https://www.githubstatus.com."),
    }
    const release = upgrade.parseRelease(ctx.allocator, body.written()) catch |e| {
        return ctx.fail(.io, try ws.text.format("Could not read GitHub's description of the release: {t}.", .{e}), "Run zanity upgrade again, and report it if it happens twice.");
    };
    if (version) |v| if (upgrade.versionOrder(v, release.tag_name)) |order| if (order != .eq) {
        return ctx.fail(.io, try ws.text.format("GitHub answered the request for v{s} with release {s}.", .{ upgrade.trimV(v), release.tag_name }), "Run zanity upgrade again, and report it if it happens twice.");
    };
    if (release.tag_name.len == 0) assert.panic("parseRelease() returned an empty tag, though it refuses anything but a version; restore that refusal", .{});
    return release;
}

/// Downloads `asset`, checks it against the SHA-256 GitHub records, and puts it at `path`.
fn replaceExecutable(up: *Upgrader, path: []const u8, asset: upgrade.Release.Asset) !void {
    const ctx = up.ctx;
    const ws = up.ws;
    if (path.len == 0) assert.panic("replacing an executable with no path by {s}; upgradeTo() passes the running one's", .{asset.name});
    const digest = asset.digest orelse {
        return ctx.fail(.usage, try ws.text.format("The release lists no SHA-256 for {s}, so its download cannot be checked.", .{asset.name}), "Download it from " ++ upgrade.releases_url ++ " and check it yourself, or install with install.sh.");
    };
    var body: std.Io.Writer.Allocating = .init(ctx.allocator);
    const status = upgrade.downloadInto(&up.client, asset.browser_download_url, &body, null) catch |e| {
        return ctx.fail(.io, try ws.text.format("Could not download {s}: {t}.", .{ asset.browser_download_url, e }), "Check the network connection, then run zanity upgrade again.");
    };
    if (status != .ok) return ctx.fail(.io, try ws.text.format("GitHub answered {d} to the download of {s}.", .{ @backingInt(status), asset.browser_download_url }), "Run zanity upgrade again; this zanity is unchanged.");
    const bytes = body.written();
    if (!upgrade.matches(bytes, digest)) {
        return ctx.fail(.io, try ws.text.format("The {d}-byte download of {s} does not hash to the release's {s}.", .{ bytes.len, asset.name, digest }), "Run zanity upgrade again; this zanity is unchanged. Report it if it happens twice.");
    }
    upgrade.replace(ws.io, path, bytes) catch |e| {
        return ctx.fail(.io, try ws.text.format("Could not replace {s}: {t}.", .{ path, e }), "Check that you can write to its directory; if it was installed as root, run the upgrade as root too.");
    };
    if (bytes.len == 0) assert.panic("installed an empty {s}; upgrade.matches() must refuse a download that does not hash to {s}", .{ asset.name, digest });
}

pub fn renderUpgrade(ctx: *zclig.Context, rows: []const UpgradeRow) !void {
    if (rows.len != 1) assert.panic("zanity upgrade reported {d} executables; upgradeTo() replaces exactly one", .{rows.len});
    const row = rows[0];
    const out = console(ctx, ctx.runtime.out);
    if (std.mem.eql(u8, row.status, "current")) {
        try out.writer.print("zanity {s} at {s} is already release {s}; there is nothing to upgrade.\n", .{ row.from, row.path, row.to });
    } else if (std.mem.eql(u8, row.status, "available")) {
        try out.writer.print("zanity {s} at {s} would become {s}. Run `zanity upgrade` to install it.\n", .{ row.from, row.path, row.to });
    } else {
        try out.writer.print("Upgraded zanity {s} to {s} at {s}.\n", .{ row.from, row.to, row.path });
    }
    if (row.path.len == 0) assert.panic("zanity upgrade reported no executable path; upgradeTo() must pass the path it found", .{});
}
