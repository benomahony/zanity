package com.acme.shipping;

import com.acme.billing.Billing;

public class Route {
    public static int route(int cost) {
        return Billing.post(cost);
    }
}
