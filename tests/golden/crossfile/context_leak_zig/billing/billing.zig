const ledger = @import("ledger.zig");

pub fn post(amount: u32) u32 {
    return ledger.postEntry(amount);
}
