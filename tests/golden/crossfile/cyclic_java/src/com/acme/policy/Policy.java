package com.acme.policy;

import com.acme.cache.Store;

public class Policy {
    public enum Kind { LRU, FIFO }

    public Kind of(Store store) {
        return store.kind();
    }
}
