fn forward(x: u32) -> u32 {
    target(x)
}

impl Default for Session {
    fn default() -> Self {
        Self::new()
    }
}
