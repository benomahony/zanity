//! Tests of the edits that fix an ungated release: adding the need on the one job that runs the
//! checks, and requiring that need's success in a condition that lets the job past its failure.
const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const Finding = @import("facts.zig").Finding;
const release = @import("release.zig");

/// Checks `source` and expects its one finding's edit to turn it into `fixed`, or to have no edit
/// when `fixed` is null.
fn expectFixed(source: []const u8, fixed: ?[]const u8) !void {
    if (source.len == 0) assert.panic("checking an empty workflow; give the test a workflow to fix", .{});
    if (fixed) |after| if (std.mem.eql(u8, after, source)) assert.panic("the fixed workflow is the workflow itself, so the test checks no edit; write what --fix should make of it instead of:\n{s}", .{after});
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var findings = try memory.Bounded(Finding).initBounded(arena, 4, "test findings");
    var text = try memory.Text.initText(arena, 1 << 16);
    _ = try release.checkWorkflow(.{ .findings = &findings, .text = &text }, ".github/workflows/release.yml", source, &.{});
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    const edit = findings.items()[0].edit;
    const after = fixed orelse return std.testing.expectEqual(null, edit);
    const made = edit orelse return error.TestExpectedEdit;
    const result = try std.mem.concat(arena, u8, &.{ source[0..made.start], made.replacement, source[made.end..] });
    try std.testing.expectEqualStrings(after, result);
}

test "a job with no needs gets the one job that runs the checks, straight after its key" {
    try expectFixed(
        \\jobs:
        \\  test:
        \\    steps:
        \\      - run: cargo test
        \\  publish:  # ships the crate
        \\    runs-on: ubuntu-latest
        \\    steps:
        \\      - run: cargo publish
    ,
        \\jobs:
        \\  test:
        \\    steps:
        \\      - run: cargo test
        \\  publish:  # ships the crate
        \\    needs: test
        \\    runs-on: ubuntu-latest
        \\    steps:
        \\      - run: cargo publish
    );
}

test "a need is added to an inline value, an inline list and a block list" {
    const build = "  build:\n    steps:\n      - run: make\n  test:\n    steps:\n      - run: cargo test\n";
    try expectFixed("jobs:\n" ++ build ++ "  publish:\n    needs: build  # first\n    steps:\n      - run: cargo publish\n", "jobs:\n" ++ build ++ "  publish:\n    needs: [build, test]  # first\n    steps:\n      - run: cargo publish\n");
    try expectFixed("jobs:\n" ++ build ++ "  publish:\n    needs: [build]\n    steps:\n      - run: cargo publish\n", "jobs:\n" ++ build ++ "  publish:\n    needs: [build, test]\n    steps:\n      - run: cargo publish\n");
    try expectFixed("jobs:\n" ++ build ++ "  publish:\n    needs:\n      - build\n    steps:\n      - run: cargo publish\n", "jobs:\n" ++ build ++ "  publish:\n    needs:\n      - build\n      - test\n    steps:\n      - run: cargo publish\n");
}

test "a failure-tolerant condition requires the need's success, inline, in an expression or quotes, or as a block's last line" {
    const head = "jobs:\n  test:\n    steps:\n      - run: cargo test\n  publish:\n    needs: test\n";
    const tail = "    steps:\n      - run: cargo publish\n";
    try expectFixed(head ++ "    if: always()  # even on failure\n" ++ tail, head ++ "    if: always() && needs.test.result == 'success'  # even on failure\n" ++ tail);
    try expectFixed(head ++ "    if: ${{ always() }}\n" ++ tail, head ++ "    if: ${{ always() && needs.test.result == 'success' }}\n" ++ tail);
    try expectFixed(head ++ "    if: \"always()\"\n" ++ tail, head ++ "    if: \"always() && needs.test.result == 'success'\"\n" ++ tail);
    try expectFixed(head ++ "    if: >-\n      always() &&\n      github.ref_type == 'tag'\n" ++ tail, head ++ "    if: >-\n      always() &&\n      github.ref_type == 'tag'\n      && needs.test.result == 'success'\n" ++ tail);
}

test "no edit where zanity cannot tell which job to need, or cannot write the condition safely" {
    const two = "jobs:\n  lint:\n    steps:\n      - run: ruff check\n  test:\n    steps:\n      - run: pytest\n";
    try expectFixed(two ++ "  publish:\n    steps:\n      - run: uv publish\n", null);
    try expectFixed("jobs:\n  publish:\n    steps:\n      - run: uv publish\n", null);
    try expectFixed("jobs:\n  test:\n    steps:\n      - run: pytest\n  publish:\n    needs: test\n    if: 'always()'\n    steps:\n      - run: uv publish\n", null);
    try expectFixed("jobs:\r\n  test:\r\n    steps:\r\n      - run: pytest\r\n  publish:\r\n    steps:\r\n      - run: uv publish\r\n", null);
}
