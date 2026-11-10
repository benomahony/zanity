//! The end-to-end tests `zig build test-integration` runs against the built zanity: the golden
//! fixtures, the command line, the language server, --fix and zanity checking its own source.
test {
    _ = @import("golden_test.zig");
    _ = @import("baseline_test.zig");
    _ = @import("infer_test.zig");
    _ = @import("lsp_test.zig");
    _ = @import("fix_test.zig");
    _ = @import("agent_test.zig");
}
