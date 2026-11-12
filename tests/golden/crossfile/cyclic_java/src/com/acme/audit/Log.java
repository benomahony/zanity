package com.acme.audit;

import static com.acme.tax.Rates.standard;
import static com.acme.tax.Rates.reduced;

public class Log {
    public static int count() {
        return standard() + reduced();
    }
}
