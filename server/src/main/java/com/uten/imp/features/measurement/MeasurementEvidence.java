package com.uten.imp.features.measurement;

import com.uten.imp.common.util.CanonicalFingerprint;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Locale;
import java.util.Optional;
import java.util.UUID;

/** Immutable reviewed/posted observation or an append-only reversal of one. */
public record MeasurementEvidence(
        UUID eventId,
        MeasurementProfileKey key,
        String idempotencyKey,
        MeasurementEvidenceStage stage,
        String sourceDocumentType,
        UUID sourceDocumentId,
        UUID sourceItemId,
        UUID unitId,
        BigDecimal qty,
        BigDecimal unitRate,
        UUID actualWeightUnitId,
        BigDecimal actualWeight,
        MeasurementCapturePreference declaredPreference,
        boolean weightCaptureAvailable,
        boolean reversible,
        LocalDate businessDate,
        String reversesFingerprint) {

    public MeasurementEvidence {
        if (eventId == null || key == null || stage == null
                || sourceDocumentId == null || sourceItemId == null
                || unitId == null
                || businessDate == null || declaredPreference == null) {
            throw new IllegalArgumentException("measurement evidence identity is incomplete");
        }
        idempotencyKey = normalizeKey(idempotencyKey);
        sourceDocumentType = sourceDocumentType == null
                ? "" : sourceDocumentType.strip().toUpperCase(Locale.ROOT);
        if (!sourceDocumentType.matches("[A-Z0-9_:-]{2,64}")) {
            throw new IllegalArgumentException("sourceDocumentType is invalid");
        }
        if (qty == null || qty.signum() <= 0
                || unitRate == null || unitRate.signum() <= 0) {
            throw new IllegalArgumentException("qty and unitRate must stay positive");
        }
        if ((actualWeight == null) != (actualWeightUnitId == null)
                || (actualWeight != null && actualWeight.signum() <= 0)) {
            throw new IllegalArgumentException(
                    "actualWeight and its unit must be present together and positive");
        }
        if (stage == MeasurementEvidenceStage.REVERSED) {
            if (reversible || reversesFingerprint == null
                    || !reversesFingerprint.matches("[0-9a-f]{64}")) {
                throw new IllegalArgumentException("reversal evidence is invalid");
            }
        } else {
            if (!reversible || reversesFingerprint != null) {
                throw new IllegalArgumentException("reviewed evidence must be reversible");
            }
            if (declaredPreference == MeasurementCapturePreference.QUANTITY_AND_WEIGHT
                    && (!weightCaptureAvailable || actualWeight == null)) {
                throw new IllegalArgumentException(
                        "quantity-and-weight evidence requires captured actual weight");
            }
            if (declaredPreference == MeasurementCapturePreference.QUANTITY
                    && actualWeight != null) {
                throw new IllegalArgumentException(
                        "quantity evidence cannot silently discard captured weight");
            }
        }
    }

    public static MeasurementEvidence reversalOf(
            MeasurementEvidence original,
            UUID reversalEventId,
            String idempotencyKey,
            LocalDate businessDate) {
        if (original == null || original.stage() == MeasurementEvidenceStage.REVERSED) {
            throw new IllegalArgumentException("only an observation can be reversed");
        }
        return new MeasurementEvidence(
                reversalEventId, original.key(), idempotencyKey,
                MeasurementEvidenceStage.REVERSED,
                original.sourceDocumentType(), original.sourceDocumentId(),
                original.sourceItemId(), original.unitId(), original.qty(),
                original.unitRate(), original.actualWeightUnitId(),
                original.actualWeight(), original.declaredPreference(),
                original.weightCaptureAvailable(), false, businessDate,
                original.fingerprint());
    }

    /** Empty weight from a source that cannot capture weight is non-classifying. */
    public Optional<MeasurementCapturePreference> classifyingPreference() {
        if (stage == MeasurementEvidenceStage.REVERSED) return Optional.empty();
        if (declaredPreference == MeasurementCapturePreference.QUANTITY
                && !weightCaptureAvailable) {
            return Optional.empty();
        }
        return Optional.of(declaredPreference);
    }

    public boolean observation() {
        return stage != MeasurementEvidenceStage.REVERSED;
    }

    public String fingerprint() {
        return CanonicalFingerprint.sha256(List.of(
                part("eventId", eventId),
                part("payloadFingerprint", payloadFingerprint())));
    }

    /** Stable business-source identity prevents a second retry key double-counting one fact. */
    public String sourceEventKey() {
        if (stage == MeasurementEvidenceStage.REVERSED) {
            return "REVERSED:" + reversesFingerprint;
        }
        return stage + ":" + sourceDocumentType + ":"
                + sourceDocumentId + ":" + sourceItemId;
    }

    public String payloadFingerprint() {
        return CanonicalFingerprint.sha256(List.of(
                part("goodsId", key.goodsId()),
                part("operationFamily", key.operationFamily()),
                part("stage", stage),
                part("sourceDocumentType", sourceDocumentType),
                part("sourceDocumentId", sourceDocumentId),
                part("sourceItemId", sourceItemId),
                part("unitId", unitId),
                part("qty", decimal(qty)),
                part("unitRate", decimal(unitRate)),
                part("actualWeightUnitId", actualWeightUnitId),
                part("actualWeight", decimal(actualWeight)),
                part("declaredPreference", declaredPreference),
                part("weightCaptureAvailable", weightCaptureAvailable),
                part("reversible", reversible),
                part("businessDate", businessDate),
                part("reversesFingerprint", reversesFingerprint)));
    }

    private static String normalizeKey(String value) {
        String normalized = value == null ? "" : value.strip();
        if (!normalized.matches("[A-Za-z0-9._:-]{8,128}")) {
            throw new IllegalArgumentException("idempotencyKey is invalid");
        }
        return normalized;
    }

    private static String decimal(BigDecimal value) {
        return value == null ? null : value.stripTrailingZeros().toPlainString();
    }

    private static String part(String name, Object value) {
        return name + '=' + (value == null ? "<null>" : value);
    }
}
