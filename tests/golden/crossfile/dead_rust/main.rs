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

struct Unused;

impl Unused {
    pub fn hello(&self) -> u32 {
        1
    }
}

trait Speaker {
    fn speak(&self) -> u32;
}

struct Quiet;

impl Speaker for Quiet {
    fn speak(&self) -> u32 {
        0
    }
}

struct Kept;

impl Kept {
    pub fn size(&self) -> u32 {
        2
    }
}

pub fn make() -> Kept {
    Kept
}
