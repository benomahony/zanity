package com.acme.cache;

import com.acme.policy.Policy.Kind;

public class Store {
    public Kind kind() {
        return Kind.LRU;
    }
}
