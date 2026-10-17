struct Floor {
    level: u32,
}

struct Building {
    floor: Floor,
}

fn describe(building: &Building) -> u32 {
    building.floor.level
}

fn countdown(n: u32) -> u32 {
    if n == 0 { 0 } else { countdown(n - 1) }
}

pub fn start() -> u32 {
    countdown(3)
}
