//! The line `zanity check` ends with when a newer release is out. The latest release is looked up
//! while the check runs, from GitHub at most once a day, and a finished check waits at most
//! `wait` for the answer, so a slow or missing network never holds it up.
const std = @import("std");
const assert = @import("assert.zig");
const store = @import("store.zig");
const upgrade = @import("upgrade.zig");
const Io = std.Io;

/// How long a finished check waits for GitHub before leaving the notice to a later run.
const wait: Io.Duration = .fromMilliseconds(500);
/// Variables that turn the notice off: CI, where nobody reads it, and the opt-out.
const off_variables = [_][]const u8{ "CI", "ZANITY_NO_UPDATE_NOTIFIER" };

/// GitHub's answer about the latest release, raced against how long a finished check waits for it.
const Race = Io.Select(union(enum) { latest: ?upgrade.Version, waited: Io.Cancelable!void });

pub const Notice = struct {
    race: ?Race = null,
    buffer: [2]Race.Union = undefined,
    dir: [std.fs.max_path_bytes]u8 = undefined,

    /// Starts looking up the latest release, unless `version` is a build from source or the
    /// environment turns the notice off.
    pub fn start(notice: *Notice, io: Io, environ: *const std.process.Environ.Map, version: []const u8) void {
        if (notice.race != null) assert.panic("looking up the latest release twice in one check; start the notice once per check", .{});
        if (version.len == 0) assert.panic("this build reports an empty version; build.zig sets it to dev or the release's", .{});
        if (upgrade.versionOrder(version, version) == null) return;
        for (off_variables) |name| if (environ.get(name)) |value| if (value.len != 0) return;
        const dir = store.cacheDir(&notice.dir, io, environ) catch return;
        notice.race = .init(io, &notice.buffer);
        notice.race.?.async(.latest, upgrade.latestRelease, .{ io, dir, Io.Clock.real.now(io).toSeconds() });
    }

    /// Stops the lookup, when the check ends without showing the notice.
    pub fn cancel(notice: *Notice, io: Io) void {
        const race = if (notice.race) |*race| race else return;
        if (race.io.userdata != io.userdata) assert.panic("cancelling the notice's lookup with Io 0x{x}, but Io 0x{x} started it; pass the check's Io", .{ @intFromPtr(io.userdata), @intFromPtr(race.io.userdata) });
        race.cancelDiscard();
        notice.race = null;
        if (notice.race != null) assert.panic("the notice's lookup outlived its cancellation; cancel() must clear it", .{});
    }

    /// Writes the notice to `w` when GitHub names a release newer than `version` within `wait`.
    pub fn finish(notice: *Notice, io: Io, w: *Io.Writer, version: []const u8) !void {
        const latest = notice.newer(io, version) orelse return;
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const length = std.process.executablePath(io, &path_buffer) catch 0;
        const managed = if (length == 0) null else upgrade.manager(path_buffer[0..length]);
        const command = if (managed) |m| m.command else "zanity upgrade";
        if (upgrade.versionOrder(version, latest.slice()) != .lt) assert.panic("announcing release {s} to zanity {s}, which is not older; newer() must return only a newer release", .{ latest.slice(), version });
        if (notice.race != null) assert.panic("the notice's lookup outlived the notice; newer() must clear it", .{});
        try w.print("zanity {s} is available; you have {s}. Run `{s}` to install it.\n", .{ latest.slice(), version, command });
    }

    /// The release newer than `version` that GitHub named within `wait`, or null.
    fn newer(notice: *Notice, io: Io, version: []const u8) ?upgrade.Version {
        const race = if (notice.race) |*race| race else return null;
        defer notice.race = null;
        if (race.io.userdata != io.userdata) assert.panic("awaiting the notice's lookup with Io 0x{x}, but Io 0x{x} started it; pass the check's Io", .{ @intFromPtr(io.userdata), @intFromPtr(race.io.userdata) });
        race.async(.waited, Io.sleep, .{ io, wait, .awake });
        const first: Race.Union = race.await() catch .{ .waited = {} };
        race.cancelDiscard();
        const latest = switch (first) {
            .latest => |answer| answer orelse return null,
            .waited => return null,
        };
        if (latest.len == 0) assert.panic("GitHub's answer kept an empty version; upgrade.Version.of() must refuse it", .{});
        return if (upgrade.versionOrder(version, latest.slice()) == .lt) latest else null;
    }
};
