fn reserve(size: usize) {
    Vec::with_capacity(size);
}

fn fixed(size: usize) {
    Vec::with_capacity(4096);
}

fn bounded(size: usize) {
    let bounded_size = size.min(4096);
    Vec::with_capacity(bounded_size);
}
