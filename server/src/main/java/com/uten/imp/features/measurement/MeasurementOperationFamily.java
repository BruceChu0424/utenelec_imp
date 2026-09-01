package com.uten.imp.features.measurement;

import java.util.Locale;

public enum MeasurementOperationFamily {
    PROCUREMENT,
    WAREHOUSE,
    SALES,
    SUBCONTRACT,
    PRODUCTION;

    public static MeasurementOperationFamily parse(String value) {
        try {
            return valueOf(value == null ? "" : value.strip().toUpperCase(Locale.ROOT));
        } catch (IllegalArgumentException ex) {
            throw new IllegalArgumentException("operationFamily is invalid", ex);
        }
    }
}
