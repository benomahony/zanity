const ledger = @import("../billing/ledger.zig");

pub fn dispatch(cost: u32) u32 {
    return ledger.postEntry(cost);
}
