const std = @import("std");

fn silenced() void {} // zanity: ignore[NASA05]

fn other_code() void {} // zanity: ignore[NASA04]

// zanity: ignore
fn next_line() void {}

fn blanket() void { // zanity: ignore
    while (true) {} // zanity:ignore[NASA02]
}
