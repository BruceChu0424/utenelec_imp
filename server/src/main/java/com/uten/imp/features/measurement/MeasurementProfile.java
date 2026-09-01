package com.uten.imp.features.measurement;

import java.math.BigDecimal;

/** Rebuildable current projection; evidence and decisions remain the authority. */
public record MeasurementProfile(
        MeasurementProfileKey key,
        MeasurementProfileStatus status,
        MeasurementCapturePreference inferredPreference,
        MeasurementCapturePreference manualOverride,
        MeasurementCapturePreference effectivePreference,
        BigDecimal confidence,
        int activeEvidenceCount,
        int quantityDocumentCount,
        int quantityDayCount,
        int quantityAndWeightDocumentCount,
        int quantityAndWeightDayCount,
        boolean inferenceConflict,
        long version) {

    public MeasurementProfile {
        if (key == null || status == null || confidence == null
                || confidence.signum() < 0 || confidence.compareTo(BigDecimal.ONE) > 0
                || activeEvidenceCount < 0 || quantityDocumentCount < 0
                || quantityDayCount < 0 || quantityAndWeightDocumentCount < 0
                || quantityAndWeightDayCount < 0 || version < 0) {
            throw new IllegalArgumentException("measurement profile shape is invalid");
        }
        if (status == MeasurementProfileStatus.CONFIRMED
                && (manualOverride == null || effectivePreference != manualOverride)) {
            throw new IllegalArgumentException("confirmed profile requires manual authority");
        }
        if (status == MeasurementProfileStatus.CONFLICT
                && effectivePreference != null) {
            throw new IllegalArgumentException("unresolved conflict cannot enforce a preference");
        }
    }
}
