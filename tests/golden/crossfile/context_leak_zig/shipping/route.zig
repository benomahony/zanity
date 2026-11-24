const billing = @import("../billing/billing.zig");

pub fn route(cost: u32) u32 {
    return billing.post(cost);
}
