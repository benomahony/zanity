fn make<T>() -> T {
    unsafe { std::mem::uninitialized() }
}

fn make_supported<T>() -> std::mem::MaybeUninit<T> {
    std::mem::MaybeUninit::uninit()
}

fn unrelated(memory: Memory) {
    memory.uninitialized();
}
