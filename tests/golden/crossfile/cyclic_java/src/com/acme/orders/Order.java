package com.acme.orders;

import com.acme.billing.Ledger;

public class Order {
    public int total() {
        return new Ledger().hashCode();
    }
}
