//! What counts as a step releasing: a command that publishes a release or a package, or an action
//! that does.
const std = @import("std");
const assert = @import("assert.zig");
const strings = @import("strings.zig");

/// Commands that publish a release or a package, lowercased.
const release_commands = [_][]const u8{ "gh release create", "npm publish", "pnpm publish", "pnpm -r publish", "yarn publish", "yarn npm publish", "lerna publish", "changeset publish", "cargo publish", "uv publish", "twine upload", "poetry publish", "flit publish", "hatch publish", "gem push", "docker push", "goreleaser release", "mvn deploy", "gradle publish", "gradlew publish", "dotnet nuget push", "nuget push", "semantic-release", "vsce publish", "helm push", "mix hex.publish", "swift package-registry publish" };
/// The action that builds an image and publishes it only when its `with:` sets `push`.
pub const image_action = "docker/build-push-action";
/// Actions that publish a release or a package, lowercased, without the version.
const release_actions = [_][]const u8{ "softprops/action-gh-release", "ncipollo/release-action", "actions/create-release", "marvinpinto/action-automatic-releases", "goreleaser/goreleaser-action", "pypa/gh-action-pypi-publish", "js-devtools/npm-publish", "changesets/action", "katyo/publish-crates", "googleapis/release-please-action", "google-github-actions/release-please-action", "cycjimmy/semantic-release-action" };

/// Whether `action`, a step's `uses:` lowercased without its version, publishes a release.
pub fn releaseAction(action: []const u8) bool {
    if (std.mem.indexOfScalar(u8, action, '@') != null) assert.panic("'{s}' still has its version; drop everything from '@' before asking whether it releases", .{action});
    if (std.mem.indexOfScalar(u8, action, '\n') != null) assert.panic("'{s}' spans lines, but a step's uses: value is one line", .{action});
    return strings.contains(&release_actions, action);
}

/// The release command `text`, a command line lowercased with its quotes blanked, runs, if any.
pub fn releaseCommand(text: []const u8) bool {
    if (std.mem.indexOfAny(u8, text, "\"'") != null) assert.panic("'{s}' still has quotes; unquote() a command before asking whether it releases", .{text});
    if (release_commands.len == 0) assert.panic("no release commands are listed, so no command could release; list them in release_commands", .{});
    for (release_commands) |release| if (startsCommand(text, release)) return true;
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
