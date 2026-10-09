//! `zanity upgrade`: replaces the running zanity with a GitHub release, checked against the SHA-256
//! GitHub records for it, as install.sh does. With --infer, it is the only part of zanity that
//! uses the network.
const std = @import("std");
const builtin = @import("builtin");
const assert = @import("assert.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const repo = "benomahony/zanity";
pub const releases_url = "https://github.com/" ++ repo ++ "/releases";
/// The release file built for this machine, named as `zig build release` names it.
pub const asset_name = "zanity-" ++ @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.cpu.arch) ++ builtin.os.tag.exeFileExt(builtin.cpu.arch);
/// Larger than any release binary, so a runaway download stops instead of filling memory.
const max_binary_bytes = 256 * 1024 * 1024;
const max_release_bytes = 1024 * 1024;

/// What GitHub's API says about a release, keeping only the fields an upgrade reads.
pub const Release = struct {
    tag_name: []const u8,
    assets: []const Asset = &.{},

    pub const Asset = struct {
        name: []const u8,
        browser_download_url: []const u8,
        size: u64 = 0,
        /// `sha256:<hex>`, which GitHub computes for each file it hosts.
        digest: ?[]const u8 = null,
    };

    /// The file built for this machine, if the release has one.
    pub fn assetFor(release: Release, name: []const u8) ?Asset {
        if (name.len == 0) assert.panic("looked for an unnamed asset in release {s}; pass upgrade.asset_name", .{release.tag_name});
        const found = for (release.assets) |asset| {
            if (std.mem.eql(u8, asset.name, name)) break asset;
        } else null;
        if (found != null and release.assets.len == 0) assert.panic("found {s} in release {s}, which has no assets", .{ name, release.tag_name });
        return found;
    }
};

/// Reads GitHub's description of a release; a tag without a version is not one zanity made.
pub fn parseRelease(arena: Allocator, json: []const u8) !Release {
    if (json.len == 0) return error.EmptyRelease;
    if (json.len > max_release_bytes) return error.StreamTooLong;
    var release = try std.json.parseFromSliceLeaky(Release, arena, json, .{ .ignore_unknown_fields = true });
    release.tag_name = trimV(release.tag_name);
    if (parseVersion(release.tag_name) == null) return error.NotAVersion;
    if (release.tag_name.len == 0) assert.panic("release with an empty version passed parseVersion(); it must refuse an empty string", .{});
    if (release.tag_name[0] == 'v') assert.panic("release version '{s}' still starts with v; trimV() must remove it", .{release.tag_name});
    return release;
}

/// A version without the `v` its tag starts with.
pub fn trimV(version: []const u8) []const u8 {
    const trimmed = if (std.mem.startsWith(u8, version, "v")) version[1..] else version;
    if (trimmed.len + 1 < version.len) assert.panic("trimmed '{s}' to '{s}'; trimV() removes at most one character", .{ version, trimmed });
    if (!std.mem.endsWith(u8, version, trimmed)) assert.panic("trimmed '{s}' to '{s}', which it does not end with", .{ version, trimmed });
    return trimmed;
}

/// Orders two `major.minor.patch` versions; null when either is not one, such as a `dev` build.
pub fn versionOrder(a: []const u8, b: []const u8) ?std.math.Order {
    const x = parseVersion(trimV(a)) orelse return null;
    const y = parseVersion(trimV(b)) orelse return null;
    const order = for (x, y) |p, q| {
        if (p != q) break std.math.order(p, q);
    } else .eq;
    if (order != .eq and std.mem.eql(u8, trimV(a), trimV(b))) assert.panic("compared {s} with itself as {t}", .{ a, order });
    if ((order == .eq) != std.mem.eql(u32, &x, &y)) assert.panic("compared {s} and {s} as {t}; versions are equal exactly when every part is", .{ a, b, order });
    return order;
}

fn parseVersion(text: []const u8) ?[3]u32 {
    if (std.mem.count(u8, text, ".") != 2) return null;
    var parts: [3]u32 = undefined;
    var it = std.mem.splitScalar(u8, text, '.');
    for (&parts) |*part| {
        const piece = it.next();
        if (piece == null) assert.panic("'{s}' has two dots but fewer than three parts", .{text});
        part.* = std.fmt.parseInt(u32, piece.?, 10) catch return null;
    }
    const rest = it.next();
    if (rest != null) assert.panic("'{s}' has two dots but more than three parts", .{text});
    return parts;
}

/// The API address for `version`'s release, or for the latest when it is null.
pub fn releaseUrl(text: *std.Io.Writer, version: ?[]const u8) ![]const u8 {
    const api = "https://api.github.com/repos/" ++ repo ++ "/releases/";
    if (text.end != 0) assert.panic("writing a release URL after {d} bytes; pass an empty writer", .{text.end});
    if (version) |v| try text.print(api ++ "tags/v{s}", .{trimV(v)}) else try text.writeAll(api ++ "latest");
    if (!std.mem.startsWith(u8, text.buffered(), api)) assert.panic("built release URL '{s}' outside {s}; write into an empty writer", .{ text.buffered(), api });
    return text.buffered();
}

/// Whether `bytes` hash to `digest`, GitHub's `sha256:<hex>`.
pub fn matches(bytes: []const u8, digest: []const u8) bool {
    const prefix = "sha256:";
    if (!std.mem.startsWith(u8, digest, prefix)) return false;
    if (bytes.len > max_binary_bytes) assert.panic("hashing a {d}-byte download, past the {d} get() allows", .{ bytes.len, max_binary_bytes });
    var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const hex = std.fmt.bytesToHex(hash, .lower);
    if (hex.len != 2 * hash.len) assert.panic("a SHA-256 is {d} hex digits, not {d}", .{ 2 * hash.len, hex.len });
    return std.ascii.eqlIgnoreCase(digest[prefix.len..], &hex);
}

/// The package manager that owns `path`, which an upgrade must leave to it, or null.
pub fn manager(path: []const u8) ?Manager {
    if (path.len == 0) assert.panic("asked who manages an empty path; pass the running executable's path", .{});
    const found = for (managers) |m| {
        if (std.mem.indexOf(u8, path, m.marker) != null) break m;
    } else null;
    if (found) |m| if (m.command.len == 0) assert.panic("{s} has no upgrade command to suggest; add it to upgrade.managers", .{m.name});
    return found;
}

pub const Manager = struct { marker: []const u8, name: []const u8, command: []const u8 };

const managers = [_]Manager{
    .{ .marker = "/mise/installs/", .name = "mise", .command = "mise upgrade github:" ++ repo },
    .{ .marker = "/Cellar/", .name = "Homebrew", .command = "brew upgrade zanity" },
    .{ .marker = "/.cache/pre-commit/", .name = "pre-commit", .command = "pre-commit autoupdate" },
};

/// GETs `url` into `out`, sending GitHub's API headers and, when given, a token for its rate limit.
pub fn get(client: *std.http.Client, url: []const u8, out: *Io.Writer.Allocating, token: ?[]const u8) !std.http.Status {
    if (url.len == 0) assert.panic("fetching an empty URL; build it with releaseUrl() or take it from the release", .{});
    var authorization: [512]u8 = undefined;
    const bearer: std.http.Client.Request.Headers.Value = if (token) |t| .{ .override = try std.fmt.bufPrint(&authorization, "Bearer {s}", .{t}) } else .default;
    // std.http drops privileged_headers without sending them, so the token goes in the
    // authorization header, which a redirect would carry to any host; a request with a token
    // therefore follows no redirect, as GitHub's API needs none.
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &out.writer,
        .headers = .{ .user_agent = .{ .override = "zanity-upgrade" }, .authorization = bearer },
        .extra_headers = &.{.{ .name = "accept", .value = "application/vnd.github+json, application/octet-stream" }},
        .redirect_behavior = if (token == null) null else .not_allowed,
    });
    if (out.written().len > max_binary_bytes) return error.StreamTooLong;
    if ((bearer == .override) != (token != null)) assert.panic("sending {t} authorization with {s} token for {s}", .{ bearer, if (token == null) "no" else "a", url });
    return result.status;
}

/// Puts `bytes` in place of the executable at `path`, keeping it executable. Windows cannot
/// overwrite a running program but can rename it, so there the old one moves aside first.
pub fn replace(io: Io, path: []const u8, bytes: []const u8) !void {
    if (bytes.len == 0) assert.panic("replacing {s} with an empty file; the download must be checked first", .{path});
    const cwd = Io.Dir.cwd();
    const permissions = (try cwd.statFile(io, path, .{})).permissions;
    if (builtin.os.tag == .windows) {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const old = try std.fmt.bufPrint(&buffer, "{s}.old", .{path});
        cwd.deleteFile(io, old) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
        try cwd.rename(path, cwd, old, io);
    }
    var atomic = try cwd.createFileAtomic(io, path, .{ .permissions = permissions, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
    const written = try cwd.statFile(io, path, .{});
    if (written.size != bytes.len) assert.panic("wrote {d} bytes to {s} but it holds {d}", .{ bytes.len, path, written.size });
}

test "the asset name matches a release platform" {
    try std.testing.expect(std.mem.startsWith(u8, asset_name, "zanity-"));
    try std.testing.expect(std.mem.indexOfScalar(u8, asset_name, '-') != std.mem.lastIndexOfScalar(u8, asset_name, '-'));
}

test "versions compare numerically, with or without v, and dev builds don't compare" {
    try std.testing.expectEqual(std.math.Order.lt, versionOrder("0.1.9", "v0.1.10").?);
    try std.testing.expectEqual(std.math.Order.gt, versionOrder("v1.0.0", "0.9.9").?);
    try std.testing.expectEqual(std.math.Order.eq, versionOrder("v0.1.4", "0.1.4").?);
    try std.testing.expectEqual(null, versionOrder("dev", "0.1.4"));
    try std.testing.expectEqual(null, versionOrder("0.1", "0.1.4"));
    try std.testing.expectEqual(null, versionOrder("0.1.4.1", "0.1.4"));
}

test "a release's asset and version come from GitHub's JSON" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const release = try parseRelease(arena.allocator(),
        \\{"tag_name":"v0.1.4","draft":false,"assets":[
        \\{"name":"zanity-linux-x86_64","size":3,"digest":"sha256:ab","browser_download_url":"https://x/a"},
        \\{"name":"zanity-windows-x86_64.exe","size":4,"browser_download_url":"https://x/b"}]}
    );
    try std.testing.expectEqualStrings("0.1.4", release.tag_name);
    try std.testing.expectEqualStrings("https://x/a", release.assetFor("zanity-linux-x86_64").?.browser_download_url);
    try std.testing.expectEqual(null, release.assetFor("zanity-windows-x86_64.exe").?.digest);
    try std.testing.expectEqual(null, release.assetFor("zanity-plan9-x86_64"));
}

test "a tag that is not a version is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.NotAVersion, parseRelease(arena.allocator(), "{\"tag_name\":\"nightly\"}"));
}

test "the download must hash to the release's digest" {
    const digest = "sha256:2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824";
    try std.testing.expect(matches("hello", digest));
    try std.testing.expect(!matches("hello!", digest));
    try std.testing.expect(!matches("hello", digest[7..]));
}

test "a package manager's install is left to it" {
    try std.testing.expectEqualStrings("mise", manager("/Users/me/.local/share/mise/installs/github-benomahony-zanity/0.1.4/zanity").?.name);
    try std.testing.expectEqualStrings("Homebrew", manager("/opt/homebrew/Cellar/zanity/0.1.4/bin/zanity").?.name);
    try std.testing.expectEqual(null, manager("/Users/me/.local/bin/zanity"));
}

test "release URLs name the tag or the latest" {
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectEqualStrings("https://api.github.com/repos/benomahony/zanity/releases/tags/v0.1.4", try releaseUrl(&w, "v0.1.4"));
    w = .fixed(&buffer);
    try std.testing.expectEqualStrings("https://api.github.com/repos/benomahony/zanity/releases/latest", try releaseUrl(&w, null));
}
