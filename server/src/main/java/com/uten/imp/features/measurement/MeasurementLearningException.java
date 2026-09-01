package com.uten.imp.features.measurement;

public final class MeasurementLearningException extends RuntimeException {

    public enum Code {
        VERSION_CONFLICT,
        IDEMPOTENCY_CONFLICT,
        INVALID_REVERSAL,
        DECISION_INVALID
    }

    private final Code code;

    public MeasurementLearningException(Code code, String message) {
        super(message);
        this.code = code;
    }

    public Code code() {
        return code;
    }
}
