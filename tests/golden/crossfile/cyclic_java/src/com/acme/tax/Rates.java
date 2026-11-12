package com.acme.tax;

import com.acme.audit.Log;

public class Rates {
    public static int standard() {
        return Log.count();
    }

    public static int reduced() {
        return 5;
    }
}
