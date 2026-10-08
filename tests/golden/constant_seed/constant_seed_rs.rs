use rand::{rngs::StdRng, SeedableRng};

fn configure_randomness() {
    let _rng = StdRng::seed_from_u64(7);
}

fn configure_from_runtime(seed: u64) {
    let _rng = StdRng::seed_from_u64(seed);
}
