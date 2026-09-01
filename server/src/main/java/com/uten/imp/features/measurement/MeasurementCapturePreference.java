package com.uten.imp.features.measurement;

/** Collection preference only; it never replaces the authoritative qty ledger. */
public enum MeasurementCapturePreference {
    QUANTITY("BUSINESS_QUANTITY"),
    QUANTITY_AND_WEIGHT("BUSINESS_QUANTITY_AND_ACTUAL_WEIGHT");

    private final String storageCode;

    MeasurementCapturePreference(String storageCode) {
        this.storageCode = storageCode;
    }

    public String storageCode() {
        return storageCode;
    }

    public static MeasurementCapturePreference fromStorageCode(String value) {
        for (MeasurementCapturePreference preference : values()) {
            if (preference.storageCode.equals(value)) return preference;
        }
        throw new IllegalArgumentException("unknown measurement capture preference");
    }
}
