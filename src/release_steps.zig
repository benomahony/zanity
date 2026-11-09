//! What counts as a step releasing or deploying: a command or action that publishes a release or a
//! package, or one that deploys, and the environments that are production.
const std = @import("std");
const assert = @import("assert.zig");
const strings = @import("strings.zig");

/// Commands that publish a release or a package, lowercased.
const release_commands = [_][]const u8{ "gh release create", "npm publish", "pnpm publish", "pnpm -r publish", "yarn publish", "yarn npm publish", "lerna publish", "changeset publish", "cargo publish", "uv publish", "twine upload", "poetry publish", "flit publish", "hatch publish", "gem push", "docker push", "goreleaser release", "mvn deploy", "gradle publish", "gradlew publish", "dotnet nuget push", "nuget push", "semantic-release", "vsce publish", "helm push", "mix hex.publish", "swift package-registry publish" };
/// The action that builds an image and publishes it only when its `with:` sets `push`.
pub const image_action = "docker/build-push-action";
/// Actions that publish a release or a package, lowercased, without the version.
const release_actions = [_][]const u8{ "softprops/action-gh-release", "ncipollo/release-action", "actions/create-release", "marvinpinto/action-automatic-releases", "goreleaser/goreleaser-action", "pypa/gh-action-pypi-publish", "js-devtools/npm-publish", "changesets/action", "katyo/publish-crates", "googleapis/release-please-action", "google-github-actions/release-please-action", "cycjimmy/semantic-release-action" };

/// Commands that deploy, lowercased.
const deploy_commands = [_][]const u8{ "kubectl apply", "helm upgrade", "terraform apply" };
/// Actions that deploy, lowercased, without the version.
const deploy_actions = [_][]const u8{ "actions/deploy-pages", "aws-actions/amazon-ecs-deploy-task-definition", "azure/webapps-deploy", "google-github-actions/deploy-cloudrun" };
/// Environment names that mean production, lowercased.
const production_environments = [_][]const u8{ "production", "prod" };

/// What a step can ship: a release or package, or a deployment.
pub const Ships = enum { release, deployment };

/// Whether `action`, a step's `uses:` lowercased without its version, ships `what`.
pub fn shipsAction(what: Ships, action: []const u8) bool {
    if (std.mem.indexOfScalar(u8, action, '@') != null) assert.panic("'{s}' still has its version; drop everything from '@' before asking whether it ships a {s}", .{ action, @tagName(what) });
    if (std.mem.indexOfScalar(u8, action, '\n') != null) assert.panic("'{s}' spans lines, but a step's uses: value is one line", .{action});
    return strings.contains(switch (what) {
        .release => &release_actions,
        .deployment => &deploy_actions,
    }, action);
}

/// Whether `text`, a command line lowercased with its quotes blanked, runs a command that ships `what`.
pub fn shipsCommand(what: Ships, text: []const u8) bool {
    if (std.mem.indexOfAny(u8, text, "\"'") != null) assert.panic("'{s}' still has quotes; unquote() a command before asking whether it ships a {s}", .{ text, @tagName(what) });
    const commands: []const []const u8 = switch (what) {
        .release => &release_commands,
        .deployment => &deploy_commands,
    };
    if (commands.len == 0) assert.panic("no {s} commands are listed, so '{s}' could match none; list them", .{ @tagName(what), text });
    for (commands) |listed| if (startsCommand(text, listed)) return true;
    return false;
}

/// Whether a job's `environment:` name is production.
pub fn productionEnvironment(name: []const u8) bool {
    if (std.mem.indexOfScalar(u8, name, '\n') != null) assert.panic("the environment name '{s}' spans lines, but it is read from one line", .{name});
    if (production_environments.len == 0) assert.panic("no production environment names are listed; list them in production_environments", .{});
    for (production_environments) |listed| if (std.ascii.eqlIgnoreCase(name, listed)) return true;
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
