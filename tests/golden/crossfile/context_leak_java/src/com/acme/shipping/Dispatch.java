package com.acme.shipping;

import com.acme.billing.Ledger;

public class Dispatch {
    public static int dispatch(int cost) {
        return Ledger.postEntry(cost);
    }
}
