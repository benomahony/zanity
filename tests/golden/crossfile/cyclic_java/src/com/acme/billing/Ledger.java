package com.acme.billing;

import com.acme.orders.Order;
import com.acme.report.Summary;

public class Ledger {
    public int post(Order order) {
        return Summary.lines() + order.total();
    }
}
