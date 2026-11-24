package com.acme.billing;

public class Billing {
    public static int post(int amount) {
        return Ledger.postEntry(amount);
    }
}
