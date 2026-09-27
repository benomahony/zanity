const std = @import("std");

fn silenced() void {} // nasa: ignore[NASA05]

fn other_code() void {} // nasa: ignore[NASA04]

// nasa: ignore
fn next_line() void {}

fn blanket() void { // nasa: ignore
    while (true) {} // nasa:ignore[NASA02]
}
