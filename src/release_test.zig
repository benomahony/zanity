//! Tests of the release gate on workflows written out in full: a release job with no tests before
//! it, with the tests in a job it needs, after always(), and after a successful workflow run.
const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const Finding = @import("facts.zig").Finding;
const release = @import("release.zig");
const checkWorkflow = release.checkWorkflow;

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
